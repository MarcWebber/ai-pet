import Foundation

/// A configuration-friendly text predicate used by stable locators.
public struct SemanticTextMatcher: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Equatable, Sendable {
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

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(text, forKey: .text)
        if mode != .exact { try values.encode(mode, forKey: .mode) }
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
public struct SemanticElementLocator: Codable, Equatable, Sendable {
    public let application: SemanticTextMatcher?
    public let window: SemanticTextMatcher?
    public let pageURL: SemanticTextMatcher?
    public let role: SemanticElementRole?
    public let label: SemanticTextMatcher?
    public let value: SemanticTextMatcher?
    public let ancestorRole: SemanticElementRole?
    public let ancestorLabel: SemanticTextMatcher?
    public let ancestorValue: SemanticTextMatcher?
    public let ordinal: Int?
    public let requiresEnabled: Bool

    public init(
        application: SemanticTextMatcher? = nil,
        window: SemanticTextMatcher? = nil,
        pageURL: SemanticTextMatcher? = nil,
        role: SemanticElementRole? = nil,
        label: SemanticTextMatcher? = nil,
        value: SemanticTextMatcher? = nil,
        ancestorRole: SemanticElementRole? = nil,
        ancestorLabel: SemanticTextMatcher? = nil,
        ancestorValue: SemanticTextMatcher? = nil,
        ordinal: Int? = nil,
        requiresEnabled: Bool = true
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
        self.requiresEnabled = requiresEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case application, window, pageURL, role, label, value
        case ancestorRole, ancestorLabel, ancestorValue
        case ordinal, requiresEnabled
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        application = try values.decodeIfPresent(SemanticTextMatcher.self, forKey: .application)
        window = try values.decodeIfPresent(SemanticTextMatcher.self, forKey: .window)
        pageURL = try values.decodeIfPresent(SemanticTextMatcher.self, forKey: .pageURL)
        role = try values.decodeIfPresent(SemanticElementRole.self, forKey: .role)
        label = try values.decodeIfPresent(SemanticTextMatcher.self, forKey: .label)
        value = try values.decodeIfPresent(SemanticTextMatcher.self, forKey: .value)
        ancestorRole = try values.decodeIfPresent(SemanticElementRole.self, forKey: .ancestorRole)
        ancestorLabel = try values.decodeIfPresent(SemanticTextMatcher.self, forKey: .ancestorLabel)
        ancestorValue = try values.decodeIfPresent(SemanticTextMatcher.self, forKey: .ancestorValue)
        ordinal = try values.decodeIfPresent(Int.self, forKey: .ordinal)
        requiresEnabled = try values.decodeIfPresent(Bool.self, forKey: .requiresEnabled)
            ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(application, forKey: .application)
        try values.encodeIfPresent(window, forKey: .window)
        try values.encodeIfPresent(pageURL, forKey: .pageURL)
        try values.encodeIfPresent(role, forKey: .role)
        try values.encodeIfPresent(label, forKey: .label)
        try values.encodeIfPresent(value, forKey: .value)
        try values.encodeIfPresent(ancestorRole, forKey: .ancestorRole)
        try values.encodeIfPresent(ancestorLabel, forKey: .ancestorLabel)
        try values.encodeIfPresent(ancestorValue, forKey: .ancestorValue)
        try values.encodeIfPresent(ordinal, forKey: .ordinal)
        if !requiresEnabled {
            try values.encode(false, forKey: .requiresEnabled)
        }
    }
}

struct SemanticLocatorResolution {
    enum Status {
        case matched, ambiguous, notFound, scopeMismatch, invalidLocator
    }

    let status: Status
    let selected: SemanticElement?
    let message: String
}

extension SemanticElementLocator {
    func resolve(in snapshot: SemanticSnapshot) -> SemanticLocatorResolution {
        if let reason = invalidReason() {
            return result(.invalidLocator, reason)
        }
        guard scopeMatches(snapshot) else {
            return result(.scopeMismatch, "当前应用、窗口或页面与 locator 范围不符。")
        }

        let byID = snapshot.elements.reduce(into: [String: SemanticElement]()) { elements, element in
            elements[element.id] = element
        }
        var matches = snapshot.elements.compactMap { element -> SemanticElement? in
            guard role == nil || role == element.role else { return nil }
            if requiresEnabled, !element.isEnabled { return nil }
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
                return result(.notFound, "locator 匹配到 \(matches.count) 个元素，但序号 \(ordinal) 不存在。")
            }
            return result(.matched, "已匹配序号 \(ordinal)。", selected: matches[ordinal])
        }
        guard !matches.isEmpty else { return result(.notFound, "没有语义元素匹配 locator。") }
        guard matches.count == 1 else {
            return result(.ambiguous, "locator 匹配到 \(matches.count) 个元素；请补充范围、祖先或序号。")
        }
        return result(.matched, "已匹配一个元素。", selected: matches[0])
    }

    private func invalidReason() -> String? {
        if let ordinal, ordinal < 0 { return "序号不能小于零。" }
        let hasElementPredicate = role != nil || label != nil
            || value != nil || ancestorRole != nil
            || ancestorLabel != nil || ancestorValue != nil
        return hasElementPredicate ? nil : "locator 至少需要一个元素条件。"
    }

    private func scopeMatches(_ snapshot: SemanticSnapshot) -> Bool {
        if let application, !application.matches(snapshot.applicationName) { return false }
        if let window, !window.matches(snapshot.windowTitle) { return false }
        if let pageURL, !pageURL.matches(snapshot.pageURL ?? "") { return false }
        return true
    }

    private func ancestorMatches(
        for element: SemanticElement,
        byID: [String: SemanticElement]
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

    private func result(
        _ status: SemanticLocatorResolution.Status,
        _ message: String,
        selected: SemanticElement? = nil
    ) -> SemanticLocatorResolution {
        SemanticLocatorResolution(status: status, selected: selected, message: message)
    }
}
