import Foundation
import JellyCore

public final class AppPreferencesStore {
    private enum Key {
        static let selectedDisplayID = "jelly.selectedDisplayID"
        static let agentRuntime = "jelly.agentRuntime"
        static let codexModel = "jelly.codexModel"
        static let reasoningEffort = "jelly.reasoningEffort"
        static let customInstructions = "jelly.customInstructions"
        static let takeoverEnabled = "jelly.takeoverEnabled"
        static let showActivityDetails = "jelly.showActivityDetails"
        static let globalShortcut = "jelly.globalShortcut"
        static let answerScrollShortcut = "jelly.answerScrollShortcut"
        static let answerHistoryShortcut = "jelly.answerHistoryShortcut"
        static let answerHistory = "jelly.answerHistory"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.agentRuntime: AssistantPreferences.default.runtime.rawValue,
            Key.codexModel: AssistantPreferences.default.model,
            Key.reasoningEffort:
                AssistantPreferences.default.reasoningEffort.rawValue,
            Key.customInstructions:
                AssistantPreferences.default.customInstructions,
            Key.takeoverEnabled: false,
            Key.showActivityDetails: true,
            Key.globalShortcut: GlobalShortcut.controlOptionSpace.rawValue,
            Key.answerScrollShortcut:
                AnswerScrollShortcut.controlOptionArrows.rawValue,
            Key.answerHistoryShortcut:
                AnswerHistoryShortcut.controlOptionArrows.rawValue
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
            let runtime = AgentRuntimeKind(
                rawValue: defaults.string(forKey: Key.agentRuntime) ?? ""
            ) ?? AssistantPreferences.default.runtime
            let model = defaults.string(forKey: Key.codexModel)
                ?? AssistantPreferences.default.model
            let effort = ReasoningEffort(
                rawValue: defaults.string(forKey: Key.reasoningEffort) ?? ""
            ) ?? AssistantPreferences.default.reasoningEffort
            return AssistantPreferences(
                runtime: runtime,
                model: model,
                reasoningEffort: effort,
                customInstructions: defaults.string(
                    forKey: Key.customInstructions
                ) ?? ""
            )
        }
        set {
            defaults.set(newValue.runtime.rawValue, forKey: Key.agentRuntime)
            defaults.set(newValue.model, forKey: Key.codexModel)
            defaults.set(
                newValue.reasoningEffort.rawValue,
                forKey: Key.reasoningEffort
            )
            defaults.set(
                newValue.customInstructions,
                forKey: Key.customInstructions
            )
        }
    }

    public var takeoverEnabled: Bool {
        get { defaults.bool(forKey: Key.takeoverEnabled) }
        set { defaults.set(newValue, forKey: Key.takeoverEnabled) }
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
            return Array(entries.suffix(AppMetadata.answerHistoryLimit))
        }
        set {
            let entries = Array(
                newValue.suffix(AppMetadata.answerHistoryLimit)
            )
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
}
