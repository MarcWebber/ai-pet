import AppKit
import Foundation
import JellyCore
import JellyMac
import UniformTypeIdentifiers

@MainActor
final class AppCoordinator {
    private let preferencesStore: AppPreferencesStore
    private let screen: ScreenDriver
    private let hotkey = CarbonHotkeyService()
    private let pet = PetPanelController()
    private let bubble = BubblePanelController()
    private let settings = SettingsWindowController()
    private let status = StatusItemController()
    private let soundPlayer: SoundPlayer
    private let codexExecutableURL: URL?
    private let session: SessionController
    private var requestTask: Task<Void, Never>?
    private var pendingAnswerQuestion: String?
    private var answerHistoryIndex: Int?
    init() {
        let configurationTemplateURL = Self.packagedResource("JellyPetConfig.json")
            ?? Bundle.module.url(forResource: "JellyPetConfig", withExtension: "json")
        let preferences = AppPreferencesStore(
            configurationTemplateURL: configurationTemplateURL
        )
        preferencesStore = preferences
        codexExecutableURL = CodexExecutableLocator.locate()
        let skillURL = Self.packagedResource("Skills/jellypet-takeover/SKILL.md")
            ?? Bundle.module.url(
            forResource: "SKILL",
            withExtension: "md",
            subdirectory: "Skills/jellypet-takeover"
        )
        let screen = ScreenDriver(
            typingSpeedPercent: { preferences.typingSpeedPercent }
        )
        self.screen = screen
        session = SessionController(
            codex: CodexClient(executableURL: codexExecutableURL, skillURL: skillURL),
            screen: screen
        )
        soundPlayer = SoundPlayer(resourceDirectory: Self.soundResourceDirectory())
    }
    func start() {
        wireActions()
        applyConfiguredSprite()
        pet.show(on: selectedNSScreen())
        pet.jellyView.apply(activity: .idle)
        bubble.setTakeoverShortcutLabel(preferencesStore.globalShortcut.label)
        updateMenu()

        installHotkeys()
    }
    func stop() {
        requestTask?.cancel()
        session.onSnapshot = nil
        if session.snapshot.isActive {
            session.cancel()
        }
        hotkey.unregister()
        settings.hide()
        bubble.hide()
        pet.hide()
    }
    private func wireActions() {
        bubble.anchor = { [weak self] in
            guard let self else { return (.zero, .main) }
            return (self.pet.panel.frame, self.pet.panel.screen)
        }
        session.onSnapshot = { [weak self] in self?.handleSession($0) }
        pet.onClick = { [weak self] in
            guard let self else { return }
            if self.bubble.panel.isVisible {
                self.closeBubble()
                return
            }

            self.pet.jellyView.reactToTap()
            self.soundPlayer.play(.dock)
            self.showComposer()
        }
        pet.onRightClick = { [weak self] in self?.status.showMenu() }
        pet.onDock = { [weak self] in self?.soundPlayer.play(.dock) }
        pet.onFrameChange = { [weak self] in self?.bubble.reposition() }

        bubble.onQuestionSubmit = { [weak self] in self?.performPrimaryAction(task: $0) }
        bubble.onSubmit = { [weak self] in self?.submitFollowUp($0) }
        bubble.onTakeoverSubmit = { [weak self] task in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !(await self.session.addInstruction(task)) {
                    self.performPrimaryAction(task: task)
                }
            }
        }
        bubble.onTakeoverToggle = { [weak self] in self?.changeMode($0, preserving: $1) }
        bubble.onClose = { [weak self] in self?.closeBubble() }

