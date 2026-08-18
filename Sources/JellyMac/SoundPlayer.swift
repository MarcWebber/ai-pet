import AppKit
import JellyCore

public final class SoundPlayer {
    public var isMuted = false

    private var sounds: [SoundCue: NSSound] = [:]

    public init(resourceDirectory: URL) {
        for cue in SoundCue.allCases {
            let url = resourceDirectory.appendingPathComponent(
                "\(cue.rawValue).wav"
            )
            sounds[cue] = NSSound(contentsOf: url, byReference: false)
        }
    }

    public func play(_ cue: SoundCue) {
        guard !isMuted else {
            return
        }
        sounds[cue]?.stop()
        sounds[cue]?.play()
    }
}
