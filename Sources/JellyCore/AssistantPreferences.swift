import Foundation

public enum CodexModel: String, CaseIterable, Sendable {
    case terra = "gpt-5.6-terra"
    case sol = "gpt-5.6-sol"
    case luna = "gpt-5.6-luna"

    public var displayName: String {
        switch self {
        case .terra: "Terra"
        case .sol: "Sol"
        case .luna: "Luna"
        }
    }
}

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
        case .claudeCode: "Claude Code / cc"
        case .openCode: "OpenCode"
        }
    }
}

public enum ReasoningEffort: String, CaseIterable, Sendable {
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
        customInstructions: ""
    )

    public let runtime: AgentRuntimeKind
    public let model: String
    public let reasoningEffort: ReasoningEffort
    public let customInstructions: String

    public init(
        runtime: AgentRuntimeKind = .automatic,
        model: String,
        reasoningEffort: ReasoningEffort,
        customInstructions: String = ""
    ) {
        self.runtime = runtime
        let normalizedModel = String(
            model.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)
        )
        self.model = normalizedModel.isEmpty
            ? Self.automaticModel : normalizedModel
        self.reasoningEffort = reasoningEffort
        self.customInstructions = String(customInstructions.prefix(4_000))
    }

    public init(
        model: CodexModel,
        reasoningEffort: ReasoningEffort,
        customInstructions: String = ""
    ) {
        self.init(
            runtime: .codex,
            model: model.rawValue,
            reasoningEffort: reasoningEffort,
            customInstructions: customInstructions
        )
    }

    public var compactLabel: String {
        let modelLabel = model == Self.automaticModel ? "默认模型" : model
        return "\(runtime.displayName) · \(modelLabel) · \(reasoningEffort.displayName)"
    }
}
