import Foundation

enum ScreenActionKind: String, Decodable {
    case click, drag, navigate, scroll, wait
    case doubleClick = "double_click"
    case typeText = "type_text"
    case keyPress = "key_press"
}

public enum ScreenKey: String, Decodable, CaseIterable, Equatable, Hashable, Sendable {
    case a, l, r, t, v, w, `return`, tab, escape, delete, forwardDelete
    case left, right, up, down, space, home, end, pageUp, pageDown
}

public enum KeyModifier: String, Decodable, CaseIterable, Hashable, Sendable {
    case command, control, option, shift
}

/// One model-visible intent. Physical mouse/key pulses stay inside the executor.
public enum ScreenAction: Equatable, Sendable {
    public static let maximumScrollDelta = 420
    case click(ElementTarget)
    case doubleClick(ElementTarget)
    case drag(fromX: Int, fromY: Int, toX: Int, toY: Int, durationMilliseconds: Int)
    case typeText(target: ElementTarget, text: String)
    case keyPress(key: ScreenKey, modifiers: [KeyModifier])
    case navigate(url: String)
    case scroll(target: ElementTarget?, deltaX: Int, deltaY: Int)
    case wait(milliseconds: Int)
    public func validate() throws {
        switch self {
        case let .click(target), let .doubleClick(target):
            try target.validate()
        case let .drag(fromX, fromY, toX, toY, duration):
            try Self.validate(x: fromX, y: fromY)
            try Self.validate(x: toX, y: toY)
            guard (200...2_000).contains(duration) else { throw PetFailure.invalidScreenAction }
        case let .typeText(target, text):
            try target.validate()
            if case .visual = target { throw PetFailure.invalidScreenAction }
            guard !text.isEmpty, text.utf16.count <= 100_000 else { throw PetFailure.invalidScreenAction }
        case let .keyPress(_, modifiers):
            guard Set(modifiers).count == modifiers.count else {
                throw PetFailure.invalidScreenAction
            }
        case let .navigate(url):
            let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard url == trimmed,
                  !url.isEmpty,
                  url.count <= 2_048,
                  url.unicodeScalars.allSatisfy({
                      !CharacterSet.controlCharacters.contains($0)
                  }),
                  let parts = URLComponents(string: url),
                  let scheme = parts.scheme?.lowercased(),
                  ["http", "https"].contains(scheme),
                  parts.host?.isEmpty == false,
                  parts.user == nil,
                  parts.password == nil else {
                throw PetFailure.invalidScreenAction
            }
        case let .scroll(target, deltaX, deltaY):
            try target?.validate()
            guard deltaX != 0 || deltaY != 0,
                  abs(deltaX) <= Self.maximumScrollDelta,
                  abs(deltaY) <= Self.maximumScrollDelta
            else { throw PetFailure.invalidScreenAction }
        case let .wait(milliseconds):
            guard (200...3_000).contains(milliseconds) else { throw PetFailure.invalidScreenAction }
        }
    }
    private static func validate(x: Int, y: Int) throws {
        guard (0...1_000).contains(x), (0...1_000).contains(y) else {
            throw PetFailure.invalidScreenAction
        }
    }
}

private extension ElementTarget {
    func validate() throws {
        switch self {
        case let .visual(x, y):
            guard (0...1_000).contains(x), (0...1_000).contains(y) else { throw PetFailure.invalidScreenAction }
        case let .element(elementID):
            guard !elementID.isEmpty else { throw PetFailure.invalidScreenAction }
        case .locator:
            break
        }
    }
}

extension ScreenAction: Decodable {
    private enum CodingKeys: String, CodingKey {
        case kind, target, fromX, fromY, toX, toY, durationMilliseconds
        case text
        case key, modifiers, url, deltaX, deltaY, milliseconds
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys) throws -> T {
            try values.decode(T.self, forKey: key)
        }
        switch try values.decode(ScreenActionKind.self, forKey: .kind) {
        case .click: self = .click(try value(.target))
        case .doubleClick: self = .doubleClick(try value(.target))
        case .drag:
            self = .drag(
                fromX: try value(.fromX), fromY: try value(.fromY),
                toX: try value(.toX), toY: try value(.toY),
                durationMilliseconds: try value(.durationMilliseconds)
            )
        case .typeText:
            self = .typeText(target: try value(.target), text: try value(.text))
        case .keyPress:
            self = .keyPress(key: try value(.key), modifiers: try value(.modifiers))
        case .navigate: self = .navigate(url: try value(.url))
        case .scroll:
            self = .scroll(
                target: try values.decodeIfPresent(ElementTarget.self, forKey: .target),
                deltaX: try value(.deltaX), deltaY: try value(.deltaY)
            )
        case .wait: self = .wait(milliseconds: try value(.milliseconds))
        }
    }

}

