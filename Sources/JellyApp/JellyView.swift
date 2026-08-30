import AppKit
import JellyCore

@MainActor
final class JellyView: NSView {
    static let panelWidth: CGFloat = 96
    static let panelHeight: CGFloat = 104
    private static let baseSpriteHeight: CGFloat = 88
    private static let columns = 8
    private static let rows = 8
    private static let successHeadroom: CGFloat = 40.0 / 256.0
    private static let successBottomTrim: CGFloat = 24.0 / 256.0
    private static let packagedSheet: NSImage = {
        let packaged = Bundle.main.resourceURL?.appendingPathComponent("PetSprites.png")
        let url = packaged.flatMap { FileManager.default.isReadableFile(atPath: $0.path) ? $0 : nil }
            ?? Bundle.module.url(forResource: "PetSprites", withExtension: "png")
        guard let url, let image = NSImage(contentsOf: url) else {
            fatalError("PetSprites.png is missing or invalid")
        }
        return image
    }()
    private(set) var renderedActivity: PetActivity = .idle
    var onClick: (() -> Void)?
    var onRightClick: ((NSPoint) -> Void)?
    var onDragBegan: ((NSPoint) -> Void)?
    var onDragChanged: ((NSPoint) -> Void)?
    var onDragEnded: (() -> Void)?
    private var sheet = packagedSheet
    private var usesPackagedSheet = true
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
    override var isOpaque: Bool { false }
    func setSpriteSheet(at url: URL?) throws {
        guard let url else {
            sheet = Self.packagedSheet
            usesPackagedSheet = true
            needsDisplay = true
            return
        }
        guard let image = NSImage(contentsOf: url) else {
            throw NSError(
                domain: AppMetadata.bundleIdentifier, code: 8,
                userInfo: [NSLocalizedDescriptionKey:
                    "自定义宠物必须是可读取的正方形 8×8 PNG 精灵图。"]
            )
        }
        sheet = image
        usesPackagedSheet = false
        needsDisplay = true
    }
    @discardableResult
    func apply(activity: PetActivity) -> Bool {
        guard activity != renderedActivity || animationTimer == nil else { return false }
        renderedActivity = activity
        animationFrame = 0
        animationDirection = 1
        needsDisplay = true
        setAccessibilityLabel(activity.label)
        animationTimer?.invalidate()
        animationTimer = Timer.scheduledTimer(withTimeInterval: activity.frameDuration, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.advanceFrame() }
        }
        return true
    }
    override func draw(_ dirtyRect: NSRect) {
        let cell = NSSize(
            width: sheet.size.width / CGFloat(Self.columns),
            height: sheet.size.height / CGFloat(Self.rows)
        )
        let column = frameIndex % Self.columns, row = frameIndex / Self.columns
        let base = NSRect(
            x: CGFloat(column) * cell.width,
            y: sheet.size.height - CGFloat(row + 1) * cell.height,
            width: cell.width, height: cell.height
        )
        var source = base
        if usesPackagedSheet, renderedActivity == .success {
            let trim = cell.height * Self.successBottomTrim
            source.origin.y += trim
            source.size.height += cell.height * Self.successHeadroom - trim
        }
        let baseHeight = min(bounds.height, bounds.width * Self.baseSpriteHeight / Self.panelWidth)
        let destination = NSRect(
            x: bounds.minX,
            y: bounds.minY + baseHeight * (source.minY - base.minY) / base.height,
            width: bounds.width,
            height: min(bounds.height, baseHeight * source.height / base.height)
        )
        sheet.draw(
            in: destination, from: source, operation: .sourceOver, fraction: 1,
            respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high]
        )
    }
    func reactToTap() { advanceFrame() }
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
    private var frameIndex: Int {
        (PetActivity.allCases.firstIndex(of: renderedActivity) ?? 0) * 8 + animationFrame
    }
    private func advanceFrame() {
        animationFrame += animationDirection
        if animationFrame == 7 { animationDirection = -1 }
        if animationFrame == 0 { animationDirection = 1 }
        needsDisplay = true
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
