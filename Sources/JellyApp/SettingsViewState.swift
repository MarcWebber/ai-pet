import JellyCore
import Foundation

struct SettingsViewState {
    let displays: [DisplayDescriptor]
    let selectedDisplayID: UInt32?
    let assistantPreferences: AssistantPreferences
    let showActivityDetails: Bool
    let typingSpeedPercent: Int
    let globalShortcut: GlobalShortcut
    let answerScrollShortcut: AnswerScrollShortcut
    let answerHistoryShortcut: AnswerHistoryShortcut
    let availableRuntimes: Set<AgentRuntimeKind>
    let modelOptions: [String]
    let runtimeText: String
    let configurationURL: URL
    let configurationError: String?
    let spriteSheetURL: URL?
}
