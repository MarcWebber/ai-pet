import Foundation

public enum AppMetadata {
    public static let bundleIdentifier = "com.local.JellyPet"
    public static let shortcutLabel = "⌃ ⌥ Space"
    public static let maximumScreenshotDimension = 2560
    public static let edgeSnapThreshold = 24.0
    public static let takeoverEventLimit = 160
    public static let syntheticEventMarker: Int64 = 0x4A454C4C59
    public static func boundedUserText(_ value: String?) -> String? {
        let text = String((value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(4_000))
        return text.isEmpty ? nil : text
    }
}

public enum GlobalShortcut: String, CaseIterable, Sendable {
    case controlOptionSpace
    case controlOptionJ
    case controlShiftSpace
    case commandShiftSpace
    public var label: String {
        switch self {
        case .controlOptionSpace: "⌃ ⌥ Space"
        case .controlOptionJ: "⌃ ⌥ J"
        case .controlShiftSpace: "⌃ ⇧ Space"
        case .commandShiftSpace: "⌘ ⇧ Space"
        }
    }
}

public enum ArrowShortcut: String, CaseIterable, Sendable {
    case controlOptionArrows
    case controlShiftArrows
    case commandOptionArrows
    case commandShiftArrows
    public var label: String {
        switch self {
        case .controlOptionArrows: "⌃ ⌥"
        case .controlShiftArrows: "⌃ ⇧"
        case .commandOptionArrows: "⌘ ⌥"
        case .commandShiftArrows: "⌘ ⇧"
        }
    }
}
