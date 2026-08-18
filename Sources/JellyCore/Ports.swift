import Foundation

public struct CaptureArtifact: Equatable, Sendable {
    public let imageURL: URL
    public let sessionDirectoryURL: URL

    public init(imageURL: URL, sessionDirectoryURL: URL) {
        self.imageURL = imageURL
        self.sessionDirectoryURL = sessionDirectoryURL
    }
}

public struct CodexRequest: Equatable, Sendable {
    public let imageURL: URL?
    public let prompt: String
    public let runtime: AgentRuntimeKind
    public let model: String
    public let reasoningEffort: ReasoningEffort
    public let conversationHistoryTurns: Int

    public init(
        imageURL: URL?,
        prompt: String,
        runtime: AgentRuntimeKind = .automatic,
        model: String,
        reasoningEffort: ReasoningEffort,
        conversationHistoryTurns: Int = 8
    ) {
        self.imageURL = imageURL
        self.prompt = prompt
        self.runtime = runtime
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

public enum ScreenToolCall: Equatable, Sendable {
    case observe
    case perform(ScreenAction)
}

public struct ScreenToolResult: Equatable, Sendable {
    public let success: Bool
    public let message: String
    public let screenshotPNG: Data?

    public init(
        success: Bool,
        message: String,
        screenshotPNG: Data? = nil
    ) {
        self.success = success
        self.message = message
        self.screenshotPNG = screenshotPNG
    }
}

public typealias ScreenToolHandler = @MainActor @Sendable (
    ScreenToolCall
) async -> ScreenToolResult

@MainActor
public protocol CaptureService: AnyObject {
    var prefersSemanticObservation: Bool { get }
    func capture(displayID: UInt32) async throws -> CaptureArtifact
}

public protocol AIResponder: AnyObject {
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

public protocol CaptureCleaning: AnyObject {
    func remove(_ artifact: CaptureArtifact)
}

@MainActor
public protocol ScreenActionExecuting: AnyObject {
    func execute(
        _ action: ScreenAction,
        snapshot: SemanticSnapshot?,
        displayID: UInt32
    ) async throws
    func cancel()
}

public enum SoundCue: String, CaseIterable, Sendable {
    case capture
    case thinking
    case answer
    case error
    case dock
}
