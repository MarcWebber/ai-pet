import Foundation

public struct CodexRequest: Equatable, Sendable {
    public let imagePNG: Data?
    public let prompt: String
    public let preferences: AssistantPreferences
    public init(
        imagePNG: Data?,
        prompt: String,
        preferences: AssistantPreferences
    ) {
        self.imagePNG = imagePNG
        self.prompt = prompt
        self.preferences = preferences
    }
}

public struct ScreenObservation: Equatable, Sendable {
    public let semantics: ScreenSemantics?
    public let screenshotPNG: Data
    public init(
        semantics: ScreenSemantics?,
        screenshotPNG: Data
    ) {
        self.semantics = semantics
        self.screenshotPNG = screenshotPNG
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
        screenToolHandler: ScreenToolHandler?
    ) async throws -> String
    func steer(_ instruction: String) async throws
    func prepare(resetHistory: Bool) async
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
