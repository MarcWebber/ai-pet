import Foundation

public enum ReasoningEffort: String, CaseIterable, Codable, Sendable {
    case low
    case medium
    case high
    case xhigh

    public var displayName: String {
        rawValue.capitalized
    }
}

public struct AssistantPreferences: Equatable, Sendable {
    public static let defaultModel = "auto"
    public static let `default` = AssistantPreferences(
        model: defaultModel,
        reasoningEffort: .high,
        customInstructions: "",
        conversationHistoryTurns:
            JellyConfiguration.Conversation(historyTurns: 8).historyTurns
    )

    public let model: String
    public let reasoningEffort: ReasoningEffort
    public let customInstructions: String
    public let conversationHistoryTurns: Int

    public init(
        model: String,
        reasoningEffort: ReasoningEffort,
        customInstructions: String = "",
        conversationHistoryTurns: Int = 8
    ) {
        let normalizedModel = String(
            model.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)
        )
        self.model = normalizedModel.isEmpty
            ? Self.defaultModel : normalizedModel
        self.reasoningEffort = reasoningEffort
        self.customInstructions = String(customInstructions.prefix(4_000))
        self.conversationHistoryTurns = min(
            max(
                conversationHistoryTurns,
                JellyConfiguration.Conversation.minimumHistoryTurns
            ),
            JellyConfiguration.Conversation.maximumHistoryTurns
        )
    }

    public var compactLabel: String {
        let modelLabel = model == Self.defaultModel ? "默认模型" : model
        return "Codex · \(modelLabel) · \(reasoningEffort.displayName)"
    }
}
