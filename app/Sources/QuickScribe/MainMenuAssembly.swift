import AppKit
import QuickScribeCore

/// Everything the menu bar menu says, in one place that can be built and read
/// without an app or a menu bar. The person's mode and the two model choices
/// come in as plain values; the class turns them into the three submenus the
/// owner approved.
@MainActor
final class MainMenuAssembly: NSObject, NSMenuDelegate {
    /// What the menu is built from, read once when it opens. A value: a menu
    /// already on screen cannot change underneath the person reading it.
    struct State {
        var hotkeysOff: Bool
        var cleanupProblem: String?
        var recording: Bool
        var profile: String
        var snapshot: MenuModelStore.Snapshot
        var updateVersion: String?
        /// The chosen server model names, so a title can show a model the
        /// service no longer lists.
        var speechModel: String
        var cleanupModel: String
    }

    /// Callbacks into the app. Kept as closures so tests can watch what a click
    /// would do without an application.
    struct Actions {
        var selectProfile: (String) -> Void
        var chooseApple: (String) -> Void          // the route's label
        var chooseModel: (String, String) -> Void  // (label, model)
        var toggleHandsFree: () -> Void
        var openAccessibility: () -> Void
        var openReleasePage: () -> Void
        var showSettings: () -> Void
        var refreshModels: () -> Void
        // The menu was opened or closed. The app tracks this so a refresh that
        // lands mid-read rebuilds on close instead of under the reader.
        var menuDidOpen: () -> Void
        var menuDidClose: () -> Void
    }

    var actions: Actions?
    private(set) var builtState: State?
    private(set) var builtMenu: NSMenu?

