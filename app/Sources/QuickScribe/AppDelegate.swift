import AppKit
import ApplicationServices
import AVFoundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let session = SessionController()
    private let historyWindow = HistoryWindow()
    private var profile = "polish"

    // MARK: Model picker (t_741dd1a3)
    /// Persisted user choice; nil = sidecar/config default.
    private static let savedModelKey = "QuickScribePolishModel"
    private var availableModels: [String] = []
    private var activeModel: String?       // authoritative (sidecar-reported)
    private var loadingModels = false
    private var switchingModel = false

    /// Icon A equalizer animation — runs ONLY while recording (t_3db202e7).
    /// Static template glyph at rest so idle CPU is zero.
    private var iconTimer: Timer?
    private var iconPhase: Double = 0
    private var sidecarDown = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)  // LSUIElement belt-and-suspenders

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = MenuBarIcon.image()
        statusItem.button?.image?.size = NSSize(width: 22, height: 22)
        statusItem.button?.toolTip = AppInfo.displayName
        rebuildMenu()

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
            self.probeSidecar()
            self.ensureAccessibility()
        }
        refreshModels()   // menu-bar Models submenu (t_741dd1a3)
    }

    /// True only when the global event tap is live (hotkeys actually work).
    private var hotkeysLive: Bool { session.hotkeys.tapLive }

    // MARK: - Menu-bar icon states (Icon A, t_3db202e7)

    private func applyIcon(animated: Bool, dimmed: Bool = false) {
        guard let button = statusItem.button else { return }
        let img = (animated || sidecarDown)
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
        applyIcon(animated: false, dimmed: sidecarDown)
    }

    // MARK: - Permissions onboarding (brief AC6: requested once, clear)

    /// Accessibility can NEVER prompt (tccd: "Service kTCCServiceAccessibility
    /// does not allow prompting") — AXIsProcessTrustedWithOptions shows no
    /// dialog, it only registers the app in the settings list. Old code
    /// assumed a dialog and silently activated a dead tap. Now: open the
    /// pane ONCE, poll, and show honest state throughout (icon + overlay).
    private func ensureAccessibility() {
        if session.activate() {
            applyIcon(animated: false, dimmed: sidecarDown)
            statusItem.button?.toolTip = "\(AppInfo.displayName): ready — hold \(AppInfo.holdLabel)"
            rebuildMenu()
            return
        }
        overlayWarn("Accessibility off — hotkeys disabled. Enable QuickScribe in System Settings.")
        openAccessibilityPaneOnce()
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
            Task { @MainActor in
                guard let self = self else { t.invalidate(); return }
                if AXIsProcessTrusted() {
                    if self.session.activate() {
                        t.invalidate()
                        self.applyIcon(animated: false, dimmed: self.sidecarDown)
                        self.statusItem.button?.toolTip = "\(AppInfo.displayName): ready — hold \(AppInfo.holdLabel)"
                        self.overlayWarn("Hotkeys live ✓  Hold \(AppInfo.holdLabel) to talk", autoHideAfter: 3)
                    } else {
                        // Trusted but tap refused (tccd cache race): force an
                        // app relaunch so the grant is re-evaluated fresh.
                        t.invalidate()
                        self.overlayWarn("Grant recorded — relaunch QuickScribe to arm hotkeys", autoHideAfter: 5)
                    }
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
            overlayWarn("Mic denied — enable in System Settings → Privacy → Microphone", autoHideAfter: 5)
            done()
        }
    }

    // MARK: - Sidecar health (never crash when down — brief §8)

    private func probeSidecar() {
        SidecarClient.shared.health { [weak self] h in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.sidecarDown = (h == nil)
                if self.sidecarDown {
                    // Owner-picked restyle (t_3db202e7): dimmed Icon A replaces 🚫.
                    self.applyIcon(animated: false, dimmed: true)
                    self.statusItem.button?.toolTip = "\(AppInfo.displayName): sidecar down (port 8790)"
                } else if !self.session.isRecording {
                    self.applyIcon(animated: false)
                }
            }
        }
    }

    // MARK: - Menu

    private func rebuildMenu() {
        let menu = NSMenu()

        if !hotkeysLive {
            let dead = NSMenuItem(title: "⚠ Hotkeys off — grant Accessibility", action: #selector(openAXSettings), keyEquivalent: "")
            dead.target = self
            menu.addItem(dead)
        }

        let how = NSMenuItem(title: "Hold \(AppInfo.holdLabel) to talk, release to insert", action: nil, keyEquivalent: "")
        how.isEnabled = false
        menu.addItem(how)

        // Hold-only keyboard gesture → hands-free toggle lives here (owner UX change 2026-09-18).
        let toggle = NSMenuItem(title: session.isRecording ? "Stop Recording (hands-free)" : "Start Recording (hands-free)",
                                action: #selector(toggleHandsFree), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        let polish = NSMenuItem(title: "Polish (default)", action: #selector(selectPolish), keyEquivalent: "")
        polish.target = self
        polish.state = profile == "polish" ? .on : .off
        menu.addItem(polish)

        let rewrite = NSMenuItem(title: "Rewrite  (or hold \(AppInfo.holdRewriteLabel))", action: #selector(selectRewrite), keyEquivalent: "")
        rewrite.target = self
        rewrite.state = profile == "rewrite" ? .on : .off
        menu.addItem(rewrite)

        menu.addItem(.separator())

        menu.addItem(modelsSubmenu())

        let hist = NSMenuItem(title: "History (last 50)", action: #selector(showHistory), keyEquivalent: "")
        hist.target = self
        menu.addItem(hist)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit \(AppInfo.displayName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
    }

    @objc private func openAXSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func selectPolish() { profile = "polish"; session.defaultProfile = "polish"; rebuildMenu() }
    @objc private func selectRewrite() { profile = "rewrite"; session.defaultProfile = "rewrite"; rebuildMenu() }
    @objc private func toggleHandsFree() { session.toggleHandsFree() }

    // MARK: - Models submenu (t_741dd1a3)
    // Live oMLX model picker: GET sidecar /models at launch + refresh;
    // selecting POSTs /models (hot-swap), persists to UserDefaults, checkmark
    // tracks the sidecar-reported ACTIVE model. Selection failure → previous
    // model stays active, checkmark honestly stays on it.

    private func modelsSubmenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Models", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false

        if activeModel == nil && availableModels.isEmpty && !loadingModels && !switchingModel {
            let none = NSMenuItem(title: "(sidecar down — no models)", action: nil, keyEquivalent: "")
            none.isEnabled = false
            sub.addItem(none)
        }
        if loadingModels {
            let l = NSMenuItem(title: "Loading…", action: nil, keyEquivalent: "")
            l.isEnabled = false
            sub.addItem(l)
        }
        if switchingModel {
            let l = NSMenuItem(title: "Switching…", action: nil, keyEquivalent: "")
            l.isEnabled = false
            sub.addItem(l)
        }
        for m in availableModels {
            let it = NSMenuItem(title: m, action: #selector(selectModel(_:)), keyEquivalent: "")
            it.target = self
            it.state = (m == activeModel) ? .on : .off
            it.isEnabled = !switchingModel
            sub.addItem(it)
        }
        sub.addItem(.separator())
        let ref = NSMenuItem(title: "Refresh", action: #selector(refreshModelsTapped), keyEquivalent: "")
        ref.target = self
        ref.isEnabled = !loadingModels && !switchingModel
        sub.addItem(ref)

        item.submenu = sub
        return item
    }

    private func refreshModels() {
        guard !loadingModels else { return }
        loadingModels = true
        rebuildMenu()
        SidecarClient.shared.listModels { [weak self] list in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.loadingModels = false
                if let list = list {
                    self.availableModels = list.models
                    self.activeModel = list.current
                }
                self.rebuildMenu()
                self.applyPersistedModelIfNeeded()
            }
        }
    }

    /// One-shot: if the user's persisted choice differs from the active model
    /// (e.g. sidecar restarted on its config default), re-apply their choice.
    private var didApplyPersistedModel = false
    private func applyPersistedModelIfNeeded() {
        guard !didApplyPersistedModel, !switchingModel else { return }
        guard let saved = UserDefaults.standard.string(forKey: Self.savedModelKey),
              saved != activeModel else { didApplyPersistedModel = true; return }
        didApplyPersistedModel = true
        performModelSwitch(to: saved, silent: true)
    }

    @objc private func refreshModelsTapped() { refreshModels() }

    @objc private func selectModel(_ sender: NSMenuItem) {
        performModelSwitch(to: sender.title, silent: false)
    }

    private func performModelSwitch(to model: String, silent: Bool) {
        guard !switchingModel else { return }
        switchingModel = true
        rebuildMenu()
        SidecarClient.shared.switchModel(model) { [weak self] ok, active in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.switchingModel = false
                if ok {
                    self.activeModel = active ?? model
                    UserDefaults.standard.set(self.activeModel, forKey: Self.savedModelKey)
                } else if !silent {
                    // Keep existing model as default/fallback — say so honestly.
                    self.overlayWarn("Switch to \(model) failed — still on \(self.activeModel ?? "?")", autoHideAfter: 4)
                }
                self.rebuildMenu()
            }
        }
    }

    @objc private func showHistory() { historyWindow.toggle(relativeTo: statusItem.button!) }
}
