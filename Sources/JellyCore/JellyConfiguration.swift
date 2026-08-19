import Foundation

public struct JellyConfiguration: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2
    public static let `default` = JellyConfiguration(
        conversation: Conversation(historyTurns: 8),
        assistant: Assistant(
            runtime: .automatic,
            model: AssistantPreferences.automaticModel,
            reasoningEffort: .high,
            customInstructions: ""
        ),
        appearance: Appearance(spriteSheet: nil),
        beta: Beta(screenTakeover: true)
    )

    public var schemaVersion: Int
    public var conversation: Conversation
    public var assistant: Assistant
    public var appearance: Appearance
    public var beta: Beta

    public init(
        schemaVersion: Int = currentSchemaVersion,
        conversation: Conversation,
        assistant: Assistant,
        appearance: Appearance,
        beta: Beta
    ) {
        self.schemaVersion = schemaVersion
        self.conversation = conversation
        self.assistant = assistant
        self.appearance = appearance
        self.beta = beta
        normalize()
    }

    public mutating func normalize() {
        schemaVersion = Self.currentSchemaVersion
        conversation.normalize()
        assistant.normalize()
        appearance.normalize()
    }

    public mutating func migrate() {
        if schemaVersion < 2 {
            beta.screenTakeover = true
        }
        normalize()
    }

    public struct Conversation: Codable, Equatable, Sendable {
        public static let minimumHistoryTurns = 1
        public static let maximumHistoryTurns = 50

        public var historyTurns: Int

        public init(historyTurns: Int) {
            self.historyTurns = historyTurns
            normalize()
        }

        public mutating func normalize() {
            historyTurns = min(
                max(historyTurns, Self.minimumHistoryTurns),
                Self.maximumHistoryTurns
            )
        }
    }

    public struct Assistant: Codable, Equatable, Sendable {
        public var runtime: AgentRuntimeKind
        public var model: String
        public var reasoningEffort: ReasoningEffort
        public var customInstructions: String

        public init(
            runtime: AgentRuntimeKind,
            model: String,
            reasoningEffort: ReasoningEffort,
            customInstructions: String
        ) {
            self.runtime = runtime
            self.model = model
            self.reasoningEffort = reasoningEffort
            self.customInstructions = customInstructions
            normalize()
        }

        public mutating func normalize() {
            let value = model.trimmingCharacters(in: .whitespacesAndNewlines)
            model = value.isEmpty
                ? AssistantPreferences.automaticModel
                : String(value.prefix(200))
            customInstructions = String(customInstructions.prefix(4_000))
        }
    }

    public struct Appearance: Codable, Equatable, Sendable {
        public static let rows = 8
        public static let columns = 8

        public var spriteSheet: String?

        public init(spriteSheet: String?) {
            self.spriteSheet = spriteSheet
            normalize()
        }

        public mutating func normalize() {
            let value = spriteSheet?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ) ?? ""
            spriteSheet = value.isEmpty ? nil : String(value.prefix(1_024))
        }
    }

    public struct Beta: Codable, Equatable, Sendable {
        public var screenTakeover: Bool

        public init(screenTakeover: Bool) {
            self.screenTakeover = screenTakeover
        }
    }
}
