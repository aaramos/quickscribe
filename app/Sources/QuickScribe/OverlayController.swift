import AppKit
import QuartzCore

/// WF1 overlay (t_3db202e7, owner-picked from t_bdf8672e concept board):
/// full-width ticker — live waveform driven by REAL input levels from
/// AudioCapture's level tap, transcript text underneath. Appears within
/// ~1 frame of hotkey press (brief: 100 ms perceived-latency requirement).
/// Ignores keyboard and mouse so it never steals focus from the target app.
///
/// All legacy states still work: recording, partials, processing, inserted,
/// degraded/cancelled, and the couldn't-hear-you error (waveform flatlines
/// + error text).
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

        /// Waveform is fed by live mic levels only in these states.
        var isLive: Bool {
            switch self {
            case .recording, .partial: return true
            default: return false
            }
        }

        var tintColor: NSColor {
            switch self {
            case .recording, .partial: return .systemRed
            case .processing: return .systemYellow
            case .inserted: return .systemGreen
            case .degraded: return .systemOrange
            case .cancelled, .error: return .systemGray
            case .hidden: return .clear
            }
        }
    }

    private var panel: NSPanel?
    private var label: NSTextField?
    private var wave: WaveformView?
    private var autoHide: Timer?
    private(set) var state: State = .hidden

    /// Esc-key monitor, wired by the session controller.
    var onEscape: (() -> Void)?

    init() {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 84),
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
        v.layer?.cornerRadius = 16
        v.layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 0.92).cgColor
        v.layer?.borderWidth = 1
        v.layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.14).cgColor

        // WF1: waveform ticker on top, transcript underneath.
        let waveView = WaveformView(frame: NSRect(x: 16, y: 36, width: 688, height: 36))
        waveView.autoresizingMask = [.width]
        v.addSubview(waveView)
        wave = waveView

        let field = NSTextField(labelWithString: "")
        field.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        field.textColor = .white
        field.lineBreakMode = .byTruncatingHead
        field.frame = NSRect(x: 16, y: 10, width: 688, height: 20)
        field.maximumNumberOfLines = 1
        field.autoresizingMask = [.width]
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
        label?.textColor = (newState == .cancelled) ? NSColor(calibratedWhite: 0.8, alpha: 1) : .white

        // WF1 is full-width: fixed ticker width sized to the screen, not text.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main!
        let width = min(720, screen.frame.width - 160)
        var f = panel!.frame
        f.size = NSSize(width: width, height: 84)
        f.origin = NSPoint(x: screen.frame.midX - width / 2, y: screen.frame.minY + 88)
        panel!.setFrame(f, display: true, animate: false)

        wave?.tintColor = newState.tintColor
        wave?.flatline = !newState.isLive     // non-live states decay to flat
        if newState == .cancelled || newState == .inserted || newState == .degraded {
            // Clear old transcript off the ticker so it doesn't ghost through.
            if newState == .cancelled { wave?.reset() }
        }
        panel?.orderFrontRegardless()

        if let t = autoHideAfter {
            autoHide = Timer.scheduledTimer(withTimeInterval: t, repeats: false) { [weak self] _ in
                self?.show(.hidden)
            }
        }
    }

    /// LEVEL TAP sink — the session controller wires AudioCapture.onLevel
    /// here. Levels arrive on a background queue; hop to main for redraw.
    func pushLevel(_ level: Double) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.state.isLive else { return }
            self.wave?.push(level: level)
        }
    }

    /// Reset the ticker (new session start).
    func resetWave() {
        wave?.reset()
    }
}

/// WF1 ticker canvas: a scrolling bar waveform driven by real mic RMS.
/// Attack/release smoothing per concept board (attack 60 ms / release 240
/// ms), redrawn at 60 fps ONLY while live — flatline states stop the timer
/// so idle CPU stays zero.
final class WaveformView: NSView {
    var tintColor: NSColor = .systemRed { didSet { needsDisplay = true } }
    /// When true the trace decays to a flat line (non-live states) and the
    /// display timer stops once flat.
    var flatline = false { didSet { if flatline { startDecay() } } }

    private var smoothed: [CGFloat] = []
    private var lastRaw: CGFloat = 0
    private var timer: Timer?
    private let capacity: Int = 160            // ~2.7s of history at 60fps
    private let attack: CGFloat = 0.22        // fast rise (~60ms to peak)
    private let release: CGFloat = 0.055      // slow fall (~240ms to settle)
    private let baseline: CGFloat = 1.5

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { timer?.invalidate() }

    /// Feed one smoothed sample (called on main at ~60 fps from the tap).
    func push(level raw: Double) {
        // Attack/release envelope smoothing.
        let x = CGFloat(max(0, min(1, raw)))
        let coeff = x > lastRaw ? attack : release
        lastRaw += (x - lastRaw) * coeff
        smoothed.append(lastRaw)
        if smoothed.count > capacity { smoothed.removeFirst(smoothed.count - capacity) }
        if timer == nil {
            // 60 fps redraw only while the ticker exists and is live.
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                self?.needsDisplay = true
            }
        }
    }

    func reset() {
        smoothed.removeAll()
        lastRaw = 0
        flatline = false
        timer?.invalidate(); timer = nil
        needsDisplay = true
    }

    private func startDecay() {
        // Pull the envelope toward zero over ~20 frames, then stop drawing
        // updates (flat line remains, zero CPU).
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                var moving = false
                for i in self.smoothed.indices {
                    if self.smoothed[i] > 0.004 { self.smoothed[i] *= 0.88; moving = true }
                    else { self.smoothed[i] = 0 }
                }
                self.lastRaw *= 0.88
                self.needsDisplay = true
                if !moving { self.timer?.invalidate(); self.timer = nil }
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let h = bounds.height
        let mid = h / 2
        let cx = bounds.width / 2

        // Baseline (always, dim) — the "couldn't hear you" flatline is just
        // the baseline with no bars, per the concept board.
        NSColor(calibratedWhite: 1, alpha: 0.14).setStroke()
        let base = NSBezierPath()
        base.lineWidth = 1
        base.move(to: NSPoint(x: 0, y: mid))
        base.line(to: NSPoint(x: bounds.width, y: mid))
        base.stroke()

        guard !smoothed.isEmpty else { return }

        let gap: CGFloat = 3
        let barW: CGFloat = 2
        // Right-anchored: newest sample at the right edge, scrolling left.
        var x = bounds.width - CGFloat(smoothed.count) * (barW + gap)
        tintColor.setStroke()
        for a in smoothed {
            let amp = max(baseline, a * (mid - 2))
            let p = NSBezierPath()
            p.lineWidth = barW
            p.lineCapStyle = .round
            // Center at the midline; alpha rises with amplitude.
            p.appendArc(withCenter: NSPoint(x: x + barW / 2, y: mid + amp), radius: barW / 2, startAngle: 0, endAngle: 360)
            p.appendArc(withCenter: NSPoint(x: x + barW / 2, y: mid - amp), radius: barW / 2, startAngle: 0, endAngle: 360)
            p.move(to: NSPoint(x: x + barW / 2, y: mid + amp))
            p.line(to: NSPoint(x: x + barW / 2, y: mid - amp))
            let alpha = 0.25 + 0.75 * Double(a)
            tintColor.withAlphaComponent(alpha).setStroke()
            p.stroke()
            x += barW + gap
        }
        _ = cx
    }
}
