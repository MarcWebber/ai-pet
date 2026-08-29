import CoreGraphics
import Foundation
import ImageIO
import JellyCore
import UniformTypeIdentifiers

public protocol ScreenCapturingBackend: AnyObject {
    func availableDisplays() async throws -> [DisplayDescriptor]
    func captureFullDisplay(
        displayID: UInt32,
        maximumDimension: Int
    ) async throws -> CGImage
}

/// The only product-level screen implementation. Observation is always an
/// explicit, silent full-display capture plus a fresh Accessibility snapshot.
@MainActor
public final class ScreenDriver: ScreenDriving {
    public let backend: ScreenCapturingBackend
    private let semantics: BrowserAccessibilityContextProvider
    private let actions: CGEventScreenActionExecutor

    public init(
        backend: ScreenCapturingBackend = FullDisplayBackend(),
        typingSpeedPercent: @escaping () -> Int = {
            TypingRhythm.defaultSpeedPercent
        }
    ) {
        self.backend = backend
        let semantics = BrowserAccessibilityContextProvider()
        self.semantics = semantics
        actions = CGEventScreenActionExecutor(
            semanticProvider: semantics,
            typingSpeedPercent: typingSpeedPercent
        )
    }

    public func observe(displayID: UInt32) async throws -> ScreenObservation {
        let image = try await backend.captureFullDisplay(
            displayID: displayID,
            maximumDimension: AppMetadata.maximumScreenshotDimension
        )
        try Task.checkCancellation()
        let semantic = await semantics.snapshot(displayID: displayID)
        return ScreenObservation(
            displayID: displayID,
            semantics: semantic,
            screenshotPNG: try Self.pngData(image)
        )
    }

    public func execute(
        _ action: ScreenAction,
        observation: ScreenObservation,
        displayID: UInt32
    ) async throws {
        guard observation.displayID == displayID else {
            throw PetFailure.selectedDisplayUnavailable
        }
        try await actions.execute(
            action,
            snapshot: observation.semantics,
            displayID: displayID
        )
    }

    public func cancel() { actions.cancel() }

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
}

/// Low-level full-display backend used by ScreenDriver and the display picker.
/// It never invokes `screencapture`, sends a keyboard shortcut, or enters an
/// interactive selection mode.
public final class FullDisplayBackend: ScreenCapturingBackend {
    public init() {}

    public func availableDisplays() async throws -> [DisplayDescriptor] {
        try onlineDisplayIDs().enumerated().map { index, displayID in
            DisplayDescriptor(
                id: displayID,
                name: CGDisplayIsBuiltin(displayID) != 0
                    ? "内建显示器" : "显示器 \(index + 1)",
                width: CGDisplayPixelsWide(displayID),
                height: CGDisplayPixelsHigh(displayID),
                isPrimary: CGDisplayIsMain(displayID) != 0
            )
        }
    }

    public func captureFullDisplay(
        displayID: UInt32,
        maximumDimension: Int
    ) async throws -> CGImage {
        guard CGPreflightScreenCaptureAccess() else {
            throw PetFailure.screenCapturePermissionRequired
        }
        guard try onlineDisplayIDs().contains(displayID) else {
            throw PetFailure.selectedDisplayUnavailable
        }
        guard let image = CGDisplayCreateImage(displayID) else {
            throw PetFailure.captureFailed
        }
        return try scaled(image, maximumDimension: maximumDimension)
    }

    private func onlineDisplayIDs() throws -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success,
              count > 0 else { throw PetFailure.noDisplaysAvailable }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else {
            throw PetFailure.noDisplaysAvailable
        }
        return Array(ids.prefix(Int(count)))
    }

    private func scaled(
        _ image: CGImage,
        maximumDimension: Int
    ) throws -> CGImage {
        let size = CaptureSizing.fit(
            width: image.width,
            height: image.height,
            maximumDimension: maximumDimension
        )
        guard size.width != image.width || size.height != image.height else {
            return image
        }
        guard let context = CGContext(
            data: nil,
            width: size.width,
            height: size.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw PetFailure.captureFailed }
        context.interpolationQuality = .high
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: size.width, height: size.height)
        )
        guard let result = context.makeImage() else {
            throw PetFailure.captureFailed
        }
        return result
    }
}
