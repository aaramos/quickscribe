import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Global hotkey listener (CGEvent tap — works while other apps are focused;
/// requires Accessibility permission).
///   ⌘⌥Space         press starts capture; quick release (<tapThreshold)
///                   switches to toggle mode; hold = push-to-talk (hold wins
///                   while held — brief §1 + card B "hold takes precedence").
///   ⌘⌥⌃Space      same gesture, Rewrite profile (brief §4 variant).
final class HotkeyManager {
    /// (down: Bool, rewrite: Bool) — called on the main queue.
    var onHotkey: ((Bool, Bool) -> Void)?
    var onHeldPoll: (() -> Void)?

    private var eventTap: CFMachPort?
    private var downAt: TimeInterval = 0
    private var heldRewrite = false
    private var pollTimer: Timer?

    private static func cmdOpt(_ flags: CGEventFlags) -> Bool {
        flags.contains(.maskCommand) && flags.contains(.maskAlternate)
    }
    private static func cmdOptCtrl(_ flags: CGEventFlags) -> Bool {
        flags.contains(.maskCommand) && flags.contains(.maskAlternate) && flags.contains(.maskControl)
    }

    func start() {
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let me = Unmanaged<HotkeyManager>.fromOpaque(refcon!).takeUnretainedValue()
            me.handle(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }
        // Listen-only tap: events flow through untouched.
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: .listenOnly, eventsOfInterest: mask,
                                           callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            NSLog("QuickScribe: could not create event tap (Accessibility permission?)")
            return
        }
        eventTap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard event.getIntegerValueField(.keyboardEventKeycode) == CGKeyCode(kVK_Space) else { return }
        let flags = event.flags
        let rewrite = Self.cmdOptCtrl(flags)
        let plain = Self.cmdOpt(flags) && !rewrite
        // Mach absolute time → seconds, same clock everywhere here.
        let now = CFAbsoluteTimeGetCurrent()

        if type == .keyDown {
            guard plain || rewrite else { return }
            if downAt > 0 { return } // auto-repeat while held
            downAt = now
            heldRewrite = rewrite
            DispatchQueue.main.async { [weak self] in self?.onHotkey?(true, rewrite) }
            pollTimer?.invalidate()
            pollTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                self?.onHeldPoll?()
            }
        } else { // keyUp
            guard downAt > 0 else { return }
            let wasRewrite = heldRewrite
            let held = now - downAt
            downAt = 0
            pollTimer?.invalidate(); pollTimer = nil
            heldRewrite = false
            DispatchQueue.main.async { [weak self] in self?.onHotkey?(false, wasRewrite) }
            _ = held // tap-vs-hold resolved in SessionController
        }
    }
}
