import Foundation
import JellyCore

public final class TerminalAgentResponder: AIResponder {
    private let runtime: LocalAgentRuntime
    private let workingDirectory: URL
    private let runner: FoundationProcessRunner
    private var history: [String] = []
    private var configuration: String?

    public init(
        runtime: LocalAgentRuntime,
        temporaryRoot: URL = FileManager.default.temporaryDirectory
    ) {
        self.runtime = runtime
        workingDirectory = temporaryRoot.appendingPathComponent(
            "JellyPet-Agent-\(runtime.kind.rawValue)-\(UUID().uuidString)",
            isDirectory: true
        )
        runner = FoundationProcessRunner(currentDirectoryURL: workingDirectory)
    }

    deinit {
        runner.cancel()
        try? FileManager.default.removeItem(at: workingDirectory)
    }

    public func respond(
        to request: CodexRequest,
        onTextDelta: @escaping @Sendable (String) -> Void,
        screenToolHandler: ScreenToolHandler?
    ) async throws -> String {
        let currentConfiguration = [
            request.model,
            request.reasoningEffort.rawValue,
            String(request.conversationHistoryTurns)
        ].joined(separator: "|")
        if configuration != currentConfiguration {
            history.removeAll()
            configuration = currentConfiguration
        }
        guard screenToolHandler == nil else {
            throw PetFailure.agentRuntimeFailed(
                runtime.kind.displayName,
                "当前 Runtime 只支持截图问答；屏幕接管请选择 Codex 或 TraeX。"
            )
        }
        let answer = try await invoke(
            prompt: request.prompt,
            imageURL: request.imageURL,
            request: request
        )
        onTextDelta(answer)
        return answer
    }

    public func steer(_: String) async throws {
        throw PetFailure.agentRuntimeFailed(
            runtime.kind.displayName,
            "当前 Runtime 不支持接管中的补充指令。"
        )
    }

    public func prepareForNextTurn() async {}

    public func resetSession() async {
        runner.cancel()
        history.removeAll()
        configuration = nil
    }

    public func cancel() {
        runner.cancel()
    }

    private func invoke(
        prompt: String,
        imageURL: URL?,
        request: CodexRequest
    ) async throws -> String {
        try FileManager.default.createDirectory(
            at: workingDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let localImage = try imageURL.map { try copyImage($0) }
        defer { if let localImage { try? FileManager.default.removeItem(at: localImage) } }
        let context = history.suffix(
            request.conversationHistoryTurns * 2
        ).joined(separator: "\n\n")
        let fullPrompt = context.isEmpty
            ? prompt
            : "此前对话（仅作上下文）：\n\(context)\n\n当前请求：\n\(prompt)"
        let (arguments, input) = command(
            prompt: fullPrompt,
            imageURL: localImage,
            request: request
        )
        let result: ProcessResult
        do {
            result = try await runner.run(
                executableURL: runtime.executableURL,
                arguments: arguments,
                standardInput: Data(input.utf8),
                timeout: 180
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PetFailure.agentRuntimeFailed(
                runtime.kind.displayName,
                error.localizedDescription
            )
        }
        let stdout = String(decoding: result.stdout, as: UTF8.self)
        let stderr = String(decoding: result.stderr, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.exitCode == 0 else {
            throw PetFailure.agentRuntimeFailed(
                runtime.kind.displayName,
                stderr.isEmpty ? "CLI 退出码 \(result.exitCode)" : stderr
            )
        }
        let answer = try parseAnswer(stdout)
        appendHistory("用户：\(prompt)", limit: request.conversationHistoryTurns)
        appendHistory("助手：\(answer)", limit: request.conversationHistoryTurns)
        return answer
    }

    private func command(
        prompt: String,
        imageURL: URL?,
        request: CodexRequest
    ) -> ([String], String) {
        switch runtime.kind {
        case .claudeCode:
            var arguments = [
                "--print",
                "--output-format", "json",
                "--permission-mode", "dontAsk",
                "--tools", "Read",
                "--no-session-persistence",
                "--effort", request.reasoningEffort.rawValue
            ]
            if request.model != AssistantPreferences.automaticModel {
                arguments += ["--model", request.model]
            }
            let imageInstruction = imageURL.map {
                "\n截图位于 \($0.path)。必须先用 Read 工具读取这张图片再回答。"
            } ?? ""
            return (arguments, prompt + imageInstruction)
        case .openCode:
            var arguments = ["run"]
            if request.model != AssistantPreferences.automaticModel {
                arguments += ["--model", request.model]
            }
            if let imageURL { arguments += ["--file", imageURL.path] }
            arguments.append(prompt)
            return (arguments, "")
        default:
            var arguments = ["exec", "--skip-git-repo-check", "--color", "never"]
            if request.model != AssistantPreferences.automaticModel {
                arguments += ["--model", request.model]
            }
            if let imageURL { arguments += ["--image", imageURL.path] }
            arguments.append("-")
            return (arguments, prompt)
        }
    }

    private func parseAnswer(_ output: String) throws -> String {
        let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw PetFailure.invalidCodexOutput }
        if runtime.kind == .claudeCode,
           let data = value.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any] {
            if object["is_error"] as? Bool == true {
                throw PetFailure.agentRuntimeFailed(
                    runtime.kind.displayName,
                    object["result"] as? String ?? "Claude Code 返回错误。"
                )
            }
            if let result = object["result"] as? String,
               !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return String(result.prefix(200_000))
            }
        }
        return String(value.prefix(200_000))
    }

    private func copyImage(_ source: URL) throws -> URL {
        let target = workingDirectory.appendingPathComponent(
            "input-\(UUID().uuidString).png"
        )
        try FileManager.default.copyItem(at: source, to: target)
        return target
    }

    private func appendHistory(_ value: String, limit: Int = 8) {
        history.append(String(value.prefix(8_000)))
        let entryLimit = max(2, limit * 2)
        let byteLimit = max(24_000, min(200_000, limit * 16_000))
        while history.count > entryLimit
            || history.reduce(0, { $0 + $1.utf8.count }) > byteLimit {
            history.removeFirst()
        }
    }
}
