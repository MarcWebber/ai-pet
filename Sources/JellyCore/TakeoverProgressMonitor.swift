import Foundation
import CoreGraphics
import ImageIO

public enum TakeoverProgressDecision: Equatable, Sendable {
    case proceed
    case warning(String)
    case stop(String)
}

/// A compact, session-local identity for one observation.
///
/// Semantic and visual identities are combined when both are present. This matters for canvas,
/// remote-desktop and media surfaces whose small accessibility tree can remain unchanged while
/// the pixels carrying the actual task change.
struct TakeoverObservationFingerprint: Sendable {
    let semanticSignature: UInt64?
    private let visualFingerprint: PerceptualVisualFingerprint?
    var isAvailable: Bool {
        semanticSignature != nil || visualFingerprint != nil
    }

    init(snapshot: SemanticSnapshot?, screenshotPNG: Data?) {
        semanticSignature = snapshot.map(Self.semanticSignature)
        visualFingerprint = screenshotPNG.flatMap(Self.perceptualVisualFingerprint)
    }

    private static func semanticSignature(_ snapshot: SemanticSnapshot) -> UInt64 {
        var hash = StableFingerprint()
        hash.add(snapshot.applicationName)
        hash.add(snapshot.windowTitle)
        hash.add(snapshot.pageURL ?? "")
        hash.add(snapshot.readableText ?? "")
        for element in snapshot.elements {
            hash.add(element.role.rawValue)
            hash.add(element.label)
            hash.add(element.value ?? "")
            hash.add(element.frame.x)
            hash.add(element.frame.y)
            hash.add(element.frame.width)
            hash.add(element.frame.height)
            hash.add(element.isEnabled ? 1 : 0)
        }
        return hash.value
    }

    fileprivate func isMeaningfullyEquivalent(
        to other: TakeoverObservationFingerprint
    ) -> Bool {
        switch (semanticSignature, other.semanticSignature) {
        case let (left?, right?):
            guard left == right else { return false }
            switch (visualFingerprint, other.visualFingerprint) {
            case let (leftVisual?, rightVisual?):
                return leftVisual.isVisuallySimilar(to: rightVisual)
            default:
                // Screenshot availability is an observation detail, not UI progress.
                return true
            }
        case (nil, nil):
            guard let visualFingerprint, let otherVisual = other.visualFingerprint else {
                return false
            }
            return visualFingerprint.isVisuallySimilar(to: otherVisual)
        default:
            return false
        }
    }

    private static func perceptualVisualFingerprint(
        _ data: Data
    ) -> PerceptualVisualFingerprint? {
        guard !data.isEmpty, let samples = decodedLuminance(from: data) else {
            return nil
        }
        let sum = samples.reduce(0) { $0 + Int($1) }
        let mean = UInt8(clamping: sum / max(1, samples.count))
        let levels = samples.prefix(256).map { $0 >> 4 }
        return PerceptualVisualFingerprint(
            meanLuminance: mean,
            luminanceLevels: levels
        )
    }

    private static func decodedLuminance(from data: Data) -> [UInt8]? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        let width = 16, height = 16
        var pixels = Array(repeating: UInt8(0), count: width * height)
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let baseAddress = buffer.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width,
                    space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                  ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return rendered ? pixels : nil
    }
}

private struct PerceptualVisualFingerprint: Sendable {
    let meanLuminance: UInt8
    /// Absolute 4-bit luminance for each cell. Unlike per-image average hashes,
    /// this does not make a nearly white image flip every bit when one cell darkens.
    let luminanceLevels: [UInt8]

    func isVisuallySimilar(to other: Self) -> Bool {
        let luminanceDelta = abs(Int(meanLuminance) - Int(other.meanLuminance))
        guard luminanceDelta <= 16,
              luminanceLevels.count == other.luminanceLevels.count else {
            return false
        }
        var totalDelta = 0
        var significantlyChangedCells = 0
        for (left, right) in zip(luminanceLevels, other.luminanceLevels) {
            let delta = abs(Int(left) - Int(right))
            totalDelta += delta
            if delta >= 2 { significantlyChangedCells += 1 }
        }
        // Ignore tiny cursor, caret, clock and compression variations while still
        // treating changes across more than ~3% of the coarse image as progress.
        return significantlyChangedCells <= 8 && totalDelta <= 64
    }
}

