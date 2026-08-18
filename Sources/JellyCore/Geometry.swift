import Foundation

public struct Rect: Equatable, Sendable {
    public var x, y, width, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
}

public enum ScreenEdge: Equatable, Sendable { case left, right, top, bottom }

public struct SnapResult: Equatable, Sendable {
    public let frame: Rect
    public let edge: ScreenEdge?
    public init(frame: Rect, edge: ScreenEdge?) { self.frame = frame; self.edge = edge }
}

public struct EdgeSnapCalculator: Sendable {
    public var threshold: Double
    public var visibleFraction: Double
    public init(
        threshold: Double = AppMetadata.edgeSnapThreshold,
        visibleFraction: Double = 1.0 / 3.0
    ) {
        self.threshold = threshold; self.visibleFraction = visibleFraction
    }

    public func snap(pet: Rect, screen: Rect) -> SnapResult {
        let distances: [(ScreenEdge, Double)] = [
            (.left, abs(pet.x - screen.x)), (.right, abs(pet.maxX - screen.maxX)),
            (.bottom, abs(pet.y - screen.y)), (.top, abs(pet.maxY - screen.maxY))
        ]
        guard let nearest = distances.min(by: { $0.1 < $1.1 }), nearest.1 <= threshold
        else { return SnapResult(frame: pet, edge: nil) }
        var frame = pet
        func clamp(_ value: Double, _ minimum: Double, _ maximum: Double) -> Double {
            min(max(value, minimum), maximum)
        }
        switch nearest.0 {
        case .left:
            frame.x = screen.x - pet.width * (1 - visibleFraction)
            frame.y = clamp(pet.y, screen.y, screen.maxY - pet.height)
        case .right:
            frame.x = screen.maxX - pet.width * visibleFraction
            frame.y = clamp(pet.y, screen.y, screen.maxY - pet.height)
        case .bottom:
            frame.y = screen.y - pet.height * (1 - visibleFraction)
            frame.x = clamp(pet.x, screen.x, screen.maxX - pet.width)
        case .top:
            frame.y = screen.maxY - pet.height * visibleFraction
            frame.x = clamp(pet.x, screen.x, screen.maxX - pet.width)
        }
        return SnapResult(frame: frame, edge: nearest.0)
    }
}

public struct PixelSize: Equatable, Sendable {
    public let width, height: Int
    public init(width: Int, height: Int) { self.width = width; self.height = height }
}

public enum CaptureSizing {
    public static func fit(width: Int, height: Int, maximumDimension: Int) -> PixelSize {
        let longest = max(width, height)
        guard longest > maximumDimension else { return PixelSize(width: width, height: height) }
        let scale = Double(maximumDimension) / Double(longest)
        return PixelSize(
            width: Int((Double(width) * scale).rounded()),
            height: Int((Double(height) * scale).rounded())
        )
    }
}

public enum BubbleLayout {
    public static func frame(
        pet: Rect,
        bubbleSize: PixelSize,
        screen: Rect,
        gap: Double = 8
    ) -> Rect {
        let width = Double(bubbleSize.width), height = Double(bubbleSize.height)
        let left = pet.x - width + pet.width * 0.35
        var x = left >= screen.x ? left : pet.maxX - pet.width * 0.35
        var y = pet.maxY - height * 0.35
        x = min(max(x, screen.x + gap), screen.maxX - width - gap)
        y = min(max(y, screen.y + gap), screen.maxY - height - gap)
        return Rect(x: x, y: y, width: width, height: height)
    }
}
