import Foundation

@MainActor
public final class TakeoverCoordinator {
    public private(set) var snapshot = TakeoverSnapshot(
        phase: .idle,
        message: nil,
        failure: nil,
        events: [],
        metrics: nil
    )
    public var onSnapshot: ((TakeoverSnapshot) -> Void)?
    public var canFollowUp: Bool { answerPreferences != nil }

    private struct Session {
        let request: TakeoverRequest
        var currentSnapshot: SemanticSnapshot?
        var hasScreenshot = false
        var sequence = 0
        var progress = TakeoverProgressMonitor()
        var terminalStopReason: String?
        var uncertainActivationSignatures: [String: UInt64] = [:]
        let startedAt = Date()
    }

    private let capture: CaptureService
    private let responder: AIResponder
    private let cleaner: CaptureCleaning
    private let executor: ScreenActionExecuting
    private let semanticProvider: SemanticContextProviding?
    private var generation = UUID()
    private var session: Session?
    private var events: [TakeoverEvent] = []
    private var answerPreferences: AssistantPreferences?
    private var streamID: UUID?
    private var streamedResponse = ""

    public init(
        capture: CaptureService,
        responder: AIResponder,
        cleaner: CaptureCleaning,
        executor: ScreenActionExecuting,
        semanticProvider: SemanticContextProviding? = nil
    ) {
        self.capture = capture
        self.responder = responder
        self.cleaner = cleaner
        self.executor = executor
        self.semanticProvider = semanticProvider
    }

    public func start(
        _ request: TakeoverRequest,
        initialMessage: String? = nil
    ) async {
        invalidate(cancelsResponder: false)
        let token = generation
        events = []
        clearAnswerContext()
        session = Session(request: request)
        if let initialMessage {
            appendEvent(TakeoverEvent(
                activity: .observing,
                message: compact(initialMessage)
            ))
        }
        publish(.deciding, "正在初始化本地 Agent Runtime 和屏幕工具")
        await responder.resetSession()
        guard token == generation, session != nil else { return }

        do {
            let task = request.task?.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let custom = request.assistantPreferences.customInstructions
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let prompt = [
                "用户任务：\(task?.isEmpty == false ? task! : "处理当前界面上的任务")",
                custom.isEmpty ? nil : "用户补充要求：\(custom)"
            ].compactMap { $0 }.joined(separator: "\n")
            let answer = try await modelResponse(
                to: CodexRequest(
                    imageURL: nil,
                    prompt: prompt,
                    runtime: request.assistantPreferences.runtime,
                    model: request.assistantPreferences.model,
                    reasoningEffort: request.assistantPreferences.reasoningEffort,
                    conversationHistoryTurns:
                        request.assistantPreferences.conversationHistoryTurns
                ),
                token: token,
                screenToolHandler: { [weak self] call in
                    guard let self else {
                        return ScreenToolResult(
                            success: false,
                            message: "JellyPet 会话已经结束。"
                        )
                    }
                    return await self.handle(call, token: token)
                }
            )
            try ensureActive(token)
            guard session != nil else { return }
            publish(.finished, answer)
            session = nil
        } catch is CancellationError {
            guard token == generation else { return }
            publish(.cancelled, "接管已停止")
            session = nil
        } catch {
            guard token == generation else { return }
            publish(
                .error,
                nil,
                error as? PetFailure
                    ?? .agentRuntimeFailed("Agent", error.localizedDescription)
            )
            session = nil
        }
    }

    public func answer(
        displayID: UInt32,
        preferences: AssistantPreferences,
        question: String? = nil
    ) async {
        invalidate(keepsAnswerContext: true, cancelsResponder: false)
        let token = generation
        events = []
        session = nil
        answerPreferences = preferences
        let question = String(
            (question ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(4_000)
        )
        await responder.prepareForNextTurn()
        guard token == generation else { return }
        publish(.capturing)
        do {
            let artifact = try await capture.capture(displayID: displayID)
            defer { cleaner.remove(artifact) }
            try ensureActive(token)
            publish(.deciding)
            await requestAnswer(
                imageURL: artifact.imageURL,
                prompt: ResponsePrompts.screenAnalysis(
                    question: question,
                    customInstructions: preferences.customInstructions
                ),
                preferences: preferences,
                token: token
            )
        } catch {
            handleAnswerError(error, token: token)
        }
    }

    public func followUp(_ question: String) async {
        let question = String(question.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).prefix(4_000))
        guard !question.isEmpty, let preferences = answerPreferences else {
            return
        }
        invalidate(keepsAnswerContext: true)
        let token = generation
        publish(.deciding, snapshot.message)
        await requestAnswer(
            imageURL: nil,
            prompt: ResponsePrompts.followUp(
                question: question,
                customInstructions: preferences.customInstructions
            ),
            preferences: preferences,
            token: token
        )
    }

