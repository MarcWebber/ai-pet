import Foundation
import JellyCore

public final class CodexProcessResponder: AIResponder {
    private let appServer: CodexAppServerClient?
    private let runtime: AgentRuntimeKind
    private var completedTurns = 0
    private var configuration: String?
    private var history: [String] = []

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

        let currentConfiguration = [
            request.model,
            request.reasoningEffort.rawValue,
            String(request.conversationHistoryTurns)
        ].joined(separator: "|")
        pruneHistory(limit: request.conversationHistoryTurns)
        let startsNewThread = configuration != currentConfiguration
            || completedTurns >= request.conversationHistoryTurns
        if startsNewThread {
            await appServer.resetSession()
            completedTurns = 0
            configuration = currentConfiguration
        }
        let effectiveRequest: CodexRequest
        if startsNewThread, !history.isEmpty {
            effectiveRequest = CodexRequest(
                imageURL: request.imageURL,
                prompt: """
                此前最近对话（仅作上下文）：
                \(history.joined(separator: "\n\n"))

                当前请求：
                \(request.prompt)
                """,
                runtime: request.runtime,
                model: request.model,
                reasoningEffort: request.reasoningEffort,
                conversationHistoryTurns: request.conversationHistoryTurns
            )
        } else {
            effectiveRequest = request
        }

        do {
            let answer = try await withTaskCancellationHandler {
                try await appServer.respond(
                    to: effectiveRequest,
                    onTextDelta: onTextDelta,
                    screenToolHandler: screenToolHandler
                )
            } onCancel: {
                Task { await appServer.cancel() }
            }
            completedTurns += 1
            appendHistory(
                "用户：\(request.prompt)",
                limit: request.conversationHistoryTurns
            )
            appendHistory(
                "助手：\(answer)",
                limit: request.conversationHistoryTurns
            )
            return answer
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
        completedTurns = 0
        configuration = nil
        history.removeAll()
    }

    public func cancel() {
        if let appServer { Task { await appServer.cancel() } }
    }

    private func appendHistory(_ value: String, limit: Int) {
        history.append(String(value.prefix(8_000)))
        pruneHistory(limit: limit)
    }

    private func pruneHistory(limit: Int) {
        let entryLimit = max(2, limit * 2)
        let byteLimit = max(24_000, min(200_000, limit * 16_000))
        while history.count > entryLimit
            || history.reduce(0, { $0 + $1.utf8.count }) > byteLimit {
            history.removeFirst()
        }
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