    /// The menu shown right now. `build` is called by the app when anything it
    /// displays changes; the result is what the person sees.
    func build(_ state: State) -> NSMenu {
        builtState = state
        let menu = NSMenu()

        if state.hotkeysOff {
            let dead = NSMenuItem(title: "⚠ Hotkeys off: grant Accessibility",
                                  action: #selector(openAccessibilityTapped), keyEquivalent: "")
            dead.target = self
            menu.addItem(dead)
        }

        if let problem = state.cleanupProblem {
            let item = NSMenuItem(title: "⚠ \(problem) Dictation still works, without AI cleanup.",
                                  action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        let how = NSMenuItem(title: "Hold \(AppInfo.holdLabel) to talk, release to insert", action: nil, keyEquivalent: "")
        how.isEnabled = false
        menu.addItem(how)

        let toggle = NSMenuItem(title: state.recording ? "Stop Recording (hands-free)" : "Start Recording (hands-free)",
                                action: #selector(handsFreeTapped), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        menu.addItem(modeItem(profile: state.profile))
        menu.addItem(modelItem(label: MainMenuBuilder.speechLabel,
                               apple: state.snapshot.speechIsApple,
                               chosen: state.speechModel,
                               route: state.snapshot.speech))
        menu.addItem(modelItem(label: MainMenuBuilder.cleanupLabel,
                               apple: state.snapshot.cleanupIsApple,
                               chosen: state.cleanupModel,
                               route: state.snapshot.cleanup))

        if let version = state.updateVersion {
            let item = NSMenuItem(title: "Update available: version \(version)",
                                  action: #selector(releasePageTapped), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(settingsTapped), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit \(AppInfo.displayName)", action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        menu.addItem(quit)

        menu.delegate = self
        builtMenu = menu
        return menu
    }

    /// The title a model submenu shows: the person's choice, never anything
    /// else. Apple Native when Apple is the route's choice.
    static func choiceName(_ apple: Bool, _ chosen: String) -> String {
        if apple { return MenuModelStore.appleNative }
        return chosen.isEmpty ? MenuModelStore.appleNative : chosen
    }

    private func modeItem(profile: String) -> NSMenuItem {
        let item = NSMenuItem(title: MainMenuBuilder.title(MainMenuBuilder.modeLabel,
                                                           RefineMode.title(forProfile: profile)),
                              action: nil, keyEquivalent: "")
        item.submenu = modeSubmenu(profile: profile)
        return item
    }

    private func modelItem(label: String, apple: Bool, chosen: String,
                           route: MenuModelStore.Route) -> NSMenuItem {
        let title = MainMenuBuilder.title(label, Self.choiceName(apple, chosen))
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = modelSubmenu(label: label, route: route, chooseApple: apple, chosen: chosen)
        return item
    }

    /// The Mode submenu: the three everyday modes and Rewrite, each with its
    /// keyboard gesture in the title, a checkmark on the one in effect.
    func modeSubmenu(profile: String) -> NSMenu {
        let menu = NSMenu(title: MainMenuBuilder.modeLabel)
        for (index, mode) in RefineMode.all.enumerated() {
            let item = NSMenuItem(title: "\(mode.title)  (\(AppInfo.holdLabel)\(index + 1))",
                                  action: #selector(profileTapped(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.id
            item.state = profile == mode.id ? .on : .off
            menu.addItem(item)
        }
        let rewrite = NSMenuItem(title: "Rewrite  (or hold \(AppInfo.holdRewriteLabel))",
                                 action: #selector(profileTapped(_:)), keyEquivalent: "")
        rewrite.target = self
        rewrite.representedObject = RefineMode.rewriteProfile
        rewrite.state = profile == RefineMode.rewriteProfile ? .on : .off
        menu.addItem(rewrite)
        return menu
    }

    /// One model submenu. Apple Native is always first. A model the service no
    /// longer lists stays, marked and not clickable, so the choice is never
    /// silently swapped. Nothing here waits: the list is what the last refresh left.
    func modelSubmenu(label: String, route: MenuModelStore.Route, chooseApple: Bool,
                      chosen: String = "") -> NSMenu {
        let menu = NSMenu(title: label)
        let apple = NSMenuItem(title: MenuModelStore.appleNative, action: #selector(appleTapped(_:)), keyEquivalent: "")
        apple.target = self
        apple.representedObject = label
        apple.state = chooseApple ? .on : .off
        menu.addItem(apple)

        // A note that says only what is true: checking, a refusal, or no answer.
        if route.checking {
            let note = NSMenuItem(title: MainMenuBuilder.checkingNote, action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
        } else if route.keyRefused {
            let note = NSMenuItem(title: MainMenuBuilder.keyRefusedNote, action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
        } else if route.unreachable {
            let note = NSMenuItem(title: MainMenuBuilder.noServerNote, action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
        }

        var offered = 0
        for name in route.entries where name != MenuModelStore.appleNative {
            let missing = route.missingChoice == name
            let item = NSMenuItem(title: missing ? "\(name) (\(MainMenuBuilder.notAvailableNote))" : name,
                                  action: #selector(modelTapped(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ModelChoice(label: label, model: name)
            item.isEnabled = !missing
            // Exactly one checkmark, on the model actually chosen. A model the
            // service stopped listing is still the choice, so it still wears it.
            let isChoice = !chooseApple && chosen == name
            item.state = isChoice ? .on : .off
            menu.addItem(item)
            if !missing { offered += 1 }
        }
        if offered == 0, !route.unreachable, !route.checking, !route.keyRefused {
            let text = label == MainMenuBuilder.speechLabel
                ? MainMenuBuilder.noSpeechModelsNote : MainMenuBuilder.noCleanupModelsNote
            let note = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
        }
        return menu
    }

    /// The label and name an item carries. A small value so representedObject
    /// never has to be a tuple, which AppKit would not carry.
    final class ModelChoice: NSObject {
        let label: String
        let model: String
        init(label: String, model: String) {
            self.label = label
            self.model = model
            super.init()
        }
    }

    // MARK: - Applying a choice

    /// What a click on a model item does to the saved settings: one route only,
    /// never the other. Pure, so the rule can be tested without a window.
    static func applied(_ settings: EndpointSettings, label: String, apple: Bool,
                        model: String? = nil) -> EndpointSettings {
        var s = settings
        if label == MainMenuBuilder.speechLabel {
            s.useCustomSpeech = !apple
            if let model { s.speechModel = model }
        } else {
            s.useCustomCleanup = !apple
            if let model { s.cleanupModel = model }
        }
        return s
    }

    // MARK: - Menu delegate

    /// The menu just opened: ask for a fresh list in the background. The menu on
    /// screen is the one already built and is not touched.
    /// The menu the person is actually looking at. Remembered when it opens,
    /// because a rebuild while it is open installs a NEW menu as the status
    /// item's menu, and the close then arrives for the old one. Comparing a
    /// close against the latest built menu would miss that close and leave the
    /// app believing a menu is still open, so a landed refresh would not show.
    private(set) var openMenu: NSMenu?

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === builtMenu else { return }
        openMenu = menu
        actions?.menuDidOpen()
        actions?.refreshModels()
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === openMenu else { return }
        openMenu = nil
        actions?.menuDidClose()
    }

    // MARK: - Item actions

    @objc private func profileTapped(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        actions?.selectProfile(id)
    }
    @objc private func appleTapped(_ sender: NSMenuItem) {
        guard let label = sender.representedObject as? String else { return }
        actions?.chooseApple(label)
    }
    @objc private func modelTapped(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? ModelChoice else { return }
        actions?.chooseModel(choice.label, choice.model)
    }
    @objc private func handsFreeTapped() { actions?.toggleHandsFree() }
    @objc private func openAccessibilityTapped() { actions?.openAccessibility() }
    @objc private func releasePageTapped() { actions?.openReleasePage() }
    @objc private func settingsTapped() { actions?.showSettings() }
}
