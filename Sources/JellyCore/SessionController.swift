import Foundation

@MainActor
public final class SessionController {
    private struct AnswerSession {
        let id: UUID
        let displayID: UInt32
        let question: String?
        let preferences: AssistantPreferences
        var phase: SessionPhase
        var message: String?
    }

    private struct TakeoverSession {
        let id: UUID
        let request: TakeoverRequest
        var phase: SessionPhase
        var message: String?
        var observation: ScreenObservation?
        var events: [ActivityEvent] = []
        var sequence = 0
    }

    private struct PresentedResult {
        enum Source { case answer(AssistantPreferences), takeover(TakeoverRequest) }
        let source: Source
        let phase: SessionPhase
        let message: String
        let failure: PetFailure?
        let events: [ActivityEvent]
    }

    private enum AppSession {
        case idle
        case answering(AnswerSession)
        case takeover(TakeoverSession)
        case presenting(PresentedResult)
    }

    public private(set) var snapshot = SessionSnapshot(
        mode: .idle,
        phase: .idle
    )
    public var onSnapshot: ((SessionSnapshot) -> Void)?
    public var canFollowUp: Bool { answerPreferences != nil }

    private let codex: CodexServing
    private let screen: ScreenDriving
    private var state: AppSession = .idle

    public init(codex: CodexServing, screen: ScreenDriving) {
        self.codex = codex
        self.screen = screen
    }

    public func start(
        _ request: TakeoverRequest,
        initialMessage: String? = nil
    ) async {
        cancelWork()
        let id = UUID()
        state = .takeover(TakeoverSession(
            id: id,
            request: request,
            phase: .deciding,
            message: initialMessage ?? "正在初始化 Codex 和屏幕工具"
        ))
        appendEvent(.observing, initialMessage)
        publish()
        await codex.resetSession()
        guard isCurrent(id) else { return }

        let task = Self.bounded(request.task)
        let custom = request.assistantPreferences.customInstructions
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = [
            "用户任务：\(task ?? "处理当前界面上的任务")",
            custom.isEmpty ? nil : "用户补充要求：\(custom)"
        ].compactMap { $0 }.joined(separator: "\n")

        do {
            var answer = try await modelResponse(
                prompt: prompt,
                preferences: request.assistantPreferences,
                id: id,
                tools: true
            )
            try ensureCurrent(id)
            if takeoverNeedsFinalObservation(id) {
                updateTakeover(id) {
                    $0.phase = .verifying
                    $0.message = "最后一步后正在确认真实界面"
                }
                answer = try await modelResponse(
                    prompt: "最后一次改变界面的动作之后还没有成功 observe。请现在重新观察实际界面；如果任务未完成就继续修复，只有确认真实结果后再结束。",
                    preferences: request.assistantPreferences,
                    id: id,
                    tools: true
                )
                try ensureCurrent(id)
            }
            guard !takeoverNeedsFinalObservation(id) else {
                throw PetFailure.codexFailed("最后动作后没有重新观察，结果尚未确认。")
            }
            presentTakeover(id: id, message: answer)
        } catch is CancellationError {
            guard isCurrent(id) else { return }
            presentTakeover(id: id, message: "接管已停止", phase: .cancelled)
        } catch {
            guard isCurrent(id) else { return }
            let failure = error as? PetFailure
                ?? .codexFailed(error.localizedDescription)
            presentTakeover(
                id: id,
                message: failure.localizedDescription,
                phase: .error,
                failure: failure
            )
        }
    }

    public func answer(
        displayID: UInt32,
        preferences: AssistantPreferences,
        question: String? = nil
    ) async {
        cancelWork()
        let id = UUID()
        let question = Self.bounded(question)
        state = .answering(AnswerSession(
            id: id,
            displayID: displayID,
            question: question,
            preferences: preferences,
            phase: .capturing,
            message: "正在截取所选整块显示器"
        ))
        publish()
        await codex.prepareForNextTurn()
        guard isCurrent(id) else { return }
        do {
            let observation = try await screen.observe(displayID: displayID)
            try ensureCurrent(id)
            updateAnswer(id, phase: .deciding, message: "正在等待 Codex 回答")
            await completeAnswer(
                id: id,
                preferences: preferences,
                prompt: ResponsePrompts.screenAnalysis(
                    question: question,
                    customInstructions: preferences.customInstructions
                ),
                imagePNG: observation.screenshotPNG
            )
        } catch {
            finishAnswer(error, id: id, preferences: preferences)
        }
    }

