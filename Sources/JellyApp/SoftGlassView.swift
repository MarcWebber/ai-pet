import AppKit

@MainActor
final class SoftGlassView: NSVisualEffectView {
    override var isOpaque: Bool {
        false
    }

    init(cornerRadius: CGFloat = 24) {
        super.init(frame: .zero)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.24).cgColor
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        nil
    }
}

@MainActor
final class CartoonBackdropView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let top = NSColor.windowBackgroundColor.blended(
            withFraction: 0.12,
            of: .systemPurple
        ) ?? .windowBackgroundColor
        let bottom = NSColor.windowBackgroundColor.blended(
            withFraction: 0.10,
            of: .systemPink
        ) ?? .windowBackgroundColor
        NSGradient(colors: [top, bottom])?.draw(in: bounds, angle: -90)

        drawBubble(
            center: NSPoint(x: bounds.maxX - 68, y: 62),
            radius: 34,
            color: .systemPink
        )
        drawBubble(
            center: NSPoint(x: bounds.maxX - 124, y: 116),
            radius: 15,
            color: .systemOrange
        )
        drawBubble(
            center: NSPoint(x: 52, y: bounds.maxY - 78),
            radius: 25,
            color: .systemPurple
        )
    }

    private func drawBubble(
        center: NSPoint,
        radius: CGFloat,
        color: NSColor
    ) {
        let rect = NSRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        color.withAlphaComponent(0.09).setFill()
        NSBezierPath(ovalIn: rect).fill()
        NSColor.white.withAlphaComponent(0.18).setStroke()
        let highlight = NSBezierPath(ovalIn: rect.insetBy(dx: 3, dy: 3))
        highlight.lineWidth = 1
        highlight.stroke()
    }
}

@MainActor
final class CartoonCardView: NSView {
    let tint: NSColor
    private let cornerRadius: CGFloat
    override var isFlipped: Bool { true }

    init(tint: NSColor, cornerRadius: CGFloat = 24) {
        self.tint = tint
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let cardRect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(
            roundedRect: cardRect,
            xRadius: cornerRadius,
            yRadius: cornerRadius
        )
        let fill = NSColor.controlBackgroundColor.blended(
            withFraction: 0.16,
            of: tint
        ) ?? .controlBackgroundColor
        fill.withAlphaComponent(0.94).setFill()
        path.fill()

        tint.withAlphaComponent(0.34).setStroke()
        path.lineWidth = 1.5
        path.stroke()

        let accent = NSBezierPath(
            roundedRect: NSRect(
                x: 22,
                y: 8,
                width: min(66, max(0, bounds.width - 44)),
                height: 5
            ),
            xRadius: 2.5,
            yRadius: 2.5
        )
        tint.withAlphaComponent(0.56).setFill()
        accent.fill()

        let dotRadius: CGFloat = 3
        for index in 0..<3 {
            let dot = NSRect(
                x: bounds.maxX - 28 - CGFloat(index * 11),
                y: 9,
                width: dotRadius * 2,
                height: dotRadius * 2
            )
            tint.withAlphaComponent(0.28 + CGFloat(index) * 0.08).setFill()
            NSBezierPath(ovalIn: dot).fill()
        }
    }
}

@MainActor
final class CartoonIconView: NSView {
    private let imageView = NSImageView()
    private let tint: NSColor

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: 36, height: 36)
    }

    init(symbolName: String, tint: NSColor) {
        self.tint = tint
        super.init(frame: .zero)
        let configuration = NSImage.SymbolConfiguration(
            pointSize: 16,
            weight: .semibold
        )
        imageView.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(configuration)
        imageView.contentTintColor = tint
        imageView.imageScaling = .scaleProportionallyDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 36),
            heightAnchor.constraint(equalToConstant: 36),
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 20),
            imageView.heightAnchor.constraint(equalToConstant: 20)
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
        tint.withAlphaComponent(0.14).setFill()
        circle.fill()
        tint.withAlphaComponent(0.34).setStroke()
        circle.lineWidth = 1.2
        circle.stroke()
    }
}
