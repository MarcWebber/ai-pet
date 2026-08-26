import Foundation

public enum SemanticElementRole: String, Codable, CaseIterable, Equatable, Sendable {
    case button, link, textField, checkBox, radioButton
    case menuItem, popUpButton, scrollArea
    /// Read-only structure roles. These make stable ancestor locators possible
    /// without turning every accessibility node into model-facing noise.
    case dialog, group, list, listItem, row, cell, tab, heading, staticText
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
    /// An observation-scoped relationship. Both this ID and `id` are invalid
    /// once the UI is observed again.
    public let parentID: String?
    public let role: SemanticElementRole
    public let label: String
    public let value: String?
    public let frame: SemanticRect
    public let isEnabled: Bool
    public init(
        id: String,
        parentID: String? = nil,
        role: SemanticElementRole,
        label: String,
        value: String? = nil,
        frame: SemanticRect,
        isEnabled: Bool
    ) {
        self.id = id; self.parentID = parentID
        self.role = role; self.label = label
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

private enum TargetSource: String, Codable { case element, locator, visual }

public enum ScreenActionTarget: Equatable, Sendable {
    case element(elementID: String)
    /// A stable recipe resolved against the latest observation immediately before execution.
    case locator(SemanticElementLocator)
    case visual(x: Int, y: Int)
}

extension ScreenActionTarget: Codable {
    private enum Key: String, CodingKey { case source, elementID, locator, x, y }

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
        case .locator:
            self = .locator(
                try values.decode(SemanticElementLocator.self, forKey: .locator)
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
        case let .locator(locator):
            try values.encode(TargetSource.locator, forKey: .source)
            try values.encode(locator, forKey: .locator)
        }
    }
}

@MainActor
public protocol SemanticContextProviding: AnyObject {
    func snapshot(displayID: UInt32) async -> SemanticSnapshot?
}
