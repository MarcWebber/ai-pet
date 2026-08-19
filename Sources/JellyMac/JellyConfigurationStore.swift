import Foundation
import ImageIO
import JellyCore

public enum JellyConfigurationStoreError: LocalizedError {
    case invalidConfiguration(String)
    case invalidSpriteSheet(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidConfiguration(message),
             let .invalidSpriteSheet(message):
            message
        }
    }
}

public final class JellyConfigurationStore {
    public let configurationURL: URL
    public private(set) var configuration: JellyConfiguration
    public private(set) var lastError: String?

    private let fileManager: FileManager
    private let decoder = JSONDecoder()
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    public init(
        configurationURL: URL? = nil,
        templateURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.configurationURL = configurationURL
            ?? Self.defaultConfigurationURL(fileManager: fileManager)
        configuration = JellyConfiguration.default
        load(templateURL: templateURL)
    }

    @discardableResult
    public func reload() -> Bool {
        guard fileManager.fileExists(atPath: configurationURL.path) else {
            return save(configuration)
        }
        do {
            var value = try decoder.decode(
                JellyConfiguration.self,
                from: Data(contentsOf: configurationURL)
            )
            let requiresMigration = value.schemaVersion
                < JellyConfiguration.currentSchemaVersion
            value.migrate()
            if requiresMigration {
                return save(value)
            }
            configuration = value
            lastError = nil
            return true
        } catch {
            lastError = "配置文件无法读取：\(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    public func update(
        _ change: (inout JellyConfiguration) -> Void
    ) -> Bool {
        var value = configuration
        change(&value)
        value.normalize()
        return save(value)
    }

    public var spriteSheetURL: URL? {
        guard let path = configuration.appearance.spriteSheet else {
            return nil
        }
        let absolute = (path as NSString).isAbsolutePath
        let url = URL(fileURLWithPath: path)
        let resolved = absolute
            ? url
            : configurationURL.deletingLastPathComponent()
                .appendingPathComponent(path)
        guard fileManager.isReadableFile(atPath: resolved.path) else {
            lastError = "宠物精灵图不存在或不可读：\(resolved.path)"
            return nil
        }
        do {
            try Self.validateSpriteSheet(at: resolved)
            return resolved.standardizedFileURL
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    public func importSpriteSheet(from source: URL) throws {
        guard source.pathExtension.lowercased() == "png" else {
            throw JellyConfigurationStoreError.invalidSpriteSheet(
                "自定义宠物必须是支持透明背景的 PNG 文件。"
            )
        }
        try Self.validateSpriteSheet(at: source)
        let directory = configurationURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let target = directory.appendingPathComponent("PetSprites.png")
        if source.standardizedFileURL != target.standardizedFileURL {
            try Data(contentsOf: source).write(to: target, options: .atomic)
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: target.path
        )
        guard update({ $0.appearance.spriteSheet = target.lastPathComponent }) else {
            throw JellyConfigurationStoreError.invalidConfiguration(
                lastError ?? "无法保存宠物外形配置。"
            )
        }
    }

    public func resetSpriteSheet() throws {
        let imported = configurationURL.deletingLastPathComponent()
            .appendingPathComponent("PetSprites.png")
        guard update({ $0.appearance.spriteSheet = nil }) else {
            throw JellyConfigurationStoreError.invalidConfiguration(
                lastError ?? "无法恢复默认宠物外形。"
            )
        }
        if fileManager.fileExists(atPath: imported.path) {
            try fileManager.removeItem(at: imported)
        }
    }

    public static func validateSpriteSheet(at url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw JellyConfigurationStoreError.invalidSpriteSheet(
                "无法读取这张精灵图。"
            )
        }
        let width = image.width
        let height = image.height
        let columns = JellyConfiguration.Appearance.columns
        let rows = JellyConfiguration.Appearance.rows
        guard width == height,
              width >= columns,
              width % columns == 0,
              height % rows == 0 else {
            throw JellyConfigurationStoreError.invalidSpriteSheet(
                "精灵图必须是正方形 8×8 网格，宽高都要能被 8 整除。当前为 \(width)×\(height)。"
            )
        }
    }

    private func load(templateURL: URL?) {
        if fileManager.fileExists(atPath: configurationURL.path) {
            _ = reload()
            return
        }
        if let templateURL,
           let data = try? Data(contentsOf: templateURL),
           var value = try? decoder.decode(JellyConfiguration.self, from: data) {
            value.migrate()
            configuration = value
        }
        _ = save(configuration)
    }

    @discardableResult
    private func save(_ value: JellyConfiguration) -> Bool {
        do {
            let directory = configurationURL.deletingLastPathComponent()
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try encoder.encode(value).write(
                to: configurationURL,
                options: .atomic
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: configurationURL.path
            )
            configuration = value
            lastError = nil
            return true
        } catch {
            lastError = "配置文件无法保存：\(error.localizedDescription)"
            return false
        }
    }

    private static func defaultConfigurationURL(
        fileManager: FileManager
    ) -> URL {
        let base = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("JellyPet", isDirectory: true)
            .appendingPathComponent("config.json")
    }
}
