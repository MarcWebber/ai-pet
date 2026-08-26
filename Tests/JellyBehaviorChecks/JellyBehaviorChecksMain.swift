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
private final class StubCapture: CaptureService {
    let prefersSemanticObservation = false

    func capture(displayID: UInt32) async throws -> CaptureArtifact {
        CaptureArtifact(
            imageURL: URL(fileURLWithPath: "/private/tmp/jelly-memory-check.png"),
            sessionDirectoryURL: URL(fileURLWithPath: "/private/tmp")
        )
    }
}

private final class StubResponder: AIResponder {
    private(set) var requests: [CodexRequest] = []
    private(set) var prepareCount = 0
    private(set) var resetCount = 0

    func respond(
        to request: CodexRequest,
        onTextDelta: @escaping @Sendable (String) -> Void,
        screenToolHandler: ScreenToolHandler?
    ) async throws -> String {
        requests.append(request)
        return "回答 \(requests.count)"
    }

    func steer(_ instruction: String) async throws {}
    func prepareForNextTurn() async { prepareCount += 1 }
    func resetSession() async { resetCount += 1 }
    func cancel() {}
}

private final class StubCleaner: CaptureCleaning {
    func remove(_ artifact: CaptureArtifact) {}
}

@MainActor
private final class StubExecutor: ScreenActionExecuting {
    func execute(
        _ action: ScreenAction,
        snapshot: SemanticSnapshot?,
        displayID: UInt32
    ) async throws {}

    func cancel() {}
}

