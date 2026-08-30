import Foundation

public struct JellyConfiguration: Codable, Equatable, Sendable {
    public static let `default` = JellyConfiguration(
        conversation: Conversation(historyTurns: 8),
        assistant: Assistant(
            model: AssistantPreferences.defaultModel,
            reasoningEffort: .high,
            customInstructions: ""
        ),
        appearance: Appearance(spriteSheet: nil),
        beta: Beta(screenTakeover: true)
    )
    public var conversation: Conversation
    public var assistant: Assistant
    public var appearance: Appearance
    public var beta: Beta
    public mutating func normalize() {
        conversation.historyTurns = min(max(
            conversation.historyTurns, Conversation.minimumHistoryTurns
        ), Conversation.maximumHistoryTurns)
        let model = assistant.model.trimmingCharacters(in: .whitespacesAndNewlines)
        assistant.model = model.isEmpty
            ? AssistantPreferences.defaultModel : String(model.prefix(200))
        assistant.customInstructions = String(assistant.customInstructions.prefix(4_000))
        let sheet = appearance.spriteSheet?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        appearance.spriteSheet = sheet.isEmpty ? nil : String(sheet.prefix(1_024))
    }
    public struct Conversation: Codable, Equatable, Sendable {
        public static let minimumHistoryTurns = 1
        public static let maximumHistoryTurns = 50

        public var historyTurns: Int
    }
    public struct Assistant: Codable, Equatable, Sendable {
        public var model: String
        public var reasoningEffort: ReasoningEffort
        public var customInstructions: String
    }
    public struct Appearance: Codable, Equatable, Sendable {
        public var spriteSheet: String?
    }
    public struct Beta: Codable, Equatable, Sendable {
        public var screenTakeover: Bool
    }
}
