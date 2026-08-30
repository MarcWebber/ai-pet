import Foundation
import JellyCore

public final class CodexClient: CodexServing {
    public static let suggestedModels = [
        "gpt-5.6-luna", "gpt-5.6-terra", "gpt-5.6-sol",
        "gpt-5.5", "gpt-5.4"
    ]
    private let engine: CodexEngine?
    public init(
        executableURL: URL?,
        skillURL: URL?,
        temporaryRoot: URL = FileManager.default.temporaryDirectory
    ) {
        Self.removeStaleDirectories(in: temporaryRoot)
        guard let executableURL, let skillURL,
              let instructions = try? String(contentsOf: skillURL, encoding: .utf8) else {
            engine = nil
            return
        }
        engine = CodexEngine(
            executableURL: executableURL,
            takeoverInstructions: String(instructions.prefix(20_000)),
            workingDirectory: temporaryRoot.appendingPathComponent(
                "JellyPet-Codex-\(UUID().uuidString)",
                isDirectory: true
            )
        )
    }
    private static func removeStaleDirectories(in root: URL) {
        let files = FileManager.default
        let cutoff = Date().addingTimeInterval(-3_600)
        let urls = (try? files.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        for url in urls where url.lastPathComponent.hasPrefix("JellyPet-Codex-") {
            let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
            if modified.map({ $0 < cutoff }) == true { try? files.removeItem(at: url) }
        }
    }
    public func respond(
        to request: CodexRequest,
        screenToolHandler: ScreenToolHandler?
    ) async throws -> String {
        guard let engine else { throw PetFailure.codexUnavailable }
        return try await withTaskCancellationHandler {
            try await engine.respond(request, screenToolHandler: screenToolHandler)
        } onCancel: {
            Task { await engine.cancel() }
        }
    }
    public func steer(_ instruction: String) async throws {
        guard let engine else { throw PetFailure.codexUnavailable }
        try await engine.steer(instruction)
    }
    public func prepare(resetHistory: Bool) async {
        await engine?.prepare(resetHistory: resetHistory)
    }
    public func cancel() {
        if let engine { Task { await engine.cancel() } }
    }
}

private actor CodexEngine {
    private let executableURL: URL
    private let takeoverInstructions: String
    private let workingDirectory: URL
    private var process: Process?
    private var stdin: FileHandle?
    private var stdout: FileHandle?
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var iterator: AsyncThrowingStream<Data, Error>.Iterator?
    private var outputBuffer = Data()
    private var requestID = 0
    private var responseInFlight = false
    private var cancelRequested = false
    private var threadID: String?
    private var activeTurnID: String?
    private var history: [String] = []
    init(executableURL: URL, takeoverInstructions: String, workingDirectory: URL) {
        self.executableURL = executableURL
        self.takeoverInstructions = takeoverInstructions
        self.workingDirectory = workingDirectory
    }
    deinit {
        stdout?.readabilityHandler = nil
        if process?.isRunning == true { process?.terminate() }
        try? FileManager.default.removeItem(at: workingDirectory)
    }
    func respond(
        _ request: CodexRequest,
        screenToolHandler: ScreenToolHandler?
    ) async throws -> String {
        guard !responseInFlight else { throw PetFailure.invalidCodexOutput }
        responseInFlight = true
        cancelRequested = false
        defer {
            responseInFlight = false
            activeTurnID = nil
        }

        try await prepare()
        pruneHistory(request.preferences.conversationHistoryTurns)
        discardThread()
        let threadID = try await startThread(
            preferences: request.preferences,
            tools: screenToolHandler != nil
        )
        try Task.checkCancellation()
        guard !cancelRequested else { throw CancellationError() }

        var prompt = request.prompt
        if !history.isEmpty {
            prompt = "此前最近对话（仅作上下文）：\n\(history.joined(separator: "\n\n"))\n\n当前请求：\n\(prompt)"
        }
        let imageURL = try writeImage(request.imagePNG)
        defer { if let imageURL { try? FileManager.default.removeItem(at: imageURL) } }
        let result = try await rpc("turn/start", [
            "threadId": threadID,
            "input": Self.turnInput(
                prompt: prompt,
                imageURL: imageURL
            )
        ])
        guard let turn = result["turn"] as? [String: Any],
              let turnID = turn["id"] as? String,
              !turnID.isEmpty else { throw PetFailure.invalidCodexOutput }
        activeTurnID = turnID
        if cancelRequested || Task.isCancelled {
            interrupt(threadID, turnID)
            throw CancellationError()
        }
        let answer = try await waitForTurn(
            turnID,
            screenToolHandler: screenToolHandler
        )
        history.append("用户：\(String(request.prompt.prefix(8_000)))\n助手：\(String(answer.prefix(8_000)))")
        pruneHistory(request.preferences.conversationHistoryTurns)
        return answer
    }
    func steer(_ instruction: String) throws {
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard responseInFlight, let threadID, let activeTurnID,
              !text.isEmpty else { throw PetFailure.invalidCodexOutput }
        requestID += 1
        try send([
            "id": requestID,
            "method": "turn/steer",
            "params": [
                "threadId": threadID,
                "expectedTurnId": activeTurnID,
                "input": [["type": "text", "text": text]]
            ]
        ])
    }
    func cancel() { cancelRequested = true; interruptActiveTurn() }
    func prepare(resetHistory: Bool) async {
        await finishCurrentTurn()
        cancelRequested = false
        if resetHistory { history.removeAll() }
    }
    private func prepare() async throws {
        guard process?.isRunning != true else { return }
        stop()
        try launch()
        _ = try await rpc("initialize", [
            "clientInfo": ["name": "JellyPet", "version": "dev"],
            "capabilities": ["experimentalApi": true]
        ])
        try send(["method": "initialized"])
    }
    private func startThread(
        preferences: AssistantPreferences,
        tools: Bool
    ) async throws -> String {
        var params: [String: Any] = [
            "cwd": workingDirectory.path,
            "approvalPolicy": "never",
            "sandbox": "danger-full-access",
            "ephemeral": false,
            "baseInstructions": tools
                ? "你是 JellyPet 的屏幕操作 Agent。用户任务已经授权本轮界面修改。只使用 jellypet 动态工具观察和操作，根据每次真实结果继续；不要设置审批、只读或额外确认门槛，不得使用 Shell 或文件工具。\n\n\(takeoverInstructions)"
                : "你是 JellyPet 的屏幕问答助手。只回答问题，不操作界面或外部状态。",
            "config": ["model_reasoning_effort": preferences.reasoningEffort.rawValue]
        ]
        if preferences.model != AssistantPreferences.defaultModel {
            params["model"] = preferences.model
        }
        if tools { params["dynamicTools"] = Self.dynamicTools }
        let result = try await rpc("thread/start", params)
        guard let thread = result["thread"] as? [String: Any],
              let value = thread["id"] as? String,
              !value.isEmpty else { throw PetFailure.invalidCodexOutput }
        threadID = value
        return value
    }
    private func waitForTurn(
        _ turnID: String,
        screenToolHandler: ScreenToolHandler?
    ) async throws -> String {
        var text = ""
        while true {
            try Task.checkCancellation()
            let message = try await nextMessage()
            if try await handleToolCall(
                message,
                turnID: turnID,
                handler: screenToolHandler
            ) { continue }
            if let answer = try consume(message, turnID: turnID, text: &text) {
                return answer
            }
        }
    }
    private func handleToolCall(
        _ message: [String: Any],
        turnID: String,
        handler: ScreenToolHandler?
    ) async throws -> Bool {
        guard message["method"] as? String == "item/tool/call",
              let params = message["params"] as? [String: Any],
              params["turnId"] as? String == turnID else { return false }
        guard let id = message["id"] else { throw PetFailure.invalidCodexOutput }
        let result: ScreenToolResult
        do {
            guard let handler else {
                throw PetFailure.codexFailed("当前会话没有启用屏幕工具。")
            }
            result = await handler(try Self.decodeTool(params))
        } catch {
            result = .init(success: false, message: "工具参数无效，请按工具定义修正后重试。")
        }
        try send(["id": id, "result": Self.toolResponse(result)])
        return true
    }
    private func consume(
        _ message: [String: Any],
        turnID: String,
        text: inout String
    ) throws -> String? {
        guard let method = message["method"] as? String,
              let params = message["params"] as? [String: Any] else { return nil }
        if method == "error", params["turnId"] as? String == turnID,
           params["willRetry"] as? Bool != true {
            throw PetFailure.codexFailed(Self.errorText(params["error"]))
        }
        if method == "item/agentMessage/delta",
           params["turnId"] as? String == turnID,
           let delta = params["delta"] as? String,
           text.utf8.count + delta.utf8.count <= 200_000 {
            text += delta
            return nil
        }
        guard method == "turn/completed",
              let turn = params["turn"] as? [String: Any],
              turn["id"] as? String == turnID,
              let status = turn["status"] as? String else { return nil }
        if status == "interrupted" { throw CancellationError() }
        guard status == "completed" else {
            throw PetFailure.codexFailed(Self.errorText(turn["error"]))
        }
        let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { throw PetFailure.invalidCodexOutput }
        return answer
    }
    private func rpc(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        requestID += 1
        let id = requestID
        try send(["id": id, "method": method, "params": params])
        while true {
            let message = try await nextMessage()
            if Self.integerID(message["id"]) == id, message["method"] == nil {
                if let error = message["error"] {
                    throw PetFailure.codexFailed(Self.errorText(error))
                }
                guard let result = message["result"] as? [String: Any] else {
                    throw PetFailure.invalidCodexOutput
                }
                return result
            }
        }
    }
    private func launch() throws {
        let files = FileManager.default
        try files.createDirectory(
            at: workingDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let process = Process()
        let input = Pipe(), output = Pipe()
        let stream = AsyncThrowingStream<Data, Error> { self.continuation = $0 }
        process.executableURL = executableURL
        process.arguments = [
            "app-server", "--stdio",
            "--disable", "apps", "--disable", "goals",
            "--disable", "multi_agent", "--disable", "shell_tool",
            "--disable", "plugins", "--config", "mcp_servers={}"
        ]
        process.currentDirectoryURL = workingDirectory
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.environment = launchEnvironment()
        let continuation = self.continuation
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { continuation?.yield(data) }
        }
        process.terminationHandler = { process in
            continuation?.finish(throwing: PetFailure.codexFailed("Codex app-server 已断开。"))
        }
        do { try process.run() }
        catch {
            output.fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = nil
            throw PetFailure.codexFailed("Codex app-server 已断开。")
        }
        self.process = process
        stdin = input.fileHandleForWriting
        stdout = output.fileHandleForReading
        iterator = stream.makeAsyncIterator()
    }
    private func nextMessage() async throws -> [String: Any] {
        while true {
            if let newline = outputBuffer.firstIndex(of: 0x0A) {
                let line = outputBuffer[..<newline]
                outputBuffer.removeSubrange(...newline)
                guard !line.isEmpty else { continue }
                guard let object = try? JSONSerialization.jsonObject(with: Data(line)),
                      let message = object as? [String: Any] else {
                    throw PetFailure.invalidCodexOutput
                }
                return message
            }
            guard var iterator, let data = try await iterator.next() else {
                stop()
                throw PetFailure.codexFailed("Codex app-server 已断开。")
            }
            self.iterator = iterator
            outputBuffer.append(data)
        }
    }
    private func send(_ message: [String: Any]) throws {
        guard let stdin, process?.isRunning == true else {
            throw PetFailure.codexFailed("Codex app-server 已断开。")
        }
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(0x0A)
        try stdin.write(contentsOf: data)
    }
    private func finishCurrentTurn() async {
        cancelRequested = true
        interruptActiveTurn()
        let deadline = Date().addingTimeInterval(1)
        while responseInFlight {
            if Date() >= deadline { stop() }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }
    private func interruptActiveTurn() {
        if let threadID, let activeTurnID { interrupt(threadID, activeTurnID) }
    }
    private func interrupt(_ threadID: String, _ turnID: String) {
        requestID += 1
        try? send([
            "id": requestID,
            "method": "turn/interrupt",
            "params": ["threadId": threadID, "turnId": turnID]
        ])
    }
    private func discardThread() {
        if let threadID {
            requestID += 1
            try? send([
                "id": requestID,
                "method": "thread/unsubscribe",
                "params": ["threadId": threadID]
            ])
        }
        threadID = nil
    }
    private func stop() {
        stdout?.readabilityHandler = nil
        process?.terminationHandler = nil
        if process?.isRunning == true { process?.terminate() }
        continuation?.finish()
        process = nil; stdin = nil; stdout = nil
        continuation = nil; iterator = nil
        outputBuffer.removeAll(keepingCapacity: true)
        threadID = nil; activeTurnID = nil
    }
    private func launchEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let directory = executableURL.deletingLastPathComponent()
            .standardizedFileURL.path
        var paths = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        paths.removeAll { $0 == directory }
        paths.insert(directory, at: 0)
        environment["PATH"] = paths.joined(separator: ":")
        return environment
    }
    private func writeImage(_ data: Data?) throws -> URL? {
        guard let data else { return nil }
        let url = workingDirectory.appendingPathComponent("observation-\(UUID().uuidString).png")
        try data.write(to: url, options: .atomic)
        return url
    }
    private func pruneHistory(_ turns: Int) {
        let entries = max(1, turns)
        let bytes = max(24_000, min(200_000, turns * 16_000))
        while history.count > entries
            || history.reduce(0, { $0 + $1.utf8.count }) > bytes {
            history.removeFirst()
        }
    }
    private static func turnInput(
        prompt: String,
        imageURL: URL?
    ) -> [[String: Any]] {
        var input: [[String: Any]] = [[
            "type": "text",
            "text": prompt
        ]]
        if let imageURL {
            input.append(["type": "localImage", "path": imageURL.path])
        }
        return input
    }
    private static func decodeTool(_ params: [String: Any]) throws -> ScreenToolCall {
        guard params["namespace"] as? String == "jellypet",
              let name = params["tool"] as? String,
              let arguments = params["arguments"] as? [String: Any] else {
            throw PetFailure.invalidCodexOutput
        }
        if name == "observe" { return .observe }
        var object = arguments
        object["kind"] = name
        return .perform(try decode(object, as: ScreenAction.self))
    }
    private static func decode<T: Decodable>(
        _ object: [String: Any],
        as type: T.Type
    ) throws -> T {
        try JSONDecoder().decode(
            T.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
    }
    private static func toolResponse(_ result: ScreenToolResult) -> [String: Any] {
        var items: [[String: Any]] = [["type": "inputText", "text": result.message]]
        if let image = result.screenshotPNG {
            items.append([
                "type": "inputImage",
                "imageUrl": "data:image/png;base64,\(image.base64EncodedString())"
            ])
        }
        return ["contentItems": items, "success": result.success]
    }
    private static let dynamicTools: [[String: Any]] = [[
        "type": "namespace",
        "name": "jellypet",
        "description": "观察并操作当前接管界面。调用结果是字符串，直接读取结果文本。",
        "tools": [
            tool("observe", "显式刷新当前显示器的整屏截图与语义元素。每次动作后重新调用；也可随时再次调用以读取用户手工修改。", [:]),
            tool("click", "单击目标。用户任务已授权所需界面操作，不增加类别限制。", ["target": targetSchema], ["target"]),
            tool("double_click", "双击目标。", ["target": targetSchema], ["target"]),
            tool("drag", "按归一化坐标拖动。", [
                "fromX": coordinate, "fromY": coordinate,
                "toX": coordinate, "toY": coordinate,
                "durationMilliseconds": integer(200, 2_000)
            ], ["fromX", "fromY", "toX", "toY", "durationMilliseconds"]),
            tool("type_text", "给出语义输入目标和完整最终文本。执行器每次重读当前值，只逐字修复真实差异；不要先全选或清空。", [
                "target": semanticTarget,
                "text": ["type": "string", "minLength": 1, "maxLength": 100_000]
            ], ["target", "text"]),
            tool("key_press", "发送一个按键与可选修饰键。", [
                "key": ["type": "string", "enum": ScreenKey.allCases.map(\.rawValue)],
                "modifiers": ["type": "array", "items": ["type": "string", "enum": KeyModifier.allCases.map(\.rawValue)], "uniqueItems": true]
            ], ["key", "modifiers"]),
            tool("navigate", "打开 HTTP 或 HTTPS 网址。", [
                "url": ["type": "string", "minLength": 1, "maxLength": 2_048]
            ], ["url"]),
            tool("scroll", "滚动页面或目标；单次绝对值不超过 \(ScreenAction.maximumScrollDelta)。", [
                "target": targetSchema,
                "deltaX": integer(-ScreenAction.maximumScrollDelta, ScreenAction.maximumScrollDelta),
                "deltaY": integer(-ScreenAction.maximumScrollDelta, ScreenAction.maximumScrollDelta)
            ], ["deltaX", "deltaY"]),
            tool("wait", "短暂等待，之后重新 observe。", [
                "milliseconds": integer(200, 3_000)
            ], ["milliseconds"])
        ]
    ]]
    private static let coordinate = integer(0, 1_000)
    private static let matcher = object([
        "text": ["type": "string", "minLength": 1, "maxLength": 1_000],
        "mode": ["type": "string", "enum": TextMatcher.Mode.allCases.map(\.rawValue)]
    ], ["text"])
    private static let role: [String: Any] = [
        "type": "string", "enum": ElementRole.allCases.map(\.rawValue)
    ]
    private static let locatorSchema = object([
        "application": matcher, "window": matcher, "pageURL": matcher,
        "role": role, "label": matcher, "value": matcher,
        "ancestorRole": role, "ancestorLabel": matcher, "ancestorValue": matcher,
        "ordinal": integer(0, 249)
    ])
    private static let targetSchema: [String: Any] = ["oneOf": [
        object(["elementID": ["type": "string", "minLength": 1]], ["elementID"]),
        object(["locator": locatorSchema], ["locator"]),
        object(["x": coordinate, "y": coordinate], ["x", "y"])
    ]]
    private static let semanticTarget: [String: Any] = ["oneOf": [
        object(["elementID": ["type": "string", "minLength": 1]], ["elementID"]),
        object(["locator": locatorSchema], ["locator"])
    ]]
    private static func tool(
        _ name: String,
        _ description: String,
        _ properties: [String: Any],
        _ required: [String] = []
    ) -> [String: Any] {
        [
            "type": "function", "name": name, "description": description,
            "inputSchema": object(properties, required)
        ]
    }
    private static func object(
        _ properties: [String: Any],
        _ required: [String] = []
    ) -> [String: Any] {
        [
            "type": "object", "properties": properties,
            "required": required, "additionalProperties": false
        ]
    }
    private static func integer(_ minimum: Int, _ maximum: Int) -> [String: Any] {
        ["type": "integer", "minimum": minimum, "maximum": maximum]
    }
    private static func integerID(_ value: Any?) -> Int? {
        (value as? Int) ?? (value as? NSNumber)?.intValue
    }
    private static func errorText(_ value: Any?) -> String {
        guard let error = value as? [String: Any] else {
            return "Codex app-server 返回了未知错误。"
        }
        let text = [error["message"] as? String, error["additionalDetails"] as? String]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "；")
        return text.isEmpty ? "Codex app-server 返回了未知错误。" : String(text.prefix(2_000))
    }
}

public enum CodexExecutableLocator {
    public static func locate(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        let home = fileManager.homeDirectoryForCurrentUser
        let directories = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0), isDirectory: true) } + [
                home.appendingPathComponent(".local/bin", isDirectory: true),
                home.appendingPathComponent(".npm-global/bin", isDirectory: true),
                URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
                URL(fileURLWithPath: "/usr/local/bin", isDirectory: true)
            ]
        var seen = Set<String>()
        return directories.lazy.map { $0.appendingPathComponent("codex") }
            .first {
                let path = $0.standardizedFileURL.path
                return seen.insert(path).inserted
                    && fileManager.isExecutableFile(atPath: path)
            }
    }
}