    public func followUp(_ question: String) async {
        guard let preferences = answerPreferences,
              let question = Self.bounded(question) else { return }
        cancelWork()
        let id = UUID()
        state = .answering(AnswerSession(
            id: id,
            displayID: 0,
            question: question,
            preferences: preferences,
            phase: .deciding,
            message: "正在继续当前对话"
        ))
        publish()
        await completeAnswer(
            id: id,
            preferences: preferences,
            prompt: ResponsePrompts.followUp(
                question: question,
                customInstructions: preferences.customInstructions
            )
        )
    }

    private func completeAnswer(
        id: UUID,
        preferences: AssistantPreferences,
        prompt: String,
        imagePNG: Data? = nil
    ) async {
        do {
            let answer = try await modelResponse(
                prompt: prompt,
                preferences: preferences,
                id: id,
                imagePNG: imagePNG
            )
            try ensureCurrent(id)
            presentAnswer(preferences: preferences, message: answer)
        } catch {
            finishAnswer(error, id: id, preferences: preferences)
        }
    }

    private func finishAnswer(
        _ error: Error,
        id: UUID,
        preferences: AssistantPreferences
    ) {
        guard isCurrent(id) else { return }
        if error is CancellationError {
            state = .idle
            publish()
            return
        }
        let failure = error as? PetFailure
            ?? .codexFailed(error.localizedDescription)
        presentAnswer(
            preferences: preferences,
            message: failure.localizedDescription,
            phase: .error,
            failure: failure
        )
    }

    public func closeAnswer() {
        cancelWork()
        state = .idle
        publish()
    }

    public func cancel(message: String = "已由你停止") {
        let request = takeoverRequest
        let events = takeoverEvents
        cancelWork()
        if let request {
            state = .presenting(PresentedResult(
                source: .takeover(request),
                phase: .cancelled,
                message: message,
                failure: nil,
                events: events
            ))
        } else {
            state = .idle
        }
        publish()
    }

    @discardableResult
    public func addInstruction(_ value: String) async -> Bool {
        guard case let .takeover(session) = state,
              let instruction = Self.bounded(value) else { return false }
        do {
            try await codex.steer("用户补充要求：\(instruction)")
            appendEvent(
                .thinking,
                "已把补充要求发送给 Codex",
                kind: .userInstruction,
                details: instruction,
                id: session.id
            )
            updateTakeover(session.id) { $0.message = "已收到补充要求" }
        } catch {
            appendEvent(
                .failure,
                "补充要求发送失败",
                kind: .outcome,
                details: error.localizedDescription,
                id: session.id
            )
        }
        return true
    }

    private func handle(_ call: ScreenToolCall, id: UUID) async -> ScreenToolResult {
        guard isCurrent(id) else {
            return .init(success: false, message: "JellyPet 会话已经结束。")
        }
        let sequence = nextSequence(id)
        switch call {
        case .observe:
            return await observe(id: id, sequence: sequence)
        case let .perform(action):
            return await perform(action, id: id, sequence: sequence)
        case let .activateAndVerify(request):
            return await activateAndVerify(request, id: id, sequence: sequence)
        }
    }

    private func observe(id: UUID, sequence: Int) async -> ScreenToolResult {
        guard let request = takeoverRequest(id) else {
            return .init(success: false, message: "接管会话已经结束。")
        }
        updateTakeover(id) {
            $0.phase = .capturing
            $0.message = "Codex 正在观察当前界面"
        }
        do {
            let observation = try await screen.observe(displayID: request.displayID)
            try ensureCurrent(id)
            updateTakeover(id) {
                $0.observation = observation
                $0.phase = .deciding
                $0.message = "观察结果已返回 Codex"
            }
            let details = render(observation.semantics)
            appendEvent(
                .observing,
                "已刷新当前界面",
                kind: .observation,
                details: details,
                sequence: sequence,
                id: id
            )
            return .init(
                success: true,
                message: "当前界面：\n\(details)\n截图是本次 observe 的指定显示器全屏图。元素 ID 仅在本次观察有效。",
                screenshotPNG: observation.screenshotPNG
            )
        } catch is CancellationError {
            return .init(success: false, message: "观察已取消。")
        } catch {
            let message = failureMessage(error)
            appendEvent(
                .failure,
                "观察失败",
                kind: .outcome,
                details: message,
                sequence: sequence,
                id: id
            )
            updateTakeover(id) {
                $0.observation = nil
                $0.phase = .deciding
                $0.message = "观察失败，等待 Codex 重试"
            }
            return .init(success: false, message: message)
        }
    }