    public func closeAnswer() {
        invalidate()
        clearAnswerContext()
        events = []
        publish(.idle)
    }

    public func cancel(message: String = "已由你停止") {
        invalidate()
        publish(.cancelled, message)
        session = nil
    }

    @discardableResult
    public func addInstruction(_ value: String) async -> Bool {
        let value = String(value.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).prefix(4_000))
        guard session != nil, !value.isEmpty else { return false }
        do {
            try await responder.steer("用户补充要求：\(value)")
            trace(
                .thinking,
                "已把补充要求发送给当前 Agent",
                kind: .userInstruction,
                details: value
            )
            publish(snapshot.phase, "已收到补充要求")
        } catch {
            let message = (error as? PetFailure)?.localizedDescription
                ?? error.localizedDescription
            trace(
                .failure,
                "补充要求发送失败",
                kind: .outcome,
                details: message
            )
            publish(snapshot.phase, "补充要求未发送：\(message)")
        }
        return true
    }

    private func handle(
        _ call: ScreenToolCall,
        token: UUID
    ) async -> ScreenToolResult {
        guard token == generation, session != nil else {
            return ScreenToolResult(
                success: false,
                message: "JellyPet 会话已经结束。"
            )
        }
        if let reason = session?.terminalStopReason {
            return ScreenToolResult(
                success: false,
                message: "\(reason) 不要继续调用屏幕工具，请向用户说明停止原因。"
            )
        }
        session?.sequence += 1
        let sequence = session?.sequence ?? 1

        switch call {
        case .observe:
            return await observe(sequence: sequence, token: token)
        case let .perform(action):
            return await perform(action, sequence: sequence, token: token)
        case let .activateAndVerify(request):
            return await activateAndVerify(request, sequence: sequence, token: token)
        }
    }

    private func activateAndVerify(
        _ request: ActivateAndVerifyRequest,
        sequence: Int,
        token: UUID
    ) async -> ScreenToolResult {
        guard await refreshObservation(sequence: sequence, token: token) else {
            return ScreenToolResult(
                success: false,
                message: "无法获取最新界面，已停止激活。"
            )
        }
        if postconditionSatisfied(request) {
            return ScreenToolResult(
                success: true,
                message: "预期结果已经存在，无需重复激活目标。"
            )
        }
        guard let activationKey = resolvedActivationKey(request.targetLocator),
              let currentSignature = semanticObservationSignature() else {
            return ScreenToolResult(
                success: false,
                message: "最新界面中无法唯一定位激活目标，未执行点击。"
            )
        }
        guard session?.uncertainActivationSignatures[activationKey]
            != currentSignature else {
            return ScreenToolResult(
                success: false,
                message: "该目标上一次激活的结果仍不确定，且界面没有变化；不会立即重复激活。"
            )
        }
        // Reserve before touching the executor. An executor error can be
        // ambiguous. A retry becomes available after a newly observed semantic
        // state proves that the user or another action changed the context.
        session?.uncertainActivationSignatures[activationKey] = currentSignature
        let actionResult = await perform(
            .click(.locator(request.targetLocator)),
            sequence: sequence,
            token: token
        )
        guard actionResult.success else { return actionResult }
        guard await refreshObservation(sequence: sequence, token: token) else {
            return ScreenToolResult(
                success: false,
                message: "激活后无法重新观察，不能确认结果；不会重复激活。"
            )
        }
        guard postconditionSatisfied(request) else {
            if let signature = semanticObservationSignature() {
                session?.uncertainActivationSignatures[activationKey] = signature
            }
            return ScreenToolResult(
                success: false,
                message: "激活动作已执行一次，但后置条件未满足；界面变化前不会重复激活。"
            )
        }
        session?.uncertainActivationSignatures.removeValue(forKey: activationKey)
        return ScreenToolResult(
            success: true,
            message: "目标已激活一次，并已在最新观察中验证后置条件。"
        )
    }

    private func refreshObservation(sequence: Int, token: UUID) async -> Bool {
        if session?.currentSnapshot != nil { return true }
        let result = await observe(sequence: sequence, token: token)
        return result.success && session?.currentSnapshot != nil
    }

    private func postconditionSatisfied(
        _ request: ActivateAndVerifyRequest
    ) -> Bool {
        guard let snapshot = session?.currentSnapshot else { return false }
        let resolution = request.expectedLocator.resolve(in: snapshot)
        if request.expectedState == .absent {
            // A different app/window/page is not proof that the target disappeared
            // from the intended scope. Treat only a scoped not-found result as absence.
            return resolution.status == .notFound
        }
        guard resolution.status == .matched, let element = resolution.selected else {
            return false
        }
        guard let expectedValue = request.expectedValueEquals else { return true }
        return element.value == expectedValue
    }

    private func semanticObservationSignature() -> UInt64? {
        guard let snapshot = session?.currentSnapshot else { return nil }
        return TakeoverObservationFingerprint(
            snapshot: snapshot,
            screenshotPNG: nil
        ).semanticSignature
    }

    private func resolvedActivationKey(
        _ locator: SemanticElementLocator
    ) -> String? {
        guard let snapshot = session?.currentSnapshot else { return nil }
        let resolution = locator.resolve(in: snapshot)
        guard resolution.status == .matched,
              let selected = resolution.selected else { return nil }

        let elementsByID = snapshot.elements.reduce(into: [String: SemanticElement]()) {
            $0[$1.id] = $1
        }
        var path: [SemanticElement] = [selected]
        var parentID = selected.parentID
        var visited = Set<String>()
        while let id = parentID,
              visited.insert(id).inserted,
              let parent = elementsByID[id] {
            path.append(parent)
            parentID = parent.parentID
        }
        let scope = [
            normalizedIdentityText(snapshot.applicationName),
            normalizedIdentityText(snapshot.windowTitle),
            normalizedIdentityText(snapshot.pageURL ?? "")
        ]
        let semanticPath = path.reversed().map {
            semanticIdentityDescriptor($0, in: snapshot)
        }
        return (scope + semanticPath).joined(separator: "\u{1F}")
    }

    private func semanticIdentityDescriptor(
        _ element: SemanticElement,
        in snapshot: SemanticSnapshot
    ) -> String {
        let normalizedLabel = normalizedIdentityText(element.label)
        let peers = snapshot.elements.filter {
            $0.parentID == element.parentID
                && $0.role == element.role
                && normalizedIdentityText($0.label) == normalizedLabel
        }.sorted {
            if $0.frame.y != $1.frame.y { return $0.frame.y < $1.frame.y }
            return $0.frame.x < $1.frame.x
        }
        let ordinal = peers.firstIndex(where: { $0.id == element.id }) ?? 0
        return "\(element.role.rawValue):\(normalizedLabel):\(ordinal)"
    }

    private func normalizedIdentityText(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    private func observe(
        sequence: Int,
        token: UUID
    ) async -> ScreenToolResult {
        guard let current = session else {
            return ScreenToolResult(success: false, message: "会话已经结束。")
        }
        guard current.currentSnapshot == nil, !current.hasScreenshot else {
            return ScreenToolResult(
                success: false,
                message: "当前界面已经观察过，且尚未执行新动作；为避免重复截图，本次 observe 已拒绝。请直接使用上一次观察结果。"
            )
        }
        publish(.capturing, "Agent 正在观察当前界面")
        let startedAt = Date()
        var artifact: CaptureArtifact?
        defer { if let artifact { cleaner.remove(artifact) } }
        do {
            let semantics: SemanticSnapshot?
            if capture.prefersSemanticObservation {
                semantics = await semanticProvider?.snapshot(
                    displayID: current.request.displayID
                )
                try ensureActive(token)
                let text = semantics?.readableText?.lowercased() ?? ""
                let semanticsAreEnough = semantics?.elements.contains(
                    where: \.isEnabled
                ) == true && !text.contains("- canvas [")
                if !semanticsAreEnough {
                    artifact = try await capture.capture(
                        displayID: current.request.displayID
                    )
                }
            } else {
                artifact = try await capture.capture(
                    displayID: current.request.displayID
                )
                try ensureActive(token)
                semantics = await semanticProvider?.snapshot(
                    displayID: current.request.displayID
                )
            }
            try ensureActive(token)
            let screenshot = try artifact.map {
                try Data(contentsOf: $0.imageURL, options: .mappedIfSafe)
            }
            guard semantics != nil || screenshot != nil else {
                throw PetFailure.captureFailed
            }

            let progressDecision = session?.progress.recordObservation(
                snapshot: semantics,
                screenshotPNG: screenshot
            )
                ?? .proceed

            session?.currentSnapshot = semantics
            session?.hasScreenshot = screenshot != nil
            let details = semantics.map(render) ?? "没有可用的语义结构，已返回当前截图。"
            let duration = String(
                format: "%.1f 秒",
                Date().timeIntervalSince(startedAt)
            )
            trace(
                .observing,
                "第 \(session?.progress.observationCount ?? 1) 次观察完成 · \(duration)",
                kind: .observation,
                sequence: sequence,
                details: details
            )
            switch progressDecision {
            case .proceed:
                break
            case let .warning(warning):
                trace(
                    .verifying,
                    "接管监管提醒",
                    kind: .outcome,
                    sequence: sequence,
                    details: warning
                )
            case let .stop(reason):
                session?.terminalStopReason = reason
                trace(
                    .failure,
                    "接管监管已停止任务",
                    kind: .outcome,
                    sequence: sequence,
                    details: reason
                )
                publish(.deciding, reason)
                return ScreenToolResult(
                    success: false,
                    message: "\(reason) 不要继续调用屏幕工具，请向用户说明停止原因。",
                    screenshotPNG: screenshot
                )
            }
            publish(.deciding, "观察结果已返回 Agent")

            let imageNote = screenshot == nil
                ? "本次没有附带截图，请只使用当前元素 ID 定位。"
                : "本次同时附带当前截图，可在没有语义元素时使用 0 到 1000 的视觉坐标。"
            let progressNote: String
            if case let .warning(warning) = progressDecision {
                progressNote = "\n监管提醒：\(warning)"
            } else {
                progressNote = ""
            }
            return ScreenToolResult(
                success: true,
                message: "当前界面：\n\(details)\n\(imageNote)\(progressNote)",
                screenshotPNG: screenshot
            )
        } catch is CancellationError {
            return ScreenToolResult(success: false, message: "观察已取消。")
        } catch {
            let message = (error as? PetFailure)?.localizedDescription
                ?? error.localizedDescription
            session?.terminalStopReason = message
            trace(
                .failure,
                "观察失败",
                kind: .outcome,
                sequence: sequence,
                details: message
            )
            publish(.deciding, "观察失败，本轮接管已停止")
            return ScreenToolResult(
                success: false,
                message: "\(message) 本轮接管已停止；不要重复截图或改用其他链路。"
            )
        }
    }

    private func perform(
        _ action: ScreenAction,
        sequence: Int,
        token: UUID
    ) async -> ScreenToolResult {
        guard let current = session else {
            return ScreenToolResult(success: false, message: "会话已经结束。")
        }
        let isWait: Bool
        if case .wait = action { isWait = true } else { isWait = false }
        guard current.currentSnapshot != nil || current.hasScreenshot || isWait else {
            return ScreenToolResult(
                success: false,
                message: "页面可能已经变化，请先调用 observe 获取当前界面。"
            )
        }
        guard !action.needsVisualObservation || current.hasScreenshot else {
            return ScreenToolResult(
                success: false,
                message: "最近一次观察没有截图，不能使用视觉坐标；请使用当前元素 ID。"
            )
        }

        do {
            try action.validate()
            let executableAction = try action.resolvingSemanticTargets(
                in: current.currentSnapshot
            )
            let progressDecision = session?.progress.recordAction() ?? .proceed
            if case let .stop(reason) = progressDecision {
                session?.terminalStopReason = reason
                trace(
                    .failure,
                    "接管监管已停止任务",
                    kind: .outcome,
                    sequence: sequence,
                    details: reason
                )
                publish(.deciding, reason)
                return ScreenToolResult(
                    success: false,
                    message: "\(reason) 不要继续调用屏幕工具，请向用户说明停止原因。"
                )
            }
            publish(.locating, "Agent 已选择 \(action.label)")
            trace(
                .acting,
                "调用 \(action.label)",
                kind: .action,
                sequence: sequence,
                details: actionDescription(action)
            )
            publish(.executing, "正在执行 \(action.label)")
            try await executor.execute(
                executableAction,
                snapshot: current.currentSnapshot,
                displayID: current.request.displayID
            )
            try ensureActive(token)
            if !isWait {
                try await Task.sleep(
                    nanoseconds: UInt64(
                        AppMetadata.interfaceSettleSeconds * 1_000_000_000
                    )
                )
            }
            try ensureActive(token)
            session?.currentSnapshot = nil
            session?.hasScreenshot = false
            trace(
                .verifying,
                "\(action.label) 已执行",
                kind: .outcome,
                sequence: sequence,
                details: "执行器已完成操作；下一步必须重新观察实际界面。"
            )
            publish(.verifying, "操作完成，等待 Agent 重新观察")
            return ScreenToolResult(
                success: true,
                message: "\(action.label) 已执行。页面状态可能变化，请调用 observe 验证结果。"
            )
        } catch is CancellationError {
            return ScreenToolResult(success: false, message: "操作已取消。")
        } catch {
            session?.currentSnapshot = nil
            session?.hasScreenshot = false
            let message = (error as? PetFailure)?.localizedDescription
                ?? error.localizedDescription
            session?.terminalStopReason = message
            trace(
                .failure,
                "\(action.label) 执行失败",
                kind: .outcome,
                sequence: sequence,
                details: message
            )
            publish(.deciding, "操作失败，本轮接管已停止")
            return ScreenToolResult(
                success: false,
                message: "\(message) 本轮接管已停止；不要换目标、坐标或导航兜底。"
            )
        }
    }

    private func render(_ snapshot: SemanticSnapshot) -> String {
        let header = [
            "应用：\(String(reflecting: snapshot.applicationName))",
            "窗口：\(String(reflecting: snapshot.windowTitle))",
            "网址：\(String(reflecting: snapshot.pageURL ?? "未知"))"
        ].joined(separator: " · ")
        let valueLimit = max(
            80,
            min(1_000, 20_000 / max(1, snapshot.elements.count))
        )
        let elements = snapshot.elements.map {
            let parent = $0.parentID.map(String.init(reflecting:)) ?? "无"
            return "\($0.id) 父级=\(parent) 角色=\(roleLabel($0.role)) 名称=\(String(reflecting: $0.label)) 值=\(String(reflecting: bounded($0.value ?? "", limit: valueLimit))) 区域=\($0.frame.x),\($0.frame.y),\($0.frame.width),\($0.frame.height)"
        }
        return ([
            header,
            "可读正文：\(String(reflecting: snapshot.readableText ?? "无"))"
        ] + elements).joined(separator: "\n")
    }

    private func roleLabel(_ role: SemanticElementRole) -> String {
        switch role {
        case .button: "按钮"
        case .link: "链接"
        case .textField: "输入框"
        case .checkBox: "复选框"
        case .radioButton: "单选框"
        case .menuItem: "菜单项"
        case .popUpButton: "下拉框"
        case .scrollArea: "滚动区域"
        case .dialog: "对话框"
        case .group: "分组"
        case .list: "列表"
        case .listItem: "列表项"
        case .row: "行"
        case .cell: "单元格"
        case .tab: "标签页"
        case .heading: "标题"
        case .staticText: "静态文本"
        }
    }

    private func actionDescription(_ action: ScreenAction) -> String {
        switch action {
        case .click: "单击当前目标"
        case .doubleClick: "双击当前目标"
        case let .drag(fromX, fromY, toX, toY, duration):
            "从 (\(fromX), \(fromY)) 拖到 (\(toX), \(toY))，持续 \(duration) 毫秒"
        case let .typeText(_, text):
            "输入 \(text.count) 个字符（完整最终文本）"
        case let .keyPress(key, modifiers):
            "按键 \((modifiers.map(\.rawValue) + [key.rawValue]).joined(separator: "+"))"
        case let .navigate(url): "打开 \(url)"
        case let .scroll(_, deltaX, deltaY):
            "滚动 x=\(deltaX), y=\(deltaY)"
        case let .wait(milliseconds): "等待 \(milliseconds) 毫秒"
        }
    }

    private func bounded(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        let head = max(1, limit * 2 / 3)
        return "\(value.prefix(head))\n…\n\(value.suffix(limit - head))"
    }

    private func ensureActive(_ token: UUID) throws {
        try Task.checkCancellation()
        guard token == generation else { throw CancellationError() }
    }

    private func invalidate(
        keepsAnswerContext: Bool = false,
        cancelsResponder: Bool = true
    ) {
        generation = UUID()
        if cancelsResponder { responder.cancel() }
        executor.cancel()
        streamID = nil
        streamedResponse = ""
        if !keepsAnswerContext { clearAnswerContext() }
    }

    private func modelResponse(
        to request: CodexRequest,
        token: UUID,
        screenToolHandler: ScreenToolHandler? = nil
    ) async throws -> String {
        let id = UUID()
        streamID = id
        streamedResponse = ""
        publish(
            .deciding,
            session == nil
                ? "已发送给本地 Agent，正在等待回复"
                : "任务已交给本地 Agent，等待它观察或回复"
        )
        defer {
            if streamID == id {
                streamID = nil
                streamedResponse = ""
            }
        }
        return try await responder.respond(
            to: request,
            onTextDelta: { [weak self] delta in
                Task { @MainActor in
                    self?.receive(delta, streamID: id, token: token)
                }
            },
            screenToolHandler: screenToolHandler
        )
    }

    private func receive(
        _ delta: String,
        streamID: UUID,
        token: UUID
    ) {
        guard self.streamID == streamID, token == generation else { return }
        streamedResponse += delta
        if streamedResponse.count > 2_000 {
            streamedResponse = String(streamedResponse.suffix(2_000))
        }
        publish(
            .deciding,
            "AI 正在回复：\(compact(String(streamedResponse.suffix(160))))"
        )
    }

    private func requestAnswer(
        imageURL: URL?,
        prompt: String,
        preferences: AssistantPreferences,
        token: UUID
    ) async {
        do {
            let answer = try await modelResponse(
                to: CodexRequest(
                    imageURL: imageURL,
                    prompt: prompt,
                    runtime: preferences.runtime,
                    model: preferences.model,
                    reasoningEffort: preferences.reasoningEffort,
                    conversationHistoryTurns:
                        preferences.conversationHistoryTurns
                ),
                token: token
            )
            try ensureActive(token)
            publish(.finished, answer)
        } catch {
            handleAnswerError(error, token: token)
        }
    }

    private func handleAnswerError(_ error: Error, token: UUID) {
        guard token == generation else { return }
        if error is CancellationError {
            publish(.idle)
        } else {
            publish(
                .error,
                nil,
                error as? PetFailure
                    ?? .agentRuntimeFailed("Agent", error.localizedDescription)
            )
        }
    }

    private func clearAnswerContext() {
        answerPreferences = nil
    }

    private func publish(
        _ phase: TakeoverPhase,
        _ message: String? = nil,
        _ failure: PetFailure? = nil
    ) {
        let eventMessage = compact(message ?? defaultMessage(phase))
        if !eventMessage.isEmpty,
           events.last?.activity != phase.activity
            || events.last?.message != eventMessage {
            appendEvent(TakeoverEvent(
                activity: phase.activity,
                message: eventMessage
            ))
        }
        let metrics = session.map {
            TakeoverMetrics(
                durationSeconds: Date().timeIntervalSince($0.startedAt),
                actionCount: $0.progress.actionCount,
                observationCount: $0.progress.observationCount
            )
        }
        snapshot = TakeoverSnapshot(
            phase: phase,
            message: message,
            failure: failure,
            events: events,
            metrics: metrics
        )
        onSnapshot?(snapshot)
    }

    private func trace(
        _ activity: PetActivity,
        _ message: String,
        kind: TakeoverEventKind = .status,
        sequence: Int? = nil,
        details: String? = nil
    ) {
        appendEvent(TakeoverEvent(
            activity: activity,
            message: compact(message),
            kind: kind,
            sequence: sequence,
            details: details
        ))
    }

    private func appendEvent(_ event: TakeoverEvent) {
        events.append(event)
        while events.count > AppMetadata.takeoverEventLimit {
            if let status = events.firstIndex(where: { $0.kind == .status }) {
                events.remove(at: status)
            } else {
                events.removeFirst()
            }
        }
    }

    private func compact(_ value: String) -> String {
        String(value.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
    }

    private func defaultMessage(_ phase: TakeoverPhase) -> String {
        switch phase {
        case .idle: ""
        case .capturing: "正在观察屏幕"
        case .deciding: "Agent 正在决定下一步"
        case .locating: "正在定位操作目标"
        case .executing: "正在执行操作"
        case .verifying: "等待 Agent 验证操作结果"
        case .finished: "任务已完成"
        case .cancelled: "接管已取消"
        case .error: "接管遇到错误"
        }
    }
}
