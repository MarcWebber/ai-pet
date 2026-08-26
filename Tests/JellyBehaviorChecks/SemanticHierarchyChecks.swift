import JellyCore
import JellyMac

func runSemanticHierarchyChecks() {
    check(
        BrowserSemanticPolicy.role("AXHeading") == .heading
            && BrowserSemanticPolicy.role("AXStaticText") == .staticText
            && BrowserSemanticPolicy.role("AXRow") == .row
            && BrowserSemanticPolicy.role("AXCell") == .cell,
        "native accessibility structure roles must be preserved for locators"
    )

    let snapshot = PlaywrightSnapshotParser.parse(
        yaml: """
        - dialog "Compose" [ref=e1] [box=40,40,800,700]
          - group "Recipient" [ref=e2] [box=80,100,700,120]
            - textbox "To" [ref=e3] [box=100,130,500,50]
          - list "Suggestions" [ref=e4] [box=80,230,700,280]
            - listitem "Alice" [ref=e5] [box=100,250,600,60]
              - button "Alice" [ref=e6] [box=120,260,300,40]
        - button "Outside" [ref=e7] [box=900,60,200,60]
        """,
        commandOutput: """
        ### Page
        - Page URL: https://example.com/messages
        - Page Title: Messages
        """
    )
    let elements = Dictionary(
        uniqueKeysWithValues: (snapshot?.elements ?? []).map { ($0.id, $0) }
    )
    check(
        elements["e1"]?.parentID == nil
            && elements["e2"]?.parentID == "e1"
            && elements["e3"]?.parentID == "e2"
            && elements["e4"]?.parentID == "e1"
            && elements["e5"]?.parentID == "e4"
            && elements["e6"]?.parentID == "e5"
            && elements["e7"]?.parentID == nil,
        "Playwright snapshots must retain observation-scoped semantic ancestry"
    )

    let resolved = snapshot.flatMap {
        try? ScreenAction.click(.locator(
            SemanticElementLocator(
                role: .button,
                label: SemanticTextMatcher("Alice"),
                ancestorRole: .list,
                ancestorLabel: SemanticTextMatcher("Suggestions")
            )
        )).resolvingSemanticTargets(in: $0)
    }
    check(
        resolved == .click(.element(elementID: "e6")),
        "ancestor locators must resolve against hierarchy emitted by Playwright"
    )

    let oversized = (1...300).map {
        "- button \"Button \($0)\" [ref=e\($0)] [box=10,10,20,20]"
    }.joined(separator: "\n")
    check(
        PlaywrightSnapshotParser.parse(yaml: oversized, commandOutput: "")?
            .elements.count == 250,
        "semantic hierarchy must retain the 250 element observation bound"
    )
}
