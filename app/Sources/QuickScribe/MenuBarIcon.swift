import AppKit

/// Icon A (waveform-pulse).
/// Exact vectors: viewBox 0 0 22 22, stroke 1.7, round caps, fill none:
///   M 7 6.5 V 15.5   M 11 4 V 18   M 15 7.5 V 14.5
/// Monochrome template image → the system tints it for light/dark menu bars.
enum MenuBarIcon {
    /// Per-bar full heights at rest (exact Icon A geometry, bottom-anchored).
    static let restBars: [(x: CGFloat, bottom: CGFloat, height: CGFloat)] = [
        (7.0, 6.5, 9.0),    // M7 6.5 V15.5
        (11.0, 4.0, 14.0),  // M11 4  V18
        (15.0, 7.5, 7.0),   // M15 7.5 V14.5
    ]

    /// Static glyph (idle / rest / dimmed variants).
    static func image(dimmed: Bool = false) -> NSImage {
        render(bars: restBars, dimmed: dimmed)
    }

    /// Equalizer micro-motion frame: bars breathe around their rest heights
    /// (±20%) at (x, phase). ONLY called while recording — at rest the icon
    /// is the static `image()` so idle CPU stays zero.
    static func animatedImage(phase: Double, dimmed: Bool = false) -> NSImage {
        let phases = [0.0, 2.1, 4.2]   // staggered so bars don't move in unison
        var bars: [(CGFloat, CGFloat, CGFloat)] = []
        for (b, ph) in zip(restBars, phases) {
            let scale = 1.0 + 0.20 * CGFloat(sin(phase + ph))
            let h = b.height * scale
            bars.append((b.x, b.bottom - (h - b.height) / 2, h))
        }
        return render(bars: bars, dimmed: dimmed)
    }

    private static func render(bars: [(CGFloat, CGFloat, CGFloat)], dimmed: Bool) -> NSImage {
        let img = NSImage(size: NSSize(width: 22, height: 22), flipped: false) { _ in
            NSColor.black.set()
            for b in bars {
                let p = NSBezierPath()
                p.lineWidth = 1.7
                p.lineCapStyle = .round
                p.move(to: NSPoint(x: b.0, y: b.1))
                p.line(to: NSPoint(x: b.0, y: b.1 + b.2))
                p.stroke()
            }
            return true
        }
        img.isTemplate = !dimmed
        if dimmed {
            // Cleanup unavailable: keep the glyph, just dim it (alpha is baked,
            // template off).
            let dim = NSImage(size: NSSize(width: 22, height: 22), flipped: false) { _ in
                img.draw(in: NSRect(x: 0, y: 0, width: 22, height: 22),
                        from: .zero, operation: .sourceOver, fraction: 0.35)
                return true
            }
            dim.isTemplate = false
            return dim
        }
        return img
    }
}
