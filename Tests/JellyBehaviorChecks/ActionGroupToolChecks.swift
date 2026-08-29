import Foundation
import JellyCore

@MainActor
private final class ActionGroupSurface: ScreenDriving {
    private(set) var generation = 0
    private(set) var inputValue = ""
    private(set) var activationCount = 0
    private(set) var resolvedElementIDs: [String] = []

    func observe(displayID: UInt32) async throws -> ScreenObservation {
        generation += 1
        var elements = [
            ScreenElement(
                id: "input-\(generation)",
                role: .textField,
                label: "Message",
                value: inputValue,
                frame: .init(x: 100, y: 100, width: 400, height: 80),
                isEnabled: true
            ),
            ScreenElement(
                id: "send-\(generation)",
                role: .button,
                label: "Send",
                frame: .init(x: 520, y: 100, width: 100, height: 80),
                isEnabled: true
            )
        ]
        if activationCount >= 1 {
            elements.append(ScreenElement(
                id: "done-\(generation)",
                role: .button,
                label: "Done",
                frame: .init(x: 100, y: 220, width: 120, height: 60),
                isEnabled: true
            ))
        }
        if activationCount >= 2 {
            elements.append(ScreenElement(
                id: "done-again-\(generation)",
                role: .button,
                label: "Done again",
                frame: .init(x: 240, y: 220, width: 160, height: 60),
                isEnabled: true
            ))
        }
        return ScreenObservation(
            displayID: displayID,
            semantics: ScreenSemantics(
                applicationName: "ActionGroupChecks",
                windowTitle: "Test",
                elements: elements
            ),
            screenshotPNG: Data([0x89, 0x50, 0x4E, 0x47])
        )
    }

    func execute(
        _ action: ScreenAction,
        observation: ScreenObservation,
        displayID: UInt32
    ) async throws {
        let snapshot = observation.semantics
        switch action {
        case let .typeText(target, text):
            guard case let .element(elementID) = target,
                  elementID == snapshot?.elements.first(where: {
                      $0.label == "Message"
                  })?.id else { throw PetFailure.semanticTargetUnavailable }
            resolvedElementIDs.append(elementID)
            inputValue = text
        case let .click(target):
            guard case let .element(elementID) = target,
                  elementID == snapshot?.elements.first(where: {
                      $0.label == "Send"
                  })?.id else { throw PetFailure.semanticTargetUnavailable }
            resolvedElementIDs.append(elementID)
            activationCount += 1
        default:
            throw PetFailure.invalidScreenAction
        }
    }

    func cancel() {}
}

private final class ActionGroupCodex: CodexServing {
    enum Scenario { case repeatedObserve, verifyOnce, retryAfterFailure }

    private let scenario: Scenario
    private(set) var results: [ScreenToolResult] = []

    init(_ scenario: Scenario) { self.scenario = scenario }

    func respond(
        to request: CodexRequest,
        onTextDelta: @escaping @Sendable (String) -> Void,
        screenToolHandler: ScreenToolHandler?
    ) async throws -> String {
        guard let tool = screenToolHandler else {
            throw PetFailure.codexUnavailable
        }
        let send = ElementLocator(
            role: .button,
            label: TextMatcher("Send")
        )
        switch scenario {
        case .repeatedObserve:
            results.append(await tool(.observe))
            results.append(await tool(.observe))
        case .verifyOnce:
            results.append(await tool(.activateAndVerify(.init(
                targetLocator: send,
                expectedLocator: ElementLocator(
                    role: .button,
                    label: TextMatcher("Done")
                )
            ))))
        case .retryAfterFailure:
            let expected = ElementLocator(
                role: .button,
                label: TextMatcher("Done again")
            )
            results.append(await tool(.activateAndVerify(.init(
                targetLocator: send,
                expectedLocator: expected
            ))))
            results.append(await tool(.activateAndVerify(.init(
                targetLocator: send,
                expectedLocator: expected
            ))))
        }
        return "done"
    }

    func steer(_ instruction: String) async throws {}
    func prepareForNextTurn() async {}
    func resetSession() async {}
    func cancel() {}
}

@MainActor
private func runScenario(
    _ scenario: ActionGroupCodex.Scenario
) async -> (ActionGroupSurface, ActionGroupCodex) {
    let screen = ActionGroupSurface()
    let codex = ActionGroupCodex(scenario)
    let controller = SessionController(codex: codex, screen: screen)
    await controller.start(TakeoverRequest(
        displayID: 1,
        task: "action group checks",
        assistantPreferences: .init(
            model: AssistantPreferences.defaultModel,
            reasoningEffort: .high
        )
    ))
    return (screen, codex)
}

@MainActor
func runActionGroupToolChecks() async {
    let observed = await runScenario(.repeatedObserve)
    check(
        observed.1.results.count == 2
            && observed.1.results.allSatisfy(\.success)
            && observed.0.generation == 2,
        "every explicit observe must refresh the screen so manual edits are visible"
    )

    let once = await runScenario(.verifyOnce)
    check(
        once.1.results.count == 1
            && once.1.results[0].success
            && once.0.activationCount == 1
            && once.0.generation == 2,
        "activate-and-verify must observe, activate exactly once, then observe again"
    )

    let retry = await runScenario(.retryAfterFailure)
    check(
        retry.1.results.count == 2
            && !retry.1.results[0].success
            && retry.1.results[1].success
            && retry.0.activationCount == 2
            && retry.0.generation == 4,
        "a failed verification must report reality without installing a retry gate"
    )
}
