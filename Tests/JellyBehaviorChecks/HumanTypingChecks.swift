import JellyCore

func runHumanTypingChecks() {
    let source = String(repeating: "int answer = value + 1; // update\n", count: 12)
    let strokes = HumanTypingPlan.strokes(for: source, seed: 42)
    check(
        strokes.count == source.count
            && strokes.allSatisfy { $0.text.count == 1 },
        "human typing must emit one visible character at a time"
    )
    check(
        strokes.filter { $0.mistypedText != nil }.count >= 2,
        "long code should occasionally include a corrected typing mistake"
    )
    check(
        strokes.allSatisfy {
            (45...360).contains($0.delayAfterMilliseconds)
                && (85...180).contains($0.mistakeDelayMilliseconds)
                && (60...135).contains($0.correctionDelayMilliseconds)
        },
        "typing and correction delays must stay inside the natural preset"
    )

    var visible = ""
    for stroke in strokes {
        if let mistake = stroke.mistypedText {
            visible += mistake
            visible.removeLast()
        }
        visible += stroke.text
    }
    check(
        visible == source,
        "mistakes and backspaces must preserve the requested final text"
    )

    let short = HumanTypingPlan.strokes(for: "return value;", seed: 7)
    check(
        short.allSatisfy { $0.mistypedText == nil },
        "short form values should not be forced to contain a fake mistake"
    )
}
