import Foundation
import JellyCore

public final class AppPreferencesStore {
    private enum Key {
        static let selectedDisplayID = "jelly.selectedDisplayID"
        static let showActivityDetails = "jelly.showActivityDetails"
        static let globalShortcut = "jelly.globalShortcut"
        static let answerScrollShortcut = "jelly.answerScrollShortcut"
        static let answerHistoryShortcut = "jelly.answerHistoryShortcut"
        static let answerHistory = "jelly.answerHistory"
        static let typingSpeedPercent = "jelly.typingSpeedPercent"
    }

    private let defaults: UserDefaults
    private let configurationStore: JellyConfigurationStore

    public init(
        defaults: UserDefaults = .standard,
        configurationURL: URL? = nil,
        configurationTemplateURL: URL? = nil
    ) {
        self.defaults = defaults
        configurationStore = JellyConfigurationStore(
            configurationURL: configurationURL,
            templateURL: configurationTemplateURL
        )
        defaults.register(defaults: [
            Key.showActivityDetails: true,
            Key.globalShortcut: GlobalShortcut.controlOptionSpace.rawValue,
            Key.answerScrollShortcut:
                AnswerScrollShortcut.controlOptionArrows.rawValue,
            Key.answerHistoryShortcut:
                AnswerHistoryShortcut.controlOptionArrows.rawValue,
            Key.typingSpeedPercent: HumanTypingPlan.defaultSpeedPercent
        ])
    }

    public var selectedDisplayID: UInt32? {
        get {
            guard defaults.object(forKey: Key.selectedDisplayID) != nil else {
                return nil
            }
            return UInt32(defaults.integer(forKey: Key.selectedDisplayID))
        }
        set {
            if let newValue {
                defaults.set(Int(newValue), forKey: Key.selectedDisplayID)
            } else {
                defaults.removeObject(forKey: Key.selectedDisplayID)
            }
        }
    }

    public var assistantPreferences: AssistantPreferences {
        get {
            let configuration = configurationStore.configuration
            return AssistantPreferences(
                runtime: configuration.assistant.runtime,
                model: configuration.assistant.model,
                reasoningEffort:
                    configuration.assistant.reasoningEffort,
                customInstructions:
                    configuration.assistant.customInstructions,
                conversationHistoryTurns:
                    configuration.conversation.historyTurns
            )
        }
        set {
            let previousTurns = conversationHistoryTurns
            configurationStore.update { configuration in
                configuration.assistant.runtime = newValue.runtime
                configuration.assistant.model = newValue.model
                configuration.assistant.reasoningEffort =
                    newValue.reasoningEffort
                configuration.assistant.customInstructions =
                    newValue.customInstructions
                configuration.conversation.historyTurns =
                    newValue.conversationHistoryTurns
            }
            if previousTurns != conversationHistoryTurns {
                answerHistory = answerHistory
            }
        }
    }

    public var conversationHistoryTurns: Int {
        get { configurationStore.configuration.conversation.historyTurns }
        set {
            configurationStore.update {
                $0.conversation.historyTurns = newValue
            }
            answerHistory = answerHistory
        }
    }

    public var takeoverEnabled: Bool {
        get { configurationStore.configuration.beta.screenTakeover }
        set {
            configurationStore.update {
                $0.beta.screenTakeover = newValue
            }
        }
    }

    public var configurationURL: URL {
        configurationStore.configurationURL
    }

    public var configurationError: String? {
        configurationStore.lastError
    }

    public var spriteSheetURL: URL? {
        configurationStore.spriteSheetURL
    }

    @discardableResult
    public func reloadConfiguration() -> Bool {
        configurationStore.reload()
    }

    public func importSpriteSheet(from source: URL) throws {
        try configurationStore.importSpriteSheet(from: source)
    }

    public func resetSpriteSheet() throws {
        try configurationStore.resetSpriteSheet()
    }

    public var globalShortcut: GlobalShortcut {
        get {
            GlobalShortcut(
                rawValue: defaults.string(forKey: Key.globalShortcut) ?? ""
            ) ?? .controlOptionSpace
        }
        set { defaults.set(newValue.rawValue, forKey: Key.globalShortcut) }
    }

    public var answerScrollShortcut: AnswerScrollShortcut {
        get {
            AnswerScrollShortcut(
                rawValue: defaults.string(
                    forKey: Key.answerScrollShortcut
                ) ?? ""
            ) ?? .controlOptionArrows
        }
        set { defaults.set(newValue.rawValue, forKey: Key.answerScrollShortcut) }
    }

    public var answerHistoryShortcut: AnswerHistoryShortcut {
        get {
            AnswerHistoryShortcut(
                rawValue: defaults.string(
                    forKey: Key.answerHistoryShortcut
                ) ?? ""
            ) ?? .controlOptionArrows
        }
        set {
            defaults.set(
                newValue.rawValue,
                forKey: Key.answerHistoryShortcut
            )
        }
    }

    public var answerHistory: [AnswerHistoryEntry] {
        get {
            guard let data = defaults.data(forKey: Key.answerHistory),
                  let entries = try? JSONDecoder().decode(
                      [AnswerHistoryEntry].self,
                      from: data
                  )
            else {
                return []
            }
            return Array(entries.suffix(conversationHistoryTurns))
        }
        set {
            let entries = Array(newValue.suffix(conversationHistoryTurns))
            guard let data = try? JSONEncoder().encode(entries) else {
                return
            }
            defaults.set(data, forKey: Key.answerHistory)
        }
    }

    public var showActivityDetails: Bool {
        get { defaults.bool(forKey: Key.showActivityDetails) }
        set { defaults.set(newValue, forKey: Key.showActivityDetails) }
    }

    public var typingSpeedPercent: Int {
        get {
            HumanTypingPlan.normalizedSpeedPercent(
                defaults.integer(forKey: Key.typingSpeedPercent)
            )
        }
        set {
            defaults.set(
                HumanTypingPlan.normalizedSpeedPercent(newValue),
                forKey: Key.typingSpeedPercent
            )
        }
    }
}
