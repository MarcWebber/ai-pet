import Foundation

public enum SemanticElementRole: String, Equatable, Sendable {
    case button, link, textField, checkBox, radioButton
    case menuItem, popUpButton, scrollArea
}

public struct SemanticRect: Equatable, Sendable {
    public let x, y, width, height: Int
    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var centerX: Int { x + width / 2 }
    public var centerY: Int { y + height / 2 }
    public var isValid: Bool {
        x >= 0 && y >= 0 && width > 0 && height > 0
            && x + width <= 1_000 && y + height <= 1_000
    }
}

public struct SemanticElement: Equatable, Sendable {
    public let id: String
    public let role: SemanticElementRole
    public let label: String
    public let value: String?
    public let frame: SemanticRect
    public let isEnabled: Bool
    public init(
        id: String,
        role: SemanticElementRole,
        label: String,
        value: String? = nil,
        frame: SemanticRect,
        isEnabled: Bool
    ) {
        self.id = id; self.role = role; self.label = label
        self.value = value; self.frame = frame; self.isEnabled = isEnabled
    }
}

public struct SemanticSnapshot: Equatable, Sendable {
    public let applicationName, windowTitle: String
    public let pageURL, readableText: String?
    public let elements: [SemanticElement]
    public init(
        applicationName: String,
        windowTitle: String,
        pageURL: String? = nil,
        readableText: String? = nil,
        elements: [SemanticElement]
    ) {
        self.applicationName = applicationName
        self.windowTitle = windowTitle; self.pageURL = pageURL
        self.readableText = readableText; self.elements = elements
    }
}

private enum TargetSource: String, Codable { case element, visual }

public enum ScreenActionTarget: Equatable, Sendable {
    case element(elementID: String)
    case visual(x: Int, y: Int)
}

extension ScreenActionTarget: Codable {
    private enum Key: String, CodingKey { case source, elementID, x, y }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: Key.self)
        switch try values.decode(TargetSource.self, forKey: .source) {
        case .visual:
            self = .visual(
                x: try values.decode(Int.self, forKey: .x),
                y: try values.decode(Int.self, forKey: .y)
            )
        case .element:
            self = .element(
                elementID: try values.decode(String.self, forKey: .elementID)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: Key.self)
        switch self {
        case let .visual(x, y):
            try values.encode(TargetSource.visual, forKey: .source)
            try values.encode(x, forKey: .x); try values.encode(y, forKey: .y)
        case let .element(elementID):
            try values.encode(TargetSource.element, forKey: .source)
            try values.encode(elementID, forKey: .elementID)
        }
    }
}

@MainActor
public protocol SemanticContextProviding: AnyObject {
    func snapshot(displayID: UInt32) async -> SemanticSnapshot?
}
