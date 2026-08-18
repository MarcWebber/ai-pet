import AppKit
import CoreGraphics
import Foundation
import JellyCore
import JellyMac
import OSLog
import UniformTypeIdentifiers

@MainActor
final class AppCoordinator {
    private let sessionLog = Logger(
        subsystem: AppMetadata.bundleIdentifier,
        category: "session"
    )
    private let preferencesStore: AppPreferencesStore
    private let screenBackend = ScreenKitBackend()
    private let hotkey = CarbonHotkeyService()
    private let pet = PetPanelController()
    private let bubble = BubblePanelController()
    private let settings = SettingsWindowController()
    private let status = StatusItemController()
    private let temporaryArtifactSweeper = TemporaryArtifactSweeper()
    private let soundPlayer: SoundPlayer
    private let runtimes: [LocalAgentRuntime]
    private let modelCatalog = LocalAgentModelCatalog()
    private let surfaceRouter: TakeoverSurfaceRouter
    private let takeover: TakeoverCoordinator

    private var requestTask: Task<Void, Never>?
    private var settingsTask: Task<Void, Never>?
    private var browserCloseTask: Task<Void, Never>?
    private var activeTakeoverRequest: TakeoverRequest?
    private var lastActivity: PetActivity = .idle
    private var lastMessage: String?
    private var pendingAnswerQuestion: String?
    private var answerHistory: [AnswerHistoryEntry] = []
    private var answerHistoryIndex: Int?
    private var isShowingAnswerHistory = false

    init() {
        let packagedConfiguration = Bundle.main.resourceURL?
            .appendingPathComponent("JellyPetConfig.json")
        let configurationTemplateURL = packagedConfiguration.flatMap {
            FileManager.default.isReadableFile(atPath: $0.path) ? $0 : nil
        } ?? Bundle.module.url(
            forResource: "JellyPetConfig",
            withExtension: "json"
        )
        preferencesStore = AppPreferencesStore(
            configurationTemplateURL: configurationTemplateURL
        )
        runtimes = LocalAgentRuntimeLocator.detect()
        let packagedSkill = Bundle.main.resourceURL?
            .appendingPathComponent("Skills/human-exam-taking/SKILL.md")
        let skillURL = packagedSkill.flatMap {
            FileManager.default.isReadableFile(atPath: $0.path) ? $0 : nil
        } ?? Bundle.module.url(
            forResource: "SKILL",
            withExtension: "md",
            subdirectory: "Skills/human-exam-taking"
        )
        let capture = ScreenCaptureService(backend: screenBackend)
        let cleaner = CaptureArtifactCleaner()
        let semanticProvider = BrowserAccessibilityContextProvider()
        let router = TakeoverSurfaceRouter(
            nativeCapture: capture,
            nativeSemantics: semanticProvider,
            nativeExecutor: CGEventScreenActionExecutor()
        )
        surfaceRouter = router
        takeover = TakeoverCoordinator(
            capture: router,
            responder: LocalAgentResponder(
                runtimes: runtimes,
                skillURL: skillURL
            ),
            cleaner: cleaner,
            executor: router,
            semanticProvider: router
        )
        soundPlayer = SoundPlayer(
            resourceDirectory: Self.soundResourceDirectory()
        )
        answerHistory = preferencesStore.answerHistory
    }

    func start() {
        temporaryArtifactSweeper.removeAll()
        wireActions()
        applyConfiguredSprite()
        pet.show(on: selectedNSScreen())
        pet.jellyView.apply(activity: .idle)
        updateMenu()

        do {
            try registerHotkey(preferencesStore.globalShortcut)
        } catch {
            showFailure(.shortcutUnavailable)
        }
        do {
            try registerAnswerScrollHotkeys(
                preferencesStore.answerScrollShortcut
            )
        } catch {
            showFailure(.answerScrollShortcutUnavailable)
        }
        do {
            try registerAnswerHistoryHotkeys(
                preferencesStore.answerHistoryShortcut
            )
        } catch {
            showFailure(.answerHistoryShortcutUnavailable)
        }

    }

