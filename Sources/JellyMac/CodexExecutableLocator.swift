import Foundation

public enum CodexExecutableLocator {
    public static func locate(
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> URL? {
        guard
            let path = bundle.object(
                forInfoDictionaryKey: "JellyCodexPath"
            ) as? String,
            !path.isEmpty,
            path != "__CODEX_PATH__",
            fileManager.isExecutableFile(atPath: path)
        else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }
}
