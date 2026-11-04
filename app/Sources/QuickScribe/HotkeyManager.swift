import ApplicationServices
import CoreGraphics
import Foundation

/// Global hotkey listener (CGEvent tap — works while other apps are focused;
/// requires Accessibility permission).
///
/// Owner UX change 2026-09-18: modifier-only chord, replacing ⌘⌥Space
/// (which collided with other apps). Pure listen-only tap — QuickScribe
/// never cancels or modifies an event; every key keeps reaching the system
/// untouched.
///   Hold ⌃⌘            after a ~150 ms dwell with NO key press in between,
///                     start capture; release EITHER ⌃ or ⌘ → stop → insert.
///   Hold ⌃⌘⇧          same, forced Rewrite profile (⇧ may arrive before or
///                     during the dwell; only its presence at fire time counts).
///   ⌃⌘ + key < dwell abort the pending start, pass through
///                     (⌃⌘F / ⌃⌘Q / ⌃⌘Space behave exactly as before).
///   key during        cancel capture with nothing inserted, pass through.
///   ⌃⌘1 / 2 / 3      pick the refine mode, before or during capture; never
///                     cancels, and the key still passes through.
///   Esc               cancel (handled by the overlay's own monitor).
final class HotkeyManager {
    /// The single gesture intent the session FSM consumes (main queue).
    enum Intent: Equatable {
        case start(rewrite: Bool)
        case stop(rewrite: Bool)
        case cancel
        case selectMode(index: Int)
    }

    var onIntent: ((Intent) -> Void)?

    fileprivate enum State: Equatable { case idle, pending, capturing }
    func _handleForTesting(type: CGEventType, event: CGEvent) { handle(type: type, event: event) }

    private var eventTap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    /// True once tapCreate succeeded AND the tap was enabled on a runloop.
    private(set) var tapLive: Bool = false
    private var state: State = .idle
    private var pendingRewrite = false
    private var capturedRewrite = false
    private var dwellTimer: Timer?

    /// Subset of CGEventFlags we reason about (device-independent masks).
    private static let ctrl: CGEventFlags  = .maskControl
    private static let cmd:  CGEventFlags  = .maskCommand
    private static let shift: CGEventFlags = .maskShift

    /// Stable modifier bits only — strips caps-lock/numeric-pad/fn noise.
    private static func mods(_ flags: CGEventFlags) -> CGEventFlags {
        CGEventFlags(rawValue: flags.rawValue &
            (CGEventFlags.maskControl.rawValue | CGEventFlags.maskCommand.rawValue
             | CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskShift.rawValue))
    }
    private static func hasCtrlCmd(_ flags: CGEventFlags) -> Bool {
        let cc = CGEventFlags.maskControl.union(.maskCommand)
        return mods(flags).intersection(cc) == cc
    }
    private static func isRewrite(_ flags: CGEventFlags) -> Bool {
        hasCtrlCmd(flags) && mods(flags).contains(.maskShift)
    }

    /// ⌃⌘ plus exactly one of the number keys 1, 2, 3 (virtual key codes 18-20),
    /// with no other modifier, picks that mode.
    static func modeIndex(keyCode: Int64, flags: CGEventFlags) -> Int? {
        let exact = CGEventFlags.maskControl.union(.maskCommand)
        guard mods(flags) == exact, (18...20).contains(keyCode) else { return nil }
        return Int(keyCode - 18)
    }

    // MARK: - Pure state machine (unit-testable; the tap below only adapts it)

    /// Reduce one event to zero or one Intent. No side effects here.
    /// `capturedRewrite` is the profile locked in when capture started —
    /// the stop intent must carry it, not whatever ⇧ is doing at release.
    /// `flags` is the TRACKED modifier mask (see handle()), not the raw
    /// event flags — a keyUp event's flags omit the key being released.
    fileprivate static func reduce(state: State, type: CGEventType, flags: CGEventFlags, capturedRewrite: Bool = false) -> (Intent?, State) {
        switch type {
        case .flagsChanged:
            switch state {
            case .idle:
                if hasCtrlCmd(flags) {
                    // Both ⌃⌘ down → arm the dwell. ⇧ toggling mid-pending
                    // re-arms (profile snapshot happens at fire time).
                    return (nil, .pending)
                }
                return (nil, .idle)
            case .pending:
                if !hasCtrlCmd(flags) {
                    // Released a modifier before dwell elapsed → nothing ever
                    // started; a plain modifier release passes through.
                    return (nil, .idle)
                }
                // ⌃⌘ still held (⇧ may have toggled) → re-arm dwell window.
                return (nil, .pending)
            case .capturing:
                if !hasCtrlCmd(flags) {
                    // Release of EITHER ⌃ or ⌘ = stop → polish → insert.
                    // Profile is whatever was locked in when capture started.
                    return (.stop(rewrite: capturedRewrite), .idle)
                }
                // ⇧ pressed/released while ⌃⌘ still held: profile update, no intent.
                return (nil, .capturing)
            }
        case .keyDown:
            switch state {
            case .idle:
                return (nil, .idle)
            case .pending:
                // A key arrived inside the dwell window (⌃⌘F, ⌃⌘Q, ⌃⌘Space…).
                // Abort the pending start; the chord was a system shortcut.
                return (nil, .idle)
            case .capturing:
                // Any key during capture cancels with nothing inserted.
                // (Esc arrives here too — the overlay monitor does the
                // clipboard-safe cancel; identical outcome by design.)
                return (.cancel, .idle)
            }
        default:
            return (nil, state)
        }
    }

