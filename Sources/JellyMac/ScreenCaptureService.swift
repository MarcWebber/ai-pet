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

public final class ScreenCaptureService: CaptureService {
    public let prefersSemanticObservation = false
    public let backend: ScreenCapturingBackend
    private let temporaryRoot: URL

    public init(
        backend: ScreenCapturingBackend,
        temporaryRoot: URL = FileManager.default.temporaryDirectory
    ) {
        self.backend = backend; self.temporaryRoot = temporaryRoot
    }

    public func capture(displayID: UInt32) async throws -> CaptureArtifact {
        let image: CGImage
        do {
            image = try await backend.captureFullDisplay(
                displayID: displayID,
                maximumDimension: AppMetadata.maximumScreenshotDimension
            )
        } catch { throw error as? PetFailure ?? .captureFailed }
        try Task.checkCancellation()
        let directory = temporaryRoot.appendingPathComponent(
            "JellyPet-Capture-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let url = directory.appendingPathComponent("screen.png")
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else { throw PetFailure.captureFailed }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: directory)
            throw PetFailure.captureFailed
        }
        return CaptureArtifact(imageURL: url, sessionDirectoryURL: directory)
    }
}

public final class CaptureArtifactCleaner: CaptureCleaning {
    private let root: URL
    public init(allowedRoot: URL = FileManager.default.temporaryDirectory) {
        root = allowedRoot.standardizedFileURL
    }
    public func remove(_ artifact: CaptureArtifact) {
        let directory = artifact.sessionDirectoryURL.standardizedFileURL
        guard directory.deletingLastPathComponent() == root,
              directory.lastPathComponent.hasPrefix("JellyPet-Capture-") else { return }
        try? FileManager.default.removeItem(at: directory)
    }
}

public final class ScreenCaptureCLIBackend: ScreenCapturingBackend {
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
        let displays = try onlineDisplayIDs()
        guard let index = displays.firstIndex(of: displayID) else {
            throw PetFailure.selectedDisplayUnavailable
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "JellyPet-FullDisplay-\(UUID().uuidString).png"
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-C", "-D\(index + 1)", "-tpng", url.path]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw PetFailure.captureFailed
        }
        guard process.terminationStatus == 0,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw PetFailure.captureFailed }
        return try scaled(image, maximumDimension: maximumDimension)
    }

    private func onlineDisplayIDs() throws -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success,
              count > 0 else {
            throw PetFailure.noDisplaysAvailable
        }
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
