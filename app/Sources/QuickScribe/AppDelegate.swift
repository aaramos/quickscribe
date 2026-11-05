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
    private var cleanupDown: Bool { cleanupProblem != nil }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)  // LSUIElement belt-and-suspenders

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = MenuBarIcon.image()
        statusItem.button?.image?.size = NSSize(width: 22, height: 22)
        statusItem.button?.toolTip = AppInfo.displayName
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
                                                   session: URLSession(configuration: .ephemeral))
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

    // MARK: - Permissions onboarding (brief AC6: requested once, clear)

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
        overlayWarn("Accessibility off, so hotkeys are disabled. Enable \(AppInfo.displayName) in System Settings.")
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
        let menu = NSMenu()

        if !hotkeysLive {
            let dead = NSMenuItem(title: "⚠ Hotkeys off: grant Accessibility", action: #selector(openAXSettings), keyEquivalent: "")
            dead.target = self
            menu.addItem(dead)
        }

        if let cleanupProblem {
            let item = NSMenuItem(title: "⚠ \(cleanupProblem) Dictation still works, without AI cleanup.", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        let how = NSMenuItem(title: "Hold \(AppInfo.holdLabel) to talk, release to insert", action: nil, keyEquivalent: "")
        how.isEnabled = false
        menu.addItem(how)

        // Hold-only keyboard gesture → hands-free toggle lives here.
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

        if let update = availableUpdate {
            // Only when a check actually said newer; opens GitHub's own page
            // for that release, where the person can read what changed.
            let item = NSMenuItem(title: "Update available: version \(update.version)",
                                  action: #selector(openReleasePage), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }

        menu.addItem(.separator())

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
}