        settings.form.onAction = { [weak self] action in
            guard let self else { return }
            switch action {
            case let .display(id):
                self.preferencesStore.selectedDisplayID = id
                self.pet.placeAtBottomRight(of: self.nsScreen(for: id))
            case let .assistant(value):
                self.preferencesStore.assistantPreferences = value
            case let .activityDetails(value): self.preferencesStore.showActivityDetails = value
            case let .typingSpeed(value):
                self.preferencesStore.typingSpeedPercent = value
            case let .shortcut(value): self.changeShortcut(value)
            case let .answerScrollShortcut(value):
                self.changeAnswerScrollShortcut(value)
            case let .answerHistoryShortcut(value):
                self.changeAnswerHistoryShortcut(value)
            case .chooseSprite: Task { await self.chooseSpriteSheet() }
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
        if session.snapshot.isActive {
            cancelTakeover()
        } else {
            requestTask?.cancel()
            requestTask = Task { [weak self] in await self?.startSession(task: task) }
        }
    }
    private func startSession(task: String?) async {
        do {
            let display = try loadSelectedDisplay()
            if !preferencesStore.takeoverEnabled {
                let question = AppMetadata.boundedUserText(task)
                pendingAnswerQuestion = question
                pet.show(on: nsScreen(for: display.id))
                await session.answer(
                    displayID: display.id, preferences: preferencesStore.assistantPreferences,
                    question: question
                )
                return
            }
            pendingAnswerQuestion = nil
            setActivity(.observing)
            answerHistoryIndex = nil
            bubble.hide()
            NSApp.deactivate()
            try await Task.sleep(nanoseconds: 120_000_000)
            pet.show(on: nsScreen(for: display.id))
            bubble.showWorking(
                previousMessage: "正在绑定当前前台窗口…",
                preferences: preferencesStore.assistantPreferences, takeoverEnabled: true
            )
            let request = TakeoverRequest(
                displayID: display.id, task: AppMetadata.boundedUserText(task),
                assistantPreferences: preferencesStore.assistantPreferences
            )
            settings.hide()
            pet.setClickThrough(true)
            pet.show(on: nsScreen(for: request.displayID))
            await session.start(request,
                initialMessage: "已绑定当前前台窗口；本轮只使用 Accessibility 和全屏观察。")
        } catch is CancellationError {
            return
        } catch let failure as PetFailure {
            showFailure(failure)
        } catch {
            showFailure(.screenActionFailed)
        }
    }
    private func cancelTakeover(message: String = "已由你停止") {
        requestTask?.cancel()
        pet.setClickThrough(false)
        if session.snapshot.isTakingOver {
            session.cancel(message: message)
        } else {
            updateMenu()
        }
    }
    private func handleSession(_ snapshot: SessionSnapshot) {
        switch snapshot.mode {
        case .idle:
            updateMenu()
        case .answering:
            handleAnswer(snapshot)
        case .takingOver:
            guard let request = snapshot.request else { return }
            if snapshot.isActive {
                setActivity(snapshot.activity)
                pet.setClickThrough(true)
                pet.show(on: nsScreen(for: request.displayID))
                bubble.showTakeoverProgress(
                    snapshot, preferences: request.assistantPreferences,
                    showsActivityDetails: preferencesStore.showActivityDetails)
                updateMenu()
            } else {
                finishTakeover(
                    message: snapshot.message ?? "任务已完成。", activity: snapshot.activity,
                    request: request, events: snapshot.events)
            }
        }
    }
    private func handleAnswer(_ snapshot: SessionSnapshot) {
        let preferences = preferencesStore.assistantPreferences
        setActivity(snapshot.activity)
        switch snapshot.activity {
        case .observing:
            answerHistoryIndex = nil
            bubble.hide()
        case .thinking:
            answerHistoryIndex = nil
            bubble.showWorking(
                previousMessage: snapshot.message, preferences: preferences,
                takeoverEnabled: false)
        case .success:
            if let message = snapshot.message {
                recordAnswer(message)
            }
        case .failure:
            pendingAnswerQuestion = nil
            showError(snapshot.message ?? PetFailure.invalidCodexOutput.localizedDescription)
        case .idle, .locating, .acting, .verifying:
            break
        }
    }
    private func recordAnswer(_ message: String) {
        let entry = AnswerHistoryEntry(question: pendingAnswerQuestion, answer: message)
        var history = preferencesStore.answerHistory
        history.append(entry)
        preferencesStore.answerHistory = history
        history = preferencesStore.answerHistory
        let latestIndex = history.count - 1
        answerHistoryIndex = latestIndex
        pendingAnswerQuestion = nil
        showAnswerHistoryEntry(at: latestIndex)
    }
    private func showAnswerHistory(offset: Int) {
        let history = preferencesStore.answerHistory
        guard !session.snapshot.isActive,
              let lastIndex = history.indices.last
        else {
            return
        }
        let target: Int
        if let current = answerHistoryIndex {
            target = min(max(current + offset, 0), lastIndex)
        } else {
            target = lastIndex
        }
        answerHistoryIndex = target
        showAnswerHistoryEntry(at: target)
    }
    private func showAnswerHistoryEntry(at index: Int) {
        let history = preferencesStore.answerHistory
        guard history.indices.contains(index) else { return }
        let entry = history[index]
        if !pet.panel.isVisible {
            pet.show(on: selectedNSScreen())
            updateMenu()
        }
        bubble.showAnswer(
            entry.answer, question: entry.question,
            historyPosition: (index + 1, history.count),
            preferences: preferencesStore.assistantPreferences)
    }
    private func submitFollowUp(_ question: String) {
        guard let question = AppMetadata.boundedUserText(question) else {
            return
        }
        guard session.canFollowUp else {
            performPrimaryAction(task: question)
            return
        }
        pendingAnswerQuestion = question
        requestTask?.cancel()
        requestTask = Task { [weak self] in
            await self?.session.followUp(question)
        }
    }
    private func showComposer(initialText: String = "") {
        answerHistoryIndex = nil
        if !pet.panel.isVisible {
            pet.show(on: selectedNSScreen())
            updateMenu()
        }
        if preferencesStore.takeoverEnabled {
            bubble.showTakeoverComposer(initialTask: initialText)
        } else {
            bubble.showQuestionComposer(initialQuestion: initialText)
        }
    }
    private func changeMode(
        _ takeoverEnabled: Bool,
        preserving text: String
    ) {
        guard !session.snapshot.isTakingOver || !takeoverEnabled else { return }
        preferencesStore.takeoverEnabled = takeoverEnabled
        updateMenu()
        if session.snapshot.isTakingOver { cancelTakeover(message: "已关闭接管") }
        showComposer(initialText: text)
    }
    private func closeBubble() {
        if session.snapshot.isTakingOver {
            cancelTakeover()
            return
        }
        clearAnswer()
        bubble.hide()
    }
    private func togglePet() {
        guard !session.snapshot.isActive else { return }
        if pet.panel.isVisible {
            clearAnswer()
            bubble.hide()
            pet.hide()
        } else {
            pet.show(on: selectedNSScreen())
        }
        updateMenu()
    }
    private func clearAnswer() {
        requestTask?.cancel()
        session.closeAnswer()
        pendingAnswerQuestion = nil
        answerHistoryIndex = nil
    }
    private func setActivity(_ activity: PetActivity) {
        guard pet.jellyView.apply(activity: activity) else { return }
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
        request: TakeoverRequest,
        events: [ActivityEvent]
    ) {
        requestTask = nil
        pet.setClickThrough(false)
        setActivity(activity)
        answerHistoryIndex = nil

        pet.show(
            on: nsScreen(for: request.displayID) ?? selectedNSScreen()
        )
        bubble.showTakeoverResult(
            message,
            events: events,
            isError: activity == .failure,
            preferences: request.assistantPreferences,
            showsActivityDetails: preferencesStore.showActivityDetails
        )
        updateMenu()
    }
    private func showFailure(_ failure: PetFailure) {
        showError(failure.localizedDescription)
    }
    private func showError(_ message: String) {
        setActivity(.failure)
        answerHistoryIndex = nil
        pet.show(on: selectedNSScreen())

        bubble.showError(
            message, preferences: preferencesStore.assistantPreferences,
            takeoverEnabled: preferencesStore.takeoverEnabled)
        updateMenu()
    }
    private func loadSelectedDisplay() throws -> DisplayDescriptor {
        let displays = screen.availableDisplays()
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
    private func refreshCurrentSettings(
        showWindow: Bool = false
    ) {
        if showWindow { settings.show() }
        _ = preferencesStore.reloadConfiguration()
        bubble.setTakeoverShortcutLabel(preferencesStore.globalShortcut.label)
        applyConfiguredSprite()
        let displays = screen.availableDisplays()
        if preferencesStore.selectedDisplayID == nil,
           let display = displays.first(where: \.isPrimary) ?? displays.first {
            preferencesStore.selectedDisplayID = display.id
        }

        let codexStatusText = codexExecutableURL.map {
            "已连接 Codex · \($0.path)"
        } ?? "未找到 Codex CLI，请先安装并登录 Codex"
        let spriteSheetURL = preferencesStore.spriteSheetURL
        let configurationError = preferencesStore.configurationError
        settings.update(
            SettingsViewState(
                displays: displays,
                selectedDisplayID: preferencesStore.selectedDisplayID,
                assistantPreferences: preferencesStore.assistantPreferences,
                showActivityDetails: preferencesStore.showActivityDetails,
                typingSpeedPercent: preferencesStore.typingSpeedPercent,
                globalShortcut: preferencesStore.globalShortcut,
                answerScrollShortcut:
                    preferencesStore.answerScrollShortcut,
                answerHistoryShortcut:
                    preferencesStore.answerHistoryShortcut,
                modelOptions: CodexClient.suggestedModels,
                codexStatusText: codexStatusText,
                configurationURL: preferencesStore.configurationURL,
                configurationError: configurationError,
                spriteSheetURL: spriteSheetURL
            )
        )
    }
    private func updateMenu() {
        let snapshot = session.snapshot
        let isTakingOver = snapshot.isTakingOver
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
    private func installHotkeys() {
        let registrations: [(() throws -> Void, PetFailure)] = [
            ({ try self.registerHotkey(self.preferencesStore.globalShortcut) }, .shortcutUnavailable),
            ({ try self.registerAnswerScrollHotkeys(self.preferencesStore.answerScrollShortcut) }, .answerScrollShortcutUnavailable),
            ({ try self.registerAnswerHistoryHotkeys(self.preferencesStore.answerHistoryShortcut) }, .answerHistoryShortcutUnavailable)
        ]
        for (register, failure) in registrations {
            do { try register() } catch { showFailure(failure) }
        }
    }
    private func registerHotkey(_ shortcut: GlobalShortcut) throws {
        try hotkey.register(shortcut: shortcut) { [weak self] in
            self?.performPrimaryAction()
        }
    }
    private func registerAnswerScrollHotkeys(_ shortcut: ArrowShortcut) throws {
        try hotkey.registerAnswerScrolling(
            shortcut: shortcut,
            onUp: { [weak self] in _ = self?.bubble.scrollAnswerUp() },
            onDown: { [weak self] in _ = self?.bubble.scrollAnswerDown() }
        )
    }
    private func registerAnswerHistoryHotkeys(_ shortcut: ArrowShortcut) throws {
        try hotkey.registerAnswerHistoryNavigation(
            shortcut: shortcut,
            onPrevious: { [weak self] in self?.showAnswerHistory(offset: -1) },
            onNext: { [weak self] in self?.showAnswerHistory(offset: 1) }
        )
    }
    private func changeShortcut(_ shortcut: GlobalShortcut) {
        replaceShortcut(
            shortcut, previous: preferencesStore.globalShortcut, register: registerHotkey,
            save: { preferencesStore.globalShortcut = $0 },
            failure: .shortcutUnavailable
        ) {
            bubble.setTakeoverShortcutLabel(shortcut.label)
            updateMenu()
        }
    }
    private func changeAnswerScrollShortcut(_ shortcut: ArrowShortcut) {
        replaceShortcut(
            shortcut, previous: preferencesStore.answerScrollShortcut,
            register: registerAnswerScrollHotkeys,
            save: { preferencesStore.answerScrollShortcut = $0 },
            failure: .answerScrollShortcutUnavailable
        )
    }
    private func changeAnswerHistoryShortcut(_ shortcut: ArrowShortcut) {
        replaceShortcut(
            shortcut, previous: preferencesStore.answerHistoryShortcut,
            register: registerAnswerHistoryHotkeys,
            save: { preferencesStore.answerHistoryShortcut = $0 },
            failure: .answerHistoryShortcutUnavailable
        )
    }
    private func replaceShortcut<Value>(
        _ value: Value,
        previous: Value,
        register: (Value) throws -> Void,
        save: (Value) -> Void,
        failure: PetFailure,
        afterSave: () -> Void = {}
    ) {
        do {
            try register(value)
            save(value)
            afterSave()
        } catch {
            try? register(previous)
            showFailure(failure)
        }
    }
    private func chooseSpriteSheet() async {
        let panel = NSOpenPanel()
        panel.title = "选择 8×8 宠物精灵图"
        panel.message = "请选择正方形 PNG：8 行状态，每行 8 帧动画。"
        panel.allowedContentTypes = [.png]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard await panel.beginSheetModal(for: settings.window) == .OK,
              let url = panel.url else { return }
        do {
            try preferencesStore.importSpriteSheet(from: url)
            applyConfiguredSprite()
            refreshCurrentSettings()
        } catch {
            showSettingsError("无法使用这张精灵图", error)
        }
    }
    private func resetSpriteSheet() {
        do {
            try preferencesStore.resetSpriteSheet()
            try pet.jellyView.setSpriteSheet(at: nil)
            refreshCurrentSettings()
        } catch {
            showSettingsError("无法恢复默认外形", error)
        }
    }
    private func applyConfiguredSprite() {
        try? pet.jellyView.setSpriteSheet(at: preferencesStore.spriteSheetURL)
    }
    private func showSettingsError(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.beginSheetModal(for: settings.window)
    }
    private func selectedNSScreen() -> NSScreen? {
        preferencesStore.selectedDisplayID.flatMap { nsScreen(for: $0) } ?? NSScreen.main
    }
    private func nsScreen(for id: UInt32) -> NSScreen? {
        NSScreen.screens.first { screen in
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            return (screen.deviceDescription[key] as? NSNumber)?
                .uint32Value == id
        }
    }
    private static func packagedResource(_ path: String) -> URL? {
        let url = Bundle.main.resourceURL?.appendingPathComponent(path)
        return url.flatMap { FileManager.default.isReadableFile(atPath: $0.path) ? $0 : nil }
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
