import Foundation

enum ScreenActionKind: String, Codable {
    case click, doubleClick, drag, typeText, keyPress, navigate, scroll, wait
}

public enum ScreenKey: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case a, l, r, t, v, w, `return`, tab, escape, delete, forwardDelete
    case left, right, up, down, space, home, end, pageUp, pageDown
}

public enum KeyModifier: String, Codable, CaseIterable, Hashable, Sendable {
    case command, control, option, shift
}

/// One model-visible intent. Physical mouse/key pulses stay inside the executor.
public enum ScreenAction: Equatable, Sendable {
    public static let maximumScrollDelta = 420

    case click(ScreenActionTarget)
    case doubleClick(ScreenActionTarget)
    case drag(fromX: Int, fromY: Int, toX: Int, toY: Int, durationMilliseconds: Int)
    case typeText(target: ScreenActionTarget, text: String, replacesExistingText: Bool)
    case keyPress(key: ScreenKey, modifiers: [KeyModifier])
    case navigate(url: String)
    case scroll(target: ScreenActionTarget?, deltaX: Int, deltaY: Int)
    case wait(milliseconds: Int)

    var kind: ScreenActionKind {
        switch self {
        case .click: .click
        case .doubleClick: .doubleClick
        case .drag: .drag
        case .typeText: .typeText
        case .keyPress: .keyPress
        case .navigate: .navigate
        case .scroll: .scroll
        case .wait: .wait
        }
    }

