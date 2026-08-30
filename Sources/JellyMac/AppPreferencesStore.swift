import Foundation
import ImageIO
import JellyCore

public enum AppPreferencesError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        if case let .invalid(message) = self { message } else { nil }
    }
}

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
    private let files = FileManager.default
    private let encoder: JSONEncoder = {
        let value = JSONEncoder()
        value.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return value
    }()
    public let configurationURL: URL
    private var configuration = JellyConfiguration.default
    public private(set) var configurationError: String?
    public init(
        defaults: UserDefaults = .standard,
        configurationURL: URL? = nil,
        configurationTemplateURL: URL? = nil
    ) {
        self.defaults = defaults
        self.configurationURL = configurationURL ?? Self.defaultConfigurationURL()
        defaults.register(defaults: [
            Key.showActivityDetails: true,
            Key.globalShortcut: GlobalShortcut.controlOptionSpace.rawValue,
            Key.answerScrollShortcut:
                ArrowShortcut.controlOptionArrows.rawValue,
            Key.answerHistoryShortcut:
                ArrowShortcut.controlOptionArrows.rawValue,
            Key.typingSpeedPercent: TypingRhythm.defaultSpeedPercent
        ])
        load(templateURL: configurationTemplateURL)
    }
    public var selectedDisplayID: UInt32? {
        get {
            guard defaults.object(forKey: Key.selectedDisplayID) != nil else { return nil }
            return UInt32(defaults.integer(forKey: Key.selectedDisplayID))
        }
        set {
            if let newValue { defaults.set(Int(newValue), forKey: Key.selectedDisplayID) }
            else { defaults.removeObject(forKey: Key.selectedDisplayID) }
        }
    }
    public var assistantPreferences: AssistantPreferences {
        get {
            return AssistantPreferences(
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
            updateConfiguration { configuration in
                configuration.assistant.model = newValue.model
                configuration.assistant.reasoningEffort =
                    newValue.reasoningEffort
                configuration.assistant.customInstructions =
                    newValue.customInstructions
                configuration.conversation.historyTurns =
                    newValue.conversationHistoryTurns
            }
            answerHistory = answerHistory
        }
    }
    public var takeoverEnabled: Bool {
        get { configuration.beta.screenTakeover }
        set { updateConfiguration { $0.beta.screenTakeover = newValue } }
    }
    public var spriteSheetURL: URL? {
        guard let path = configuration.appearance.spriteSheet else { return nil }
        let url = (path as NSString).isAbsolutePath
            ? URL(fileURLWithPath: path)
            : configurationURL.deletingLastPathComponent().appendingPathComponent(path)
        do {
            guard files.isReadableFile(atPath: url.path) else {
                throw AppPreferencesError.invalid("宠物精灵图不存在或不可读：\(url.path)")
            }
            try Self.validateSpriteSheet(at: url)
            return url.standardizedFileURL
        } catch {
            configurationError = error.localizedDescription
            return nil
        }
    }
    public func importSpriteSheet(from source: URL) throws {
        guard source.pathExtension.lowercased() == "png" else {
            throw AppPreferencesError.invalid("自定义宠物必须是支持透明背景的 PNG 文件。")
        }
        try Self.validateSpriteSheet(at: source)
        let directory = configurationURL.deletingLastPathComponent()
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("PetSprites.png")
        if source.standardizedFileURL != target.standardizedFileURL {
            try Data(contentsOf: source).write(to: target, options: .atomic)
        }
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        guard updateConfiguration({ $0.appearance.spriteSheet = target.lastPathComponent }) else {
            throw AppPreferencesError.invalid(configurationError ?? "无法保存宠物外形配置。")
        }
    }
    public func resetSpriteSheet() throws {
        let imported = configurationURL.deletingLastPathComponent()
            .appendingPathComponent("PetSprites.png")
        guard updateConfiguration({ $0.appearance.spriteSheet = nil }) else {
            throw AppPreferencesError.invalid(configurationError ?? "无法恢复默认宠物外形。")
        }
        if files.fileExists(atPath: imported.path) { try files.removeItem(at: imported) }
    }
    public var globalShortcut: GlobalShortcut {
        get { choice(Key.globalShortcut, or: .controlOptionSpace) }
        set { setChoice(newValue, for: Key.globalShortcut) }
    }
    public var answerScrollShortcut: ArrowShortcut {
        get { choice(Key.answerScrollShortcut, or: .controlOptionArrows) }
        set { setChoice(newValue, for: Key.answerScrollShortcut) }
    }
    public var answerHistoryShortcut: ArrowShortcut {
        get { choice(Key.answerHistoryShortcut, or: .controlOptionArrows) }
        set { setChoice(newValue, for: Key.answerHistoryShortcut) }
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
            return Array(entries.suffix(configuration.conversation.historyTurns))
        }
        set {
            let entries = Array(newValue.suffix(configuration.conversation.historyTurns))
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
        get { TypingRhythm.normalizedSpeedPercent(defaults.integer(forKey: Key.typingSpeedPercent)) }
        set { defaults.set(TypingRhythm.normalizedSpeedPercent(newValue),
                           forKey: Key.typingSpeedPercent) }
    }
    private func choice<T: RawRepresentable>(_ key: String, or fallback: T) -> T
        where T.RawValue == String {
        T(rawValue: defaults.string(forKey: key) ?? "") ?? fallback
    }
    private func setChoice<T: RawRepresentable>(_ value: T, for key: String)
        where T.RawValue == String {
        defaults.set(value.rawValue, forKey: key)
    }
    private func load(templateURL: URL?) {
        if files.fileExists(atPath: configurationURL.path) {
            _ = reloadConfiguration(); return
        }
        if let templateURL, let data = try? Data(contentsOf: templateURL),
           var value = try? JSONDecoder().decode(JellyConfiguration.self, from: data) {
            value.normalize(); configuration = value
        }
        _ = save(configuration)
    }
    @discardableResult
    public func reloadConfiguration() -> Bool {
        guard files.fileExists(atPath: configurationURL.path) else {
            return save(configuration)
        }
        do {
            var value = try JSONDecoder().decode(
                JellyConfiguration.self, from: Data(contentsOf: configurationURL)
            )
            value.normalize()
            return accept(value)
        } catch {
            configurationError = "配置文件无法读取：\(error.localizedDescription)"
            return false
        }
    }
    @discardableResult
    private func updateConfiguration(
        _ change: (inout JellyConfiguration) -> Void
    ) -> Bool {
        var value = configuration
        change(&value); value.normalize()
        return save(value)
    }
    private func accept(_ value: JellyConfiguration) -> Bool {
        configuration = value; configurationError = nil
        return true
    }
    private func save(_ value: JellyConfiguration) -> Bool {
        do {
            let directory = configurationURL.deletingLastPathComponent()
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
            try encoder.encode(value).write(to: configurationURL, options: .atomic)
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configurationURL.path)
            return accept(value)
        } catch {
            configurationError = "配置文件无法保存：\(error.localizedDescription)"
            return false
        }
    }
    private static func defaultConfigurationURL() -> URL {
        let files = FileManager.default
        let root = (try? files.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )) ?? files.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        return root.appendingPathComponent("JellyPet/config.json")
    }
    private static func validateSpriteSheet(at url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw AppPreferencesError.invalid("无法读取这张精灵图。")
        }
        guard image.width == image.height, image.width >= 8,
              image.width.isMultiple(of: 8), image.height.isMultiple(of: 8) else {
            throw AppPreferencesError.invalid(
                "精灵图必须是正方形 8×8 网格，宽高都要能被 8 整除。当前为 \(image.width)×\(image.height)。"
            )
        }
    }
}
