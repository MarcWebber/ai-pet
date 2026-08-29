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
        guard let executableURL, let skillURL,
              FileManager.default.isReadableFile(atPath: skillURL.path) else {
            engine = nil
            return
        }
        engine = CodexEngine(
            executableURL: executableURL,
            skillURL: skillURL,
            workingDirectory: temporaryRoot.appendingPathComponent(
                "JellyPet-Codex-\(UUID().uuidString)",
                isDirectory: true
            )
        )
    }

    public func respond(
        to request: CodexRequest,
        onTextDelta: @escaping @Sendable (String) -> Void,
        screenToolHandler: ScreenToolHandler?
    ) async throws -> String {
        guard let engine else { throw PetFailure.codexUnavailable }
        do {
            return try await withTaskCancellationHandler {
                try await engine.respond(
                    request,
                    onTextDelta: onTextDelta,
                    screenToolHandler: screenToolHandler
                )
            } onCancel: {
                Task { await engine.cancel() }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as PetFailure {
            throw failure
        } catch {
            throw PetFailure.codexFailed(error.localizedDescription)
        }
    }

    public func steer(_ instruction: String) async throws {
        guard let engine else { throw PetFailure.codexUnavailable }
        do { try await engine.steer(instruction) }
        catch { throw PetFailure.codexFailed(error.localizedDescription) }
    }

    public func prepareForNextTurn() async {
        await engine?.prepareForNextTurn()
    }

    public func resetSession() async {
        await engine?.resetSession()
    }

    public func cancel() {
        if let engine { Task { await engine.cancel() } }
    }
}

private enum CodexEngineError: LocalizedError {
    case disconnected(String?)
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case let .disconnected(message): message ?? "Codex app-server 已断开。"
        case .invalidResponse: "Codex app-server 返回了无效响应。"
        case let .server(message): message
        }
    }
}

private final class StderrBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""

    func clear() { lock.withLock { value = "" } }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.withLock {
            value = String((value + String(decoding: data, as: UTF8.self)).suffix(8_000))
        }
    }

    func message() -> String? {
        lock.withLock {
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
    }
}

