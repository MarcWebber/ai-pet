import Foundation

public struct TypingStroke: Codable, Equatable, Sendable {
    public let text: String
    public let mistypedText: String?
    public let mistakeDelayMilliseconds: Int
    public let correctionDelayMilliseconds: Int
    public let delayAfterMilliseconds: Int

    public init(
        text: String,
        mistypedText: String?,
        mistakeDelayMilliseconds: Int,
        correctionDelayMilliseconds: Int,
        delayAfterMilliseconds: Int
    ) {
        self.text = text
        self.mistypedText = mistypedText
        self.mistakeDelayMilliseconds = mistakeDelayMilliseconds
        self.correctionDelayMilliseconds = correctionDelayMilliseconds
        self.delayAfterMilliseconds = delayAfterMilliseconds
    }
}

public enum TextEditPlan: Equatable, Sendable {
    case unchanged
    case replace(
        location: Int,
        length: Int,
        text: String
    )
}

public enum TextEditing {
    public static func make(
        currentText: String?,
        desiredText: String
    ) -> TextEditPlan? {
        let desired = normalize(desiredText)
        guard let currentText else { return nil }
        let current = normalize(currentText)
        guard current != desired else { return .unchanged }

        let old = Array(current), new = Array(desired)
        let sharedLimit = min(old.count, new.count)
        var prefixCount = 0
        while prefixCount < sharedLimit,
              old[prefixCount] == new[prefixCount] {
            prefixCount += 1
        }
        var suffixCount = 0
        while suffixCount < sharedLimit - prefixCount,
              old[old.count - suffixCount - 1]
                == new[new.count - suffixCount - 1] {
            suffixCount += 1
        }
        let oldEnd = old.count - suffixCount
        let newEnd = new.count - suffixCount
        return .replace(
            location: String(old[..<prefixCount]).utf16.count,
            length: String(old[prefixCount..<oldEnd]).utf16.count,
            text: String(new[prefixCount..<newEnd])
        )
    }

    public static func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }
}

public enum TypingRhythm {
    public static let minimumSpeedPercent = 40
    public static let maximumSpeedPercent = 160
    public static let defaultSpeedPercent = 80

    public static func strokes(
        for text: String,
        seed: UInt64,
        speedPercent: Int = defaultSpeedPercent
    ) -> [TypingStroke] {
        var random = TypingRandom(seed: seed)
        var eligibleUntilMistake = random.value(in: 72...132)
        return text.map { character in
            let value = String(character)
            let wrong = wrongCharacter(for: character, random: &random)
            let mistyped: String?
            if wrong != nil {
                eligibleUntilMistake -= 1
            }
            if eligibleUntilMistake == 0, let wrong {
                mistyped = wrong
                eligibleUntilMistake = random.value(in: 96...190)
            } else {
                mistyped = nil
            }
            return TypingStroke(
                text: value,
                mistypedText: mistyped,
                mistakeDelayMilliseconds: scaled(
                    random.value(in: 85...180),
                    for: speedPercent
                ),
                correctionDelayMilliseconds: scaled(
                    random.value(in: 60...135),
                    for: speedPercent
                ),
                delayAfterMilliseconds: scaled(
                    delay(after: character, random: &random),
                    for: speedPercent
                )
            )
        }
    }

    public static func normalizedSpeedPercent(_ value: Int) -> Int {
        min(max(value, minimumSpeedPercent), maximumSpeedPercent)
    }

    private static func scaled(_ milliseconds: Int, for speedPercent: Int) -> Int {
        let speed = normalizedSpeedPercent(speedPercent)
        return max(
            1,
            Int((Double(milliseconds) * 100 / Double(speed)).rounded())
        )
    }

    private static func delay(
        after character: Character,
        random: inout TypingRandom
    ) -> Int {
        switch character {
        case "\n": random.value(in: 180...360)
        case " ", "\t": random.value(in: 45...95)
        case ";", "{", "}": random.value(in: 105...220)
        case ",", ".", ":", "!", "?": random.value(in: 80...170)
        default: random.value(in: 48...108)
        }
    }

    private static func wrongCharacter(
        for character: Character,
        random: inout TypingRandom
    ) -> String? {
        let value = String(character)
        let lower = value.lowercased()
        let rows = ["qwertyuiop", "asdfghjkl", "zxcvbnm", "1234567890"]
        guard let row = rows.first(where: { $0.contains(lower) }),
              let index = row.firstIndex(of: Character(lower)) else {
            return nil
        }
        let offset = row.distance(from: row.startIndex, to: index)
        let candidates = [offset - 1, offset + 1].filter {
            $0 >= 0 && $0 < row.count
        }
        guard !candidates.isEmpty else { return nil }
        let selected = candidates[random.value(in: 0...(candidates.count - 1))]
        let wrongIndex = row.index(row.startIndex, offsetBy: selected)
        let wrong = String(row[wrongIndex])
        return value == value.uppercased() && value != lower
            ? wrong.uppercased()
            : wrong
    }
}

private struct TypingRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
    }

    mutating func value(in range: ClosedRange<Int>) -> Int {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        let width = UInt64(range.upperBound - range.lowerBound + 1)
        return range.lowerBound + Int(state % width)
    }
}
