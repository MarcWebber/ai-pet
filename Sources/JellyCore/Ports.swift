import Foundation

public struct CodexRequest: Equatable, Sendable {
    public let imagePNG: Data?
    public let prompt: String
    public let model: String
    public let reasoningEffort: ReasoningEffort
    public let conversationHistoryTurns: Int

    public init(
        imagePNG: Data?,
        prompt: String,
        model: String,
        reasoningEffort: ReasoningEffort,
        conversationHistoryTurns: Int = 8
    ) {
        self.imagePNG = imagePNG
        self.prompt = prompt
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.conversationHistoryTurns = min(
            max(
                conversationHistoryTurns,
                JellyConfiguration.Conversation.minimumHistoryTurns
            ),
            JellyConfiguration.Conversation.maximumHistoryTurns
        )
    }
}

public struct ScreenObservation: Equatable, Sendable {
    public let displayID: UInt32
    public let semantics: ScreenSemantics?
    public let screenshotPNG: Data?

    public init(
        displayID: UInt32,
        semantics: ScreenSemantics?,
        screenshotPNG: Data?
    ) {
        self.displayID = displayID
        self.semantics = semantics
        self.screenshotPNG = screenshotPNG
    }
}

public enum ScreenToolCall: Equatable, Sendable {
    case observe
    case perform(ScreenAction)
    case activateAndVerify(ActivateAndVerifyRequest)
}

public enum ConditionState: String, Codable, CaseIterable, Equatable, Sendable {
    case present, absent
}

public struct ActivateAndVerifyRequest: Codable, Equatable, Sendable {
    public let targetLocator: ElementLocator
    public let expectedLocator: ElementLocator
    public let expectedState: ConditionState
    public let expectedValueEquals: String?

    public init(
        targetLocator: ElementLocator,
        expectedLocator: ElementLocator,
        expectedState: ConditionState = .present,
        expectedValueEquals: String? = nil
    ) {
        self.targetLocator = targetLocator
        self.expectedLocator = expectedLocator
        self.expectedState = expectedState
        self.expectedValueEquals = expectedValueEquals
    }
}

public struct ScreenToolResult: Equatable, Sendable {
    public let success: Bool
    public let message: String
    public let screenshotPNG: Data?

    public init(success: Bool, message: String, screenshotPNG: Data? = nil) {
        self.success = success
        self.message = message
        self.screenshotPNG = screenshotPNG
    }
}

public typealias ScreenToolHandler = @MainActor @Sendable (
    ScreenToolCall
) async -> ScreenToolResult

public protocol CodexServing: AnyObject {
    func respond(
        to request: CodexRequest,
        onTextDelta: @escaping @Sendable (String) -> Void,
        screenToolHandler: ScreenToolHandler?
    ) async throws -> String
    func steer(_ instruction: String) async throws
    func prepareForNextTurn() async
    func resetSession() async
    func cancel()
}

@MainActor
public protocol ScreenDriving: AnyObject {
    func observe(displayID: UInt32) async throws -> ScreenObservation
    func execute(
        _ action: ScreenAction,
        observation: ScreenObservation,
        displayID: UInt32
    ) async throws
    func cancel()
}

public enum SoundCue: String, CaseIterable, Sendable {
    case capture, thinking, answer, error, dock
}
