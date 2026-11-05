import AppKit
import QuartzCore

/// The floating pill under the menu bar, in the spirit of the iPhone's Dynamic Island.
/// It uses Apple's own Liquid Glass, SF Symbols, system font and system colors, so it
/// follows light and dark mode, Reduce Motion and Reduce Transparency by itself. It starts
/// small and grows to show the last few words as you speak. Those words are raw, so the
/// pasted text can differ once cleanup has run.
@MainActor
final class OverlayController {
    enum State: Equatable {
        case hidden
        case recording(mode: String, words: String = "")
        case processing
        case inserted
        case degraded        // model unavailable, refused or too slow: tidied text inserted
        case cancelled
        case copied          // nowhere to paste: the text is on the clipboard
        case modeChanged(String)
        case error(String)

        var message: String {
            switch self {
            case .hidden, .inserted: return ""
            case .recording(let mode, let words): return words.isEmpty ? mode : words
            case .processing: return "Cleaning up…"
            case .degraded: return "Inserted without AI cleanup"
            case .cancelled: return "Cancelled"
            case .copied: return "Copied to clipboard"
            case .modeChanged(let name): return name
            case .error(let text): return text
            }
        }

        var symbol: (name: String, color: NSColor)? {
            switch self {
            case .hidden, .recording, .processing: return nil
            case .inserted: return ("checkmark.circle.fill", .systemGreen)
            case .degraded: return ("exclamationmark.triangle.fill", .systemOrange)
            case .cancelled: return ("xmark.circle.fill", .secondaryLabelColor)
            case .copied: return ("doc.on.clipboard.fill", .controlAccentColor)
            case .modeChanged: return ("text.badge.checkmark", .controlAccentColor)
            case .error: return ("exclamationmark.circle.fill", .systemOrange)
            }
        }

        var isRecording: Bool {
            if case .recording = self { return true }
            return false
        }
    }

    private static let height: CGFloat = 40
    // The owner tunes the pill's size from these two lines.
    static let recordingHeight: CGFloat = 98
    static let maxWidth: CGFloat = 650
    /// What a single message line has to fit in at the pill's font: the panel
    /// max minus the row's padding. Notices are written to this budget.
    /// What the one-line message can measure across: the pill's width less
    /// its padding. With maxWidth up to 650 this grows with it automatically.
    static let messageTextBudget: CGFloat = maxWidth - 60
    private static let gapBelowMenuBar: CGFloat = 8

    private let panel: NSPanel
    private let icon = NSImageView()
    private let spinner = NSProgressIndicator()
    private let levels = WaveformView()
    private let label = NSTextField(labelWithString: "")
    private let row = NSStackView()
    private let glass = NSGlassEffectView()
    private var stackedWidthLimits: [NSLayoutConstraint] = []
    private var autoHide: Timer?
    private(set) var state: State = .hidden

    /// Esc-key monitor, wired by the session controller.
    var onEscape: (() -> Void)?

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 120, height: Self.height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false       // Liquid Glass draws its own edge and depth
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = makeContent()