private actor CodexEngine {
    typealias DeltaHandler = @Sendable (String) -> Void

    private struct ThreadConfiguration: Equatable {
        let model: String
        let reasoning: String
        let tools: Bool
        let historyTurns: Int
    }

    private enum TurnOutcome {
        case waiting
        case finished(String)
        case failed(Error)
    }

    private let executableURL: URL
    private let sourceSkillURL: URL
    private let workingDirectory: URL
    private let stderr = StderrBuffer()
    private var process: Process?
    private var stdin: FileHandle?
    private var stdout: FileHandle?
    private var stderrHandle: FileHandle?
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var iterator: AsyncThrowingStream<Data, Error>.Iterator?
    private var outputBuffer = Data()
    private var requestID = 0
    private var initialized = false
    private var responseInFlight = false
    private var cancelRequested = false
    private var threadID: String?
    private var threadConfiguration: ThreadConfiguration?
    private var activeTurnID: String?
    private var skillPath: String?
    private var skillPending = true
    private var bufferedEvents: [String: [[String: Any]]] = [:]
    private var completedTurns = 0
    private var history: [String] = []

    init(executableURL: URL, skillURL: URL, workingDirectory: URL) {
        self.executableURL = executableURL
        sourceSkillURL = skillURL
        self.workingDirectory = workingDirectory
    }

    deinit {
        stdout?.readabilityHandler = nil
        stderrHandle?.readabilityHandler = nil
        if process?.isRunning == true { process?.terminate() }
        try? FileManager.default.removeItem(at: workingDirectory)
    }

    func respond(
        _ request: CodexRequest,
        onTextDelta: @escaping DeltaHandler,
        screenToolHandler: ScreenToolHandler?
    ) async throws -> String {
        guard !responseInFlight else { throw CodexEngineError.invalidResponse }
        responseInFlight = true
        cancelRequested = false
        defer {
            responseInFlight = false
            activeTurnID = nil
        }

        try await prepare()
        let configuration = ThreadConfiguration(
            model: request.model,
            reasoning: request.reasoningEffort.rawValue,
            tools: screenToolHandler != nil,
            historyTurns: request.conversationHistoryTurns
        )
        pruneHistory(request.conversationHistoryTurns)
        let startsNewThread = configuration != threadConfiguration
            || completedTurns >= request.conversationHistoryTurns
        if startsNewThread {
            discardThread()
            completedTurns = 0
        }
        let threadID = try await ensureThread(configuration)
        try Task.checkCancellation()
        guard !cancelRequested else { throw CancellationError() }

        var prompt = request.prompt
        if startsNewThread, !history.isEmpty {
            prompt = "此前最近对话（仅作上下文）：\n\(history.joined(separator: "\n\n"))\n\n当前请求：\n\(prompt)"
        }
        let imageURL = try writeImage(request.imagePNG)
        defer { if let imageURL { try? FileManager.default.removeItem(at: imageURL) } }
        let attachedSkill = screenToolHandler != nil && skillPending
            ? skillPath : nil
        if screenToolHandler != nil, attachedSkill == nil {
            throw CodexEngineError.invalidResponse
        }
        let result = try await rpc("turn/start", [
            "threadId": threadID,
            "input": Self.turnInput(
                prompt: prompt,
                imageURL: imageURL,
                skillPath: attachedSkill
            )
        ])
        if attachedSkill != nil { skillPending = false }
        guard let turn = result["turn"] as? [String: Any],
              let turnID = turn["id"] as? String,
              !turnID.isEmpty else { throw CodexEngineError.invalidResponse }
        activeTurnID = turnID
        if cancelRequested || Task.isCancelled {
            interrupt(threadID, turnID)
            throw CancellationError()
        }
        let answer = try await waitForTurn(
            turnID,
            onTextDelta: onTextDelta,
            screenToolHandler: screenToolHandler
        )
        completedTurns += 1
        history.append("用户：\(String(request.prompt.prefix(8_000)))")
        history.append("助手：\(String(answer.prefix(8_000)))")
        pruneHistory(request.conversationHistoryTurns)
        return answer
    }

    func steer(_ instruction: String) throws {
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard responseInFlight, let threadID, let activeTurnID,
              !text.isEmpty else { throw CodexEngineError.invalidResponse }
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

    func prepareForNextTurn() async {
        await finishCurrentTurn()
        cancelRequested = false
    }

    func resetSession() async {
        await finishCurrentTurn()
        discardThread()
        history.removeAll()
        completedTurns = 0
        cancelRequested = false
    }

    private func prepare() async throws {
        guard !initialized || process?.isRunning != true else { return }
        stop()
        try launch()
        _ = try await rpc("initialize", [
            "clientInfo": ["name": "JellyPet", "version": "dev"],
            "capabilities": ["experimentalApi": true]
        ])
        try send(["method": "initialized"])
        try await discoverSkill()
        initialized = true
    }

    private func discoverSkill() async throws {
        let result = try await rpc("skills/list", [
            "cwds": [workingDirectory.path],
            "forceReload": true
        ])
        let expected = sourceSkillURL.resolvingSymlinksInPath()
            .standardizedFileURL.path
        guard let groups = result["data"] as? [[String: Any]] else {
            throw CodexEngineError.invalidResponse
        }
        for group in groups {
            for skill in group["skills"] as? [[String: Any]] ?? [] {
                if skill["name"] as? String == "jellypet-takeover",
                   skill["enabled"] as? Bool == true,
                   let path = skill["path"] as? String,
                   URL(fileURLWithPath: path).resolvingSymlinksInPath()
                    .standardizedFileURL.path == expected {
                    skillPath = path
                    return
                }
            }
        }
        throw CodexEngineError.invalidResponse
    }

    private func ensureThread(_ configuration: ThreadConfiguration) async throws -> String {
        if let threadID, threadConfiguration == configuration { return threadID }
        discardThread()
        var params: [String: Any] = [
            "cwd": workingDirectory.path,
            "approvalPolicy": "never",
            "sandbox": "danger-full-access",
            "ephemeral": false,
            "baseInstructions": configuration.tools
                ? "你是 JellyPet 的屏幕操作 Agent。用户任务已经授权本轮界面修改。只使用 jellypet 动态工具观察和操作，根据每次真实结果继续；不要设置审批、只读或额外确认门槛，不得使用 Shell 或文件工具。"
                : "你是 JellyPet 的屏幕问答助手。只回答问题，不操作界面或外部状态。",
            "config": ["model_reasoning_effort": configuration.reasoning]
        ]
        if configuration.model != AssistantPreferences.defaultModel {
            params["model"] = configuration.model
        }
        if configuration.tools { params["dynamicTools"] = Self.dynamicTools }
        let result = try await rpc("thread/start", params)
        guard let thread = result["thread"] as? [String: Any],
              let value = thread["id"] as? String,
              !value.isEmpty else { throw CodexEngineError.invalidResponse }
        threadID = value
        threadConfiguration = configuration
        skillPending = true
        return value
    }

    private func waitForTurn(
        _ turnID: String,
        onTextDelta: @escaping DeltaHandler,
        screenToolHandler: ScreenToolHandler?
    ) async throws -> String {
        var text = ""
        var pendingDelta = ""
        var lastEmission = Date.distantPast
        func emit(_ force: Bool = false) {
            guard !pendingDelta.isEmpty,
                  force || Date().timeIntervalSince(lastEmission) >= 0.25 else { return }
            onTextDelta(pendingDelta)
            pendingDelta = ""
            lastEmission = Date()
        }
        var queue = bufferedEvents.removeValue(forKey: turnID) ?? []
        while true {
            try Task.checkCancellation()
            let message = queue.isEmpty ? try await nextMessage() : queue.removeFirst()
            if try await handleToolCall(
                message,
                turnID: turnID,
                handler: screenToolHandler
            ) { continue }
            switch consume(message, turnID: turnID, text: &text) {
            case .waiting:
                if let params = message["params"] as? [String: Any],
                   message["method"] as? String == "item/agentMessage/delta",
                   let delta = params["delta"] as? String {
                    pendingDelta += delta
                    emit()
                }
            case let .finished(answer):
                emit(true)
                return answer
            case let .failed(error): throw error
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
        guard let id = message["id"] else { throw CodexEngineError.invalidResponse }
        let result: ScreenToolResult
        do {
            guard let handler else {
                throw CodexEngineError.server("当前会话没有启用屏幕工具。")
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
    ) -> TurnOutcome {
        guard let method = message["method"] as? String,
              let params = message["params"] as? [String: Any] else { return .waiting }
        if method == "error", params["turnId"] as? String == turnID,
           params["willRetry"] as? Bool != true {
            return .failed(CodexEngineError.server(Self.errorText(params["error"])))
        }
        if method == "item/agentMessage/delta",
           params["turnId"] as? String == turnID,
           let delta = params["delta"] as? String,
           text.utf8.count + delta.utf8.count <= 200_000 {
            text += delta
            return .waiting
        }
        guard method == "turn/completed",
              let turn = params["turn"] as? [String: Any],
              turn["id"] as? String == turnID,
              let status = turn["status"] as? String else { return .waiting }
        if status == "interrupted" { return .failed(CancellationError()) }
        guard status == "completed" else {
            return .failed(CodexEngineError.server(Self.errorText(turn["error"])))
        }
        let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return answer.isEmpty ? .failed(CodexEngineError.invalidResponse) : .finished(answer)
    }

    private func rpc(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        requestID += 1
        let id = requestID
        try send(["id": id, "method": method, "params": params])
        while true {
            let message = try await nextMessage()
            if Self.integerID(message["id"]) == id, message["method"] == nil {
                if let error = message["error"] {
                    throw CodexEngineError.server(Self.errorText(error))
                }
                guard let result = message["result"] as? [String: Any] else {
                    throw CodexEngineError.invalidResponse
                }
                return result
            }
            buffer(message)
        }
    }

    private func buffer(_ message: [String: Any]) {
        guard let method = message["method"] as? String,
              ["item/agentMessage/delta", "item/tool/call", "error", "turn/completed"]
                .contains(method),
              let params = message["params"] as? [String: Any],
              let turnID = params["turnId"] as? String
                ?? (params["turn"] as? [String: Any])?["id"] as? String else { return }
        if bufferedEvents[turnID, default: []].count < 128 {
            bufferedEvents[turnID, default: []].append(message)
        }
    }

    private func launch() throws {
        let files = FileManager.default
        try files.createDirectory(
            at: workingDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let link = workingDirectory
            .appendingPathComponent(".agents/skills/jellypet-takeover", isDirectory: true)
        try files.createDirectory(
            at: link.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        if !files.fileExists(atPath: link.path) {
            try files.createSymbolicLink(
                at: link,
                withDestinationURL: sourceSkillURL.deletingLastPathComponent()
            )
        }
        let process = Process()
        let input = Pipe(), output = Pipe(), errors = Pipe()
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
        process.standardError = errors
        process.environment = launchEnvironment()
        stderr.clear()
        let continuation = self.continuation
        let stderr = self.stderr
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { continuation?.yield(data) }
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            stderr.append(handle.availableData)
        }
        process.terminationHandler = { process in
            continuation?.finish(throwing: CodexEngineError.disconnected(
                stderr.message() ?? "Codex 提前退出（\(process.terminationStatus)）。"
            ))
        }
        do { try process.run() }
        catch {
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = nil
            throw CodexEngineError.disconnected(error.localizedDescription)
        }
        self.process = process
        stdin = input.fileHandleForWriting
        stdout = output.fileHandleForReading
        stderrHandle = errors.fileHandleForReading
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
                    throw CodexEngineError.invalidResponse
                }
                return message
            }
            guard var iterator, let data = try await iterator.next() else {
                stop()
                throw CodexEngineError.disconnected(stderr.message())
            }
            self.iterator = iterator
            outputBuffer.append(data)
        }
    }

    private func send(_ message: [String: Any]) throws {
        guard let stdin, process?.isRunning == true else {
            throw CodexEngineError.disconnected(stderr.message())
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
        threadConfiguration = nil
        skillPending = true
        bufferedEvents.removeAll()
    }

    private func stop() {
        stdout?.readabilityHandler = nil
        stderrHandle?.readabilityHandler = nil
        process?.terminationHandler = nil
        if process?.isRunning == true { process?.terminate() }
        continuation?.finish()
        process = nil; stdin = nil; stdout = nil; stderrHandle = nil
        continuation = nil; iterator = nil
        outputBuffer.removeAll(keepingCapacity: true)
        initialized = false
        threadID = nil; threadConfiguration = nil; activeTurnID = nil
        skillPath = nil; skillPending = true
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
        let entries = max(2, turns * 2)
        let bytes = max(24_000, min(200_000, turns * 16_000))
        while history.count > entries
            || history.reduce(0, { $0 + $1.utf8.count }) > bytes {
            history.removeFirst()
        }
    }

    private static func turnInput(
        prompt: String,
        imageURL: URL?,
        skillPath: String?
    ) -> [[String: Any]] {
        var input: [[String: Any]] = [[
            "type": "text",
            "text": skillPath == nil ? prompt : "$jellypet-takeover\n\(prompt)"
        ]]
        if let skillPath {
            input.append([
                "type": "skill",
                "name": "jellypet-takeover",
                "path": skillPath
            ])
        }
        if let imageURL {
            input.append(["type": "localImage", "path": imageURL.path])
        }
        return input
    }

    private static func decodeTool(_ params: [String: Any]) throws -> ScreenToolCall {
        guard params["namespace"] as? String == "jellypet",
              let name = params["tool"] as? String,
              let arguments = params["arguments"] as? [String: Any] else {
            throw CodexEngineError.invalidResponse
        }
        if name == "observe" { return .observe }
        if name == "activate_and_verify" {
            return .activateAndVerify(try decode(arguments, as: ActivateAndVerifyRequest.self))
        }
        let kinds = [
            "click": "click", "double_click": "doubleClick", "drag": "drag",
            "type_text": "typeText", "key_press": "keyPress",
            "navigate": "navigate", "scroll": "scroll", "wait": "wait"
        ]
        guard let kind = kinds[name] else { throw CodexEngineError.invalidResponse }
        var object = arguments
        object["kind"] = kind
        if let target = arguments["target"] as? [String: Any] {
            object["target"] = try normalizeTarget(target)
        }
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

    private static func normalizeTarget(_ target: [String: Any]) throws -> [String: Any] {
        var result = target
        if target.keys.count == 1, target["elementID"] is String {
            result["source"] = "element"
        } else if target.keys.count == 1, target["locator"] is [String: Any] {
            result["source"] = "locator"
        } else if Set(target.keys) == ["x", "y"] {
            result["source"] = "visual"
        } else {
            throw CodexEngineError.invalidResponse
        }
        return result
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
            tool("activate_and_verify", "原子执行：刷新、激活一次、再刷新并检查条件。每次调用独立，不保存跨调用限制。", [
                "targetLocator": locatorSchema,
                "expectedLocator": locatorSchema,
                "expectedState": ["type": "string", "enum": ConditionState.allCases.map(\.rawValue)],
                "expectedValueEquals": ["type": "string", "maxLength": 100_000]
            ], ["targetLocator", "expectedLocator", "expectedState"]),
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
        "ordinal": integer(0, 249), "requiresEnabled": ["type": "boolean"]
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
        if let error = value as? [String: Any] {
            let text = [error["message"] as? String, error["additionalDetails"] as? String]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "；")
            if !text.isEmpty { return String(text.prefix(2_000)) }
        }
        guard let value,
              JSONSerialization.isValidJSONObject(["error": value]),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let text = String(data: data, encoding: .utf8) else {
            return "Codex app-server 返回了未知错误。"
        }
        return String(text.prefix(2_000))
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