    private func perform(
        _ action: ScreenAction,
        id: UUID,
        sequence: Int
    ) async -> ScreenToolResult {
        guard let request = takeoverRequest(id),
              let observation = takeoverObservation(id) else {
            return .init(
                success: false,
                message: "请先调用 observe 获取当前界面；旧观察不能用于新动作。"
            )
        }
        guard !action.needsVisualObservation
                || observation.screenshotPNG != nil else {
            return .init(success: false, message: "本次观察没有截图，不能使用视觉坐标。")
        }
        do {
            try action.validate()
            let executable = try action.resolvingSemanticTargets(
                in: observation.semantics
            )
            updateTakeover(id) {
                $0.phase = .executing
                $0.message = "正在执行 \(action.label)"
            }
            appendEvent(
                .acting,
                "调用 \(action.label)",
                kind: .action,
                details: actionDescription(action),
                sequence: sequence,
                id: id
            )
            try await screen.execute(
                executable,
                observation: observation,
                displayID: request.displayID
            )
            try ensureCurrent(id)
            updateTakeover(id) {
                $0.observation = nil
                $0.phase = .verifying
                $0.message = "动作完成，等待重新观察"
            }
            return .init(
                success: true,
                message: "\(action.label) 已执行。请调用 observe 读取真实结果。"
            )
        } catch is CancellationError {
            return .init(success: false, message: "操作已取消。")
        } catch {
            let message = failureMessage(error)
            updateTakeover(id) {
                $0.observation = nil
                $0.phase = .verifying
                $0.message = "动作结果不确定，等待重新观察"
            }
            appendEvent(
                .failure,
                "\(action.label) 执行失败",
                kind: .outcome,
                details: message,
                sequence: sequence,
                id: id
            )
            return .init(
                success: false,
                message: "\(message) 请重新 observe 后继续。"
            )
        }
    }

    private func activateAndVerify(
        _ request: ActivateAndVerifyRequest,
        id: UUID,
        sequence: Int
    ) async -> ScreenToolResult {
        let before = await observe(id: id, sequence: sequence)
        guard before.success, let observation = takeoverObservation(id) else {
            return .init(success: false, message: "无法获取激活前界面，未执行点击。")
        }
        guard let semantic = observation.semantics,
              request.targetLocator.resolve(in: semantic).status == .matched else {
            return .init(success: false, message: "当前界面无法唯一定位激活目标。")
        }
        let action = await perform(
            .click(.locator(request.targetLocator)),
            id: id,
            sequence: sequence
        )
        guard action.success else { return action }
        let after = await observe(id: id, sequence: sequence)
        guard after.success, let current = takeoverObservation(id) else {
            return .init(success: false, message: "已激活一次，但无法观察结果。")
        }
        guard postconditionSatisfied(request, in: current) else {
            return .init(success: false, message: "已激活一次，但后置条件尚未满足。")
        }
        return .init(success: true, message: "目标已激活一次，并已验证后置条件。")
    }

    private func postconditionSatisfied(
        _ request: ActivateAndVerifyRequest,
        in observation: ScreenObservation
    ) -> Bool {
        guard let semantic = observation.semantics else { return false }
        let resolution = request.expectedLocator.resolve(in: semantic)
        if request.expectedState == .absent {
            return resolution.status == .notFound
        }
        guard resolution.status == .matched,
              let element = resolution.selected else { return false }
        return request.expectedValueEquals.map { element.value == $0 } ?? true
    }

