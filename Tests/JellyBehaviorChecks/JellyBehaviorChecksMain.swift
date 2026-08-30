import CoreGraphics
import Foundation
import JellyCore
import JellyMac

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAILED: \(message)\n", stderr)
        exit(EXIT_FAILURE)
    }
}

@MainActor
private final class StubScreen: ScreenDriving {
    private(set) var observations = 0
    private(set) var lastDisplayID: UInt32?

    func observe(displayID: UInt32) async throws -> ScreenObservation {
        observations += 1
        lastDisplayID = displayID
        return ScreenObservation(
            semantics: nil,
            screenshotPNG: Data(base64Encoded:
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        )
    }

    func execute(
        _ action: ScreenAction,
        observation: ScreenObservation,
        displayID: UInt32
    ) async throws {}

    func cancel() {}
}

private final class StubResponder: CodexServing {
    private(set) var requests: [CodexRequest] = []
    private(set) var prepareCount = 0
    private(set) var resetCount = 0

    func respond(
        to request: CodexRequest,
        screenToolHandler: ScreenToolHandler?
    ) async throws -> String {
        requests.append(request)
        return "回答 \(requests.count)"
    }

    func steer(_ instruction: String) async throws {}
    func prepare(resetHistory: Bool) async {
        if resetHistory { resetCount += 1 } else { prepareCount += 1 }
    }
    func cancel() {}
}

@main
private enum JellyBehaviorChecksMain {
    @MainActor
    static func main() async throws {
        try runLocatorChecks()
        runTextEditingChecks()
        await runActionGroupToolChecks()

        if ProcessInfo.processInfo.environment["JELLY_VERIFY_LIVE_CAPTURE"] == "1" {
            let screen = ScreenDriver()
            let displays = screen.availableDisplays()
            guard let display = displays.first(where: \.isPrimary)
                ?? displays.first else {
                throw PetFailure.noDisplaysAvailable
            }
            let observation = try await screen.observe(displayID: display.id)
            check(
                !observation.screenshotPNG.isEmpty,
                "live full-display capture must return a non-empty PNG"
            )
        }

        check(
            AccessibilityPolicy.isCodeEditorCandidate(
                role: "AXGroup",
                label: "Editor content",
                identifier: "monaco-editor"
            ),
            "Monaco editor group should be an editor candidate"
        )
        check(
            !AccessibilityPolicy.isCodeEditorCandidate(
                role: "AXGroup",
                label: "Question panel",
                identifier: "content"
            ),
            "ordinary groups must not become editor candidates"
        )
        check(
            AccessibilityPolicy.role(
                "AXWebArea",
                label: "Code editor",
                identifier: "monaco-editor"
            ) == .textField,
            "an editor-labelled web area must be exposed as an input"
        )

        var validNavigation = true
        do {
            try ScreenAction.navigate(url: "https://example.com/path").validate()
        } catch { validNavigation = false }
        check(validNavigation, "ordinary HTTPS navigation must remain available")
        var credentialNavigationRejected = false
        do {
            try ScreenAction.navigate(
                url: "https://user:secret@example.com"
            ).validate()
        } catch { credentialNavigationRejected = true }
        check(
            credentialNavigationRejected,
            "URLs containing credentials must be rejected"
        )

        var invalidActionRejected = false
        do {
            let action = try JSONDecoder().decode(
                ScreenAction.self,
                from: Data(#"{"kind":"click","target":{"x":1001,"y":500}}"#.utf8)
            )
            try action.validate()
        } catch { invalidActionRejected = true }
        check(
            invalidActionRejected,
            "out-of-range tool arguments must be rejected before execution"
        )
        check(
            AssistantPreferences.default.model
                == AssistantPreferences.defaultModel,
            "new installs must use the Codex default model"
        )
        let questionPrompt = ResponsePrompts.screenAnalysis(
            question: "这个页面需要我做什么？",
            customInstructions: ""
        )
        check(
            questionPrompt.contains("用户问题：这个页面需要我做什么？")
                && questionPrompt.contains("只观察附带内容")
                && questionPrompt.contains("全部可见题目")
                && questionPrompt.contains("逐题回答所有可读题目")
                && !questionPrompt.contains("不超过 600"),
            "screen questions must reach Codex without weakening passive mode"
        )
        let defaultsName = "com.local.JellyPet.behavior-checks"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defaults.removePersistentDomain(forName: defaultsName)
        let configurationRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "JellyPet-Configuration-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: configurationRoot) }
        let configurationURL = configurationRoot
            .appendingPathComponent("config.json")
        let preferences = AppPreferencesStore(
            defaults: defaults,
            configurationURL: configurationURL
        )
        check(
            preferences.showActivityDetails,
            "activity details must remain visible by default"
        )
        check(
            preferences.answerScrollShortcut == .controlOptionArrows,
            "answer scrolling must have a usable default shortcut"
        )
        check(
            preferences.answerHistoryShortcut == .controlOptionArrows,
            "answer history must have a usable default shortcut"
        )
        check(
            preferences.takeoverEnabled,
            "new installs must open in Beta takeover mode by default"
        )
        check(
            preferences.typingSpeedPercent
                == TypingRhythm.defaultSpeedPercent,
            "new installs must use the slightly slower human typing speed"
        )
        preferences.typingSpeedPercent = 120
        check(
            preferences.typingSpeedPercent == 120,
            "typing speed must be configurable and persist in user settings"
        )
        preferences.assistantPreferences = AssistantPreferences(
            model: "sonnet",
            reasoningEffort: .medium,
            customInstructions: "先给结论",
            conversationHistoryTurns: 3
        )
        let reloadedPreferences = AppPreferencesStore(
            defaults: defaults,
            configurationURL: configurationURL
        )
        check(
            reloadedPreferences.assistantPreferences.model == "sonnet"
                && reloadedPreferences.assistantPreferences.reasoningEffort
                    == .medium
                && reloadedPreferences.assistantPreferences
                    .conversationHistoryTurns == 3
                && reloadedPreferences.assistantPreferences
                    .customInstructions == "先给结论"
                && reloadedPreferences.typingSpeedPercent == 120,
            "assistant, conversation and typing settings must persist"
        )
        let history = (0..<10).map { index in
            AnswerHistoryEntry(
                question: "问题 \(index)",
                answer: "回答 \(index)"
            )
        }
        preferences.answerHistory = history
        let storedHistory = preferences.answerHistory
        check(
            storedHistory.count == 3
                && storedHistory.first?.question == "问题 7"
                && storedHistory.last?.answer == "回答 9",
            "answer history must follow the configured conversation limit"
        )
        let spriteSource = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath
        ).appendingPathComponent(
            "Sources/JellyApp/Resources/PetSprites.png"
        )
        try preferences.importSpriteSheet(from: spriteSource)
        check(
            preferences.spriteSheetURL != nil,
            "a valid 8x8 PNG sprite sheet must be importable"
        )
        try preferences.resetSpriteSheet()
        check(
            preferences.spriteSheetURL == nil,
            "the custom sprite sheet must be resettable"
        )
        let responder = StubResponder()
        let screen = StubScreen()
        let coordinator = SessionController(codex: responder, screen: screen)
        let screenPreferences = AssistantPreferences(
            model: AssistantPreferences.defaultModel,
            reasoningEffort: .high,
            conversationHistoryTurns: 3
        )
        await coordinator.answer(
            displayID: 1,
            preferences: screenPreferences,
            question: "第一张截图"
        )
        await coordinator.answer(
            displayID: 1,
            preferences: screenPreferences,
            question: "第二张截图"
        )
        check(
            responder.requests.count == 2
                && responder.requests.allSatisfy {
                    $0.preferences.conversationHistoryTurns == 3
                }
                && responder.prepareCount == 2
                && responder.resetCount == 0
                && coordinator.canFollowUp,
            "consecutive screenshot questions must preserve the Codex session"
        )
        coordinator.closeAnswer()
        check(
            !coordinator.canFollowUp,
            "closing an answer must clear follow-up context without deleting history"
        )
        defaults.removePersistentDomain(forName: defaultsName)

        let fakeCodexRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "JellyPet-Fake-Codex-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: fakeCodexRoot,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: fakeCodexRoot) }
        let fakeCodex = fakeCodexRoot.appendingPathComponent("codex")
        try "#!/bin/sh\nexit 0\n".write(
            to: fakeCodex,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: fakeCodex.path
        )
        let locatedCodex = CodexExecutableLocator.locate(
            environment: ["PATH": fakeCodexRoot.path]
        )
        check(
            locatedCodex?.standardizedFileURL == fakeCodex.standardizedFileURL,
            "Codex must be located from PATH"
        )

        if ProcessInfo.processInfo.environment["JELLY_REAL_CODEX_SMOKE"] == "1" {
            guard let executableURL = CodexExecutableLocator.locate() else {
                fputs("FAILED: Codex was not detected\n", stderr)
                exit(EXIT_FAILURE)
            }
            let skillURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(
                    "Sources/JellyApp/Resources/Skills/jellypet-takeover/SKILL.md"
                )
            let liveResponder = CodexClient(
                executableURL: executableURL,
                skillURL: skillURL
            )
            let answer = try await liveResponder.respond(
                to: CodexRequest(
                    imagePNG: nil,
                    prompt: "这是 JellyPet 0.9.2 Codex 连通性测试。只回复 JELLY_CODEX_OK。",
                    preferences: .init(
                        model: AssistantPreferences.defaultModel,
                        reasoningEffort: .low
                    )
                ),
                screenToolHandler: nil
            )
            check(
                answer.trimmingCharacters(in: .whitespacesAndNewlines)
                    == "JELLY_CODEX_OK",
                "Codex must complete a real model round trip"
            )
            await liveResponder.prepare(resetHistory: true)
        }

        if ProcessInfo.processInfo.environment["JELLY_REAL_CODEX_TOOL_SMOKE"] == "1" {
            guard let executableURL = CodexExecutableLocator.locate() else {
                fputs("FAILED: Codex was not detected\n", stderr)
                exit(EXIT_FAILURE)
            }
            let skillURL = URL(
                fileURLWithPath: FileManager.default.currentDirectoryPath
            ).appendingPathComponent(
                "Sources/JellyApp/Resources/Skills/jellypet-takeover/SKILL.md"
            )
            let probe = StubScreen()
            let controller = SessionController(
                codex: CodexClient(
                    executableURL: executableURL,
                    skillURL: skillURL
                ),
                screen: probe
            )
            await controller.start(TakeoverRequest(
                displayID: 73,
                task: "先且只调用一次 observe；观察成功后只回复 JELLY_TOOL_OK，不执行其他动作。",
                assistantPreferences: .init(
                    model: AssistantPreferences.defaultModel,
                    reasoningEffort: .low
                )
            ))
            check(
                probe.lastDisplayID == 73
                    && controller.snapshot.activity == .success
                    && controller.snapshot.message?.contains("JELLY_TOOL_OK") == true,
                "Codex dynamic screen tools must complete a real observe round trip"
            )
        }

        print("Jelly behavior checks passed")
    }
}
