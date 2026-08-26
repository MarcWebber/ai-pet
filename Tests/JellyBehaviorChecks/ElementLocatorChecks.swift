import Foundation
import JellyCore

func runElementLocatorChecks() throws {
    let scopedSnapshot = locatorSnapshot(elements: [
        locatorElement("e1", role: .textField, label: "Search people"),
        locatorElement("e2", role: .button, label: "Send")
    ])
    let scoped = SemanticElementLocator(
        application: SemanticTextMatcher("Messages"),
        window: SemanticTextMatcher("Alice", mode: .contains),
        pageURL: SemanticTextMatcher("chat/42", mode: .contains),
        role: .textField,
        label: SemanticTextMatcher("Search", mode: .prefix)
    )
    check(
        resolvedID(scoped, in: scopedSnapshot) == "e1",
        "stable locators must resolve within the current app, window, and page"
    )

    let ordered = locatorSnapshot(elements: [
        locatorElement("bottom", role: .button, label: "Open", y: 500),
        locatorElement("top", role: .button, label: "Open", y: 100)
    ])
    let ambiguous = SemanticElementLocator(
        role: .button,
        label: SemanticTextMatcher("Open")
    )
    check(
        resolvedID(ambiguous, in: ordered) == nil
            && resolvedID(SemanticElementLocator(
                role: .button,
                label: SemanticTextMatcher("Open"),
                ordinal: 1
            ), in: ordered) == "bottom",
        "ambiguous locators must require an explicit discriminator"
    )

    let hierarchy = locatorSnapshot(elements: [
        locatorElement("dialog", role: .scrollArea, label: "Compose message"),
        locatorElement("recipient", parentID: "dialog", role: .textField, label: "To"),
        locatorElement("other", role: .textField, label: "To")
    ])
    check(
        resolvedID(SemanticElementLocator(
            role: .textField,
            label: SemanticTextMatcher("To"),
            ancestorRole: .scrollArea,
            ancestorLabel: SemanticTextMatcher("Compose message")
        ), in: hierarchy) == "recipient",
        "ancestor constraints must distinguish equivalent fields"
    )

    let send = SemanticElementLocator(
        role: .button,
        label: SemanticTextMatcher("Send")
    )
    let first = locatorSnapshot(elements: [
        locatorElement("e9", role: .button, label: "Send")
    ])
    let next = locatorSnapshot(elements: [
        locatorElement("e2", role: .button, label: "Send")
    ])
    check(
        resolvedID(send, in: first) == "e9"
            && resolvedID(send, in: next) == "e2",
        "stable locators must resolve a fresh element ID after every observation"
    )

    check(
        resolvedID(SemanticElementLocator(
            application: SemanticTextMatcher("Mail"),
            role: .button
        ), in: first) == nil
            && resolvedID(SemanticElementLocator(), in: first) == nil,
        "scope mismatches and empty locators must not resolve"
    )

    let configured = SemanticElementLocator(
        application: SemanticTextMatcher("Messages"),
        role: .button,
        label: SemanticTextMatcher("Send"),
        ordinal: 0
    )
    let roundTrip = try JSONDecoder().decode(
        SemanticElementLocator.self,
        from: JSONEncoder().encode(configured)
    )
    check(roundTrip == configured, "locators must round-trip through tool JSON")
    let minimal = try JSONDecoder().decode(
        SemanticElementLocator.self,
        from: Data(#"{"role":"button"}"#.utf8)
    )
    check(minimal.requiresEnabled == true, "locators must require enabled elements by default")

    let enabled = locatorSnapshot(elements: [
        locatorElement("enabled", role: .button, label: "Send"),
        locatorElement("disabled", role: .button, label: "Send", isEnabled: false)
    ])
    check(
        resolvedID(send, in: enabled) == "enabled"
            && resolvedID(SemanticElementLocator(
                role: .button,
                label: SemanticTextMatcher("Send"),
                requiresEnabled: false
            ), in: enabled) == nil,
        "disabled elements must be excluded unless explicitly allowed"
    )

    let locatorAction = ScreenAction.click(.locator(send))
    let decodedAction = try JSONDecoder().decode(
        ScreenAction.self,
        from: JSONEncoder().encode(locatorAction)
    )
    check(
        decodedAction == locatorAction
            && resolvedID(send, in: first) == "e9",
        "screen actions must preserve and resolve stable locator targets"
    )
}

private func resolvedID(
    _ locator: SemanticElementLocator,
    in snapshot: SemanticSnapshot
) -> String? {
    guard let action = try? ScreenAction.click(.locator(locator))
        .resolvingSemanticTargets(in: snapshot),
          case let .click(.element(elementID)) = action else { return nil }
    return elementID
}

private func locatorSnapshot(elements: [SemanticElement]) -> SemanticSnapshot {
    SemanticSnapshot(
        applicationName: "Messages",
        windowTitle: "Chat with Alice",
        pageURL: "https://example.test/chat/42",
        elements: elements
    )
}

private func locatorElement(
    _ id: String,
    parentID: String? = nil,
    role: SemanticElementRole,
    label: String,
    y: Int = 0,
    isEnabled: Bool = true
) -> SemanticElement {
    SemanticElement(
        id: id,
        parentID: parentID,
        role: role,
        label: label,
        frame: SemanticRect(x: 10, y: y, width: 100, height: 30),
        isEnabled: isEnabled
    )
}