    private func modelResponse(
        prompt: String,
        preferences: AssistantPreferences,
        id: UUID,
        imagePNG: Data? = nil,
        tools: Bool = false
    ) async throws -> String {
        streamedText = ""
        defer { streamedText = "" }
        let handler: ScreenToolHandler?
        if tools {
            handler = { [weak self] call in
                guard let self else {
                    return .init(
                        success: false,
                        message: "JellyPet 会话已经结束。"
                    )
                }
                return await self.handle(call, id: id)
            }
        } else {
            handler = nil
        }
        return try await codex.respond(
            to: CodexRequest(
                imagePNG: imagePNG,
                prompt: prompt,
                model: preferences.model,
                reasoningEffort: preferences.reasoningEffort,
                conversationHistoryTurns: preferences.conversationHistoryTurns
            ),
            onTextDelta: { [weak self] delta in
                Task { @MainActor in
                    self?.receive(delta, id: id)
                }
            },
            screenToolHandler: handler
        )
    }

    private var streamedText = ""

    private func receive(_ delta: String, id: UUID) {
        guard isCurrent(id) else { return }
        streamedText = String((streamedText + delta).suffix(2_000))
        let message = "Codex 正在回复：\(Self.compact(String(streamedText.suffix(160))))"
        switch state {
        case var .answering(session) where session.id == id:
            session.message = message
            state = .answering(session)
        case var .takeover(session) where session.id == id:
            session.message = message
            state = .takeover(session)
        default: return
        }
        publish()
    }

    private func updateAnswer(
        _ id: UUID,
        phase: SessionPhase,
        message: String
    ) {
        guard case var .answering(session) = state, session.id == id else { return }
        session.phase = phase
        session.message = message
        state = .answering(session)
        publish()
    }

    private func updateTakeover(
        _ id: UUID,
        _ change: (inout TakeoverSession) -> Void
    ) {
        guard case var .takeover(session) = state, session.id == id else { return }
        change(&session)
        state = .takeover(session)
        publish()
    }

    private func appendEvent(
        _ activity: PetActivity,
        _ message: String?,
        kind: ActivityEventKind = .status,
        details: String? = nil,
        sequence: Int? = nil,
        id: UUID? = nil
    ) {
        guard let message, !Self.compact(message).isEmpty else { return }
        let targetID = id ?? takeoverRequestID
        guard let targetID,
              case var .takeover(session) = state,
              session.id == targetID else { return }
        let event = ActivityEvent(
            activity: activity,
            message: Self.compact(message),
            kind: kind,
            sequence: sequence,
            details: details
        )
        if session.events.last != event { session.events.append(event) }
        if session.events.count > AppMetadata.takeoverEventLimit {
            session.events.removeFirst(
                session.events.count - AppMetadata.takeoverEventLimit
            )
        }
        state = .takeover(session)
        publish()
    }

    private func presentAnswer(
        preferences: AssistantPreferences,
        message: String,
        phase: SessionPhase = .finished,
        failure: PetFailure? = nil
    ) {
        state = .presenting(PresentedResult(
            source: .answer(preferences),
            phase: phase,
            message: message,
            failure: failure,
            events: []
        ))
        publish()
    }

    private func presentTakeover(
        id: UUID,
        message: String,
        phase: SessionPhase = .finished,
        failure: PetFailure? = nil
    ) {
        guard case let .takeover(session) = state, session.id == id else { return }
        state = .presenting(PresentedResult(
            source: .takeover(session.request),
            phase: phase,
            message: message,
            failure: failure,
            events: session.events
        ))
        publish()
    }

    private func publish() {
        snapshot = switch state {
        case .idle:
            SessionSnapshot(mode: .idle, phase: .idle)
        case let .answering(session):
            SessionSnapshot(
                mode: .answering,
                phase: session.phase,
                message: session.message
            )
        case let .takeover(session):
            SessionSnapshot(
                mode: .takingOver,
                phase: session.phase,
                message: session.message,
                events: session.events,
                request: session.request
            )
        case let .presenting(result):
            switch result.source {
            case .answer:
                SessionSnapshot(
                    mode: .presentingAnswer,
                    phase: result.phase,
                    message: result.message,
                    failure: result.failure
                )
            case let .takeover(request):
                SessionSnapshot(
                    mode: .presentingTakeover,
                    phase: result.phase,
                    message: result.message,
                    failure: result.failure,
                    events: result.events,
                    request: request
                )
            }
        }
        onSnapshot?(snapshot)
    }

