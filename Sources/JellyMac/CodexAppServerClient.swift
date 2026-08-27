import Foundation
import JellyCore

enum CodexAppServerError: Error {
    case startup(String?)
    case disconnected(String?)
    case invalidResponse
    case server(String)
}

private final class CodexStderrBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""

    func clear() {
        lock.withLock { value = "" }
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.withLock {
            value += String(decoding: data, as: UTF8.self)
            if value.count > 8_000 {
                value = String(value.suffix(8_000))
            }
        }
    }

    func message() -> String? {
        lock.withLock {
            let message = value.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            return message.isEmpty ? nil : message
        }
    }
}

actor CodexAppServerClient {
    typealias UpdateHandler = @Sendable (String) -> Void

    private static let skillName = "jellypet-takeover"

    private enum TurnOutcome {
        case waiting
        case completed(String)
        case failed(Error)
    }

    private struct ThreadConfiguration: Equatable {
        let model: String
        let reasoningEffort: String
        let enablesScreenTools: Bool
    }

    private struct DeltaEmitter {
        private var pending = ""
        private var lastEmission = Date.distantPast

        mutating func append(_ delta: String, to handler: UpdateHandler) {
            pending += delta
            guard Date().timeIntervalSince(lastEmission) >= 0.25 else { return }
            flush(to: handler)
        }

        mutating func flush(to handler: UpdateHandler) {
            guard !pending.isEmpty else { return }
            handler(pending)
            pending = ""
            lastEmission = Date()
        }
    }

    private let executableURL: URL
    private let runtime: AgentRuntimeKind
    private let sourceSkillURL: URL
    private let workingDirectory: URL
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var errors: FileHandle?
    private var iterator: AsyncThrowingStream<Data, Error>.Iterator?
    private var streamContinuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var outputBuffer = Data()
    private let stderrBuffer = CodexStderrBuffer()
    private var requestID = 0
    private var initialized = false
    private var preparation: Task<Void, Error>?
    private var responseInFlight = false
    private var cancelRequested = false
    private var threadID: String?
    private var threadConfiguration: ThreadConfiguration?
    private var activeTurnID: String?
    private var skillPath: String?
    private var skillPending = true
    private var bufferedTurnEvents: [String: [[String: Any]]] = [:]

    init(
        executableURL: URL,
        runtime: AgentRuntimeKind = .codex,
        skillURL: URL,
        workingDirectory: URL
    ) {
        self.executableURL = executableURL
        self.runtime = runtime
        self.sourceSkillURL = skillURL
        self.workingDirectory = workingDirectory
    }

    deinit {
        output?.readabilityHandler = nil
        errors?.readabilityHandler = nil
        if process?.isRunning == true { process?.terminate() }
        try? FileManager.default.removeItem(at: workingDirectory)
    }

    func respond(
        to request: CodexRequest,
        onTextDelta: @escaping UpdateHandler,
        screenToolHandler: ScreenToolHandler?
    ) async throws -> String {
        guard !responseInFlight else { throw CodexAppServerError.invalidResponse }
        responseInFlight = true
        cancelRequested = false
        defer {
            responseInFlight = false
            activeTurnID = nil
        }

        do { try await prepare() }
        catch let error as CodexAppServerError { throw error }
        catch { throw CodexAppServerError.startup(error.localizedDescription) }
        let threadID: String
        do {
            threadID = try await ensureThread(
                for: request,
                enablesScreenTools: screenToolHandler != nil
            )
        }
        catch let error as CodexAppServerError { throw error }
        catch { throw CodexAppServerError.startup(error.localizedDescription) }
        try Task.checkCancellation()
        guard !cancelRequested else { throw CancellationError() }

        let attachedSkillPath: String?
        if screenToolHandler != nil, skillPending {
            guard let skillPath else {
                throw CodexAppServerError.invalidResponse
            }
            attachedSkillPath = skillPath
        } else {
            attachedSkillPath = nil
        }
        let result = try await rpc(method: "turn/start", params: [
            "threadId": threadID,
            "input": Self.input(
                for: request,
                skillPath: attachedSkillPath
            )
        ])
        if attachedSkillPath != nil { skillPending = false }
        guard let turn = result["turn"] as? [String: Any],
              let turnID = turn["id"] as? String, !turnID.isEmpty else {
            throw CodexAppServerError.invalidResponse
        }
        activeTurnID = turnID
        if cancelRequested || Task.isCancelled {
            interrupt(threadID: threadID, turnID: turnID)
            throw CancellationError()
        }
        return try await waitForTurn(
            turnID: turnID,
            onTextDelta: onTextDelta,
            screenToolHandler: screenToolHandler
        )
    }

    func steer(_ instruction: String) throws {
        let value = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard responseInFlight,
              let threadID,
              let activeTurnID,
              !value.isEmpty else { throw CodexAppServerError.invalidResponse }
        requestID += 1
        try send([
            "id": requestID,
            "method": "turn/steer",
            "params": [
                "threadId": threadID,
                "expectedTurnId": activeTurnID,
                "input": [["type": "text", "text": value]]
            ]
        ])
    }

    func cancel() {
        cancelRequested = true
        if let threadID, let activeTurnID {
            interrupt(threadID: threadID, turnID: activeTurnID)
        }
    }

    func prepareForNextTurn() async {
        await finishCurrentTurn()
        cancelRequested = false
    }

    func resetSession() async {
        await finishCurrentTurn()
        discardThread()
        cancelRequested = false
    }

    private func finishCurrentTurn() async {
        cancelRequested = true
        if let threadID, let activeTurnID {
            interrupt(threadID: threadID, turnID: activeTurnID)
        }
        let stopDeadline = Date().addingTimeInterval(1)
        while responseInFlight {
            if Date() >= stopDeadline { stop() }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
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
        bufferedTurnEvents.removeAll()
    }

    private func prepare() async throws {
        if initialized, process?.isRunning == true { return }
        if let preparation {
            try await preparation.value
            return
        }
        let task = Task { try await self.startAndInitialize() }
        preparation = task
        do {
            try await task.value
            preparation = nil
        } catch {
            preparation = nil
            throw error
        }
    }

    private func startAndInitialize() async throws {
        stop()
        try launch()
        _ = try await rpc(method: "initialize", params: [
            "clientInfo": [
                "name": "JellyPet",
                "version": Bundle.main.object(
                    forInfoDictionaryKey: "CFBundleShortVersionString"
                ) as? String ?? "dev"
            ],
            "capabilities": ["experimentalApi": true]
        ])
        try send(["method": "initialized"])
        try await discoverSkill()
        initialized = true
    }

    private func discoverSkill() async throws {
        let result = try await rpc(method: "skills/list", params: [
            "cwds": [workingDirectory.path],
            "forceReload": true
        ])
        let expectedPath = sourceSkillURL.resolvingSymlinksInPath().standardizedFileURL.path
        guard let entries = result["data"] as? [[String: Any]] else {
            throw CodexAppServerError.invalidResponse
        }
        for entry in entries {
            guard let skills = entry["skills"] as? [[String: Any]] else { continue }
            for skill in skills {
                guard skill["name"] as? String == Self.skillName,
                      skill["enabled"] as? Bool == true,
                      let path = skill["path"] as? String,
                      URL(fileURLWithPath: path)
                        .resolvingSymlinksInPath().standardizedFileURL.path == expectedPath
                else { continue }
                skillPath = path
                return
            }
        }
        throw CodexAppServerError.invalidResponse
    }

    private func ensureThread(
        for request: CodexRequest,
        enablesScreenTools: Bool
    ) async throws -> String {
        let configuration = ThreadConfiguration(
            model: request.model,
            reasoningEffort: request.reasoningEffort.rawValue,
            enablesScreenTools: enablesScreenTools
        )
        if let threadID, threadConfiguration == configuration {
            return threadID
        }
        if threadID != nil {
            discardThread()
        }
        var params: [String: Any] = [
            "cwd": workingDirectory.path,
            "approvalPolicy": "never",
            "sandbox": "danger-full-access",
            "ephemeral": false,
            "baseInstructions": enablesScreenTools
                ? "你是 JellyPet 的界面操作 Agent。使用 jellypet 命名空间里的工具观察和操作当前界面；根据每次真实工具结果继续工作，不要返回动作 JSON。不得使用 Shell、文件修改或未提供的外部工具。"
                : "你是 JellyPet 的屏幕问答助手。只回答用户的问题，不执行界面操作、文件修改或外部命令。",
            "config": ["model_reasoning_effort": request.reasoningEffort.rawValue]
        ]
        if request.model != AssistantPreferences.automaticModel {
            params["model"] = request.model
        }
        if enablesScreenTools {
            params["dynamicTools"] = Self.dynamicTools
        }
        let result = try await rpc(method: "thread/start", params: params)
        guard let thread = result["thread"] as? [String: Any],
              let value = thread["id"] as? String, !value.isEmpty else {
            throw CodexAppServerError.invalidResponse
        }
        skillPending = true
        threadID = value
        threadConfiguration = configuration
        return value
    }

    private func rpc(
        method: String,
        params: [String: Any]
    ) async throws -> [String: Any] {
        requestID += 1
        let expectedID = requestID
        try send(["id": expectedID, "method": method, "params": params])
        while true {
            let message = try await nextMessage()
            if Self.integerID(message["id"]) == expectedID,
               message["method"] == nil {
                if let error = message["error"] {
                    throw CodexAppServerError.server(
                        Self.errorMessage(error)
                    )
                }
                guard let result = message["result"] as? [String: Any] else {
                    throw CodexAppServerError.invalidResponse
                }
                return result
            }
            bufferTurnEvent(message)
        }
    }

    private func waitForTurn(
        turnID: String,
        onTextDelta: @escaping UpdateHandler,
        screenToolHandler: ScreenToolHandler?
    ) async throws -> String {
        var text = ""
        var emitter = DeltaEmitter()
        let buffered = bufferedTurnEvents.removeValue(forKey: turnID) ?? []
        for event in buffered {
            if try await handleToolRequest(
                event,
                turnID: turnID,
                screenToolHandler: screenToolHandler
            ) { continue }
            switch consume(
                event, turnID: turnID, text: &text,
                emitter: &emitter, onTextDelta: onTextDelta
            ) {
            case .waiting: break
            case let .completed(answer):
                emitter.flush(to: onTextDelta)
                return answer
            case let .failed(error): throw error
            }
        }
        while true {
            try Task.checkCancellation()
            let message = try await nextMessage()
            if try await handleToolRequest(
                message,
                turnID: turnID,
                screenToolHandler: screenToolHandler
            ) { continue }
            switch consume(
                message, turnID: turnID, text: &text,
                emitter: &emitter, onTextDelta: onTextDelta
            ) {
            case .waiting: continue
            case let .completed(answer):
                emitter.flush(to: onTextDelta)
                return answer
            case let .failed(error): throw error
            }
        }
    }

    private func handleToolRequest(
        _ message: [String: Any],
        turnID: String,
        screenToolHandler: ScreenToolHandler?
    ) async throws -> Bool {
        guard message["method"] as? String == "item/tool/call",
              let params = message["params"] as? [String: Any],
              params["turnId"] as? String == turnID else {
            return false
        }
        guard let serverRequestID = message["id"] else {
            throw CodexAppServerError.invalidResponse
        }

        let result: ScreenToolResult
        if let screenToolHandler {
            do {
                result = await screenToolHandler(
                    try Self.screenToolCall(from: params)
                )
            } catch {
                result = ScreenToolResult(
                    success: false,
                    message: "工具参数无效，请根据工具定义修正后重试。"
                )
            }
        } else {
            result = ScreenToolResult(
                success: false,
                message: "当前会话没有启用屏幕工具。"
            )
        }
        try send([
            "id": serverRequestID,
            "result": Self.dynamicToolResponse(result)
        ])
        return true
    }

    private func consume(
        _ message: [String: Any],
        turnID: String,
        text: inout String,
        emitter: inout DeltaEmitter,
        onTextDelta: UpdateHandler
    ) -> TurnOutcome {
        guard let method = message["method"] as? String,
              let params = message["params"] as? [String: Any] else { return .waiting }
        if method == "error",
           params["turnId"] as? String == turnID,
           params["willRetry"] as? Bool != true {
            return .failed(CodexAppServerError.server(
                Self.errorMessage(params["error"])
            ))
        }
        if method == "item/agentMessage/delta",
           params["turnId"] as? String == turnID,
           let delta = params["delta"] as? String,
           !delta.isEmpty,
           text.utf8.count + delta.utf8.count <= 200_000 {
            text += delta
            emitter.append(delta, to: onTextDelta)
            return .waiting
        }
        guard method == "turn/completed",
              let turn = params["turn"] as? [String: Any],
              turn["id"] as? String == turnID,
              let status = turn["status"] as? String else { return .waiting }
        if status == "interrupted" { return .failed(CancellationError()) }
        guard status == "completed" else {
            return .failed(CodexAppServerError.server(
                Self.errorMessage(turn["error"])
            ))
        }
        guard let answer = Self.normalized(text) else {
            return .failed(CodexAppServerError.invalidResponse)
        }
        return .completed(answer)
    }

    private func bufferTurnEvent(_ message: [String: Any]) {
        guard let method = message["method"] as? String,
              [
                  "item/agentMessage/delta",
                  "item/tool/call",
                  "error",
                  "turn/completed"
              ].contains(method),
              let params = message["params"] as? [String: Any],
              let turnID = params["turnId"] as? String
                ?? (params["turn"] as? [String: Any])?["id"] as? String else { return }
        var events = bufferedTurnEvents[turnID] ?? []
        if events.count < 128 { events.append(message) }
        bufferedTurnEvents[turnID] = events
    }

    private func interrupt(threadID: String, turnID: String) {
        requestID += 1
        try? send([
            "id": requestID,
            "method": "turn/interrupt",
            "params": ["threadId": threadID, "turnId": turnID]
        ])
    }

    private func launch() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: workingDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let skillsDirectory = runtimeSkillURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        try fileManager.createDirectory(
            at: skillsDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let runtimeSkillDirectory = runtimeSkillURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: runtimeSkillURL.path) {
            if (try? fileManager.destinationOfSymbolicLink(
                atPath: runtimeSkillDirectory.path
            )) != nil {
                try fileManager.removeItem(at: runtimeSkillDirectory)
            }
            try fileManager.createSymbolicLink(
                at: runtimeSkillDirectory,
                withDestinationURL: sourceSkillURL.deletingLastPathComponent()
            )
        }
        let process = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            self.streamContinuation = continuation
        }
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        process.currentDirectoryURL = workingDirectory
        process.environment = launchEnvironment()
        stderrBuffer.clear()
        let continuation = streamContinuation
        let stderrBuffer = self.stderrBuffer
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { continuation?.yield(data) }
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            stderrBuffer.append(handle.availableData)
        }
        process.terminationHandler = { process in
            let message = stderrBuffer.message()
                ?? "Agent CLI 提前退出（状态码 \(process.terminationStatus)）。"
            continuation?.finish(
                throwing: CodexAppServerError.disconnected(message)
            )
        }
        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = nil
            throw CodexAppServerError.startup(error.localizedDescription)
        }
        self.process = process
        self.input = input.fileHandleForWriting
        self.output = output.fileHandleForReading
        self.errors = errors.fileHandleForReading
        self.iterator = stream.makeAsyncIterator()
    }

    private var runtimeSkillURL: URL {
        workingDirectory
            .appendingPathComponent(".agents/skills", isDirectory: true)
            .appendingPathComponent(Self.skillName, isDirectory: true)
            .appendingPathComponent("SKILL.md")
    }

    private func nextMessage() async throws -> [String: Any] {
        while true {
            if let newline = outputBuffer.firstIndex(of: 0x0A) {
                let line = outputBuffer[..<newline]
                outputBuffer.removeSubrange(...newline)
                guard !line.isEmpty else { continue }
                guard let value = try? JSONSerialization.jsonObject(with: Data(line)),
                      let message = value as? [String: Any] else {
                    throw CodexAppServerError.invalidResponse
                }
                return message
            }
            guard var iterator,
                  let data = try await iterator.next() else {
                stop()
                throw CodexAppServerError.disconnected(
                    stderrBuffer.message()
                )
            }
            self.iterator = iterator
            outputBuffer.append(data)
        }
    }

    private func send(_ message: [String: Any]) throws {
        guard let input, process?.isRunning == true else {
            throw CodexAppServerError.disconnected(stderrBuffer.message())
        }
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(0x0A)
        try input.write(contentsOf: data)
    }

    private func stop() {
        output?.readabilityHandler = nil
        errors?.readabilityHandler = nil
        process?.terminationHandler = nil
        if process?.isRunning == true { process?.terminate() }
        streamContinuation?.finish()
        process = nil; input = nil; output = nil; errors = nil
        iterator = nil; streamContinuation = nil
        outputBuffer.removeAll(keepingCapacity: true)
        initialized = false; threadID = nil; threadConfiguration = nil
        skillPath = nil; skillPending = true
    }

    private func launchEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let executableDirectory = executableURL.deletingLastPathComponent()
            .standardizedFileURL.path
        var paths = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        paths.removeAll { $0 == executableDirectory }
        paths.insert(executableDirectory, at: 0)
        environment["PATH"] = paths.joined(separator: ":")
        return environment
    }

    private var arguments: [String] {
        switch runtime {
        case .traex:
            return [
                "app-server", "--listen", "stdio://",
                "--config", "mcp_servers={}"
            ]
        default:
            return [
                "app-server", "--stdio",
                "--disable", "apps",
                "--disable", "goals",
                "--disable", "multi_agent",
                "--disable", "shell_tool",
                "--disable", "plugins",
                "--config", "mcp_servers={}"
            ]
        }
    }

    private static func input(
        for request: CodexRequest,
        skillPath: String?
    ) -> [[String: Any]] {
        let prompt = skillPath == nil
            ? request.prompt
            : "$\(skillName)\n\(request.prompt)"
        var input: [[String: Any]] = [["type": "text", "text": prompt]]
        if let skillPath {
            input.append([
                "type": "skill",
                "name": skillName,
                "path": skillPath
            ])
        }
        if let imageURL = request.imageURL {
            input.append(["type": "localImage", "path": imageURL.path])
        }
        return input
    }

    private static func screenToolCall(
        from params: [String: Any]
    ) throws -> ScreenToolCall {
        guard params["namespace"] as? String == "jellypet",
              let tool = params["tool"] as? String,
              let arguments = params["arguments"] as? [String: Any]
        else { throw CodexAppServerError.invalidResponse }

        if tool == "observe" {
            guard arguments.isEmpty else {
                throw CodexAppServerError.invalidResponse
            }
            return .observe
        }
        if tool == "activate_and_verify" {
            let keys = Set(arguments.keys)
            guard Set(["targetLocator", "expectedLocator", "expectedState"])
                .isSubset(of: keys),
                  keys.isSubset(of: [
                      "targetLocator", "expectedLocator", "expectedState",
                      "expectedValueEquals"
                  ]) else {
                throw CodexAppServerError.invalidResponse
            }
            let data = try JSONSerialization.data(withJSONObject: arguments)
            return .activateAndVerify(try JSONDecoder().decode(
                ActivateAndVerifyRequest.self,
                from: data
            ))
        }
        let specification: (
            kind: String,
            required: Set<String>,
            allowed: Set<String>
        )
        switch tool {
        case "click":
            specification = ("click", ["target"], ["target"])
        case "double_click":
            specification = ("doubleClick", ["target"], ["target"])
        case "drag":
            specification = (
                "drag",
                ["fromX", "fromY", "toX", "toY", "durationMilliseconds"],
                ["fromX", "fromY", "toX", "toY", "durationMilliseconds"]
            )
        case "type_text":
            specification = (
                "typeText",
                ["target", "text", "replace"],
                ["target", "text", "replace"]
            )
        case "key_press":
            specification = (
                "keyPress",
                ["key", "modifiers"],
                ["key", "modifiers"]
            )
        case "navigate":
            specification = ("navigate", ["url"], ["url"])
        case "scroll":
            specification = (
                "scroll",
                ["deltaX", "deltaY"],
                ["target", "deltaX", "deltaY"]
            )
        case "wait":
            specification = ("wait", ["milliseconds"], ["milliseconds"])
        default:
            throw CodexAppServerError.invalidResponse
        }
        let keys = Set(arguments.keys)
        guard specification.required.isSubset(of: keys),
              keys.isSubset(of: specification.allowed) else {
            throw CodexAppServerError.invalidResponse
        }

        var object = arguments
        object["kind"] = specification.kind
        if let target = object["target"] as? [String: Any] {
            object["target"] = try normalizedTarget(target)
        } else if keys.contains("target") {
            throw CodexAppServerError.invalidResponse
        }
        if tool == "type_text" {
            object["replacesExistingText"] = object.removeValue(forKey: "replace")
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        return .perform(try JSONDecoder().decode(ScreenAction.self, from: data))
    }

    private static func normalizedTarget(
        _ target: [String: Any]
    ) throws -> [String: Any] {
        let keys = Set(target.keys)
        var value = target
        if keys == ["elementID"],
           let elementID = target["elementID"] as? String,
           !elementID.isEmpty {
            value["source"] = "element"
            return value
        }
        if keys == ["locator"], target["locator"] is [String: Any] {
            value["source"] = "locator"
            return value
        }
        if keys == ["x", "y"] {
            value["source"] = "visual"
            return value
        }
        throw CodexAppServerError.invalidResponse
    }

    private static func dynamicToolResponse(
        _ result: ScreenToolResult
    ) -> [String: Any] {
        var contentItems: [[String: Any]] = [[
            "type": "inputText",
            "text": result.message
        ]]
        if let screenshot = result.screenshotPNG {
            contentItems.append([
                "type": "inputImage",
                "imageUrl": "data:image/png;base64,\(screenshot.base64EncodedString())"
            ])
        }
        return [
            "contentItems": contentItems,
            "success": result.success
        ]
    }

    private static let dynamicTools: [[String: Any]] = [[
        "type": "namespace",
        "name": "jellypet",
        "description": "观察并操作 JellyPet 当前接管的浏览器或桌面界面。",
        "tools": [
            tool(
                "observe",
                "读取当前界面的最新语义结构，并在需要时附带截图。开始任务以及每次操作后都调用。",
                schema(properties: [:], required: [])
            ),
            tool(
                "click",
                "单击可逆的导航或选择目标；发送、提交、购买、删除必须改用 activate_and_verify。支持当前元素、稳定语义 locator 或视觉坐标。",
                schema(
                    properties: ["target": targetSchema],
                    required: ["target"]
                )
            ),
            tool(
                "double_click",
                "双击可逆目标；不得用于发送、提交、购买或删除。支持当前元素、稳定语义 locator 或视觉坐标。",
                schema(
                    properties: ["target": targetSchema],
                    required: ["target"]
                )
            ),
            tool(
                "drag",
                "在当前截图上从一个归一化坐标拖到另一个坐标。",
                schema(
                    properties: [
                        "fromX": coordinateSchema,
                        "fromY": coordinateSchema,
                        "toX": coordinateSchema,
                        "toY": coordinateSchema,
                        "durationMilliseconds": [
                            "type": "integer", "minimum": 200, "maximum": 2_000
                        ]
                    ],
                    required: [
                        "fromX", "fromY", "toX", "toY", "durationMilliseconds"
                    ]
                )
            ),
            tool(
                "type_text",
                "定位输入目标并给出完整最终文本；优先使用稳定 locator。JellyPet 会保留编辑器中未变化的起始代码，只对差异范围逐字输入，包含自然停顿和少量立即退格纠正；读不到现有内容时会拒绝清空。",
                schema(
                    properties: [
                        "target": targetSchema,
                        "text": ["type": "string", "minLength": 1, "maxLength": 100_000],
                        "replace": ["type": "boolean"]
                    ],
                    required: ["target", "text", "replace"]
                )
            ),
            tool(
                "activate_and_verify",
                "在最新观察中重新解析并激活目标一次，然后重新观察并验证预期元素存在、消失或具有指定值；校验失败也不会重复激活。",
                schema(
                    properties: [
                        "targetLocator": locatorSchema,
                        "expectedLocator": locatorSchema,
                        "expectedState": [
                            "type": "string",
                            "enum": SemanticConditionState.allCases.map(\.rawValue)
                        ],
                        "expectedValueEquals": [
                            "type": "string", "maxLength": 100_000
                        ]
                    ],
                    required: [
                        "targetLocator", "expectedLocator", "expectedState"
                    ]
                )
            ),
            tool(
                "key_press",
                "发送一个按键及可选的组合键。",
                schema(
                    properties: [
                        "key": [
                            "type": "string",
                            "enum": ScreenKey.allCases.map(\.rawValue)
                        ],
                        "modifiers": [
                            "type": "array",
                            "items": [
                                "type": "string",
                                "enum": KeyModifier.allCases.map(\.rawValue)
                            ],
                            "uniqueItems": true
                        ]
                    ],
                    required: ["key", "modifiers"]
                )
            ),
            tool(
                "navigate",
                "在当前浏览器中打开无内嵌凭据的 HTTP 或 HTTPS 网址。",
                schema(
                    properties: [
                        "url": ["type": "string", "minLength": 1, "maxLength": 2_048]
                    ],
                    required: ["url"]
                )
            ),
            tool(
                "scroll",
                "滚动当前页面、当前元素或稳定 locator 指向的容器。负的 deltaY 向下，正的 deltaY 向上；单次绝对值不超过 \(ScreenAction.maximumScrollDelta)。",
                schema(
                    properties: [
                        "target": targetSchema,
                        "deltaX": [
                            "type": "integer",
                            "minimum": -ScreenAction.maximumScrollDelta,
                            "maximum": ScreenAction.maximumScrollDelta
                        ],
                        "deltaY": [
                            "type": "integer",
                            "minimum": -ScreenAction.maximumScrollDelta,
                            "maximum": ScreenAction.maximumScrollDelta
                        ]
                    ],
                    required: ["deltaX", "deltaY"]
                )
            ),
            tool(
                "wait",
                "等待当前页面短暂加载、运行或判题，之后重新观察。",
                schema(
                    properties: [
                        "milliseconds": [
                            "type": "integer", "minimum": 200, "maximum": 3_000
                        ]
                    ],
                    required: ["milliseconds"]
                )
            )
        ]
    ]]

    private static let coordinateSchema: [String: Any] = [
        "type": "integer",
        "minimum": 0,
        "maximum": 1_000
    ]

    private static let targetSchema: [String: Any] = [
        "oneOf": [
            schema(
                properties: [
                    "elementID": ["type": "string", "minLength": 1]
                ],
                required: ["elementID"]
            ),
            schema(
                properties: ["x": coordinateSchema, "y": coordinateSchema],
                required: ["x", "y"]
            ),
            schema(
                properties: ["locator": locatorSchema],
                required: ["locator"]
            )
        ]
    ]

    private static let textMatcherSchema: [String: Any] = schema(
        properties: [
            "text": ["type": "string", "minLength": 1, "maxLength": 1_000],
            "mode": [
                "type": "string",
                "enum": SemanticTextMatcher.Mode.allCases.map(\.rawValue)
            ]
        ],
        required: ["text"]
    )

    private static let locatorSchema: [String: Any] = schema(
        properties: [
            "application": textMatcherSchema,
            "window": textMatcherSchema,
            "pageURL": textMatcherSchema,
            "role": semanticRoleSchema,
            "label": textMatcherSchema,
            "value": textMatcherSchema,
            "ancestorRole": semanticRoleSchema,
            "ancestorLabel": textMatcherSchema,
            "ancestorValue": textMatcherSchema,
            "ordinal": ["type": "integer", "minimum": 0, "maximum": 249],
            "requiresEnabled": ["type": "boolean"]
        ],
        required: []
    )

    private static let semanticRoleSchema: [String: Any] = [
        "type": "string",
        "enum": SemanticElementRole.allCases.map(\.rawValue)
    ]

    private static func tool(
        _ name: String,
        _ description: String,
        _ inputSchema: [String: Any]
    ) -> [String: Any] {
        [
            "type": "function",
            "name": name,
            "description": description,
            "inputSchema": inputSchema
        ]
    }

    private static func schema(
        properties: [String: Any],
        required: [String]
    ) -> [String: Any] {
        [
            "type": "object",
            "properties": properties,
            "required": required,
            "additionalProperties": false
        ]
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty || result.utf8.count > 200_000 ? nil : result
    }

    private static func errorMessage(_ value: Any?) -> String {
        if let object = value as? [String: Any] {
            let values = [
                object["message"] as? String,
                object["additionalDetails"] as? String
            ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !values.isEmpty {
                return String(values.joined(separator: "；").prefix(2_000))
            }
        }
        guard let value,
              JSONSerialization.isValidJSONObject(["error": value]),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let text = String(data: data, encoding: .utf8) else {
            return "app-server 返回了未知错误。"
        }
        return String(text.prefix(2_000))
    }

    private static func integerID(_ value: Any?) -> Int? {
        (value as? Int) ?? (value as? NSNumber)?.intValue
    }

}
