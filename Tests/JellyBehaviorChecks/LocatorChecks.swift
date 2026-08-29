import Foundation
import JellyCore

func runLocatorChecks() throws {
    let scopedSnapshot = locatorSnapshot(elements: [
        locatorElement("e1", role: .textField, label: "Search people"),
        locatorElement("e2", role: .button, label: "Send")
    ])
    let scoped = ElementLocator(
        application: TextMatcher("Messages"),
        window: TextMatcher("Alice", mode: .contains),
        pageURL: TextMatcher("chat/42", mode: .contains),
        role: .textField,
        label: TextMatcher("Search", mode: .prefix)
    )
    check(
        resolvedID(scoped, in: scopedSnapshot) == "e1",
        "stable locators must resolve within the current app, window, and page"
    )

    let ordered = locatorSnapshot(elements: [
        locatorElement("bottom", role: .button, label: "Open", y: 500),
        locatorElement("top", role: .button, label: "Open", y: 100)
    ])
    let ambiguous = ElementLocator(
        role: .button,
        label: TextMatcher("Open")
    )
    check(
        resolvedID(ambiguous, in: ordered) == nil
            && resolvedID(ElementLocator(
                role: .button,
                label: TextMatcher("Open"),
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
        resolvedID(ElementLocator(
            role: .textField,
            label: TextMatcher("To"),
            ancestorRole: .scrollArea,
            ancestorLabel: TextMatcher("Compose message")
        ), in: hierarchy) == "recipient",
        "ancestor constraints must distinguish equivalent fields"
    )

    let send = ElementLocator(
        role: .button,
        label: TextMatcher("Send")
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
        resolvedID(ElementLocator(
            application: TextMatcher("Mail"),
            role: .button
        ), in: first) == nil
            && resolvedID(ElementLocator(), in: first) == nil,
        "scope mismatches and empty locators must not resolve"
    )

    let configured = ElementLocator(
        application: TextMatcher("Messages"),
        role: .button,
        label: TextMatcher("Send"),
        ordinal: 0
    )
    let roundTrip = try JSONDecoder().decode(
        ElementLocator.self,
        from: JSONEncoder().encode(configured)
    )
    check(roundTrip == configured, "locators must round-trip through tool JSON")
    let minimal = try JSONDecoder().decode(
        ElementLocator.self,
        from: Data(#"{"role":"button"}"#.utf8)
    )
    check(minimal.requiresEnabled == true, "locators must require enabled elements by default")

    let enabled = locatorSnapshot(elements: [
        locatorElement("enabled", role: .button, label: "Send"),
        locatorElement("disabled", role: .button, label: "Send", isEnabled: false)
    ])
    check(
        resolvedID(send, in: enabled) == "enabled"
            && resolvedID(ElementLocator(
                role: .button,
                label: TextMatcher("Send"),
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
    _ locator: ElementLocator,
    in snapshot: ScreenSemantics
) -> String? {
    guard let action = try? ScreenAction.click(.locator(locator))
        .resolvingSemanticTargets(in: snapshot),
          case let .click(.element(elementID)) = action else { return nil }
    return elementID
}

private func locatorSnapshot(elements: [ScreenElement]) -> ScreenSemantics {
    ScreenSemantics(
        applicationName: "Messages",
        windowTitle: "Chat with Alice",
        pageURL: "https://example.test/chat/42",
        elements: elements
    )
}

private func locatorElement(
    _ id: String,
    parentID: String? = nil,
    role: ElementRole,
    label: String,
    y: Int = 0,
    isEnabled: Bool = true
) -> ScreenElement {
    ScreenElement(
        id: id,
        parentID: parentID,
        role: role,
        label: label,
        frame: NormalizedRect(x: 10, y: y, width: 100, height: 30),
        isEnabled: isEnabled
    )
}
