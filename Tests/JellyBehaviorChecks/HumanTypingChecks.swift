import JellyCore

func runHumanTypingChecks() {
    let source = String(repeating: "int answer = value + 1; // update\n", count: 12)
    let strokes = HumanTypingPlan.strokes(for: source, seed: 42)
    let baseline = HumanTypingPlan.strokes(
        for: source,
        seed: 42,
        speedPercent: 100
    )
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
            (56...450).contains($0.delayAfterMilliseconds)
                && (106...225).contains($0.mistakeDelayMilliseconds)
                && (75...169).contains($0.correctionDelayMilliseconds)
        },
        "typing and correction delays must stay inside the natural preset"
    )
    check(
        zip(strokes, baseline).allSatisfy {
            $0.delayAfterMilliseconds > $1.delayAfterMilliseconds
        },
        "the default configured typing speed must be slightly slower than baseline"
    )
    let faster = HumanTypingPlan.strokes(
        for: source,
        seed: 42,
        speedPercent: 140
    )
    check(
        zip(faster, baseline).allSatisfy {
            $0.delayAfterMilliseconds < $1.delayAfterMilliseconds
        },
        "raising the configured percentage must make typing faster"
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

    let blankBody = String(repeating: " ", count: 12)
    let starter = """
    class Solution {
        public:
            int solve(int value) {
    \(blankBody)
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
        desiredText: completed
    )
    if case let .insertAtBoundary(prefix, suffix, replacement) = edit {
        let old = Array(starter), new = Array(completed)
        let replayed = String(old[..<prefix]) + replacement
            + String(old[(old.count - suffix)...])
        check(
            prefix > "class Solution {".count
                && suffix > 0
                && !replacement.contains("class Solution")
                && replayed == String(new),
            "starter code must be preserved while the blank method body is typed"
        )
    } else {
        check(false, "starter code should produce a minimal replacement range")
    }
    check(
        HumanTextEditPlan.make(
            currentText: completed,
            desiredText: completed
        ) == .unchanged,
        "identical editor content must not be typed again"
    )
    check(
        HumanTextEditPlan.make(
            currentText: nil,
            desiredText: completed
        ) == .currentTextUnavailable,
        "unknown editor content must stop instead of deleting starter code"
    )
    let nonBlankStarter = starter.replacingOccurrences(
        of: "\(blankBody)\n",
        with: "            return 0;\n"
    )
    check(
        HumanTextEditPlan.make(
            currentText: nonBlankStarter,
            desiredText: completed
        ) == .existingTextProtected,
        "non-blank starter code must never be deleted or replaced"
    )
    check(
        HumanTextEditPlan.make(
            currentText: "existing code",
            desiredText: "different code"
        ) == .existingTextProtected,
        "an unrelated final answer must never trigger replace-all"
    )
    check(
        HumanTextEditPlan.make(
            currentText: "class Solution {\n    return ;\n}",
            desiredText: "class Solution {\n    return answer;\n}"
        ) == .insertAtBoundary(
            prefixCount: 28,
            suffixCount: 3,
            text: "answer"
        ),
        "a contiguous fragment deleted during typing must be resumed at the gap"
    )
    check(
        (try? ScreenAction.keyPress(key: .delete, modifiers: []).validate()) == nil
            && (try? ScreenAction.keyPress(
                key: .a,
                modifiers: [.command]
            ).validate()) == nil,
        "model-visible key presses must not expose delete or select-all"
    )
    check(
        (try? ScreenAction.typeText(
            target: .visual(x: 500, y: 500),
            text: "unsafe"
        ).validate()) == nil,
        "typing must require a semantic target"
    )
}
