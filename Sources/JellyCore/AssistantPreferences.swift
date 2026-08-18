import Foundation

public enum AgentRuntimeKind: String, CaseIterable, Codable, Sendable {
    case automatic
    case codex
    case traex
    case claudeCode
    case openCode

    public var displayName: String {
        switch self {
        case .automatic: "自动选择"
        case .codex: "Codex"
        case .traex: "TraeX"
        case .claudeCode: "Claude Code"
        case .openCode: "OpenCode"
        }
    }
}

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
    public static let automaticModel = "auto"
    public static let `default` = AssistantPreferences(
        runtime: .automatic,
        model: automaticModel,
        reasoningEffort: .high,
        customInstructions: "",
        conversationHistoryTurns:
            JellyConfiguration.Conversation(historyTurns: 8).historyTurns
    )

    public let runtime: AgentRuntimeKind
    public let model: String
    public let reasoningEffort: ReasoningEffort
    public let customInstructions: String
    public let conversationHistoryTurns: Int

    public init(
        runtime: AgentRuntimeKind = .automatic,
        model: String,
        reasoningEffort: ReasoningEffort,
        customInstructions: String = "",
        conversationHistoryTurns: Int = 8
    ) {
        self.runtime = runtime
        let normalizedModel = String(
            model.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)
        )
        self.model = normalizedModel.isEmpty
            ? Self.automaticModel : normalizedModel
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
        let modelLabel = model == Self.automaticModel ? "默认模型" : model
        return "\(runtime.displayName) · \(modelLabel) · \(reasoningEffort.displayName)"
    }
}