    public func validate() throws {
        switch self {
        case let .click(target), let .doubleClick(target):
            try target.validate()
        case let .drag(fromX, fromY, toX, toY, duration):
            try Self.validate(x: fromX, y: fromY)
            try Self.validate(x: toX, y: toY)
            guard (200...2_000).contains(duration) else { throw PetFailure.invalidScreenAction }
        case let .typeText(target, text, _):
            try target.validate()
            guard !text.isEmpty, text.utf16.count <= 100_000 else { throw PetFailure.invalidScreenAction }
        case let .keyPress(_, modifiers):
            guard Set(modifiers).count == modifiers.count else { throw PetFailure.invalidScreenAction }
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

private extension ScreenActionTarget {
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

extension ScreenAction: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, target, fromX, fromY, toX, toY, durationMilliseconds
        case text, replacesExistingText
        case key, modifiers, url, deltaX, deltaY, milliseconds
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(ScreenActionKind.self, forKey: .kind) {
        case .click: self = .click(try values.decode(ScreenActionTarget.self, forKey: .target))
        case .doubleClick: self = .doubleClick(try values.decode(ScreenActionTarget.self, forKey: .target))
        case .drag:
            self = .drag(
                fromX: try values.decode(Int.self, forKey: .fromX),
                fromY: try values.decode(Int.self, forKey: .fromY),
                toX: try values.decode(Int.self, forKey: .toX),
                toY: try values.decode(Int.self, forKey: .toY),
                durationMilliseconds: try values.decode(Int.self, forKey: .durationMilliseconds)
            )
        case .typeText:
            self = .typeText(
                target: try values.decode(ScreenActionTarget.self, forKey: .target),
                text: try values.decode(String.self, forKey: .text),
                replacesExistingText: try values.decode(Bool.self, forKey: .replacesExistingText)
            )
        case .keyPress:
            self = .keyPress(
                key: try values.decode(ScreenKey.self, forKey: .key),
                modifiers: try values.decode([KeyModifier].self, forKey: .modifiers)
            )
        case .navigate: self = .navigate(url: try values.decode(String.self, forKey: .url))
        case .scroll:
            self = .scroll(
                target: try values.decodeIfPresent(ScreenActionTarget.self, forKey: .target),
                deltaX: try values.decode(Int.self, forKey: .deltaX),
                deltaY: try values.decode(Int.self, forKey: .deltaY)
            )
        case .wait: self = .wait(milliseconds: try values.decode(Int.self, forKey: .milliseconds))
        }
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(kind, forKey: .kind)
        switch self {
        case let .click(target), let .doubleClick(target): try values.encode(target, forKey: .target)
        case let .drag(fromX, fromY, toX, toY, duration):
            try values.encode(fromX, forKey: .fromX); try values.encode(fromY, forKey: .fromY)
            try values.encode(toX, forKey: .toX); try values.encode(toY, forKey: .toY)
            try values.encode(duration, forKey: .durationMilliseconds)
        case let .typeText(target, text, replaces):
            try values.encode(target, forKey: .target); try values.encode(text, forKey: .text)
            try values.encode(replaces, forKey: .replacesExistingText)
        case let .keyPress(key, modifiers):
            try values.encode(key, forKey: .key); try values.encode(modifiers, forKey: .modifiers)
        case let .navigate(url): try values.encode(url, forKey: .url)
        case let .scroll(target, deltaX, deltaY):
            try values.encodeIfPresent(target, forKey: .target)
            try values.encode(deltaX, forKey: .deltaX); try values.encode(deltaY, forKey: .deltaY)
        case let .wait(milliseconds): try values.encode(milliseconds, forKey: .milliseconds)
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

public enum TakeoverPhase: Equatable, Sendable {
    case idle, capturing, deciding, locating, executing
    case verifying, finished, cancelled, error

    public var activity: PetActivity {
        switch self {
        case .idle, .cancelled: .idle
        case .capturing: .observing
        case .deciding: .thinking
        case .locating: .locating
        case .executing: .acting
        case .verifying: .verifying
        case .finished: .success
        case .error: .failure
        }
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

public struct TakeoverEvent: Equatable, Sendable {
    public let activity: PetActivity
    public let message: String
    public let kind: TakeoverEventKind
    public let sequence: Int?
    public let details: String?

    public init(
        activity: PetActivity,
        message: String,
        kind: TakeoverEventKind = .status,
        sequence: Int? = nil,
        details: String? = nil
    ) {
        self.activity = activity; self.message = message
        self.kind = kind; self.sequence = sequence; self.details = details
    }
}

public enum TakeoverEventKind: String, Equatable, Sendable {
    case status, observation, action, outcome, userInstruction
}

public struct TakeoverMetrics: Equatable, Sendable {
    public let durationSeconds: Double
    public let actionCount: Int
    public let observationCount: Int

    public init(durationSeconds: Double, actionCount: Int, observationCount: Int) {
        self.durationSeconds = durationSeconds
        self.actionCount = actionCount
        self.observationCount = observationCount
    }
}

public struct TakeoverSnapshot: Equatable, Sendable {
    public let phase: TakeoverPhase
    public let message: String?
    public let failure: PetFailure?
    public let events: [TakeoverEvent]
    public let metrics: TakeoverMetrics?
    public var activity: PetActivity { phase.activity }
    public var isActive: Bool {
        switch phase {
        case .capturing, .deciding, .locating, .executing, .verifying: true
        default: false
        }
    }
}

extension ScreenAction {
    /// Resolves stable locator recipes against one current observation. The returned action
    /// contains only observation-scoped element IDs and must not be reused after the UI changes.
    public func resolvingSemanticTargets(
        in snapshot: SemanticSnapshot?
    ) throws -> ScreenAction {
        switch self {
        case let .click(target):
            return .click(try target.resolved(in: snapshot))
        case let .doubleClick(target):
            return .doubleClick(try target.resolved(in: snapshot))
        case let .typeText(target, text, replaces):
            return .typeText(
                target: try target.resolved(in: snapshot),
                text: text,
                replacesExistingText: replaces
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
        guard case let .scroll(_, deltaX, deltaY) = self else { return kind.rawValue }
        if abs(deltaY) >= abs(deltaX) { return "scroll\(deltaY < 0 ? "↓" : "↑")(\(abs(deltaY))px)" }
        return "scroll\(deltaX < 0 ? "←" : "→")(\(abs(deltaX))px)"
    }

    public var needsVisualObservation: Bool {
        switch self {
        case let .click(target), let .doubleClick(target),
             let .typeText(target, _, _):
            return target.isVisual
        case let .scroll(target, _, _):
            return target?.isVisual == true
        case .drag:
            return true
        case .keyPress, .navigate, .wait:
            return false
        }
    }
}

private extension ScreenActionTarget {
    func resolved(in snapshot: SemanticSnapshot?) throws -> ScreenActionTarget {
        guard case let .locator(locator) = self else { return self }
        guard let snapshot else {
            throw PetFailure.semanticLocatorFailed("当前观察没有语义元素。")
        }
        let resolution = locator.resolve(in: snapshot)
        guard resolution.status == .matched,
              let selected = resolution.selected else {
            throw PetFailure.semanticLocatorFailed(resolution.message)
        }
        return .element(elementID: selected.id)
    }

    var isVisual: Bool {
        if case .visual = self { return true }
        return false
    }
}