public struct TakeoverProgressMonitor: Sendable {
    private static let maximumActions = 60
    private static let maximumObservations = 90
    private static let maximumUnchangedActionObservations = 6
    private static let maximumIdenticalObservations = 12
    private static let maximumUnavailableObservations = 3

    private(set) var actionCount = 0
    private(set) var observationCount = 0

    private var lastFingerprint: TakeoverObservationFingerprint?
    private var actionCountAtLastObservation = 0
    private var unchangedActionObservations = 0
    private var identicalObservations = 0
    private var unavailableObservations = 0

    public init() {}

    /// Records an attempted action before it reaches the executor.
    public mutating func recordAction() -> TakeoverProgressDecision {
        guard actionCount < Self.maximumActions else {
            return .stop("连续操作已达到 \(Self.maximumActions) 次，接管已停止以避免失控。")
        }
        actionCount += 1
        return .proceed
    }

    /// Records the latest observation. Unchanged-state checks only advance after an action;
    /// repeated explicit observations are bounded separately by the observation budget.
    public mutating func recordObservation(
        snapshot: SemanticSnapshot?,
        screenshotPNG: Data?
    ) -> TakeoverProgressDecision {
        let fingerprint = TakeoverObservationFingerprint(
            snapshot: snapshot,
            screenshotPNG: screenshotPNG
        )
        guard observationCount < Self.maximumObservations else {
            return .stop("连续观察已达到 \(Self.maximumObservations) 次，接管已停止以避免无效循环。")
        }
        observationCount += 1

        if !fingerprint.isAvailable {
            unavailableObservations += 1
        } else {
            unavailableObservations = 0
        }
        if unavailableObservations >= Self.maximumUnavailableObservations {
            return .stop("连续 \(unavailableObservations) 次无法取得有效界面，接管已停止。")
        }

        let actionOccurred = actionCount > actionCountAtLastObservation
        let meaningfullyUnchanged = lastFingerprint.map {
            fingerprint.isMeaningfullyEquivalent(to: $0)
        } ?? false
        if fingerprint.isAvailable, meaningfullyUnchanged {
            identicalObservations += 1
        } else {
            identicalObservations = 0
        }
        if actionOccurred, meaningfullyUnchanged {
            unchangedActionObservations += 1
        } else if actionOccurred {
            unchangedActionObservations = 0
        }

        lastFingerprint = fingerprint
        actionCountAtLastObservation = actionCount

        if unchangedActionObservations >= Self.maximumUnchangedActionObservations {
            return .stop("执行动作后界面连续 \(unchangedActionObservations) 次没有可确认的变化，接管已停止。")
        }
        if identicalObservations >= Self.maximumIdenticalObservations {
            return .stop("界面连续 \(identicalObservations) 次没有可确认的变化，接管已停止。")
        }
        if unchangedActionObservations
            == Self.maximumUnchangedActionObservations - 1 {
            return .warning("界面已连续 \(unchangedActionObservations) 次没有可确认的变化，请重新定位或更换策略。")
        }
        if identicalObservations == Self.maximumIdenticalObservations - 1 {
            return .warning("界面已连续 \(identicalObservations) 次没有可确认的变化，请重新定位或更换策略。")
        }
        if unavailableObservations == Self.maximumUnavailableObservations - 1 {
            return .warning("已连续 \(unavailableObservations) 次没有取得有效界面，请等待加载或检查窗口状态。")
        }
        return .proceed
    }
}

private struct StableFingerprint {
    private(set) var value: UInt64 = 14_695_981_039_346_656_037

    mutating func add(_ value: String) {
        for byte in value.utf8 { add(byte) }
        add(UInt8(0xFF))
    }

    mutating func add(_ value: Int) {
        add(String(value))
    }

    private mutating func add(_ byte: UInt8) {
        value ^= UInt64(byte)
        value &*= 1_099_511_628_211
    }
}
