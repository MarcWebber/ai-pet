import Foundation

public final class TemporaryArtifactSweeper {
    private let allowedRoot: URL
    private let minimumAge: TimeInterval
    private let allowedPrefix = "JellyPet-Codex-"

    public init(
        allowedRoot: URL = FileManager.default.temporaryDirectory,
        minimumAge: TimeInterval = 3_600
    ) {
        self.allowedRoot = allowedRoot.standardizedFileURL
        self.minimumAge = max(0, minimumAge)
    }

    public func removeAll() {
        guard
            let children = try? FileManager.default.contentsOfDirectory(
                at: allowedRoot,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        else {
            return
        }

        for child in children {
            let candidate = child.standardizedFileURL
            guard
                candidate.deletingLastPathComponent() == allowedRoot,
                candidate.lastPathComponent.hasPrefix(allowedPrefix),
                let values = try? candidate.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ),
                let modified = values.contentModificationDate,
                Date().timeIntervalSince(modified) >= minimumAge
            else {
                continue
            }
            try? FileManager.default.removeItem(at: candidate)
        }
    }
}
