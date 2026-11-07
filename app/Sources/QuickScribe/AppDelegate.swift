import AppKit
import ApplicationServices
import AVFoundation
import QuickScribeCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let prompts = PromptLibrary(fileURL: AppInfo.dataFolder.appendingPathComponent("prompts.json"))
    private lazy var endpointStore = EndpointSettingsStore(secrets: KeychainSecrets(service: AppInfo.bundleID + ".endpoint"))
    private lazy var session = SessionController(prompts: prompts, endpointStore: endpointStore)
    /// What the two model submenus show, and the background refresh behind them.
    private lazy var modelStore = MenuModelStore(endpointStore: endpointStore)
    /// Builds the menu bar menu. Owns nothing itself, so it can be read in a test.
    private let menuAssembly = MainMenuAssembly()
    /// A menu is on screen. A refresh that lands now waits for the close, so
    /// the list never changes under the person reading it.
    private var menuIsOpen = false
    private var rebuildAfterClose = false
    private lazy var settingsWindow = SettingsWindow(library: prompts, endpointStore: endpointStore)

    /// Icon A equalizer animation — runs ONLY while recording.
    /// Static template glyph at rest so idle CPU is zero.
    private var iconTimer: Timer?
    private var iconPhase: Double = 0
    /// Why AI cleanup can't run right now. Dictation still works without it.
    private var cleanupProblem: String?
    /// A release newer than this app, when GitHub says so. The menu carries
    /// it until the next check says we are level again; the pill says it
    /// once per version, kept in UserDefaults under this key.
    private var availableUpdate: (version: String, page: URL)?
    private static let updateNotifiedKey = "UpdateNoticeVersion"
    /// One session for the whole life of the app. Ephemeral stores nothing
    /// on disk; keeping it alive lets the connection wind down on its own
    /// instead of building and abandoning a stack every day.
    private let updateSession = URLSession(configuration: .ephemeral)
    private var cleanupDown: Bool { cleanupProblem != nil }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)  // LSUIElement belt-and-suspenders

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = MenuBarIcon.image()
        statusItem.button?.image?.size = NSSize(width: 22, height: 22)
        statusItem.button?.toolTip = AppInfo.displayName

        wireMenuActions()
        // The store is told where answers go and starts fetching before the
        // first menu is built, or that menu shows a false empty list.
        MenuLaunch.start(store: modelStore,
                         onRefreshFinished: { [weak self] in self?.refreshLanded() },
                         buildMenu: { [weak self] in self?.rebuildMenu() })
        settingsWindow.onConnectionChanged = { [weak self] addressChanged, keyChanged in
            guard let self else { return }
            if addressChanged { self.modelStore.addressChanged() }
            if keyChanged { self.modelStore.keyChanged() }
            self.modelStore.refreshIfUseful()
            self.rebuildMenu()
        }
        session.onProfileChange = { [weak self] in self?.rebuildMenu() }
        session.onPhaseChange = { [weak self] recording in
            guard let self = self else { return }
            if recording {
                self.startIconAnimation()
            } else {
                self.stopIconAnimation()
            }
            self.rebuildMenu()   // keep the hands-free toggle label truthful
        }

        requestMic { [weak self] in
            guard let self = self else { return }
            self.startReadinessMonitor()
            self.ensureAccessibility()
        }
        startUpdateChecks()
    }

    // MARK: - Update notice

    /// A question to GitHub at launch and once a day. It runs beside
    /// dictation, never before it: nothing here gates a recording, and every
    /// failure is a silent no, logged in one short line with no URL in it.
    private func startUpdateChecks() {
        runUpdateCheck()
        Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.runUpdateCheck() }
        }
    }

    private func runUpdateCheck() {
        Task { [weak self] in
            guard let self else { return }
            let answer = await UpdateChecker.check(repo: AppInfo.githubRepo,
                                                   appName: AppInfo.displayName,
                                                   appVersion: AppInfo.version,
                                                   session: updateSession)
            switch answer {
            case .newer(let version, let page):
                self.availableUpdate = (version, page)
                let busy = !self.session.pillIsFree
                if let notice = Self.updateNotice(answer,
                                                  lastNotified: UserDefaults.standard
                                                      .string(forKey: Self.updateNotifiedKey),
                                                  sessionBusy: busy) {
                    UserDefaults.standard.set(notice, forKey: Self.updateNotifiedKey)
                    self.overlayWarn("Version \(notice) is out. Open the \(AppInfo.displayName) menu.",
                                     autoHideAfter: 5)
                }
                self.rebuildMenu()
            case .current:
                if self.availableUpdate != nil {
                    self.availableUpdate = nil
                    self.rebuildMenu()
                }
            case .malformed:
                NSLog("QuickScribe: update check got an answer it could not read")
            case .failed:
                NSLog("QuickScribe: update check did not reach GitHub")
            }
        }
    }

    /// A notice only goes on an empty pill. It would otherwise bury whatever
    /// the person is reading, dictation or a permission warning alike, and
    /// hide again before anyone could. A skipped notice is not a told one:
    /// the version stays unmarked so a later check announces into a quiet
    /// screen. The menu item still appears now; a menu opens when the person
    /// chooses, interrupting nothing.
    nonisolated static func updateNotice(_ answer: UpdateChecker.Check, lastNotified: String?,
                                         sessionBusy: Bool) -> String? {
        guard !sessionBusy else { return nil }
        return UpdateChecker.noticeVersion(for: answer, lastNotified: lastNotified)
    }

    @objc private func openReleasePage() {
        if let page = availableUpdate?.page { NSWorkspace.shared.open(page) }
    }

    /// True only when the global event tap is live (hotkeys actually work).
    private var hotkeysLive: Bool { session.hotkeys.tapLive }

    // MARK: - Menu-bar icon states

    private func applyIcon(animated: Bool, dimmed: Bool = false) {
        guard let button = statusItem.button else { return }
        let img = (animated || cleanupDown)
            ? (animated ? MenuBarIcon.animatedImage(phase: iconPhase, dimmed: dimmed)
                        : MenuBarIcon.image(dimmed: true))
            : MenuBarIcon.image(dimmed: dimmed)
        img.size = NSSize(width: 22, height: 22)
        button.image = img
    }

    /// ~12.5 fps equalizer micro-motion — visible life, negligible CPU.
    /// Stopped the moment recording ends (static glyph at rest).
    private func startIconAnimation() {
        iconPhase = 0
        applyIcon(animated: true)
        iconTimer?.invalidate()
        iconTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, self.session.isRecording else { return }
                self.iconPhase += 0.55
                self.applyIcon(animated: true)
            }
        }
    }

    private func stopIconAnimation() {
        iconTimer?.invalidate(); iconTimer = nil
        applyIcon(animated: false, dimmed: cleanupDown)
    }

    // MARK: - Permissions onboarding (requested once, explained clearly)

    /// Accessibility can NEVER prompt (tccd: "Service kTCCServiceAccessibility
    /// does not allow prompting") — AXIsProcessTrustedWithOptions shows no
    /// dialog, it only registers the app in the settings list. Old code
    /// assumed a dialog and silently activated a dead tap. Now: open the
    /// pane ONCE, poll, and show honest state throughout (icon + overlay).
    private func ensureAccessibility() {
        // Setup logging: a re-granted Accessibility grant once went unconfirmed on
        // screen, so each step leaves a short trace. No personal details.
        NSLog("QuickScribe: accessibility at launch: \(AXIsProcessTrusted() ? "granted" : "not granted")")
        if session.activate() {
            NSLog("QuickScribe: hotkeys started at launch")
            applyIcon(animated: false, dimmed: cleanupDown)
            statusItem.button?.toolTip = readyTip
            rebuildMenu()
            return
        }
        overlayWarn(AppDelegate.accessibilityOffNotice)
        openAccessibilityPaneOnce()
        NSLog("QuickScribe: waiting timer started (checks every 2 s)")
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
            Task { @MainActor in
                guard let self = self else { t.invalidate(); return }
                // While untrusted NOTHING has changed — do NOT rebuildMenu()
                // every 2s (swapping statusItem.menu yanks a menu the user may
                // be reading shut, and the poll ran forever).
                guard AXIsProcessTrusted() else { return }
                t.invalidate()
                NSLog("QuickScribe: accessibility grant noticed")
                if self.session.activate() {
                    NSLog("QuickScribe: hotkeys started after grant")
                    self.applyIcon(animated: false, dimmed: self.cleanupDown)
                    self.statusItem.button?.toolTip = self.readyTip
                    self.overlayWarn("Hotkeys live ✓  Hold \(AppInfo.holdLabel) to talk", autoHideAfter: 3)
                } else {
                    // Trusted but tap refused (tccd cache race): force an
                    // app relaunch so the grant is re-evaluated fresh.
                    NSLog("QuickScribe: hotkeys did NOT start after grant — relaunch needed")
                    self.overlayWarn("Permission recorded. Relaunch \(AppInfo.displayName) to turn on hotkeys.", autoHideAfter: 5)
                }
                self.rebuildMenu()
            }
        }
    }

    private var didOpenAXPane = false
    private func openAccessibilityPaneOnce() {
        guard !didOpenAXPane else { return }
        didOpenAXPane = true
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Shown when Accessibility is not in effect. The switch can look on while
    /// it does not apply (an older build with the same app id), so the sentence
    /// also says what to do when it already looks on. Pinned by a pill-fit test.
    static let accessibilityOffNotice = "Hotkeys are off. If QuickScribe already looks on in Settings, remove it and add it again."

    private func overlayWarn(_ msg: String, autoHideAfter: TimeInterval? = nil) {
        session.showOverlay(.error(msg), autoHide: autoHideAfter)
    }

    private func requestMic(done: @escaping () -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            done()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                DispatchQueue.main.async { done() }
            }
        default:
            // Denied previously — mic prompt will NOT re-appear; say so.
            overlayWarn("Mic denied. Enable it in System Settings → Privacy → Microphone.", autoHideAfter: 5)
            done()
        }
    }

    // MARK: - Readiness

    /// Apple Intelligence can be turned on or finish downloading at any time, so this
    /// keeps checking. Also makes sure the speech model is there and warmed up.
    private var readinessTimer: Timer?

    private func startReadinessMonitor() {
        session.prepare()
        checkReadiness()
        readinessTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkReadiness() }
        }
    }

    private func checkReadiness() {
        let problem = AppleCleaner.unavailableReason()
        guard problem != cleanupProblem else { return }
        cleanupProblem = problem
        if !session.isRecording { applyIcon(animated: false, dimmed: cleanupDown) }
        statusItem.button?.toolTip = problem.map { "\(AppInfo.displayName): \($0)" } ?? readyTip
        rebuildMenu()
    }

    private var readyTip: String { "\(AppInfo.displayName): ready, hold \(AppInfo.holdLabel)" }

    // MARK: - Menu

    private func rebuildMenu() {
        // The menu is a value: everything it shows is read now, and a menu
        // already open keeps what it was given.
        let settings = endpointStore.load()
        let state = MainMenuAssembly.State(
            hotkeysOff: !hotkeysLive,
            cleanupProblem: cleanupProblem,
            recording: session.isRecording,
            profile: session.defaultProfile,
            snapshot: modelStore.snapshot(),
            updateVersion: availableUpdate?.version,
            speechModel: settings.speechModel,
            cleanupModel: settings.cleanupModel)
        statusItem.menu = menuAssembly.build(state)
    }

    /// A refresh finished. The menu is rebuilt so the fresh list is actually
    /// seen, unless a menu is on screen: rebuilding then would yank it from
    /// under the person reading it, so the rebuild waits for the close.
    private func refreshLanded() {
        if menuIsOpen {
            rebuildAfterClose = true
        } else {
            rebuildMenu()
        }
    }

    /// Where the assembly's clicks land: each one changes the app and rebuilds
    /// the menu, so the next open shows the new choice.
    private func wireMenuActions() {
        menuAssembly.actions = MainMenuAssembly.Actions(
            selectProfile: { [weak self] id in self?.session.selectProfile(id) },
            chooseApple: { [weak self] label in self?.setModelChoice(label: label, apple: true) },
            chooseModel: { [weak self] label, model in
                self?.setModelChoice(label: label, apple: false, model: model)
            },
            toggleHandsFree: { [weak self] in self?.session.toggleHandsFree() },
            openAccessibility: { [weak self] in self?.openAXSettings() },
            openReleasePage: { [weak self] in self?.openReleasePage() },
            showSettings: { [weak self] in self?.showSettings() },
            refreshModels: { [weak self] in self?.modelStore.refreshIfUseful() },
            menuDidOpen: { [weak self] in self?.menuIsOpen = true },
            menuDidClose: { [weak self] in
                guard let self else { return }
                self.menuIsOpen = false
                guard self.rebuildAfterClose else { return }
                self.rebuildAfterClose = false
                self.rebuildMenu()
            })
    }

    /// Apple Native, or a server model, on one route only: speech and cleanup
    /// are independent. A choice applies from the next dictation, because every
    /// session reads the settings when it starts.
    private func setModelChoice(label: String, apple: Bool, model: String? = nil) {
        endpointStore.save(MainMenuAssembly.applied(endpointStore.load(), label: label, apple: apple, model: model))
        // The Settings page, if it is open, may now be describing a route that
        // no longer sends words, or miss one that does.
        settingsWindow.connectionChangedOutside()
        rebuildMenu()
    }

    @objc private func openAXSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func showSettings() { settingsWindow.show() }
}