        // Global monitor because this app never takes key focus.
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { MainActor.assumeIsolated { self?.onEscape?() } }
        }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            MainActor.assumeIsolated { self?.onEscape?() }
            return nil
        }
    }

    private func makeContent() -> NSView {
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.alignment = .center
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        [icon, spinner, levels, label].forEach(row.addArrangedSubview)
        // A centered vertical stack ignores its side padding, so hold the content to it.
        stackedWidthLimits = [levels, label].map {
            $0.widthAnchor.constraint(lessThanOrEqualTo: row.widthAnchor, constant: -36)
        }
        arrange(forRecording: false)
        glass.contentView = row
        return glass
    }

    /// While recording: waves centered on top, words centered below. Otherwise one line.
    private func arrange(forRecording recording: Bool) {
        stackedWidthLimits.forEach { $0.isActive = recording }
        row.orientation = recording ? .vertical : .horizontal
        row.alignment = recording ? .centerX : .centerY
        row.spacing = recording ? 2 : 8
        row.edgeInsets = recording
            ? NSEdgeInsets(top: 6, left: 18, bottom: 8, right: 18)
            : NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 16)
        glass.cornerRadius = recording ? 28 : Self.height / 2
    }

    func show(_ newState: State, autoHideAfter: TimeInterval? = nil) {
        autoHide?.invalidate()
        autoHide = nil
        let wasHidden = state == .hidden || !panel.isVisible
        state = newState
        guard newState != .hidden else { fadeOut(); return }

        apply(newState)
        place(animated: !wasHidden)
        if wasHidden { fadeIn() }

        if let autoHideAfter {
            autoHide = Timer.scheduledTimer(withTimeInterval: autoHideAfter, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.show(.hidden) }
            }
        }
    }

    private func apply(_ state: State) {
        arrange(forRecording: state.isRecording)
        label.stringValue = state.message
        label.isHidden = state.message.isEmpty
        if case .recording(_, let words) = state {
            label.textColor = words.isEmpty ? .secondaryLabelColor : .labelColor
            label.lineBreakMode = .byTruncatingHead   // the newest words matter most
        } else {
            label.textColor = .labelColor
            label.lineBreakMode = .byTruncatingTail
        }
        levels.isHidden = !state.isRecording
        levels.isAnimating = state.isRecording
        if state == .processing {
            spinner.isHidden = false
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
            spinner.isHidden = true
        }
        if let symbol = state.symbol {
            icon.image = NSImage(systemSymbolName: symbol.name, accessibilityDescription: state.message)
            icon.contentTintColor = symbol.color
            icon.isHidden = false
        } else {
            icon.isHidden = true
        }
        panel.setAccessibilityLabel(state.message.isEmpty ? "Inserted" : state.message)
    }

    /// Top center of whichever screen the pointer is on, just under the menu bar.
    private func place(animated: Bool) {
        panel.contentView?.layoutSubtreeIfNeeded()
        let fitted = row.fittingSize.width
        let height = state.isRecording ? Self.recordingHeight : Self.height
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main ?? NSScreen.screens.first else { return }
        var width = min(max(fitted, height), min(Self.maxWidth, screen.visibleFrame.width - 48))
        // While words are arriving it only grows, so it doesn't jitter from word to word.
        if animated, state.isRecording, panel.frame.height == height { width = max(width, panel.frame.width) }
        let frame = NSRect(x: screen.visibleFrame.midX - width / 2,
                           y: screen.visibleFrame.maxY - height - Self.gapBelowMenuBar,
                           width: width, height: height)
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.setFrame(frame, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
        }
    }

    private func fadeIn() {
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
    }

    private func fadeOut() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // A new state may have arrived during the fade.
                if self?.state == .hidden { self?.panel.orderOut(nil) }
            }
        })
    }

    /// Levels arrive on the audio thread.
    nonisolated func pushLevel(_ level: Double) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.state.isRecording else { return }
                self.levels.push(level)
            }
        }
    }

    /// For layout tests: the pill's current window and content.
    var panelFrameForTesting: NSRect { panel.frame }
    var panelContentForTesting: NSView? { panel.contentView }
    var panelIsVisibleForTesting: Bool { panel.isVisible }

    func resetLevels() {
        levels.reset()
    }
}

/// Flowing strands of colored light whose height follows the real mic level. It only
/// redraws while recording, at 30 frames a second, so it costs nothing the rest of the time.
final class WaveformView: NSView {
    private static let strandCount = 9
    private static let violet = NSColor(srgbRed: 0.56, green: 0.42, blue: 1.0, alpha: 1)
    private static let indigo = NSColor(srgbRed: 0.33, green: 0.27, blue: 0.98, alpha: 1)
    private static let blue = NSColor(srgbRed: 0.20, green: 0.36, blue: 1.0, alpha: 1)
    private static let gradient = NSGradient(colors: [violet, indigo, blue, indigo, violet])
    /// The bright center line. White glows on dark glass but would vanish on light glass,
    /// so light mode uses a deep indigo instead.
    private static let glowOnDark = NSGradient(colors: [violet, .white, .white, .white, violet])
    private static let coreOnLight = NSGradient(colors: [indigo, blue, indigo])

