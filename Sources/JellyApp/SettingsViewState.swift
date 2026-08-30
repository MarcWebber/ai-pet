import JellyCore
import Foundation

struct SettingsViewState {
    var displays: [DisplayDescriptor]
    var selectedDisplayID: UInt32?
    var assistantPreferences: AssistantPreferences
    var showActivityDetails: Bool
    var typingSpeedPercent: Int
    var globalShortcut: GlobalShortcut
    var answerScrollShortcut: ArrowShortcut
    var answerHistoryShortcut: ArrowShortcut
    var modelOptions: [String]
    var codexStatusText: String
    var configurationURL: URL
    var configurationError: String?
    var spriteSheetURL: URL?
    static let placeholder = SettingsViewState(
        displays: [],
        selectedDisplayID: nil,
        assistantPreferences: .default,
        showActivityDetails: true,
        typingSpeedPercent: TypingRhythm.defaultSpeedPercent,
        globalShortcut: .controlOptionSpace,
        answerScrollShortcut: .controlOptionArrows,
        answerHistoryShortcut: .controlOptionArrows,
        modelOptions: [],
        codexStatusText: "检查中…",
        configurationURL: URL(fileURLWithPath: "/"),
        configurationError: nil,
        spriteSheetURL: nil
    )
}
