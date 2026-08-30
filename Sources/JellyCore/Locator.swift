import Foundation

/// A configuration-friendly text predicate used by stable locators.
public struct TextMatcher: Decodable, Equatable, Sendable {
    public enum Mode: String, Decodable, CaseIterable, Equatable, Sendable {
        case exact, prefix, contains
    }
    public let text: String
    public let mode: Mode
    public init(_ text: String, mode: Mode = .exact) {
        self.text = text
        self.mode = mode
    }
    private enum CodingKeys: String, CodingKey {
        case text, mode
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        text = try values.decode(String.self, forKey: .text)
        mode = try values.decodeIfPresent(Mode.self, forKey: .mode) ?? .exact
    }
    fileprivate func matches(_ candidate: String) -> Bool {
        let expected = normalized(text)
        let actual = normalized(candidate)
        guard !expected.isEmpty else { return false }
        switch mode {
        case .exact: return actual == expected
        case .prefix: return actual.hasPrefix(expected)
        case .contains: return actual.contains(expected)
        }
    }
    private func normalized(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
    }
}

/// A stable recipe that is resolved afresh against every semantic observation.
/// It deliberately does not contain an element ID or screen coordinates.
public struct ElementLocator: Decodable, Equatable, Sendable {
    public let application: TextMatcher?
    public let window: TextMatcher?
    public let pageURL: TextMatcher?
    public let role: ElementRole?
    public let label: TextMatcher?
    public let value: TextMatcher?
    public let ancestorRole: ElementRole?
    public let ancestorLabel: TextMatcher?
    public let ancestorValue: TextMatcher?
    public let ordinal: Int?
    public init(
        application: TextMatcher? = nil,
        window: TextMatcher? = nil,
        pageURL: TextMatcher? = nil,
        role: ElementRole? = nil,
        label: TextMatcher? = nil,
        value: TextMatcher? = nil,
        ancestorRole: ElementRole? = nil,
        ancestorLabel: TextMatcher? = nil,
        ancestorValue: TextMatcher? = nil,
        ordinal: Int? = nil
    ) {
        self.application = application
        self.window = window
        self.pageURL = pageURL
        self.role = role
        self.label = label
        self.value = value
        self.ancestorRole = ancestorRole
        self.ancestorLabel = ancestorLabel
        self.ancestorValue = ancestorValue
        self.ordinal = ordinal
    }
    private enum CodingKeys: String, CodingKey {
        case application, window, pageURL, role, label, value
        case ancestorRole, ancestorLabel, ancestorValue
        case ordinal
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        application = try values.decodeIfPresent(TextMatcher.self, forKey: .application)
        window = try values.decodeIfPresent(TextMatcher.self, forKey: .window)
        pageURL = try values.decodeIfPresent(TextMatcher.self, forKey: .pageURL)
        role = try values.decodeIfPresent(ElementRole.self, forKey: .role)
        label = try values.decodeIfPresent(TextMatcher.self, forKey: .label)
        value = try values.decodeIfPresent(TextMatcher.self, forKey: .value)
        ancestorRole = try values.decodeIfPresent(ElementRole.self, forKey: .ancestorRole)
        ancestorLabel = try values.decodeIfPresent(TextMatcher.self, forKey: .ancestorLabel)
        ancestorValue = try values.decodeIfPresent(TextMatcher.self, forKey: .ancestorValue)
        ordinal = try values.decodeIfPresent(Int.self, forKey: .ordinal)
    }

}

extension ElementLocator {
    func resolve(in snapshot: ScreenSemantics) throws -> ScreenElement {
        if let reason = invalidReason() {
            throw PetFailure.semanticLocatorFailed(reason)
        }
        guard scopeMatches(snapshot) else {
            throw PetFailure.semanticLocatorFailed("当前应用、窗口或页面与 locator 范围不符。")
        }

        let byID = snapshot.elements.reduce(into: [String: ScreenElement]()) { elements, element in
            elements[element.id] = element
        }
        var matches = snapshot.elements.compactMap { element -> ScreenElement? in
            guard role == nil || role == element.role else { return nil }
            if !element.isEnabled { return nil }
            if let label, !label.matches(element.label) { return nil }
            if let value, !value.matches(element.value ?? "") { return nil }
            if ancestorRole != nil || ancestorLabel != nil
                || ancestorValue != nil {
                guard ancestorMatches(for: element, byID: byID) else {
                    return nil
                }
            }
            return element
        }
        matches.sort {
            if $0.frame.y != $1.frame.y { return $0.frame.y < $1.frame.y }
            return $0.frame.x < $1.frame.x
        }

        if let ordinal {
            guard matches.indices.contains(ordinal) else {
                throw PetFailure.semanticLocatorFailed(
                    "locator 匹配到 \(matches.count) 个元素，但序号 \(ordinal) 不存在。")
            }
            return matches[ordinal]
        }
        guard !matches.isEmpty else {
            throw PetFailure.semanticLocatorFailed("没有语义元素匹配 locator。")
        }
        guard matches.count == 1 else {
            throw PetFailure.semanticLocatorFailed(
                "locator 匹配到 \(matches.count) 个元素；请补充范围、祖先或序号。")
        }
        return matches[0]
    }
    private func invalidReason() -> String? {
        if let ordinal, ordinal < 0 { return "序号不能小于零。" }
        let hasElementPredicate = role != nil || label != nil
            || value != nil || ancestorRole != nil
            || ancestorLabel != nil || ancestorValue != nil
        return hasElementPredicate ? nil : "locator 至少需要一个元素条件。"
    }
    private func scopeMatches(_ snapshot: ScreenSemantics) -> Bool {
        if let application, !application.matches(snapshot.applicationName) { return false }
        if let window, !window.matches(snapshot.windowTitle) { return false }
        if let pageURL, !pageURL.matches(snapshot.pageURL ?? "") { return false }
        return true
    }
    private func ancestorMatches(
        for element: ScreenElement,
        byID: [String: ScreenElement]
    ) -> Bool {
        var parentID = element.parentID
        var visited = Set<String>()
        while let id = parentID, visited.insert(id).inserted, let ancestor = byID[id] {
            if (ancestorRole == nil || ancestorRole == ancestor.role)
                && (ancestorLabel?.matches(ancestor.label) ?? true)
                && (ancestorValue?.matches(ancestor.value ?? "") ?? true) {
                return true
            }
            parentID = ancestor.parentID
        }
        return false
    }
}
