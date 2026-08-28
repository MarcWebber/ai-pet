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

private final class FullDisplayCaptureProbe: ScreenCapturingBackend {
    private(set) var request: (displayID: UInt32, maximumDimension: Int)?

    func availableDisplays() async throws -> [DisplayDescriptor] { [] }

    func captureFullDisplay(
        displayID: UInt32,
        maximumDimension: Int
    ) async throws -> CGImage {
        request = (displayID, maximumDimension)
        guard let context = CGContext(
            data: nil,
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = context.makeImage() else {
            throw PetFailure.captureFailed
        }
        return image
    }
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
        runHumanTypingChecks()
        await runActionGroupToolChecks()

        let captureProbe = FullDisplayCaptureProbe()
        let captureService = ScreenCaptureService(backend: captureProbe)
        let captureArtifact = try await captureService.capture(displayID: 73)
        defer { CaptureArtifactCleaner().remove(captureArtifact) }
        check(
            captureProbe.request?.displayID == 73
                && captureProbe.request?.maximumDimension
                    == AppMetadata.maximumScreenshotDimension,
            "screen capture must request one exact full display without a region"
        )
        check(
            FileManager.default.fileExists(atPath: captureArtifact.imageURL.path),
            "full-display capture must produce a PNG artifact"
        )
        if ProcessInfo.processInfo.environment["JELLY_VERIFY_LIVE_CAPTURE"] == "1" {
            let liveBackend = ScreenCaptureCLIBackend()
            let displays = try await liveBackend.availableDisplays()
            guard let display = displays.first(where: \.isPrimary)
                ?? displays.first else {
                throw PetFailure.noDisplaysAvailable
            }
            let image = try await liveBackend.captureFullDisplay(
                displayID: display.id,
                maximumDimension: AppMetadata.maximumScreenshotDimension
            )
            check(
                image.width > 0 && image.height > 0,
                "live full-display capture must return a non-empty image"
            )
        }

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
                == HumanTypingPlan.defaultSpeedPercent,
            "new installs must use the slightly slower human typing speed"
        )
        preferences.typingSpeedPercent = 120
        check(
            preferences.typingSpeedPercent == 120,
            "typing speed must be configurable and persist in user settings"
        )
        let legacyConfigurationURL = configurationRoot
            .appendingPathComponent("legacy-config.json")
        try """
        {
          "schemaVersion": 1,
          "conversation": { "historyTurns": 8 },
          "assistant": {
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
            let liveResponder = CodexProcessResponder(
                executableURL: executableURL,
                skillURL: skillURL
            )
            let answer = try await liveResponder.respond(
                to: CodexRequest(
                    imageURL: nil,
                    prompt: "这是 JellyPet 0.9.2 Codex 连通性测试。只回复 JELLY_CODEX_OK。",
                    model: AssistantPreferences.defaultModel,
                    reasoningEffort: .low
                ),
                onTextDelta: { _ in },
                screenToolHandler: nil
            )
            check(
                answer.trimmingCharacters(in: .whitespacesAndNewlines)
                    == "JELLY_CODEX_OK",
                "Codex must complete a real model round trip"
            )
            await liveResponder.resetSession()
        }

        print("Jelly behavior checks passed")
    }
}
