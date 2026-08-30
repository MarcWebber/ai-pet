import Foundation

public enum ElementRole: String, Decodable, CaseIterable, Equatable, Sendable {
    case button, link, textField, checkBox, radioButton
    case menuItem, popUpButton, scrollArea
    /// Read-only structure roles. These make stable ancestor locators possible
    /// without turning every accessibility node into model-facing noise.
    case dialog, group, list, listItem, row, cell, tab, heading, staticText
}

public struct NormalizedRect: Equatable, Sendable {
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

public struct ScreenElement: Equatable, Sendable {
    public let id: String
    /// An observation-scoped relationship. Both this ID and `id` are invalid
    /// once the UI is observed again.
    public let parentID: String?
    public let role: ElementRole
    public let label: String
    public let value: String?
    public let frame: NormalizedRect
    public let isEnabled: Bool
    public init(
        id: String,
        parentID: String? = nil,
        role: ElementRole,
        label: String,
        value: String? = nil,
        frame: NormalizedRect,
        isEnabled: Bool
    ) {
        self.id = id; self.parentID = parentID
        self.role = role; self.label = label
        self.value = value; self.frame = frame; self.isEnabled = isEnabled
    }
}

public struct ScreenSemantics: Equatable, Sendable {
    public let applicationName, windowTitle: String
    public let pageURL: String?
    public let elements: [ScreenElement]
    public init(
        applicationName: String,
        windowTitle: String,
        pageURL: String? = nil,
        elements: [ScreenElement]
    ) {
        self.applicationName = applicationName
        self.windowTitle = windowTitle; self.pageURL = pageURL
        self.elements = elements
    }
}

public enum ElementTarget: Equatable, Sendable {
    case element(elementID: String)
    /// A stable recipe resolved against the latest observation immediately before execution.
    case locator(ElementLocator)
    case visual(x: Int, y: Int)
}

extension ElementTarget: Decodable {
    private enum Key: String, CodingKey { case elementID, locator, x, y }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: Key.self)
        if let id = try values.decodeIfPresent(String.self, forKey: .elementID) {
            self = .element(elementID: id)
        } else if let locator = try values.decodeIfPresent(ElementLocator.self, forKey: .locator) {
            self = .locator(locator)
        } else {
            self = .visual(
                x: try values.decode(Int.self, forKey: .x),
                y: try values.decode(Int.self, forKey: .y)
            )
        }
    }

}
