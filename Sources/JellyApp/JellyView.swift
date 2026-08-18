import AppKit
import JellyCore

@MainActor
class JellySpriteView: NSView {
    override var isOpaque: Bool { false }

    private static let columns = 8
    private static let rows = 8
    static let sheet: NSImage = {
        let packaged = Bundle.main.executableURL?
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/PetSprites.png")
        let url = packaged.flatMap {
            FileManager.default.fileExists(atPath: $0.path) ? $0 : nil
        } ?? Bundle.module.url(forResource: "PetSprites", withExtension: "png")
        guard let url, let image = NSImage(contentsOf: url) else {
            fatalError("PetSprites.png is missing or invalid")
        }
        return image
    }()

    var frameIndex = 0 { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let source = spriteSourceRect()
        let destination = spriteDestinationRect(for: source)
        guard !source.isEmpty, !destination.isEmpty else { return }
        Self.sheet.draw(
            in: destination,
            from: source,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
    }

    func spriteSourceRect() -> NSRect {
        let cell = NSSize(
            width: Self.sheet.size.width / CGFloat(Self.columns),
            height: Self.sheet.size.height / CGFloat(Self.rows)
        )
        let column = frameIndex % Self.columns
        let row = frameIndex / Self.columns
        return NSRect(
            x: CGFloat(column) * cell.width,
            y: Self.sheet.size.height - CGFloat(row + 1) * cell.height,
            width: cell.width,
            height: cell.height
        )
    }

    func spriteDestinationRect(for source: NSRect) -> NSRect {
        bounds
    }

    static func verifySpriteAsset() -> String {
        let valid = sheet.size.width > 0
            && sheet.size.height > 0
            && abs(
                sheet.size.width / CGFloat(columns)
                    - sheet.size.height / CGFloat(rows)
            ) < 1
        return "Sprite asset verification \(valid ? "passed" : "failed")."
    }
}

@MainActor
final class JellyView: JellySpriteView {
    /// The atlas's success row intentionally jumps up to 36 source pixels
    /// above its nominal cell. Keep a little extra room so AppKit does not
    /// crop the top of the jelly at the peak of the animation.
    static let successSourceHeadroomRatio: CGFloat = 40.0 / 256.0
    /// The bottom of the nominal success cell is empty, apart from a few
    /// pixels spilled upward by the next atlas row. Trim that contaminated
    /// band while preserving the success animation's original coordinates.
    static let successSourceBottomTrimRatio: CGFloat = 24.0 / 256.0
    static let panelWidth: CGFloat = 96
    static let baseSpriteHeight: CGFloat = 88
    static let panelHeadroom: CGFloat = 16
    static let panelHeight = baseSpriteHeight + panelHeadroom

    private(set) var renderedActivity: PetActivity = .idle
    var onClick: (() -> Void)?
    var onRightClick: ((NSPoint) -> Void)?
    var onDragBegan: ((NSPoint) -> Void)?
    var onDragChanged: ((NSPoint) -> Void)?
    var onDragEnded: (() -> Void)?

    private var animationTimer: Timer?
    private var mouseDownLocation: NSPoint?
    private var dragged = false
    private var animationFrame = 0
    private var animationDirection = 1

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        apply(activity: .idle)
    }

    required init?(coder: NSCoder) { nil }

    func apply(activity: PetActivity) {
        renderedActivity = activity
        animationFrame = 0
        animationDirection = 1
        updateFrame()
        setAccessibilityLabel(activity.label)
        animationTimer?.invalidate()
        animationTimer = Timer.scheduledTimer(withTimeInterval: activity.frameDuration, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.advanceFrame()
            }
        }
    }

    static func verifyBehaviorConfiguration() -> String {
        let assetPassed = verifySpriteAsset().hasSuffix("passed.")
        let requiredHeight = baseSpriteHeight
            * (1 + successSourceHeadroomRatio)
        let layoutPassed = panelHeight >= ceil(requiredHeight)
            && successSourceBottomTrimRatio < 1
            && successSourceBottomTrimRatio < successSourceHeadroomRatio
        return "Sprite asset and jump headroom verification \(assetPassed && layoutPassed ? "passed" : "failed")."
    }

    override func spriteSourceRect() -> NSRect {
        var source = super.spriteSourceRect()
        guard renderedActivity == .success else { return source }
        let cellHeight = source.height
        let bottomTrim = cellHeight * Self.successSourceBottomTrimRatio
        source.origin.y += bottomTrim
        source.size.height += cellHeight * Self.successSourceHeadroomRatio
            - bottomTrim
        return source
    }

    override func spriteDestinationRect(for source: NSRect) -> NSRect {
        let cell = super.spriteSourceRect()
        let baseHeight = min(
            bounds.height,
            bounds.width * Self.baseSpriteHeight / Self.panelWidth
        )
        let verticalOffset = baseHeight
            * (source.minY - cell.minY) / cell.height
        let scaledHeight = baseHeight * source.height / cell.height
        return NSRect(
            x: bounds.minX,
            y: bounds.minY + verticalOffset,
            width: bounds.width,
            height: min(bounds.height, scaledHeight)
        )
    }

    func reactToTap() { advanceFrame() }
    func showAttention() { apply(activity: .failure) }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return onClick != nil
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = NSEvent.mouseLocation
        dragged = false
        onDragBegan?(NSEvent.mouseLocation)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownLocation else { return }
        let current = NSEvent.mouseLocation
        dragged = dragged || hypot(current.x - start.x, current.y - start.y) > 3
        onDragChanged?(current)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownLocation = nil
        dragged ? onDragEnded?() : onClick?()
        dragged = false
    }

    override func rightMouseUp(with event: NSEvent) {
        onRightClick?(event.locationInWindow)
    }

    private func updateFrame() {
        let state = PetActivity.allCases.firstIndex(of: renderedActivity) ?? 0
        frameIndex = state * 8 + animationFrame
    }

    private func advanceFrame() {
        animationFrame += animationDirection
        if animationFrame == 7 { animationDirection = -1 }
        if animationFrame == 0 { animationDirection = 1 }
        updateFrame()
    }
}

private extension PetActivity {
    var frameDuration: TimeInterval {
        switch self {
        case .idle: 0.14
        case .observing, .thinking, .verifying: 0.11
        case .locating, .failure: 0.10
        case .acting, .success: 0.083
        }
    }
}

@MainActor
final class JellyMarkView: JellySpriteView {
    private let preferredSize: CGFloat

    init(size: CGFloat = 44) {
        preferredSize = size
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
    }

    required init?(coder: NSCoder) { nil }
    override var intrinsicContentSize: NSSize {
        NSSize(width: preferredSize, height: preferredSize)
    }
}
