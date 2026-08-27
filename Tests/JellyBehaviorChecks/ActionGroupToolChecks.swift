import Foundation
import JellyCore

@MainActor
private final class ActionGroupSurface:
    CaptureService,
    SemanticContextProviding,
    ScreenActionExecuting
{
    let prefersSemanticObservation = true
    private(set) var generation = 0
    private(set) var inputValue = ""
    private(set) var activationCount = 0
    private(set) var resolvedElementIDs: [String] = []

    func capture(displayID: UInt32) async throws -> CaptureArtifact {
        throw PetFailure.captureFailed
    }

    func snapshot(displayID: UInt32) async -> SemanticSnapshot? {
        generation += 1
        var elements = [
            SemanticElement(
                id: "input-\(generation)",
                role: .textField,
                label: "Message",
                value: inputValue,
                frame: .init(x: 100, y: 100, width: 400, height: 80),
                isEnabled: true
            ),
            SemanticElement(
                id: "send-\(generation)",
                role: .button,
                label: "Send",
                frame: .init(x: 520, y: 100, width: 100, height: 80),
                isEnabled: true
            )
        ]
        if activationCount >= 1 {
            elements.append(SemanticElement(
                id: "done-\(generation)",
                role: .button,
                label: "Done",
                frame: .init(x: 100, y: 220, width: 120, height: 60),
                isEnabled: true
            ))
        }
        if activationCount >= 2 {
            elements.append(SemanticElement(
                id: "done-again-\(generation)",
                role: .button,
                label: "Done again",
                frame: .init(x: 240, y: 220, width: 160, height: 60),
                isEnabled: true
            ))
        }
        return SemanticSnapshot(
            applicationName: "ActionGroupChecks",
            windowTitle: "Test",
            elements: elements
        )
    }

    func execute(
        _ action: ScreenAction,
        snapshot: SemanticSnapshot?,
        displayID: UInt32
    ) async throws {
        switch action {
        case let .typeText(target, text):
            guard case let .element(elementID) = target,
                  elementID == snapshot?.elements.first(where: { $0.label == "Message" })?.id
            else { throw PetFailure.semanticTargetUnavailable }
            resolvedElementIDs.append(elementID)
            inputValue = text
        case let .click(target):
            guard case let .element(elementID) = target,
                  elementID == snapshot?.elements.first(where: { $0.label == "Send" })?.id
            else { throw PetFailure.semanticTargetUnavailable }
            resolvedElementIDs.append(elementID)
            activationCount += 1
        default:
            throw PetFailure.invalidScreenAction
        }
    }

    func cancel() {}
}

private final class ActionGroupResponder: AIResponder {
    enum Scenario {
        case uncertainRepeat, verifiedRepeat, retryAfterChange, repeatedObserve
    }

    private let scenario: Scenario
    private(set) var results: [ScreenToolResult] = []

    init(_ scenario: Scenario) { self.scenario = scenario }

    func respond(
        to request: CodexRequest,
        onTextDelta: @escaping @Sendable (String) -> Void,
        screenToolHandler: ScreenToolHandler?
    ) async throws -> String {
        guard let screenToolHandler else { throw PetFailure.agentRuntimeUnavailable("Agent") }
        let send = SemanticElementLocator(
            role: .button,
            label: SemanticTextMatcher("Send")
        )
        switch scenario {
        case .repeatedObserve:
            results.append(await screenToolHandler(.observe))
            results.append(await screenToolHandler(.observe))
        case .uncertainRepeat:
            let expected = SemanticElementLocator(
                application: SemanticTextMatcher("Another App"),
                role: .button,
                label: SemanticTextMatcher("Never appears")
            )
            results.append(await screenToolHandler(.activateAndVerify(.init(
                targetLocator: send,
                expectedLocator: expected,
                expectedState: .absent
            ))))
            results.append(await screenToolHandler(.activateAndVerify(.init(
                targetLocator: SemanticElementLocator(
                    application: SemanticTextMatcher(
                        "actiongroup",
                        mode: .prefix
                    ),
                    role: .button,
                    label: SemanticTextMatcher("sen", mode: .contains)
                ),
                expectedLocator: expected,
                expectedState: .absent
            ))))
        case .verifiedRepeat:
            for expectedLabel in ["Done", "Done again"] {
                results.append(await screenToolHandler(.activateAndVerify(.init(
                    targetLocator: send,
                    expectedLocator: SemanticElementLocator(
                        role: .button,
                        label: SemanticTextMatcher(expectedLabel)
                    )
                ))))
            }
        case .retryAfterChange:
            let doneAgain = SemanticElementLocator(
                role: .button,
                label: SemanticTextMatcher("Done again")
            )
            results.append(await screenToolHandler(.activateAndVerify(.init(
                targetLocator: send,
                expectedLocator: doneAgain
            ))))
            results.append(await screenToolHandler(.perform(.typeText(
                target: .locator(SemanticElementLocator(
                    role: .textField,
                    label: SemanticTextMatcher("Message")
                )),
                text: "changed context"
            ))))
            results.append(await screenToolHandler(.activateAndVerify(.init(
                targetLocator: send,
                expectedLocator: doneAgain
            ))))
        }
        return "done"
    }

    func steer(_ instruction: String) async throws {}
    func prepareForNextTurn() async {}
    func resetSession() async {}
    func cancel() {}
}

private final class ActionGroupCleaner: CaptureCleaning {
    func remove(_ artifact: CaptureArtifact) {}
}

@MainActor
private func runActionGroupScenario(
    _ scenario: ActionGroupResponder.Scenario
) async -> (surface: ActionGroupSurface, responder: ActionGroupResponder) {
    let surface = ActionGroupSurface()
    let responder = ActionGroupResponder(scenario)
    let coordinator = TakeoverCoordinator(
        capture: surface,
        responder: responder,
        cleaner: ActionGroupCleaner(),
        executor: surface,
        semanticProvider: surface
    )
    await coordinator.start(TakeoverRequest(
        displayID: 1,
        task: "action group checks",
        assistantPreferences: AssistantPreferences(
            runtime: .automatic,
            model: AssistantPreferences.automaticModel,
            reasoningEffort: .high
        )
    ))
    return (surface, responder)
}

@MainActor
func runActionGroupToolChecks() async {
    let observed = await runActionGroupScenario(.repeatedObserve)
    check(
        observed.responder.results.count == 2
            && observed.responder.results[0].success
            && !observed.responder.results[1].success
            && observed.surface.generation == 1,
        "a repeated observe without an intervening action must not capture again"
    )

    let uncertain = await runActionGroupScenario(.uncertainRepeat)
    check(
        uncertain.responder.results.count == 2
            && uncertain.responder.results.allSatisfy { !$0.success }
            && uncertain.surface.activationCount == 1,
        "activate-and-verify must not treat a scope mismatch as proof of absence or allow a repeated consequential click"
    )

    let repeated = await runActionGroupScenario(.verifiedRepeat)
    check(
        repeated.responder.results.count == 2
            && repeated.responder.results.allSatisfy(\.success)
            && repeated.surface.activationCount == 2
            && Set(repeated.surface.resolvedElementIDs).count == 2,
        "a target must become reusable after the previous activation was verified"
    )

    let changed = await runActionGroupScenario(.retryAfterChange)
    check(
        changed.responder.results.count == 3
            && !changed.responder.results[0].success
            && changed.responder.results[1].success
            && changed.responder.results[2].success
            && changed.surface.activationCount == 2,
        "an uncertain target must become retryable after another verified action changes the interface"
    )
}