    func stop() async {
        requestTask?.cancel()
        settingsTask?.cancel()
        takeover.onSnapshot = nil
        takeover.closeAnswer()
        if takeover.snapshot.isActive {
            takeover.cancel()
        }
        temporaryArtifactSweeper.removeAll()
        hotkey.unregister()
        settings.hide()
        bubble.hide()
        pet.hide()
        scheduleBrowserClose()
        await waitForBrowserClose()
    }

    private func wireActions() {
        takeover.onSnapshot = { [weak self] snapshot in
            self?.handleSession(snapshot)
        }
        pet.onClick = { [weak self] in
            guard let self else {
                return
            }
            if self.bubble.panel.isVisible {
                self.closeBubble()
                return
            }

            self.pet.jellyView.reactToTap()
            self.soundPlayer.play(.dock)
            self.showComposer()
        }
        pet.onRightClick = { [weak self] in
            self?.status.showMenu()
        }
        pet.onDock = { [weak self] in
            self?.soundPlayer.play(.dock)
        }
        pet.onFrameChange = { [weak self] in
            self?.repositionBubble()
        }

        bubble.onQuestionSubmit = { [weak self] question in
            self?.performPrimaryAction(task: question)
        }
        bubble.onSubmit = { [weak self] question in
            self?.submitFollowUp(question)
        }
        bubble.onTakeoverSubmit = { [weak self] task in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !(await self.takeover.addInstruction(task)) {
                    self.performPrimaryAction(task: task)
                }
            }
        }
        bubble.onModeChange = { [weak self] takeoverEnabled, text in
            self?.changeMode(takeoverEnabled, preserving: text)
        }
        bubble.onClose = { [weak self] in
            self?.closeBubble()
        }

        settings.form.onAction = { [weak self] action in
            guard let self else { return }
            switch action {
            case let .display(id):
                self.preferencesStore.selectedDisplayID = id
                self.pet.placeAtBottomRight(of: self.nsScreen(for: id))
                self.refreshCurrentSettings()
            case let .assistant(value):
                let previousTurns = self.preferencesStore
                    .conversationHistoryTurns
                self.preferencesStore.assistantPreferences = value
                if previousTurns != value.conversationHistoryTurns {
                    self.answerHistory = Array(
                        self.answerHistory.suffix(
                            value.conversationHistoryTurns
                        )
                    )
                    self.preferencesStore.answerHistory = self.answerHistory
                }
                self.refreshCurrentSettings()
            case let .takeover(value):
                self.preferencesStore.takeoverEnabled = value
                self.updateMenu()
            case let .activityDetails(value): self.preferencesStore.showActivityDetails = value
            case let .shortcut(value): self.changeShortcut(value)
            case let .answerScrollShortcut(value):
                self.changeAnswerScrollShortcut(value)
            case let .answerHistoryShortcut(value):
                self.changeAnswerHistoryShortcut(value)
            case .chooseSprite:
                self.chooseSpriteSheet()
            case .resetSprite:
                self.resetSpriteSheet()
            case .revealConfiguration:
                NSWorkspace.shared.activateFileViewerSelecting([
                    self.preferencesStore.configurationURL
                ])
            case .finish: self.settings.hide()
            }
        }