public struct TakeoverRequest: Equatable, Sendable {
    public let displayID: UInt32
    public let task: String?
    public let assistantPreferences: AssistantPreferences
    public init(
        displayID: UInt32,
        task: String?,
        assistantPreferences: AssistantPreferences
    ) {
        self.displayID = displayID; self.task = task
        self.assistantPreferences = assistantPreferences
    }
}

public enum PetActivity: String, CaseIterable, Equatable, Sendable {
    case idle, observing, thinking, locating, acting, verifying, success, failure
    public var label: String {
        switch self {
        case .idle: "空闲"; case .observing: "观察"; case .thinking: "思考"
        case .locating: "定位"; case .acting: "操作"; case .verifying: "验证"
        case .success: "完成"; case .failure: "失败"
        }
    }
}

public struct ActivityEvent: Equatable, Sendable {
    public let activity: PetActivity
    public let message: String
    public let sequence: Int?
    public let details: String?
    public init(
        activity: PetActivity,
        message: String,
        sequence: Int? = nil,
        details: String? = nil
    ) {
        self.activity = activity; self.message = message
        self.sequence = sequence; self.details = details
    }
}

public enum SessionMode: String, Equatable, Sendable {
    case idle, answering, takingOver
}

public struct SessionSnapshot: Equatable, Sendable {
    public var mode: SessionMode
    public var activity: PetActivity
    public var message: String?
    public var events: [ActivityEvent]
    public var request: TakeoverRequest?
    public init(
        mode: SessionMode,
        activity: PetActivity,
        message: String? = nil,
        events: [ActivityEvent] = [],
        request: TakeoverRequest? = nil
    ) {
        self.mode = mode
        self.activity = activity
        self.message = message
        self.events = events
        self.request = request
    }
    public var isActive: Bool {
        switch activity {
        case .observing, .thinking, .locating, .acting, .verifying: true
        case .idle, .success, .failure: false
        }
    }
    public var isTakingOver: Bool { mode == .takingOver && isActive }
}

extension ScreenAction {
    /// Resolves stable locator recipes against one current observation. The returned action
    /// contains only observation-scoped element IDs and must not be reused after the UI changes.
    public func resolvingSemanticTargets(
        in snapshot: ScreenSemantics?
    ) throws -> ScreenAction {
        switch self {
        case let .click(target):
            return .click(try target.resolved(in: snapshot))
        case let .doubleClick(target):
            return .doubleClick(try target.resolved(in: snapshot))
        case let .typeText(target, text):
            return .typeText(
                target: try target.resolved(in: snapshot),
                text: text
            )
        case let .scroll(target, deltaX, deltaY):
            return .scroll(
                target: try target?.resolved(in: snapshot),
                deltaX: deltaX,
                deltaY: deltaY
            )
        case .drag, .keyPress, .navigate, .wait:
            return self
        }
    }
    public var label: String {
        switch self {
        case .click: "单击"
        case .doubleClick: "双击"
        case .drag: "拖动"
        case .typeText: "键入"
        case .keyPress: "按键"
        case .navigate: "导航"
        case let .scroll(_, x, y):
            abs(y) >= abs(x) ? "滚动\(y < 0 ? "↓" : "↑")(\(abs(y))px)"
                : "滚动\(x < 0 ? "←" : "→")(\(abs(x))px)"
        case .wait: "等待"
        }
    }

}

private extension ElementTarget {
    func resolved(in snapshot: ScreenSemantics?) throws -> ElementTarget {
        guard case let .locator(locator) = self else { return self }
        guard let snapshot else {
            throw PetFailure.semanticLocatorFailed("当前观察没有语义元素。")
        }
        let selected = try locator.resolve(in: snapshot)
        return .element(elementID: selected.id)
    }
}
