import AppKit
import ApplicationServices
import AVFoundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let session = SessionController()
    private let historyWindow = HistoryWindow()
    private var profile = "polish"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)  // LSUIElement belt-and-suspenders

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🎙︎"
        statusItem.button?.toolTip = AppInfo.displayName
        rebuildMenu()

        session.onPhaseChange = { [weak self] recording in
            self?.statusItem.button?.title = recording ? "🔴" : "🎙︎"
            self?.rebuildMenu()   // keep the hands-free toggle label truthful
        }

        requestMic { [weak self] in
            guard let self = self else { return }
            self.probeSidecar()
            self.ensureAccessibility()
        }
    }

    /// True only when the global event tap is live (hotkeys actually work).
    private var hotkeysLive: Bool { session.hotkeys.tapLive }

    // MARK: - Permissions onboarding (brief AC6: requested once, clear)

    /// Accessibility can NEVER prompt (tccd: "Service kTCCServiceAccessibility
    /// does not allow prompting") — AXIsProcessTrustedWithOptions shows no
    /// dialog, it only registers the app in the settings list. Old code
    /// assumed a dialog and silently activated a dead tap. Now: open the
    /// pane ONCE, poll, and show honest state throughout (icon + overlay).
    private func ensureAccessibility() {
        if session.activate() {
            statusItem.button?.title = "🎙︎"
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
                        self.statusItem.button?.title = "🎙︎"
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
                if h == nil {
                    self?.statusItem.button?.title = "🚫"
                    self?.statusItem.button?.toolTip = "\(AppInfo.displayName): sidecar down (port 8790)"
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

    @objc private func showHistory() { historyWindow.toggle(relativeTo: statusItem.button!) }
}