@main
private enum JellyBehaviorChecksMain {
    @MainActor
    static func main() async throws {
        try runElementLocatorChecks()
        runSemanticHierarchyChecks()
        runTakeoverProgressMonitorChecks()
        runHumanTypingChecks()
        await runActionGroupToolChecks()

        check(
            BrowserSemanticPolicy.isCodeEditorCandidate(
                role: "AXGroup",
                label: "Editor content",
                identifier: "monaco-editor"
            ),
            "Monaco editor group should be an editor candidate"
        )
        check(
            !BrowserSemanticPolicy.isCodeEditorCandidate(
                role: "AXGroup",
                label: "Question panel",
                identifier: "content"
            ),
            "ordinary groups must not become editor candidates"
        )
        check(
            BrowserSemanticPolicy.role(
                "AXWebArea",
                label: "Code editor",
                identifier: "monaco-editor"
            ) == .textField,
            "an editor-labelled web area must be exposed as an input"
        )

        let playwrightSnapshot = PlaywrightSnapshotParser.parse(
            yaml: """
            - heading "代码题" [level=1]
            - textbox "Code editor": "print(1)" [ref=e5] [box=128,90,768,540]
            - checkbox "保存答案" [checked] [ref=e6] [box=900,640,120,40]
            - button "运行" [ref=e8] [box=960,720,160,54]
            """,
            commandOutput: """
            ### Page
            - Page URL: https://example.com/problem/1
            - Page Title: 示例代码题
            """
        )
        check(
            playwrightSnapshot?.pageURL == "https://example.com/problem/1"
                && playwrightSnapshot?.elements.map(\.id) == ["e5", "e6", "e8"]
                && playwrightSnapshot?.elements.first?.value == "print(1)"
                && playwrightSnapshot?.elements[1].value == "checked",
            "Playwright snapshots must preserve page identity, values and refs"
        )
        check(
            PlaywrightBrowserChannel.channel(
                bundleIdentifier: "com.google.Chrome"
            ) == .chrome,
            "Chrome must map to its Playwright attachment channel"
        )
        check(
            PlaywrightBrowserChannel.channel(
                bundleIdentifier: "com.apple.Safari"
            ) == nil,
            "unsupported browsers must use the native route"
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

        let invalidAction = try? JSONDecoder().decode(
            ScreenAction.self,
            from: Data(
                #"{"kind":"click","target":{"source":"visual","x":1001,"y":500}}"#.utf8
            )
        )
        check(
            invalidAction == nil,
            "out-of-range tool arguments must be rejected before execution"
        )
        check(
            AssistantPreferences.default.runtime == .automatic
                && AssistantPreferences.default.model
                    == AssistantPreferences.automaticModel,
            "new installs must let the detected runtime choose its default model"
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
        let legacyConfigurationURL = configurationRoot
            .appendingPathComponent("legacy-config.json")
        try """
        {
          "schemaVersion": 1,
          "conversation": { "historyTurns": 8 },
          "assistant": {
            "runtime": "automatic",
            "model": "auto",
            "reasoningEffort": "high",
            "customInstructions": ""
          },
          "appearance": { "spriteSheet": null },
          "beta": { "screenTakeover": false }
        }
        """.write(
            to: legacyConfigurationURL,
            atomically: true,
            encoding: .utf8
        )
        let legacyPreferences = AppPreferencesStore(
            defaults: defaults,
            configurationURL: legacyConfigurationURL
        )
        let migratedConfiguration = try JSONDecoder().decode(
            JellyConfiguration.self,
            from: Data(contentsOf: legacyConfigurationURL)
        )
        check(
            legacyPreferences.takeoverEnabled
                && migratedConfiguration.schemaVersion
                    == JellyConfiguration.currentSchemaVersion
                && migratedConfiguration.beta.screenTakeover,
            "schema 1 installs must migrate the new default takeover mode once"
        )
        preferences.assistantPreferences = AssistantPreferences(
            runtime: .claudeCode,
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
            reloadedPreferences.assistantPreferences.runtime == .claudeCode
                && reloadedPreferences.assistantPreferences.model == "sonnet"
                && reloadedPreferences.assistantPreferences.reasoningEffort
                    == .medium
                && reloadedPreferences.assistantPreferences
                    .conversationHistoryTurns == 3
                && reloadedPreferences.assistantPreferences
                    .customInstructions == "先给结论",
            "assistant and conversation settings must persist in config.json"
        )
        let history = (0..<10).map { index in
            AnswerHistoryEntry(
                question: "问题 \(index)",
                answer: "回答 \(index)",
                createdAt: Date(timeIntervalSince1970: Double(index))
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
        let coordinator = TakeoverCoordinator(
            capture: StubCapture(),
            responder: responder,
            cleaner: StubCleaner(),
            executor: StubExecutor()
        )
        let screenPreferences = AssistantPreferences(
            runtime: .automatic,
            model: AssistantPreferences.automaticModel,
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
                    $0.conversationHistoryTurns == 3
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

        let fakeRuntimeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "JellyPet-Fake-Runtime-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: fakeRuntimeRoot,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: fakeRuntimeRoot) }
        let fakeCC = fakeRuntimeRoot.appendingPathComponent("cc")
        try "#!/bin/sh\nexit 0\n".write(
            to: fakeCC,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: fakeCC.path
        )
        let detectedWithoutClaude = LocalAgentRuntimeLocator.detect(
            environment: [
                "PATH": fakeRuntimeRoot.path,
                "JELLY_CLAUDE_PATH": fakeCC.path
            ]
        )
        check(
            detectedWithoutClaude.allSatisfy { $0.commandName != "cc" },
            "cc must never be treated as a Claude Code alias"
        )
        let fakeClaude = fakeRuntimeRoot.appendingPathComponent("claude")
        try """
        #!/bin/sh
        while IFS= read -r line; do :; done
        printf '%s\\n' '{"is_error":false,"result":"FAKE_AGENT_OK"}'
        """.write(to: fakeClaude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: fakeClaude.path
        )
        let terminalResponder = TerminalAgentResponder(
            runtime: LocalAgentRuntime(
                kind: .claudeCode,
                executableURL: fakeClaude,
                commandName: "claude"
            ),
            temporaryRoot: fakeRuntimeRoot
        )
        let terminalAnswer = try await terminalResponder.respond(
            to: CodexRequest(
                imageURL: nil,
                prompt: "fake terminal adapter probe",
                runtime: .claudeCode,
                model: AssistantPreferences.automaticModel,
                reasoningEffort: .low
            ),
            onTextDelta: { _ in },
            screenToolHandler: nil
        )
        check(
            terminalAnswer == "FAKE_AGENT_OK",
            "terminal runtimes must launch, receive stdin and decode their result"
        )

        if let requested = ProcessInfo.processInfo.environment[
            "JELLY_REAL_AGENT_SMOKE"
        ], let kind = AgentRuntimeKind(rawValue: requested) {
            let runtimes = LocalAgentRuntimeLocator.detect()
            guard let runtime = runtimes.first(where: { $0.kind == kind }) else {
                fputs("FAILED: requested runtime \(requested) was not detected\n", stderr)
                exit(EXIT_FAILURE)
            }
            let skillURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(
                    "Sources/JellyApp/Resources/Skills/jellypet-takeover/SKILL.md"
                )
            let liveResponder = LocalAgentResponder(
                runtimes: [runtime],
                skillURL: skillURL
            )
            let answer = try await liveResponder.respond(
                to: CodexRequest(
                    imageURL: nil,
                    prompt: "这是 JellyPet 0.9.2 Runtime 连通性测试。只回复 JELLY_RUNTIME_OK。",
                    runtime: kind,
                    model: AssistantPreferences.automaticModel,
                    reasoningEffort: .low
                ),
                onTextDelta: { _ in },
                screenToolHandler: nil
            )
            check(
                answer.trimmingCharacters(in: .whitespacesAndNewlines)
                    == "JELLY_RUNTIME_OK",
                "the selected local Agent Runtime must complete a real model round trip"
            )
            await liveResponder.resetSession()
        }

        print("Jelly behavior checks passed")
    }
}
