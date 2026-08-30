import Foundation

@MainActor
public final class SessionController {
    public private(set) var snapshot = SessionSnapshot(mode: .idle, activity: .idle)
    public var onSnapshot: ((SessionSnapshot) -> Void)?
    public var canFollowUp: Bool { answerPreferences != nil }
    private let codex: CodexServing
    private let screen: ScreenDriving
    private var currentID: UUID?
    private var answerPreferences: AssistantPreferences?
    private var observation: ScreenObservation?
    private var sequence = 0
    public init(codex: CodexServing, screen: ScreenDriving) {
        self.codex = codex
        self.screen = screen
    }
    public func start(_ request: TakeoverRequest, initialMessage: String? = nil) async {
        let id = begin(
            mode: .takingOver, activity: .thinking,
            message: initialMessage ?? "正在初始化 Codex 和屏幕工具",
            request: request
        )
        sequence = 0
        appendEvent(.observing, initialMessage, id: id)
        await codex.prepare(resetHistory: true)
        guard isCurrent(id) else { return }

        let task = AppMetadata.boundedUserText(request.task) ?? "处理当前界面上的任务"
        let custom = request.assistantPreferences.customInstructions
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = custom.isEmpty
            ? "用户任务：\(task)"
            : "用户任务：\(task)\n用户补充要求：\(custom)"
        do {
            var answer = try await respond(
                prompt, preferences: request.assistantPreferences, id: id, tools: true
            )
            try ensureCurrent(id)
            if observation == nil {
                update(.verifying, "最后一步后正在确认真实界面", id: id)
                answer = try await respond(
                    "最后一次改变界面的动作之后还没有成功 observe。请重新观察实际界面；未完成就继续修复，只有确认真实结果后再结束。",
                    preferences: request.assistantPreferences,
                    id: id,
                    tools: true
                )
                try ensureCurrent(id)
            }
            guard observation != nil else {
                throw PetFailure.codexFailed("最后动作后没有重新观察，结果尚未确认。")
            }
            presentTakeover(answer, id: id)
        } catch is CancellationError {
            if isCurrent(id) { presentTakeover("接管已停止", id: id, activity: .idle) }
        } catch {
            guard isCurrent(id) else { return }
            let failure = error as? PetFailure ?? .codexFailed(error.localizedDescription)
            presentTakeover(failure.localizedDescription, id: id, activity: .failure)
        }
    }
    public func answer(
        displayID: UInt32,
        preferences: AssistantPreferences,
        question: String? = nil
    ) async {
        let id = begin(
            mode: .answering, activity: .observing,
            message: "正在截取所选整块显示器", preferences: preferences
        )
        await codex.prepare(resetHistory: false)
        guard isCurrent(id) else { return }
        do {
            let image = try await screen.observe(displayID: displayID).screenshotPNG
            try ensureCurrent(id)
            update(.thinking, "正在等待 Codex 回答", id: id)
            try await completeAnswer(
                ResponsePrompts.screenAnalysis(
                    question: AppMetadata.boundedUserText(question),
                    customInstructions: preferences.customInstructions
                ),
                imagePNG: image,
                preferences: preferences,
                id: id
            )
        } catch { finishAnswer(error, preferences: preferences, id: id) }
    }
    public func followUp(_ question: String) async {
        guard let preferences = answerPreferences,
              let question = AppMetadata.boundedUserText(question) else { return }
        let id = begin(
            mode: .answering, activity: .thinking,
            message: "正在继续当前对话", preferences: preferences
        )
        do {
            try await completeAnswer(
                ResponsePrompts.followUp(
                    question: question,
                    customInstructions: preferences.customInstructions
                ),
                preferences: preferences,
                id: id
            )
        } catch { finishAnswer(error, preferences: preferences, id: id) }
    }
    public func closeAnswer() {
        cancelWork()
        currentID = nil
        answerPreferences = nil
        observation = nil
        publish(.init(mode: .idle, activity: .idle))
    }
    public func cancel(message: String = "已由你停止") {
        let request = snapshot.request
        let events = snapshot.events
        cancelWork()
        currentID = nil
        answerPreferences = nil
        observation = nil
        publish(request.map {
            SessionSnapshot(
                mode: .takingOver,
                activity: .idle,
                message: message,
                events: events,
                request: $0
            )
        } ?? .init(mode: .idle, activity: .idle))
    }
    @discardableResult
    public func addInstruction(_ value: String) async -> Bool {
        guard snapshot.isTakingOver,
              let id = currentID,
              let instruction = AppMetadata.boundedUserText(value) else { return false }
        do {
            try await codex.steer("用户补充要求：\(instruction)")
            appendEvent(
                .thinking,
                "已把补充要求发送给 Codex",
                details: instruction,
                id: id
            )
            update(snapshot.activity, "已收到补充要求", id: id)
        } catch {
            appendEvent(
                .failure,
                "补充要求发送失败",
                details: error.localizedDescription,
                id: id
            )
        }
        return true
    }
    private func completeAnswer(
        _ prompt: String,
        imagePNG: Data? = nil,
        preferences: AssistantPreferences,
        id: UUID
    ) async throws {
        let answer = try await respond(
            prompt, preferences: preferences, id: id, imagePNG: imagePNG
        )
        try ensureCurrent(id)
        currentID = nil
        observation = nil
        publish(.init(mode: .answering, activity: .success, message: answer))
    }
    private func finishAnswer(
        _ error: Error,
        preferences: AssistantPreferences,
        id: UUID
    ) {
        guard isCurrent(id) else { return }
        currentID = nil
        observation = nil
        if error is CancellationError {
            answerPreferences = nil
            publish(.init(mode: .idle, activity: .idle))
            return
        }
        answerPreferences = preferences
        let failure = error as? PetFailure ?? .codexFailed(error.localizedDescription)
        publish(.init(
            mode: .answering,
            activity: .failure,
            message: failure.localizedDescription
        ))
    }
    private func handle(_ call: ScreenToolCall, id: UUID) async -> ScreenToolResult {
        guard isCurrent(id) else { return .init(success: false, message: "会话已经结束。") }
        sequence += 1
        switch call {
        case .observe: return await observe(id: id, sequence: sequence)
        case let .perform(action): return await perform(action, id: id, sequence: sequence)
        }
    }
    private func observe(id: UUID, sequence: Int) async -> ScreenToolResult {
        guard let request = request(id) else {
            return .init(success: false, message: "接管会话已经结束。")
        }
        update(.observing, "Codex 正在观察当前界面", id: id)
        do {
            let current = try await screen.observe(displayID: request.displayID)
            try ensureCurrent(id)
            observation = current
            update(.thinking, "观察结果已返回 Codex", id: id)
            let details = render(current.semantics)
            appendEvent(
                .observing,
                "已刷新当前界面",
                details: details,
                sequence: sequence,
                id: id
            )
            return .init(
                success: true,
                message: "当前界面：\n\(details)\n截图是本次 observe 的指定显示器全屏图。元素 ID 仅在本次观察有效。",
                screenshotPNG: current.screenshotPNG
            )
        } catch is CancellationError {
            return .init(success: false, message: "观察已取消。")
        } catch {
            observation = nil
            let message = failureMessage(error)
            update(.thinking, "观察失败，等待 Codex 重试", id: id)
            appendEvent(
                .failure,
                "观察失败",
                details: message,
                sequence: sequence,
                id: id
            )
            return .init(success: false, message: message)
        }
    }
    private func perform(
        _ action: ScreenAction,
        id: UUID,
        sequence: Int
    ) async -> ScreenToolResult {
        guard let request = request(id), let current = observation else {
            return .init(success: false, message: "请先调用 observe；旧观察不能用于新动作。")
        }
        do {
            try action.validate()
            update(.locating, "正在定位动作目标", id: id)
            let executable = try action.resolvingSemanticTargets(in: current.semantics)
            update(.acting, "正在执行 \(action.label)", id: id)
            appendEvent(
                .acting,
                "调用 \(action.label)",
                details: action.label,
                sequence: sequence,
                id: id
            )
            try await screen.execute(
                executable,
                observation: current,
                displayID: request.displayID
            )
            try ensureCurrent(id)
            observation = nil
            update(.verifying, "动作完成，等待重新观察", id: id)
            return .init(success: true, message: "\(action.label) 已执行。请调用 observe 读取真实结果。")
        } catch is CancellationError {
            return .init(success: false, message: "操作已取消。")
        } catch {
            observation = nil
            let message = failureMessage(error)
            update(.verifying, "动作结果不确定，等待重新观察", id: id)
            appendEvent(
                .failure,
                "\(action.label) 执行失败",
                details: message,
                sequence: sequence,
                id: id
            )
            return .init(success: false, message: "\(message) 请重新 observe 后继续。")
        }
    }
    private func respond(
        _ prompt: String,
        preferences: AssistantPreferences,
        id: UUID,
        imagePNG: Data? = nil,
        tools: Bool = false
    ) async throws -> String {
        let handler: ScreenToolHandler?
        if tools {
            handler = { [weak self] call in
                guard let self else {
                    return .init(success: false, message: "会话已经结束。")
                }
                return await self.handle(call, id: id)
            }
        } else {
            handler = nil
        }
        return try await codex.respond(
            to: .init(
                imagePNG: imagePNG,
                prompt: prompt,
                preferences: preferences
            ),
            screenToolHandler: handler
        )
    }
    private func update(_ activity: PetActivity, _ message: String, id: UUID) {
        guard isCurrent(id) else { return }
        snapshot.activity = activity
        snapshot.message = message
        publish()
    }
    private func appendEvent(
        _ activity: PetActivity,
        _ rawMessage: String?,
        details: String? = nil,
        sequence: Int? = nil,
        id: UUID
    ) {
        guard isCurrent(id), let rawMessage else { return }
        let message = Self.compact(rawMessage)
        guard !message.isEmpty else { return }
        let event = ActivityEvent(
            activity: activity,
            message: message,
            sequence: sequence,
            details: details
        )
        if snapshot.events.last != event { snapshot.events.append(event) }
        snapshot.events = Array(snapshot.events.suffix(AppMetadata.takeoverEventLimit))
        publish()
    }
    private func presentTakeover(
        _ message: String,
        id: UUID,
        activity: PetActivity = .success
    ) {
        guard isCurrent(id), let request = snapshot.request else { return }
        currentID = nil
        observation = nil
        snapshot.mode = .takingOver
        snapshot.activity = activity
        snapshot.message = message
        snapshot.request = request
        publish()
    }
    private func request(_ id: UUID) -> TakeoverRequest? {
        isCurrent(id) && snapshot.isTakingOver ? snapshot.request : nil
    }
    private func isCurrent(_ id: UUID) -> Bool {
        currentID == id && snapshot.isActive
    }
    private func ensureCurrent(_ id: UUID) throws {
        try Task.checkCancellation()
        guard isCurrent(id) else { throw CancellationError() }
    }
    private func cancelWork() {
        codex.cancel()
        screen.cancel()
    }
    private func begin(
        mode: SessionMode,
        activity: PetActivity,
        message: String,
        preferences: AssistantPreferences? = nil,
        request: TakeoverRequest? = nil
    ) -> UUID {
        cancelWork()
        let id = UUID()
        currentID = id
        answerPreferences = preferences
        observation = nil
        publish(.init(mode: mode, activity: activity, message: message, request: request))
        return id
    }
    private func publish(_ value: SessionSnapshot? = nil) {
        if let value { snapshot = value }
        onSnapshot?(snapshot)
    }
    private func render(_ semantics: ScreenSemantics?) -> String {
        guard let semantics else { return "没有可读取的 Accessibility 结构。" }
        let header = "应用：\(semantics.applicationName) · 窗口：\(semantics.windowTitle) · 网址：\(semantics.pageURL ?? "未知")"
        let limit = max(80, min(1_000, 20_000 / max(1, semantics.elements.count)))
        let elements = semantics.elements.map { element in
            let value = bounded(element.value ?? "", limit: limit)
            return "\(element.id) 父级=\(element.parentID ?? "无") 角色=\(element.role.rawValue) 名称=\(String(reflecting: element.label)) 值=\(String(reflecting: value)) 区域=\(element.frame.x),\(element.frame.y),\(element.frame.width),\(element.frame.height)"
        }
        return ([header] + elements).joined(separator: "\n")
    }
    private func bounded(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        let head = max(1, limit * 2 / 3)
        return "\(value.prefix(head))\n…\n\(value.suffix(limit - head))"
    }
    private func failureMessage(_ error: Error) -> String {
        (error as? PetFailure)?.localizedDescription ?? error.localizedDescription
    }
    private static func compact(_ value: String) -> String {
        String(value.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
    }
}
