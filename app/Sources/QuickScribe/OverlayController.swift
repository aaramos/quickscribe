import AppKit

/// Minimal overlay pill: recording state + live partials, then processing /
/// inserted / cancelled / degraded states. Appears within ~1 frame of hotkey
/// press (brief: 100 ms perceived-latency requirement). Ignores keyboard and
/// mouse so it never steals focus from the target app.
final class OverlayController {
    enum State: Equatable {
        case hidden
        case recording(device: String?)
        case partial(String, device: String?)
        case processing
        case inserted
        case degraded        // polish unavailable — raw inserted (brief §8)
        case cancelled
        case error(String)

        var label: String {
            switch self {
            case .hidden: return ""
            case .recording(let d): return "● Recording \(d.map { "· \($0)" } ?? "")  (Esc to cancel)"
            case .partial(let t, let d): return "● \(t)\(d.map { "  · \($0)" } ?? "")"
            case .processing: return "○ Transcribing…"
            case .inserted: return "✓ Inserted"
            case .degraded: return "! LLM down — inserted raw text"
            case .cancelled: return "✕ Cancelled"
            case .error(let m): return "! " + m
            }
        }

        var showsDot: Bool {
            switch self {
            case .hidden: return false
            default: return true
            }
        }
    }

    private var panel: NSPanel?
    private var label: NSTextField?
    private var dot: NSView?
    private var autoHide: Timer?
    private(set) var state: State = .hidden

    /// Esc-key monitor, wired by the session controller.
    var onEscape: (() -> Void)?

    init() {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 56),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.hidesOnDeactivate = false
        p.ignoresMouseEvents = true
        p.becomesKeyOnlyIfNeeded = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let v = NSView(frame: p.contentView!.bounds)
        v.wantsLayer = true
        v.layer?.cornerRadius = 14
        v.layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 0.92).cgColor
        v.layer?.borderWidth = 1
        v.layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.14).cgColor

        let dotView = NSView(frame: NSRect(x: 16, y: 24, width: 8, height: 8))
        dotView.wantsLayer = true
        dotView.layer?.cornerRadius = 4
        dotView.layer?.backgroundColor = NSColor.systemRed.cgColor
        v.addSubview(dotView)
        dot = dotView

        let field = NSTextField(labelWithString: "")
        field.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        field.textColor = .white
        field.lineBreakMode = .byTruncatingHead
        field.frame = NSRect(x: 32, y: 18, width: 412, height: 20)
        field.maximumNumberOfLines = 1
        v.addSubview(field)
        label = field

        p.contentView = v
        panel = p

        // Global key monitor for Esc during capture (we never own key focus).
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            if ev.keyCode == 53 { self?.onEscape?() }
        }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            if ev.keyCode == 53 { self?.onEscape?(); return nil }
            return ev
        }
    }

    func show(_ newState: State, autoHideAfter: TimeInterval? = nil) {
        state = newState
        guard newState != .hidden else { panel?.orderOut(nil); return }
        autoHide?.invalidate(); autoHide = nil

        label?.stringValue = newState.label
        let textW = (newState.label as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium)]).width
        let width = min(max(200, textW + 64), 560)
        var f = panel!.frame
        f.size = NSSize(width: width, height: 56)
        // Bottom-center of the screen containing the mouse.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main!
        f.origin = NSPoint(x: screen.frame.midX - width / 2, y: screen.frame.minY + 96)
        panel!.setFrame(f, display: true, animate: false)

        dot?.layer?.backgroundColor = dotColor(for: newState).cgColor
        panel?.orderFrontRegardless()

        if let t = autoHideAfter {
            autoHide = Timer.scheduledTimer(withTimeInterval: t, repeats: false) { [weak self] _ in
                self?.show(.hidden)
            }
        }
    }

    private func dotColor(for s: State) -> NSColor {
        switch s {
        case .recording, .partial: return .systemRed
        case .processing: return .systemYellow
        case .inserted: return .systemGreen
        case .degraded: return .systemOrange
        case .cancelled, .error: return .systemGray
        case .hidden: return .clear
        }
    }
}
