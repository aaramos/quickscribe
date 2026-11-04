import AppKit
import ApplicationServices
import AVFoundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let session = SessionController()
    private let historyWindow = HistoryWindow()
    private let settingsWindow = SettingsWindow()

    // MARK: Model pickers (polish: t_741dd1a3; transcription: 2026-11-01)
    /// Persisted user choices; nil = sidecar/config default. Both pickers are
    /// the shared ModelPicker — same honest semantics for both model classes.
    private static let savedModelKey = "QuickScribePolishModel"
    private static let savedSttModelKey = "QuickScribeSttModel"
    private var polishPicker: ModelPicker!
    private var sttPicker: ModelPicker!

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
        setupModelPickers()
        rebuildMenu()

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
            self.startSidecarMonitor()
            self.ensureAccessibility()
        }
        refreshModels()   // menu-bar Models submenus (polish + transcription)
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
                // While untrusted NOTHING has changed — do NOT rebuildMenu()
                // every 2s (swapping statusItem.menu yanks a menu the user may
                // be reading shut, and the poll ran forever).
                guard AXIsProcessTrusted() else { return }
                t.invalidate()
                if self.session.activate() {
                    self.applyIcon(animated: false, dimmed: self.sidecarDown)
                    self.statusItem.button?.toolTip = "\(AppInfo.displayName): ready — hold \(AppInfo.holdLabel)"
                    self.overlayWarn("Hotkeys live ✓  Hold \(AppInfo.holdLabel) to talk", autoHideAfter: 3)
                } else {
                    // Trusted but tap refused (tccd cache race): force an
                    // app relaunch so the grant is re-evaluated fresh.
                    self.overlayWarn("Grant recorded — relaunch QuickScribe to arm hotkeys", autoHideAfter: 5)
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

    // MARK: - Sidecar health monitor (never crash when down — brief §8)

    /// PERMANENT monitor (t_a0fb24bb): a single ~30 s probe runs for the
    /// app's life, so healthy → LATER-outage → recovery are all observable
    /// without relaunch. Earlier shapes failed: launch-only probe never saw
    /// an outage; the down-only retry stopped after success.
    /// Invariants: exactly one timer (create-once), no overlapping requests
    /// (in-flight gate), probes skipped while recording, and delayed
    /// responses never overwrite the recording icon — all decided by the
    /// pure SidecarHealth machine (unit-tested).
    private var sidecarTimer: Timer?
    private var sidecarProbeInFlight = false

    func startSidecarMonitor() {
        probeSidecar()   // immediate first probe (launch race with LaunchAgent)
        guard sidecarTimer == nil else { return }   // create-once: no duplicates
        sidecarTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                if self.session.isRecording { return }   // don't disturb a live session
                self.probeSidecar()
            }
        }
    }

    private func probeSidecar() {
        guard !sidecarProbeInFlight else { return }   // never overlap requests
        sidecarProbeInFlight = true
        SidecarClient.shared.health { [weak self] h in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.sidecarProbeInFlight = false
                let t = SidecarHealth.next(down: self.sidecarDown, probeOK: (h != nil),
                                           hotkeysLive: self.hotkeysLive,
                                           recording: self.session.isRecording)
                self.sidecarDown = t.down
                switch t.icon {
                case .keep: break
                case .normal: self.applyIcon(animated: false, dimmed: false)
                // Owner-picked restyle (t_3db202e7): dimmed Icon A replaces 🚫.
                case .dimmed: self.applyIcon(animated: false, dimmed: true)
                }
                switch t.tip {
                case .keep: break
                case .down: self.statusItem.button?.toolTip = "\(AppInfo.displayName): sidecar down (port 8790)"
                case .ready: self.statusItem.button?.toolTip = "\(AppInfo.displayName): ready — hold \(AppInfo.holdLabel)"
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

        for (index, mode) in RefineMode.all.enumerated() {
            let item = NSMenuItem(title: "\(mode.title)  (\(AppInfo.holdLabel)\(index + 1))",
                                  action: #selector(selectProfile(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.id
            item.state = session.defaultProfile == mode.id ? .on : .off
            menu.addItem(item)
        }

        let rewrite = NSMenuItem(title: "Rewrite  (or hold \(AppInfo.holdRewriteLabel))",
                                 action: #selector(selectProfile(_:)), keyEquivalent: "")
        rewrite.target = self
        rewrite.representedObject = RefineMode.rewriteProfile
        rewrite.state = session.defaultProfile == RefineMode.rewriteProfile ? .on : .off
        menu.addItem(rewrite)

        menu.addItem(.separator())

        menu.addItem(polishPicker.submenuItem)
        menu.addItem(sttPicker.submenuItem)

        let hist = NSMenuItem(title: "History (last 50)", action: #selector(showHistory), keyEquivalent: "")
        hist.target = self
        menu.addItem(hist)

        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

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

    @objc private func selectProfile(_ sender: NSMenuItem) {
        guard let profile = sender.representedObject as? String else { return }
        session.selectProfile(profile)
    }
    @objc private func showSettings() { settingsWindow.show() }
    @objc private func toggleHandsFree() { session.toggleHandsFree() }

    // MARK: - Model pickers wiring (polish: t_741dd1a3; transcription: 2026-11-01)
    // The picker behavior itself lives in ModelPicker.swift (shared class):
    // GET /models | /stt/models at launch + refresh; selecting POSTs the same
    // path (hot-swap, sidecar-side), persists to UserDefaults, checkmark
    // tracks the sidecar-reported ACTIVE model. Selection failure → previous
    // model stays active, checkmark honestly stays on it. The app NEVER
    // talks to HuggingFace or oMLX directly — localhost sidecar only (AC8).

    private func setupModelPickers() {
        polishPicker = ModelPicker(
            title: "Polish Model",
            storageKey: Self.savedModelKey,
            fetch: { done in
                SidecarClient.shared.listModels { m in done(m?.models, m?.current) }
            },
            apply: { model, done in
                SidecarClient.shared.switchModel(model) { ok, active in done(ok, active) }
            },
            notify: { [weak self] msg, secs in self?.overlayWarn(msg, autoHideAfter: secs) },
            onChanged: { [weak self] in self?.rebuildMenu() })

        sttPicker = ModelPicker(
            title: "Transcription Model",
            storageKey: Self.savedSttModelKey,
            fetch: { done in
                SidecarClient.shared.listModels(path: "/stt/models") { m in done(m?.models, m?.current) }
            },
            // STT switches warm-load (first time may download) an MLX model
            // inside the request before committing — allow generously; on
            // timeout/failure the sidecar keeps the previous model active.
            apply: { model, done in
                SidecarClient.shared.switchModel(model, path: "/stt/models", timeout: 300) { ok, active in
                    done(ok, active)
                }
            },
            notify: { [weak self] msg, secs in self?.overlayWarn(msg, autoHideAfter: secs) },
            onChanged: { [weak self] in self?.rebuildMenu() })
    }

    private func refreshModels() {
        polishPicker.refresh()
        sttPicker.refresh()
    }

    @objc private func showHistory() {
        guard let button = statusItem.button else { return }
        historyWindow.toggle(relativeTo: button)
    }
}
