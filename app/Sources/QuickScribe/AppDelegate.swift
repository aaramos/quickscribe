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

        requestPermissions { [weak self] in
            self?.session.activate()
            self?.probeSidecar()
        }
    }

    // MARK: - Permissions onboarding (brief AC6: requested once, clear)

    private func requestPermissions(done: @escaping () -> Void) {
        let needMic = AVCaptureDevice.authorizationStatus(for: .audio) != .authorized
        let axAX = AXIsProcessTrusted()

        if needMic {
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                DispatchQueue.main.async { self.requestAX(done: done) }
            }
        } else {
            requestAX(done: done)
        }
        _ = axAX
    }

    private func requestAX(done: @escaping () -> Void) {
        if AXIsProcessTrusted() { done(); return }
        // Prompt once with the system dialog; poll until granted (hotkeys
        // stay disabled until then — overlay states still work).
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { t in
            if AXIsProcessTrusted() { t.invalidate(); done() }
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

    @objc private func selectPolish() { profile = "polish"; session.defaultProfile = "polish"; rebuildMenu() }
    @objc private func selectRewrite() { profile = "rewrite"; session.defaultProfile = "rewrite"; rebuildMenu() }
    @objc private func toggleHandsFree() { session.toggleHandsFree() }

    @objc private func showHistory() { historyWindow.toggle(relativeTo: statusItem.button!) }
}
