import Foundation
import JellyCore

public final class CodexProcessResponder: AIResponder {
    private let appServer: CodexAppServerClient?
    private let runtime: AgentRuntimeKind

    public init(
        executableURL: URL?,
        runtime: AgentRuntimeKind = .codex,
        skillURL: URL?,
        temporaryRoot: URL = FileManager.default.temporaryDirectory
    ) {
        self.runtime = runtime
        self.appServer = executableURL.flatMap { executableURL in
            guard let skillURL,
                  FileManager.default.isReadableFile(atPath: skillURL.path)
            else { return nil }
            return CodexAppServerClient(
                executableURL: executableURL,
                runtime: runtime,
                skillURL: skillURL,
                workingDirectory: temporaryRoot.appendingPathComponent(
                    "JellyPet-Codex-Isolated-\(UUID().uuidString)",
                    isDirectory: true
                )
            )
        }
    }

    public func respond(
        to request: CodexRequest,
        onTextDelta: @escaping @Sendable (String) -> Void,
        screenToolHandler: ScreenToolHandler?
    ) async throws -> String {
        guard let appServer else {
            throw PetFailure.agentRuntimeUnavailable(runtime.displayName)
        }

        do {
            return try await withTaskCancellationHandler {
                try await appServer.respond(
                    to: request,
                    onTextDelta: onTextDelta,
                    screenToolHandler: screenToolHandler
                )
            } onCancel: {
                Task { await appServer.cancel() }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CodexAppServerError {
            throw Self.failure(for: error, runtime: runtime)
        } catch {
            throw PetFailure.agentRuntimeFailed(
                runtime.displayName,
                error.localizedDescription
            )
        }
    }

    public func steer(_ instruction: String) async throws {
        guard let appServer else {
            throw PetFailure.agentRuntimeUnavailable(runtime.displayName)
        }
        do {
            try await appServer.steer(instruction)
        } catch let error as CodexAppServerError {
            throw Self.failure(for: error, runtime: runtime)
        } catch {
            throw PetFailure.agentRuntimeFailed(
                runtime.displayName,
                error.localizedDescription
            )
        }
    }

    public func prepareForNextTurn() async {
        await appServer?.prepareForNextTurn()
    }

    public func resetSession() async {
        await appServer?.resetSession()
    }

    public func cancel() {
        if let appServer { Task { await appServer.cancel() } }
    }

    private static func failure(
        for error: CodexAppServerError,
        runtime: AgentRuntimeKind
    ) -> PetFailure {
        switch error {
        case let .startup(message), let .disconnected(message):
            if let message,
               !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .agentRuntimeFailed(runtime.displayName, message)
            }
            return .agentRuntimeUnavailable(runtime.displayName)
        case let .server(message):
            return .agentRuntimeFailed(runtime.displayName, message)
        case .invalidResponse: return .invalidCodexOutput
        }
    }
}
