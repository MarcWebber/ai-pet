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

    let starter = """
    class Solution {
        public:
            int solve(int value) {
                return 0;
            }
    };
    """
    let completed = """
    class Solution {
        public:
            int solve(int value) {
                // Keep the provided wrapper and only finish the method.
                return value + 1;
            }
    };
    """
    let edit = HumanTextEditPlan.make(
        currentText: starter,
        desiredText: completed,
        replacesExistingText: true
    )
    if case let .replaceRange(prefix, removed, suffix, replacement) = edit {
        let old = Array(starter), new = Array(completed)
        let replayed = String(old[..<prefix]) + replacement
            + String(old[(old.count - suffix)...])
        check(
            prefix > "class Solution {".count
                && suffix > 0
                && removed < old.count
                && !replacement.contains("class Solution")
                && replayed == String(new),
            "starter code must be preserved while only the changed range is typed"
        )
    } else {
        check(false, "starter code should produce a minimal replacement range")
    }
    check(
        HumanTextEditPlan.make(
            currentText: completed,
            desiredText: completed,
            replacesExistingText: true
        ) == .unchanged,
        "identical editor content must not be typed again"
    )
    check(
        HumanTextEditPlan.make(
            currentText: nil,
            desiredText: completed,
            replacesExistingText: true
        ) == .currentTextUnavailable,
        "unknown editor content must stop instead of deleting starter code"
    )
}
