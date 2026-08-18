import Foundation
import JellyCore

public final class LocalAgentResponder: AIResponder {
    public let runtimes: [LocalAgentRuntime]

    private let skillURL: URL?
    private let temporaryRoot: URL
    private var activeKind: AgentRuntimeKind?
    private var activeResponder: AIResponder?

    public init(
        runtimes: [LocalAgentRuntime],
        skillURL: URL?,
        temporaryRoot: URL = FileManager.default.temporaryDirectory
    ) {
        self.runtimes = runtimes
        self.skillURL = skillURL
        self.temporaryRoot = temporaryRoot
    }

    public func respond(
        to request: CodexRequest,
        onTextDelta: @escaping @Sendable (String) -> Void,
        screenToolHandler: ScreenToolHandler?
    ) async throws -> String {
        guard let runtime = LocalAgentRuntimeLocator.resolve(
            request.runtime,
            from: runtimes
        ) else {
            throw PetFailure.agentRuntimeUnavailable(
                request.runtime.displayName
            )
        }
        let responder = try await responder(for: runtime)
        return try await responder.respond(
            to: request,
            onTextDelta: onTextDelta,
            screenToolHandler: screenToolHandler
        )
    }

    public func steer(_ instruction: String) async throws {
        guard let activeResponder else {
            throw PetFailure.agentRuntimeUnavailable("当前 Agent Runtime")
        }
        try await activeResponder.steer(instruction)
    }

    public func prepareForNextTurn() async {
        await activeResponder?.prepareForNextTurn()
    }

    public func resetSession() async {
        await activeResponder?.resetSession()
    }

    public func cancel() {
        activeResponder?.cancel()
    }

    private func responder(
        for runtime: LocalAgentRuntime
    ) async throws -> AIResponder {
        if activeKind == runtime.kind, let activeResponder {
            return activeResponder
        }
        activeResponder?.cancel()
        if let activeResponder {
            await activeResponder.resetSession()
        }
        let responder: AIResponder
        switch runtime.kind {
        case .codex, .traex:
            responder = CodexProcessResponder(
                executableURL: runtime.executableURL,
                runtime: runtime.kind,
                skillURL: skillURL,
                temporaryRoot: temporaryRoot
            )
        case .claudeCode, .openCode:
            responder = TerminalAgentResponder(
                runtime: runtime,
                temporaryRoot: temporaryRoot
            )
        case .automatic:
            throw PetFailure.agentRuntimeUnavailable(
                AgentRuntimeKind.automatic.displayName
            )
        }
        activeKind = runtime.kind
        activeResponder = responder
        return responder
    }
}