    private var target: CGFloat = 0
    private var level: CGFloat = 0
    private var phase: CGFloat = 0
    private var link: CADisplayLink?

    /// Starts and stops the redraws.
    var isAnimating = false {
        didSet {
            guard isAnimating != oldValue else { return }
            link?.invalidate()
            link = nil
            guard isAnimating else { return }
            let newLink = displayLink(target: self, selector: #selector(step))
            newLink.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 30, preferred: 30)
            newLink.add(to: .main, forMode: .common)
            link = newLink
        }
    }

    // The wave box: about a quarter larger all round, also for the owner to tune.
    static let waveWidth: CGFloat = 225
    static let waveHeight: CGFloat = 55
    override var intrinsicContentSize: NSSize { NSSize(width: Self.waveWidth, height: Self.waveHeight) }

    func push(_ newLevel: Double) {
        target = CGFloat(Self.loudness(fromLevel: newLevel))
    }

    /// Normal speech is far quieter than the mic's full range, so a straight reading barely
    /// registers. Ears hear loudness in decibels, so this maps the range speech really uses
    /// onto the waves' full height. The two numbers are the owner's tuning knobs: the floor
    /// is where pauses go flat, the ceiling is where the top of a speaking voice sits.
    /// The ceiling came down from -22 dB so ordinary speech fills the taller waves.
    static let silenceFloorDb = -48.0
    static let topOfSpeechDb = -26.0
    static func loudness(fromLevel level: Double) -> Double {
        let rms = level / 6       // AudioCapture reports its level as rms x 6
        guard rms > 0 else { return 0 }
        return max(0, min(1, (20 * log10(rms) - silenceFloorDb) / (topOfSpeechDb - silenceFloorDb)))
    }

    func reset() {
        target = 0
        level = 0
        needsDisplay = true
    }

    @objc private func step() {
        level += (target - level) * (target > level ? 0.6 : 0.16)
        // With Reduce Motion the strands stop flowing and only rise and fall with your voice.
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { phase += 0.08 + level * 0.22 }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        for strand in 0..<Self.strandCount {
            let offset = CGFloat(strand) / CGFloat(Self.strandCount - 1) * 2 - 1    // -1 to 1
            context.saveGState()
            context.setAlpha(1 - abs(offset) * 0.65)
            context.setLineCap(.round)
            context.addPath(strandPath(offset: offset).cgPath)
            context.setLineWidth(strand == Self.strandCount / 2 ? 1.8 : 1)
            context.replacePathWithStrokedPath()
            context.clip()
            let isCore = strand == Self.strandCount / 2
            (isCore ? coreGradient : Self.gradient)?.draw(in: bounds, angle: 0)
            context.restoreGState()
        }
    }

    private var coreGradient: NSGradient? {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? Self.glowOnDark : Self.coreOnLight
    }

    /// One strand: a few overlapping waves that fade to nothing at both ends. A small
    /// floor keeps it alive during pauses instead of collapsing to a single flat line.
    private func strandPath(offset: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        let middle = bounds.midY
        let reach = bounds.height / 2 - 1
        let loudness = 0.1 + level * 0.9
        for x in stride(from: CGFloat(0), through: bounds.width, by: 1.5) {
            let along = x / max(bounds.width, 1)
            let fade = sin(along * .pi)
            let shift = offset * 1.1
            let wave = sin(along * 15 + phase + shift) * 0.55
                + sin(along * 26 - phase * 1.3 + shift * 1.6) * 0.3
                + sin(along * 7 + phase * 0.6 - shift) * 0.25
            let point = NSPoint(x: x, y: middle + wave * fade * loudness * reach * (1 - abs(offset) * 0.3))
            if x == 0 { path.move(to: point) } else { path.line(to: point) }
        }
        return path
    }
}
