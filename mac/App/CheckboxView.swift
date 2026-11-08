import AppKit

/// Things-style rounded-square checkbox. Ticked = filled with the accent color and a white check.
final class CheckboxView: NSView {
    /// The ghost row shows a faint plus instead of a box.
    var isAddMarker = false { didSet { needsDisplay = true } }
    var isChecked = false { didSet { if oldValue != isChecked { needsDisplay = true; pulse() } } }
    var onToggle: (() -> Void)?
    private var hovering = false { didSet { needsDisplay = true } }

    override var intrinsicContentSize: NSSize { NSSize(width: 17, height: 17) }
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel("Done")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { if !isAddMarker { onToggle?() } }
    override func accessibilityValue() -> Any? { isChecked }
    override func accessibilityPerformPress() -> Bool { onToggle?(); return true }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        if isAddMarker {
            let plus = NSBezierPath()
            plus.lineWidth = 1.4
            plus.lineCapStyle = .round
            plus.move(to: NSPoint(x: r.midX, y: r.minY + 3.5))
            plus.line(to: NSPoint(x: r.midX, y: r.maxY - 3.5))
            plus.move(to: NSPoint(x: r.minX + 3.5, y: r.midY))
            plus.line(to: NSPoint(x: r.maxX - 3.5, y: r.midY))
            NSColor.labelColor.withAlphaComponent(0.3).setStroke()
            plus.stroke()
            return
        }
        // Things-like: a soft rounded square, close to a squircle.
        let radius = r.width * 0.32
        let path = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
        if isChecked {
            Theme.accent.setFill()
            path.fill()
            let check = NSBezierPath()
            check.lineWidth = 1.8
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            check.move(to: NSPoint(x: r.minX + r.width * 0.26, y: r.minY + r.height * 0.52))
            check.line(to: NSPoint(x: r.minX + r.width * 0.43, y: r.minY + r.height * 0.70))
            check.line(to: NSPoint(x: r.minX + r.width * 0.75, y: r.minY + r.height * 0.32))
            NSColor.white.setStroke()
            check.stroke()
        } else {
            NSColor.labelColor.withAlphaComponent(hovering ? 0.6 : 0.36).setStroke()
            path.lineWidth = 1.5
            path.stroke()
        }
    }

    private func pulse() {
        guard let layer, isChecked, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let a = CAKeyframeAnimation(keyPath: "transform.scale")
        a.values = [1, 0.86, 1.06, 1]
        a.keyTimes = [0, 0.3, 0.7, 1]
        a.duration = 0.22
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.position = CGPoint(x: frame.midX, y: frame.midY)
        layer.add(a, forKey: "pulse")
    }
}
