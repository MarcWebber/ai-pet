import AppKit

@MainActor
final class SoftGlassView: NSVisualEffectView {
    override var isOpaque: Bool { false }

    init(cornerRadius: CGFloat = 24) {
        super.init(frame: .zero)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.24).cgColor
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { nil }
}

@MainActor
final class CartoonBackdropView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let base = NSColor.windowBackgroundColor
        let top = base.blended(withFraction: 0.12, of: .systemPurple) ?? base
        let bottom = base.blended(withFraction: 0.10, of: .systemPink) ?? base
        NSGradient(colors: [top, bottom])?.draw(in: bounds, angle: -90)
        [
            (NSPoint(x: bounds.maxX - 68, y: 62), CGFloat(34), NSColor.systemPink),
            (NSPoint(x: bounds.maxX - 124, y: 116), CGFloat(15), NSColor.systemOrange),
            (NSPoint(x: 52, y: bounds.maxY - 78), CGFloat(25), NSColor.systemPurple)
        ].forEach { center, radius, color in
            let rect = NSRect(
                x: center.x - radius, y: center.y - radius,
                width: radius * 2, height: radius * 2
            )
            color.withAlphaComponent(0.09).setFill()
            NSBezierPath(ovalIn: rect).fill()
        }
    }
}

@MainActor
final class CartoonCardView: NSView {
    let tint: NSColor
    override var isFlipped: Bool { true }

    init(tint: NSColor) {
        self.tint = tint
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 1, dy: 1),
            xRadius: 24,
            yRadius: 24
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
        tint.withAlphaComponent(0.56).setFill()
        NSBezierPath(
            roundedRect: NSRect(x: 22, y: 8, width: min(66, bounds.width - 44), height: 5),
            xRadius: 2.5,
            yRadius: 2.5
        ).fill()
    }
}

@MainActor
final class CartoonIconView: NSView {
    private let image = NSImageView()
    private let tint: NSColor
    override var intrinsicContentSize: NSSize { .init(width: 36, height: 36) }

    init(symbolName: String, tint: NSColor) {
        self.tint = tint
        super.init(frame: .zero)
        image.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(.init(pointSize: 16, weight: .semibold))
        image.contentTintColor = tint
        image.translatesAutoresizingMaskIntoConstraints = false
        addSubview(image)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 36),
            heightAnchor.constraint(equalToConstant: 36),
            image.centerXAnchor.constraint(equalTo: centerXAnchor),
            image.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
        tint.withAlphaComponent(0.14).setFill()
        circle.fill()
        tint.withAlphaComponent(0.34).setStroke()
        circle.stroke()
    }
}

@MainActor
final class CartoonButton: NSButton {
    private var accent = NSColor.systemPurple
    private var filled = false
    private var hovering = false
    private var tracking: NSTrackingArea?

    var isCartoonStyled: Bool {
        !isBordered && image != nil && (layer?.cornerRadius ?? 0) >= 10
    }
    var isContentCentered: Bool { alignment == .center && imagePosition == .imageLeading }
    override var isEnabled: Bool { didSet { updateAppearance() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        alignment = .center
        imagePosition = .imageLeading
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.cornerCurve = .continuous
    }

    required init?(coder: NSCoder) { nil }

    func applyStyle(
        title: String,
        symbolName: String,
        color: NSColor,
        filled: Bool,
        font: NSFont
    ) {
        self.title = title
        image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: title
        )?.withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        self.font = font
        accent = color
        self.filled = filled
        toolTip = title
        setAccessibilityLabel(title)
        updateAppearance()
    }

    override var intrinsicContentSize: NSSize {
        .init(width: max(104, super.intrinsicContentSize.width + 16), height: filled ? 38 : 30)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(tracking!)
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; updateAppearance() }
    override func mouseExited(with event: NSEvent) { hovering = false; updateAppearance() }

    private func updateAppearance() {
        guard let layer else { return }
        let foreground: NSColor = !isEnabled ? .disabledControlTextColor
            : filled ? .white : accent
        let background = !isEnabled ? accent.withAlphaComponent(0.06)
            : filled ? accent : accent.withAlphaComponent(hovering ? 0.18 : 0.12)
        contentTintColor = foreground
        layer.backgroundColor = background.cgColor
        layer.borderWidth = filled ? 0 : 1
        layer.borderColor = accent.withAlphaComponent(0.28).cgColor
        alphaValue = isEnabled ? 1 : 0.72
    }
}
