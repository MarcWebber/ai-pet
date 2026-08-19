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

@MainActor
final class CartoonButton: NSButton {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let content = NSStackView()
    private var tracking: NSTrackingArea?
    private var accentColor = NSColor.systemPurple
    private var usesFilledStyle = false
    private var isHovering = false
    private var isPressing = false

    var isCartoonStyled: Bool {
        !isBordered
            && iconView.image != nil
            && (layer?.cornerRadius ?? 0) >= 10
    }

    var isContentCentered: Bool {
        layoutSubtreeIfNeeded()
        return abs(content.frame.midX - bounds.midX) <= 0.5
            && abs(content.frame.midY - bounds.midY) <= 0.5
    }

    override var isEnabled: Bool {
        didSet { updateAppearance() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = ""
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.cornerCurve = .continuous

        iconView.imageScaling = .scaleProportionallyDown
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)

        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 6
        content.addArrangedSubview(iconView)
        content.addArrangedSubview(titleLabel)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.centerXAnchor.constraint(equalTo: centerXAnchor),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 10),
            content.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14)
        ])
        updateAppearance()
    }

    required init?(coder: NSCoder) { nil }

    func applyStyle(
        title: String,
        symbolName: String,
        color: NSColor,
        filled: Bool,
        font: NSFont
    ) {
        accentColor = color
        usesFilledStyle = filled
        titleLabel.stringValue = title
        titleLabel.font = font
        let configuration = NSImage.SymbolConfiguration(
            pointSize: 12,
            weight: .semibold
        )
        iconView.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(configuration)
        setAccessibilityLabel(title)
        toolTip = title
        invalidateIntrinsicContentSize()
        updateAppearance()
    }

    override var intrinsicContentSize: NSSize {
        let contentWidth = max(0, content.fittingSize.width)
        return NSSize(
            width: max(104, contentWidth + 26),
            height: usesFilledStyle ? 38 : 30
        )
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        updateAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        updateAppearance()
    }

    override func mouseDown(with event: NSEvent) {
        isPressing = true
        updateAppearance()
        super.mouseDown(with: event)
        isPressing = false
        updateAppearance()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    private func updateAppearance() {
        guard let layer else { return }
        let foreground: NSColor
        let background: NSColor
        let border: NSColor
        if !isEnabled {
            foreground = .disabledControlTextColor
            background = accentColor.withAlphaComponent(0.06)
            border = accentColor.withAlphaComponent(0.10)
        } else if usesFilledStyle {
            foreground = .white
            let whiteMix: CGFloat = isHovering ? 0.12 : 0
            background = accentColor.blended(
                withFraction: whiteMix,
                of: .white
            ) ?? accentColor
            border = .clear
        } else {
            foreground = accentColor
            background = accentColor.withAlphaComponent(
                isPressing ? 0.24 : (isHovering ? 0.18 : 0.12)
            )
            border = accentColor.withAlphaComponent(0.28)
        }
        layer.backgroundColor = background.cgColor
        layer.borderWidth = usesFilledStyle ? 0 : 1
        layer.borderColor = border.cgColor
        layer.shadowColor = usesFilledStyle ? accentColor.cgColor : nil
        layer.shadowOpacity = usesFilledStyle && isEnabled ? 0.18 : 0
        layer.shadowRadius = usesFilledStyle ? 5 : 0
        layer.shadowOffset = NSSize(width: 0, height: -2)
        titleLabel.textColor = foreground
        iconView.contentTintColor = foreground
        alphaValue = isPressing ? 0.86 : 1
    }
}
