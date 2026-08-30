import JellyCore

func runTextEditingChecks() {
    let source = String(repeating: "int answer = value + 1; // update\n", count: 12)
    let strokes = TypingRhythm.strokes(for: source, seed: 42)
    let baseline = TypingRhythm.strokes(
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
        strokes.allSatisfy { (56...450).contains($0.delayAfterMilliseconds) },
        "typing delays must stay inside the natural preset"
    )
    check(
        zip(strokes, baseline).allSatisfy {
            $0.delayAfterMilliseconds > $1.delayAfterMilliseconds
        },
        "the default configured typing speed must be slightly slower than baseline"
    )
    let faster = TypingRhythm.strokes(
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

    let short = TypingRhythm.strokes(for: "return value;", seed: 7)
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
    let edit = TextEditing.make(
        currentText: starter,
        desiredText: completed
    )
    if case let .replace(location, length, replacement) = edit {
        let old = Array(starter.utf16)
        let replayed = String(decoding: old[..<location], as: UTF16.self)
            + replacement
            + String(decoding: old[(location + length)...], as: UTF16.self)
        check(
            location > "class Solution {".utf16.count
                && location + length < old.count
                && !replacement.contains("class Solution")
                && replayed == completed,
            "starter code must be preserved while the blank method body is typed"
        )
    } else {
        check(false, "starter code should produce a minimal replacement range")
    }
    check(
        TextEditing.make(
            currentText: completed,
            desiredText: completed
        ) == .unchanged,
        "identical editor content must not be typed again"
    )
    let nonBlankStarter = starter.replacingOccurrences(
        of: "\(blankBody)\n",
        with: "            return 0;\n"
    )
    let damagedEdit = TextEditing.make(
        currentText: nonBlankStarter,
        desiredText: completed
    )
    if case let .replace(location, length, replacement)
        = damagedEdit {
        let old = Array(nonBlankStarter.utf16)
        let repaired = String(decoding: old[..<location], as: UTF16.self)
            + replacement
            + String(decoding: old[(location + length)...], as: UTF16.self)
        check(
            length > 0 && repaired == completed,
            "non-blank damaged code must be repaired inside its shared wrapper"
        )
    } else {
        check(false, "damaged code should produce one bounded repair")
    }
    let unrelatedCurrent = "existing code"
    let unrelatedDesired = "different code"
    if case let .replace(location, length, replacement)
        = TextEditing.make(
            currentText: unrelatedCurrent,
            desiredText: unrelatedDesired
        ) {
        let old = Array(unrelatedCurrent.utf16)
        let repaired = String(decoding: old[..<location], as: UTF16.self)
            + replacement
            + String(decoding: old[(location + length)...], as: UTF16.self)
        check(
            length > 0 && repaired == unrelatedDesired,
            "the takeover agent must be able to replace fully damaged code"
        )
    } else {
        check(false, "unrelated damaged text should still produce a repair")
    }
    check(
        TextEditing.make(
            currentText: "class Solution {\n    return ;\n}",
            desiredText: "class Solution {\n    return answer;\n}"
        ) == .replace(
            location: 28,
            length: 0,
            text: "answer"
        ),
        "a contiguous fragment deleted during typing must be resumed at the gap"
    )
    check(
        TextEditing.make(
            currentText: "a😀c",
            desiredText: "a😃c"
        ) == .replace(location: 1, length: 2, text: "😃"),
        "minimal edits must use valid UTF-16 ranges without splitting emoji"
    )
    check(
        (try? ScreenAction.keyPress(key: .delete, modifiers: []).validate()) != nil
            && (try? ScreenAction.keyPress(
                key: .a,
                modifiers: [.command]
            ).validate()) != nil,
        "the takeover agent must have delete and select-all keyboard access"
    )
    check(
        (try? ScreenAction.typeText(
            target: .visual(x: 500, y: 500),
            text: "unsafe"
        ).validate()) == nil,
        "typing must require a semantic target"
    )
}
