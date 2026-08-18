import JellyCore

struct SettingsViewState {
    let displays: [DisplayDescriptor]
    let selectedDisplayID: UInt32?
    let assistantPreferences: AssistantPreferences
    let takeoverEnabled: Bool
    let showActivityDetails: Bool
    let globalShortcut: GlobalShortcut
    let answerScrollShortcut: AnswerScrollShortcut
    let answerHistoryShortcut: AnswerHistoryShortcut
    let availableRuntimes: Set<AgentRuntimeKind>
    let modelOptions: [String]
    let runtimeText: String
}
