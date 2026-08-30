import CoreGraphics
import Foundation
import ImageIO
import JellyCore
import UniformTypeIdentifiers

/// The only product-level screen implementation. Observation is always an
/// explicit, silent full-display capture plus a fresh Accessibility snapshot.
@MainActor
public final class ScreenDriver: ScreenDriving {
    private let semantics: BrowserAccessibilityContextProvider
    private let actions: CGEventScreenActionExecutor
    public init(
        typingSpeedPercent: @escaping () -> Int = {
            TypingRhythm.defaultSpeedPercent
        }
    ) {
        let semantics = BrowserAccessibilityContextProvider()
        self.semantics = semantics
        actions = CGEventScreenActionExecutor(
            semanticProvider: semantics,
            typingSpeedPercent: typingSpeedPercent
        )
    }
    public func observe(displayID: UInt32) async throws -> ScreenObservation {
        let image = try capture(displayID)
        try Task.checkCancellation()
        let semantic = await semantics.snapshot(displayID: displayID)
        return ScreenObservation(
            semantics: semantic,
            screenshotPNG: try Self.pngData(image)
        )
    }
    public func availableDisplays() -> [DisplayDescriptor] {
        (try? Self.onlineDisplayIDs())?.enumerated().map { index, id in
            DisplayDescriptor(
                id: id,
                name: CGDisplayIsBuiltin(id) != 0 ? "内建显示器" : "显示器 \(index + 1)",
                width: CGDisplayPixelsWide(id), height: CGDisplayPixelsHigh(id),
                isPrimary: CGDisplayIsMain(id) != 0
            )
        } ?? []
    }
    public func execute(
        _ action: ScreenAction,
        observation: ScreenObservation,
        displayID: UInt32
    ) async throws {
        try await actions.execute(
            action,
            snapshot: observation.semantics,
            displayID: displayID
        )
    }
    public func cancel() { actions.cancel() }
    private func capture(_ displayID: UInt32) throws -> CGImage {
        guard CGPreflightScreenCaptureAccess() else {
            throw PetFailure.screenCapturePermissionRequired
        }
        _ = try Self.onlineBounds(displayID)
        guard let image = CGDisplayCreateImage(displayID) else {
            throw PetFailure.captureFailed
        }
        let longest = max(image.width, image.height)
        guard longest > AppMetadata.maximumScreenshotDimension else { return image }
        let scale = Double(AppMetadata.maximumScreenshotDimension) / Double(longest)
        let size = CGSize(
            width: Int((Double(image.width) * scale).rounded()),
            height: Int((Double(image.height) * scale).rounded())
        )
        guard let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw PetFailure.captureFailed }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: size))
        guard let scaled = context.makeImage() else { throw PetFailure.captureFailed }
        return scaled
    }
    private static func pngData(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { throw PetFailure.captureFailed }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw PetFailure.captureFailed
        }
        return data as Data
    }
    static func onlineDisplayIDs() throws -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success,
              count > 0 else { throw PetFailure.noDisplaysAvailable }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else {
            throw PetFailure.noDisplaysAvailable
        }
        return Array(ids.prefix(Int(count)))
    }
    static func onlineBounds(_ displayID: UInt32) throws -> CGRect {
        guard try onlineDisplayIDs().contains(displayID) else {
            throw PetFailure.selectedDisplayUnavailable
        }
        let bounds = CGDisplayBounds(displayID)
        guard bounds.width > 0, bounds.height > 0 else {
            throw PetFailure.selectedDisplayUnavailable
        }
        return bounds
    }
}