    private var answerPreferences: AssistantPreferences? {
        switch state {
        case let .answering(session): session.preferences
        case let .presenting(result):
            if case let .answer(preferences) = result.source { preferences } else { nil }
        default: nil
        }
    }

    private var takeoverRequestID: UUID? {
        if case let .takeover(session) = state { session.id } else { nil }
    }

    private var takeoverRequest: TakeoverRequest? {
        if case let .takeover(session) = state { session.request } else { nil }
    }

    private var takeoverEvents: [ActivityEvent] {
        if case let .takeover(session) = state { session.events } else { [] }
    }

    private func takeoverRequest(_ id: UUID) -> TakeoverRequest? {
        guard case let .takeover(session) = state, session.id == id else { return nil }
        return session.request
    }

    private func takeoverObservation(_ id: UUID) -> ScreenObservation? {
        guard case let .takeover(session) = state, session.id == id else { return nil }
        return session.observation
    }

    private func takeoverNeedsFinalObservation(_ id: UUID) -> Bool {
        guard case let .takeover(session) = state, session.id == id else { return true }
        return session.observation == nil
    }

    private func nextSequence(_ id: UUID) -> Int {
        guard case var .takeover(session) = state, session.id == id else { return 0 }
        session.sequence += 1
        state = .takeover(session)
        return session.sequence
    }

    private func isCurrent(_ id: UUID) -> Bool {
        switch state {
        case let .answering(session): session.id == id
        case let .takeover(session): session.id == id
        default: false
        }
    }

    private func ensureCurrent(_ id: UUID) throws {
        try Task.checkCancellation()
        guard isCurrent(id) else { throw CancellationError() }
    }

    private func cancelWork() {
        codex.cancel()
        screen.cancel()
        streamedText = ""
    }

    private func render(_ snapshot: ScreenSemantics?) -> String {
        guard let snapshot else { return "没有可读取的 Accessibility 结构。" }
        let header = "应用：\(snapshot.applicationName) · 窗口：\(snapshot.windowTitle) · 网址：\(snapshot.pageURL ?? "未知")"
        let valueLimit = max(80, min(1_000, 20_000 / max(1, snapshot.elements.count)))
        let elements = snapshot.elements.map { element in
            let value = bounded(element.value ?? "", limit: valueLimit)
            return "\(element.id) 父级=\(element.parentID ?? "无") 角色=\(element.role.rawValue) 名称=\(String(reflecting: element.label)) 值=\(String(reflecting: value)) 区域=\(element.frame.x),\(element.frame.y),\(element.frame.width),\(element.frame.height)"
        }
        return ([header, "可读正文：\(snapshot.readableText ?? "无")"] + elements)
            .joined(separator: "\n")
    }

    private func actionDescription(_ action: ScreenAction) -> String {
        switch action {
        case .click: "单击当前目标"
        case .doubleClick: "双击当前目标"
        case let .drag(fromX, fromY, toX, toY, duration):
            "从 (\(fromX), \(fromY)) 拖到 (\(toX), \(toY))，持续 \(duration) 毫秒"
        case let .typeText(_, text): "渐入完整目标文本，共 \(text.count) 个字符"
        case let .keyPress(key, modifiers):
            "按键 \((modifiers.map(\.rawValue) + [key.rawValue]).joined(separator: "+"))"
        case let .navigate(url): "打开 \(url)"
        case let .scroll(_, x, y): "滚动 x=\(x), y=\(y)"
        case let .wait(milliseconds): "等待 \(milliseconds) 毫秒"
        }
    }

    private func bounded(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        let head = max(1, limit * 2 / 3)
        return "\(value.prefix(head))\n…\n\(value.suffix(limit - head))"
    }

    private func failureMessage(_ error: Error) -> String {
        (error as? PetFailure)?.localizedDescription ?? error.localizedDescription
    }

    private static func bounded(_ value: String?) -> String? {
        let value = String((value ?? "").trimmingCharacters(
            in: .whitespacesAndNewlines
        ).prefix(4_000))
        return value.isEmpty ? nil : value
    }

    private static func compact(_ value: String) -> String {
        String(value.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
    }
}