        status.onAction = { [weak self] action in
            guard let self else { return }
            switch action {
            case .primary: self.performPrimaryAction()
            case .pet: self.togglePet()
            case .mute: self.soundPlayer.isMuted.toggle(); self.updateMenu()
            case .settings: self.refreshCurrentSettings(showWindow: true)
            case .quit: NSApp.terminate(nil)
            }
        }
    }

    private func performPrimaryAction(task: String? = nil) {
        if takeover.snapshot.isActive {
            cancelTakeover()
        } else {
            requestTask?.cancel()
            requestTask = Task { [weak self] in await self?.startSession(task: task) }
        }
    }

    private func startSession(task: String?) async {
        do {
            await waitForBrowserClose()
            surfaceRouter.useNative()
            let display = try await loadSelectedDisplay()
            if !preferencesStore.takeoverEnabled {
                let question = Self.normalizedAnswerQuestion(task)
                pendingAnswerQuestion = question
                pet.show(on: nsScreen(for: display.id))
                await takeover.answer(
                    displayID: display.id,
                    preferences: preferencesStore.assistantPreferences,
                    question: question
                )
                return
            }
            pendingAnswerQuestion = nil
            setActivity(.observing)
            isShowingAnswerHistory = false
            bubble.hide()
            NSApp.deactivate()
            try await Task.sleep(nanoseconds: 120_000_000)
            let browserChannel = PlaywrightBrowserChannel.channel(
                bundleIdentifier: NSWorkspace.shared.frontmostApplication?
                    .bundleIdentifier
            )
            let preparationMessage = if browserChannel != nil {
                "正在检查 Playwright 与当前浏览器的连接…"
            } else {
                "当前前台不是可附着浏览器，正在准备原生屏幕模式…"
            }
            pet.show(on: nsScreen(for: display.id))
            bubble.showWorking(
                previousMessage: preparationMessage,
                preferences: preferencesStore.assistantPreferences,
                petFrame: pet.panel.frame,
                screen: pet.panel.screen
            )
            let browserPreparationStartedAt = Date()
            let browserPreparation = try await surfaceRouter.prepareBrowser(
                attachingTo: browserChannel
            )
            let browserPreparationSeconds = Date().timeIntervalSince(
                browserPreparationStartedAt
            )
            let request = takeoverRequest(displayID: display.id, task: task)
            activeTakeoverRequest = request
            lastMessage = nil
            settingsTask?.cancel()
            takeover.closeAnswer()
            settings.hide()
            pet.setClickThrough(true)
            pet.show(on: nsScreen(for: request.displayID))
            let duration = String(
                format: "%.1f",
                browserPreparationSeconds
            )
            let initialMessage = switch browserPreparation {
            case .attached:
                "已连接当前浏览器标签页，使用 Playwright DOM 接管；准备耗时 \(duration) 秒。"
            case let .unavailable(reason):
                "Playwright 未连接：\(reason)。本轮已切换到 Accessibility 和截图操作；准备耗时 \(duration) 秒。"
            }
            await takeover.start(
                request,
                initialMessage: initialMessage
            )
        } catch is CancellationError {
            return
        } catch let failure as PetFailure {
            guard preferencesStore.takeoverEnabled else {
                showFailure(failure)
                return
            }
            let request = takeoverRequest(
                displayID: preferencesStore.selectedDisplayID ?? CGMainDisplayID(),
                task: task
            )
            finishTakeover(
                message: failure.localizedDescription,
                activity: .failure,
                failure: failure,
                request: request
            )
        } catch {
            showFailure(.screenActionFailed)
        }
    }

    private func cancelTakeover(message: String = "已由你停止") {
        let wasActive = takeover.snapshot.isActive
        requestTask?.cancel()
        pet.setClickThrough(false)
        if wasActive {
            takeover.cancel(message: message)
        } else {
            activeTakeoverRequest = nil
            updateMenu()
        }
        scheduleBrowserClose()
    }

    private func handleSession(_ snapshot: TakeoverSnapshot) {
        sessionLog.notice(
            "phase=\(String(describing: snapshot.phase), privacy: .public) actions=\(snapshot.metrics?.actionCount ?? 0) observations=\(snapshot.metrics?.observationCount ?? 0)"
        )
        guard snapshot.phase != .idle else {
            updateMenu()
            return
        }
        guard let request = activeTakeoverRequest else {
            handleAnswer(snapshot)
            return
        }

        setActivity(snapshot.activity)
        pet.setClickThrough(snapshot.isActive)
        if snapshot.isActive {
            pet.show(on: nsScreen(for: request.displayID))
            bubble.showTakeoverProgress(
                snapshot,
                preferences: request.assistantPreferences,
                showsActivityDetails: preferencesStore.showActivityDetails,
                petFrame: pet.panel.frame,
                screen: pet.panel.screen
            )
        }

        switch snapshot.phase {
        case .idle:
            break

        case .executing, .locating, .verifying:
            updateMenu()

        case .capturing, .deciding:
            updateMenu()

        case .finished:
            finishTakeover(
                message: snapshot.message ?? "任务已完成。",
                activity: .success,
                request: request
            )

        case .error:
            let failure = snapshot.failure ?? .invalidCodexOutput
            finishTakeover(
                message: snapshot.message ?? failure.localizedDescription,
                activity: .failure,
                failure: failure,
                request: request
            )

        case .cancelled:
            finishTakeover(
                message: snapshot.message ?? "已由你停止",
                activity: .idle,
                request: request
            )
        }
    }

    private func handleAnswer(_ snapshot: TakeoverSnapshot) {
        let preferences = preferencesStore.assistantPreferences
        setActivity(snapshot.activity)
        switch snapshot.phase {
        case .capturing:
            isShowingAnswerHistory = false
            bubble.hide()
        case .deciding:
            isShowingAnswerHistory = false
            bubble.showWorking(
                previousMessage: snapshot.message ?? lastMessage,
                preferences: preferences,
                petFrame: pet.panel.frame,
                screen: pet.panel.screen
            )
        case .finished:
            if let message = snapshot.message {
                recordAnswer(message, preferences: preferences)
            }
        case .error:
            pendingAnswerQuestion = nil
            showFailure(
                snapshot.failure ?? .invalidCodexOutput,
                preferences: preferences
            )
        case .idle, .locating, .executing, .verifying, .cancelled:
            break
        }
    }

    private func recordAnswer(
        _ message: String,
        preferences: AssistantPreferences
    ) {
        let entry = AnswerHistoryEntry(
            question: pendingAnswerQuestion,
            answer: message
        )
        answerHistory.append(entry)
        answerHistory = Array(
            answerHistory.suffix(
                preferencesStore.conversationHistoryTurns
            )
        )
        preferencesStore.answerHistory = answerHistory
        let latestIndex = answerHistory.count - 1
        answerHistoryIndex = latestIndex
        pendingAnswerQuestion = nil
        lastMessage = message
        showAnswerHistoryEntry(
            at: latestIndex,
            preferences: preferences
        )
    }

    private func showPreviousAnswer() {
        showAnswerHistory(offset: -1)
    }

    private func showNextAnswer() {
        showAnswerHistory(offset: 1)
    }

    private func showAnswerHistory(offset: Int) {
        guard !takeover.snapshot.isActive,
              let lastIndex = answerHistory.indices.last
        else {
            return
        }
        let target: Int
        if isShowingAnswerHistory, let current = answerHistoryIndex {
            target = min(max(current + offset, 0), lastIndex)
        } else {
            target = lastIndex
        }
        answerHistoryIndex = target
        showAnswerHistoryEntry(
            at: target,
            preferences: preferencesStore.assistantPreferences
        )
    }

    private func showAnswerHistoryEntry(
        at index: Int,
        preferences: AssistantPreferences
    ) {
        guard answerHistory.indices.contains(index) else { return }
        let entry = answerHistory[index]
        isShowingAnswerHistory = true
        lastMessage = entry.answer
        if !pet.panel.isVisible {
            pet.show(on: selectedNSScreen())
            updateMenu()
        }
        bubble.showAnswer(
            entry.answer,
            question: entry.question,
            historyPosition: (index + 1, answerHistory.count),
            preferences: preferences,
            petFrame: pet.panel.frame,
            screen: pet.panel.screen
        )
    }

    private func submitFollowUp(_ question: String) {
        guard let question = Self.normalizedAnswerQuestion(question) else {
            return
        }
        guard takeover.canFollowUp else {
            performPrimaryAction(task: question)
            return
        }
        pendingAnswerQuestion = question
        requestTask?.cancel()
        requestTask = Task { [weak self] in
            await self?.takeover.followUp(question)
        }
    }

    private func showComposer(initialText: String = "") {
        isShowingAnswerHistory = false
        if !pet.panel.isVisible {
            pet.show(on: selectedNSScreen())
            updateMenu()
        }
        if preferencesStore.takeoverEnabled {
            bubble.showTakeoverComposer(
                initialTask: initialText,
                petFrame: pet.panel.frame,
                screen: pet.panel.screen
            )
        } else {
            bubble.showQuestionComposer(
                initialQuestion: initialText,
                petFrame: pet.panel.frame,
                screen: pet.panel.screen
            )
        }
    }

    private func changeMode(
        _ takeoverEnabled: Bool,
        preserving text: String
    ) {
        guard !takeover.snapshot.isActive else { return }
        preferencesStore.takeoverEnabled = takeoverEnabled
        updateMenu()
        showComposer(initialText: text)
    }

    private func closeBubble() {
        if takeover.snapshot.isActive {
            cancelTakeover()
            return
        }
        requestTask?.cancel()
        takeover.closeAnswer()
        pendingAnswerQuestion = nil
        lastMessage = nil
        isShowingAnswerHistory = false
        bubble.hide()
    }

    private func togglePet() {
        guard !takeover.snapshot.isActive
            || activeTakeoverRequest == nil
        else {
            return
        }
        if pet.panel.isVisible {
            requestTask?.cancel()
            takeover.closeAnswer()
            pendingAnswerQuestion = nil
            lastMessage = nil
            isShowingAnswerHistory = false
            bubble.hide()
            pet.hide()
        } else {
            pet.show(on: selectedNSScreen())
        }
        updateMenu()
    }

    private func setActivity(
        _ activity: PetActivity,
        playsSound: Bool = true
    ) {
        pet.jellyView.apply(activity: activity)
        guard activity != lastActivity else { return }
        lastActivity = activity
        guard playsSound else { return }
        let cue: SoundCue? = switch activity {
        case .observing: .capture
        case .thinking, .locating, .acting, .verifying: .thinking
        case .success: .answer
        case .failure: .error
        case .idle: nil
        }
        if let cue { soundPlayer.play(cue) }
    }

    private func finishTakeover(
        message: String,
        activity: PetActivity,
        failure: PetFailure? = nil,
        request: TakeoverRequest
    ) {
        requestTask = nil
        activeTakeoverRequest = nil
        surfaceRouter.useNative()
        scheduleBrowserClose()

        pet.setClickThrough(false)
        setActivity(activity)
        isShowingAnswerHistory = false

        if failure != nil {
            pet.show(
                on: nsScreen(for: request.displayID) ?? selectedNSScreen()
            )
            bubble.showTakeoverResult(
                message,
                events: takeover.snapshot.events,
                isError: true,
                preferences: request.assistantPreferences,
                showsActivityDetails: preferencesStore.showActivityDetails,
                petFrame: pet.panel.frame,
                screen: pet.panel.screen
            )
            pet.jellyView.showAttention()
            updateMenu()
            return
        }
        pet.show(
            on: nsScreen(for: request.displayID) ?? selectedNSScreen()
        )
        bubble.showTakeoverResult(
            message,
            events: takeover.snapshot.events,
            isError: activity == .failure,
            preferences: request.assistantPreferences,
            showsActivityDetails: preferencesStore.showActivityDetails,
            petFrame: pet.panel.frame,
            screen: pet.panel.screen
        )
        updateMenu()
    }

    private func takeoverRequest(
        displayID: UInt32,
        task: String?
    ) -> TakeoverRequest {
        let task = task?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let boundedTask = task.flatMap {
            $0.isEmpty ? nil : String($0.prefix(4_000))
        }
        return TakeoverRequest(
            displayID: displayID,
            task: boundedTask,
            assistantPreferences: preferencesStore.assistantPreferences
        )
    }

    private static func normalizedAnswerQuestion(
        _ question: String?
    ) -> String? {
        let value = String(
            (question ?? "").trimmingCharacters(
                in: .whitespacesAndNewlines
            ).prefix(4_000)
        )
        return value.isEmpty ? nil : value
    }

    private func scheduleBrowserClose() {
        guard browserCloseTask == nil else { return }
        browserCloseTask = Task { await surfaceRouter.closeBrowser() }
    }

    private func waitForBrowserClose() async {
        guard let task = browserCloseTask else { return }
        await task.value
        browserCloseTask = nil
    }

    private func showFailure(
        _ failure: PetFailure,
        message: String? = nil,
        preferences: AssistantPreferences? = nil
    ) {
        setActivity(.failure)
        isShowingAnswerHistory = false
        pet.show(on: selectedNSScreen())

        bubble.showError(
            message ?? failure.localizedDescription,
            preferences: preferences,
            petFrame: pet.panel.frame,
            screen: pet.panel.screen
        )
        updateMenu()
    }

    private func loadSelectedDisplay() async throws -> DisplayDescriptor {
        let displays: [DisplayDescriptor]
        do {
            displays = try await screenBackend.availableDisplays()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PetFailure.captureFailed
        }

        guard !displays.isEmpty else {
            throw PetFailure.noDisplaysAvailable
        }
        let selectedID = preferencesStore.selectedDisplayID
        let display = selectedID.flatMap { id in
            displays.first { $0.id == id }
        } ?? displays.first(where: \.isPrimary) ?? displays[0]
        preferencesStore.selectedDisplayID = display.id
        return display
    }

    private func repositionBubble() {
        bubble.reposition(
            petFrame: pet.panel.frame,
            screen: pet.panel.screen
        )
    }

    private func refreshCurrentSettings(
        showWindow: Bool = false
    ) {
        if showWindow {
            settings.show()
        }
        scheduleSettingsTask { coordinator in
            await coordinator.refreshSettings(showWindow: false)
        }
    }

    private func scheduleSettingsTask(
        _ operation: @escaping @MainActor (AppCoordinator) async -> Void
    ) {
        settingsTask?.cancel()
        settingsTask = Task { [weak self] in
            guard let self else {
                return
            }
            await operation(self)
        }
    }

    private func refreshSettings(
        showWindow: Bool
    ) async {
        _ = preferencesStore.reloadConfiguration()
        applyConfiguredSprite()
        answerHistory = Array(
            answerHistory.suffix(
                preferencesStore.conversationHistoryTurns
            )
        )
        preferencesStore.answerHistory = answerHistory
        let displays = (try? await screenBackend.availableDisplays()) ?? []
        if preferencesStore.selectedDisplayID == nil,
           let display = displays.first(where: \.isPrimary) ?? displays.first {
            preferencesStore.selectedDisplayID = display.id
        }

        let preferences = preferencesStore.assistantPreferences
        let selectedRuntime = LocalAgentRuntimeLocator.resolve(
            preferences.runtime,
            from: runtimes
        )
        let models = if let selectedRuntime {
            await modelCatalog.models(for: selectedRuntime)
        } else {
            [String]()
        }
        let runtimeText = runtimes.isEmpty
            ? "未发现兼容 CLI；支持 Codex、TraeX、Claude Code、OpenCode"
            : runtimes.map {
                "\($0.kind.displayName) · \($0.executableURL.path)"
            }.joined(separator: "\n")
        guard !Task.isCancelled else {
            return
        }
        let spriteSheetURL = preferencesStore.spriteSheetURL
        let configurationError = preferencesStore.configurationError
        settings.update(
            SettingsViewState(
                displays: displays,
                selectedDisplayID: preferencesStore.selectedDisplayID,
                assistantPreferences: preferencesStore.assistantPreferences,
                takeoverEnabled: preferencesStore.takeoverEnabled,
                showActivityDetails: preferencesStore.showActivityDetails,
                globalShortcut: preferencesStore.globalShortcut,
                answerScrollShortcut:
                    preferencesStore.answerScrollShortcut,
                answerHistoryShortcut:
                    preferencesStore.answerHistoryShortcut,
                availableRuntimes: Set(runtimes.map(\.kind)),
                modelOptions: models,
                runtimeText: runtimeText,
                configurationURL: preferencesStore.configurationURL,
                configurationError: configurationError,
                spriteSheetURL: spriteSheetURL
            )
        )
        if showWindow {
            settings.show()
        }
    }

    private func updateMenu() {
        let snapshot = takeover.snapshot
        let isTakingOver = snapshot.isActive
            && activeTakeoverRequest != nil
        status.update(
            isPetVisible: pet.panel.isVisible,
            isMuted: soundPlayer.isMuted,
            isTakeoverEnabled:
                preferencesStore.takeoverEnabled,
            isTakingOver: isTakingOver,
            takeoverStatus: isTakingOver ? snapshot.message : nil,
            shortcutLabel: preferencesStore.globalShortcut.label
        )
    }

    private func registerHotkey(_ shortcut: GlobalShortcut) throws {
        try hotkey.register(shortcut: shortcut) { [weak self] in
            Task { @MainActor in self?.performPrimaryAction() }
        }
    }

    private func registerAnswerScrollHotkeys(
        _ shortcut: AnswerScrollShortcut
    ) throws {
        try hotkey.registerAnswerScrolling(
            shortcut: shortcut,
            onUp: { [weak self] in
                Task { @MainActor in self?.bubble.scrollAnswerUp() }
            },
            onDown: { [weak self] in
                Task { @MainActor in self?.bubble.scrollAnswerDown() }
            }
        )
    }

    private func registerAnswerHistoryHotkeys(
        _ shortcut: AnswerHistoryShortcut
    ) throws {
        try hotkey.registerAnswerHistoryNavigation(
            shortcut: shortcut,
            onPrevious: { [weak self] in
                Task { @MainActor in self?.showPreviousAnswer() }
            },
            onNext: { [weak self] in
                Task { @MainActor in self?.showNextAnswer() }
            }
        )
    }

    private func changeShortcut(_ shortcut: GlobalShortcut) {
        let previous = preferencesStore.globalShortcut
        do {
            try registerHotkey(shortcut)
            preferencesStore.globalShortcut = shortcut
            refreshCurrentSettings(); updateMenu()
        } catch {
            try? registerHotkey(previous)
            showFailure(.shortcutUnavailable); refreshCurrentSettings()
        }
    }

    private func changeAnswerScrollShortcut(
        _ shortcut: AnswerScrollShortcut
    ) {
        let previous = preferencesStore.answerScrollShortcut
        do {
            try registerAnswerScrollHotkeys(shortcut)
            preferencesStore.answerScrollShortcut = shortcut
            refreshCurrentSettings()
        } catch {
            try? registerAnswerScrollHotkeys(previous)
            showFailure(.answerScrollShortcutUnavailable)
            refreshCurrentSettings()
        }
    }

    private func changeAnswerHistoryShortcut(
        _ shortcut: AnswerHistoryShortcut
    ) {
        let previous = preferencesStore.answerHistoryShortcut
        do {
            try registerAnswerHistoryHotkeys(shortcut)
            preferencesStore.answerHistoryShortcut = shortcut
            refreshCurrentSettings()
        } catch {
            try? registerAnswerHistoryHotkeys(previous)
            showFailure(.answerHistoryShortcutUnavailable)
            refreshCurrentSettings()
        }
    }

    private func chooseSpriteSheet() {
        let panel = NSOpenPanel()
        panel.title = "选择 8×8 宠物精灵图"
        panel.message = "请选择正方形 PNG：8 行状态，每行 8 帧动画。"
        panel.allowedContentTypes = [.png]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: settings.window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try self.preferencesStore.importSpriteSheet(from: url)
                    self.applyConfiguredSprite()
                    self.refreshCurrentSettings()
                } catch {
                    self.showSettingsError(
                        title: "无法使用这张精灵图",
                        message: error.localizedDescription
                    )
                }
            }
        }
    }

    private func resetSpriteSheet() {
        do {
            try preferencesStore.resetSpriteSheet()
            try pet.jellyView.setSpriteSheet(at: nil)
            refreshCurrentSettings()
        } catch {
            showSettingsError(
                title: "无法恢复默认外形",
                message: error.localizedDescription
            )
        }
    }

    private func applyConfiguredSprite() {
        do {
            try pet.jellyView.setSpriteSheet(
                at: preferencesStore.spriteSheetURL
            )
        } catch {
            try? pet.jellyView.setSpriteSheet(at: nil)
        }
    }

    private func showSettingsError(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        if settings.window.isVisible {
            alert.beginSheetModal(for: settings.window)
        } else {
            alert.runModal()
        }
    }

    private func selectedNSScreen() -> NSScreen? {
        if let id = preferencesStore.selectedDisplayID,
           let screen = nsScreen(for: id) {
            return screen
        }
        return NSScreen.main
    }

    private func nsScreen(for id: UInt32) -> NSScreen? {
        NSScreen.screens.first { screen in
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            return (screen.deviceDescription[key] as? NSNumber)?
                .uint32Value == id
        }
    }

    private static func soundResourceDirectory() -> URL {
        if let resourceURL = Bundle.main.resourceURL {
            let bundled = resourceURL.appendingPathComponent(
                "Sounds",
                isDirectory: true
            )
            if FileManager.default.fileExists(atPath: bundled.path) {
                return bundled
            }
        }
        return URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath
        ).appendingPathComponent("Resources/Sounds", isDirectory: true)
    }

}
