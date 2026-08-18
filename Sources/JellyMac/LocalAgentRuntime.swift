import Foundation
import JellyCore

public struct LocalAgentRuntime: Equatable, Sendable {
    public let kind: AgentRuntimeKind
    public let executableURL: URL
    public let commandName: String

    public init(
        kind: AgentRuntimeKind,
        executableURL: URL,
        commandName: String
    ) {
        self.kind = kind
        self.executableURL = executableURL
        self.commandName = commandName
    }

    public var suggestedModels: [String] {
        switch kind {
        case .codex:
            return [
                "gpt-5.6-luna", "gpt-5.6-terra", "gpt-5.6-sol",
                "gpt-5.5", "gpt-5.4"
            ]
        case .traex:
            return [
                "gpt-5.4", "gpt-5.6-luna", "gpt-5.6-terra",
                "gpt-5.6-sol", "Doubao-Seed-2.1-Pro",
                "Doubao-Seed-2.1-Turbo", "DeepSeek-V4-Pro",
                "gemini-3.1-pro"
            ]
        case .claudeCode:
            return ["sonnet", "opus", "haiku", "fable"]
        case .openCode:
            return []
        case .automatic:
            return []
        }
    }
}

public enum LocalAgentRuntimeLocator {
    public static func detect(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [LocalAgentRuntime] {
        let home = fileManager.homeDirectoryForCurrentUser
        var directories = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0), isDirectory: true) }
        directories += [
            home.appendingPathComponent(".local/bin", isDirectory: true),
            home.appendingPathComponent(".npm-global/bin", isDirectory: true),
            URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
            URL(fileURLWithPath: "/usr/local/bin", isDirectory: true)
        ]

        var result: [LocalAgentRuntime] = []
        if let url = locate(
            names: ["codex"],
            directories: directories,
            fileManager: fileManager
        ) {
            result.append(LocalAgentRuntime(
                kind: .codex,
                executableURL: url,
                commandName: url.lastPathComponent
            ))
        }
        if let url = locate(
            names: ["traex", "traecli", "trae"],
            directories: directories,
            fileManager: fileManager
        ) {
            result.append(LocalAgentRuntime(
                kind: .traex,
                executableURL: url,
                commandName: url.lastPathComponent
            ))
        }
        if let url = locate(
            names: ["claude"],
            directories: directories,
            fileManager: fileManager
        ) {
            result.append(LocalAgentRuntime(
                kind: .claudeCode,
                executableURL: url,
                commandName: url.lastPathComponent
            ))
        }
        if let url = locate(
            names: ["opencode"],
            directories: directories,
            fileManager: fileManager
        ) {
            result.append(LocalAgentRuntime(
                kind: .openCode,
                executableURL: url,
                commandName: url.lastPathComponent
            ))
        }
        return result
    }

    public static func resolve(
        _ requested: AgentRuntimeKind,
        from runtimes: [LocalAgentRuntime]
    ) -> LocalAgentRuntime? {
        if requested != .automatic {
            return runtimes.first { $0.kind == requested }
        }
        for kind in [
            AgentRuntimeKind.codex,
            .traex,
            .claudeCode,
            .openCode
        ] {
            if let runtime = runtimes.first(where: { $0.kind == kind }) {
                return runtime
            }
        }
        return nil
    }

    private static func locate(
        names: [String],
        directories: [URL],
        fileManager: FileManager
    ) -> URL? {
        let candidates = directories.flatMap { directory in
            names.map { directory.appendingPathComponent($0) }
        }
        var seen = Set<String>()
        return candidates.first { candidate in
            let path = candidate.standardizedFileURL.path
            guard seen.insert(path).inserted else { return false }
            return fileManager.isExecutableFile(atPath: path)
        }
    }

}

public actor LocalAgentModelCatalog {
    private var cache: [AgentRuntimeKind: [String]] = [:]

    public init() {}

    public func models(for runtime: LocalAgentRuntime) async -> [String] {
        if let cached = cache[runtime.kind] { return cached }
        let discovered = await discover(runtime)
        let models = discovered.isEmpty
            ? runtime.suggestedModels : discovered
        cache[runtime.kind] = models
        return models
    }

    public func invalidate() {
        cache.removeAll()
    }

    private func discover(_ runtime: LocalAgentRuntime) async -> [String] {
        let arguments: [String]
        switch runtime.kind {
        case .traex: arguments = ["models", "--json"]
        case .openCode: arguments = ["models"]
        default: return runtime.suggestedModels
        }
        let runner = FoundationProcessRunner(
            currentDirectoryURL: FileManager.default.temporaryDirectory
        )
        guard let result = try? await runner.run(
            executableURL: runtime.executableURL,
            arguments: arguments,
            standardInput: Data(),
            timeout: 8
        ), result.exitCode == 0 else {
            return runtime.suggestedModels
        }
        switch runtime.kind {
        case .traex:
            guard let values = try? JSONSerialization.jsonObject(
                with: result.stdout
            ) as? [[String: Any]] else { return runtime.suggestedModels }
            return unique(values.compactMap { $0["name"] as? String })
        case .openCode:
            let output = String(decoding: result.stdout, as: UTF8.self)
            return unique(output.split(whereSeparator: \Character.isNewline).map {
                String($0).trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty && !$0.hasPrefix("\u{001B}") })
        default:
            return runtime.suggestedModels
        }
    }

    private func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { value in
            !value.isEmpty && value.count <= 200 && seen.insert(value).inserted
        }.prefix(100).map { $0 }
    }
}