    // MARK: - Event tap wiring

    /// Returns true only if a live event tap was created AND enabled.
    /// false = hotkeys are DEAD (almost always: Accessibility grant missing,
    /// e.g. every ad-hoc rebuild resets TCC). Callers MUST surface this —
    /// a silent idle with a normal-looking menu icon is a defect (AC6).
    @discardableResult
    func start() -> Bool {
        // A listener created before Accessibility was granted stays off for good, and
        // re-enabling it does nothing, so it has to be replaced. This is what lets the
        // grant take effect without a relaunch.
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
            if CGEvent.tapIsEnabled(tap: tap) {
                tapLive = AXIsProcessTrusted()
                return tapLive
            }
            discardTap()
        }
        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let me = Unmanaged<HotkeyManager>.fromOpaque(refcon!).takeUnretainedValue()
            me.handle(type: type, event: event)
            return Unmanaged.passUnretained(event) // NEVER swallow
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: .listenOnly, eventsOfInterest: mask,
                                           callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            NSLog("QuickScribe: could not create event tap (Accessibility permission?)")
            tapLive = false
            return false
        }
        eventTap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        tapSource = src
        // Without Accessibility, tapCreate can still succeed and the listener then
        // sits off, receiving nothing, so both checks are needed before saying it works.
        CGEvent.tapEnable(tap: tap, enable: true)
        tapLive = AXIsProcessTrusted() && CGEvent.tapIsEnabled(tap: tap)
        if tapLive {
            NSLog("QuickScribe: event tap live (hold \(AppInfo.holdLabel) armed)")
        } else {
            NSLog("QuickScribe: event tap created but ENABLE FAILED — hotkeys dead (Accessibility grant missing?)")
        }
        return tapLive
    }

    private func discardTap() {
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        if let eventTap { CFMachPortInvalidate(eventTap) }
        tapSource = nil
        eventTap = nil
    }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        // Auto-repeat of a held key: already handled / irrelevant.
        if type == .keyDown && event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return }

        let flags = event.flags
        lastFlags = flags
        switch type {
        case .flagsChanged:
            let (intent, next) = Self.reduce(state: state, type: type, flags: flags, capturedRewrite: capturedRewrite)
            switch next {
            case .pending:
                pendingRewrite = Self.isRewrite(flags)
                armDwell()
            case .idle:
                dwellTimer?.invalidate(); dwellTimer = nil
            case .capturing:
                // ⇧ toggling mid-capture does NOT change the profile —
                // it was locked in when capture started.
                break
            }
            state = next
            emit(intent)
        case .keyDown:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if let index = Self.modeIndex(keyCode: keyCode, flags: flags) {
                // Inside the dwell window this was a shortcut, not a hold: nothing
                // starts. An already-running capture keeps going.
                if state == .pending {
                    dwellTimer?.invalidate(); dwellTimer = nil
                    state = .idle
                }
                emit(.selectMode(index: index))
                return
            }
            let (intent, next) = Self.reduce(state: state, type: type, flags: flags)
            if next != .pending { dwellTimer?.invalidate(); dwellTimer = nil }
            state = next
            emit(intent)
        default:
            break
        }
    }

    /// Dwell: capture begins only if ⌃⌘ are STILL held when it fires.
    private func armDwell() {
        dwellTimer?.invalidate()
        dwellTimer = Timer.scheduledTimer(withTimeInterval: AppInfo.holdDwell, repeats: false) { [weak self] _ in
            guard let self = self, case .pending = self.state else { return }
            self.state = .capturing
            self.capturedRewrite = Self.isRewrite(self.lastFlags)
            self.emit(.start(rewrite: self.capturedRewrite))
        }
    }

    private var lastFlags: CGEventFlags = []

    private func emit(_ intent: Intent?) {
        guard let intent = intent else { return }
        DispatchQueue.main.async { [weak self] in self?.onIntent?(intent) }
    }
}
