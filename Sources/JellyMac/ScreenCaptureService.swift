import CoreGraphics
import Darwin
import Foundation
import ImageIO
import JellyCore
import ScreenCaptureKit
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

public final class ScreenKitBackend: ScreenCapturingBackend {
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
        let picker = SCContentSharingPicker.shared
        picker.isActive = false
        defer { picker.isActive = false }
        let shareable: SCShareableContent
        do { shareable = try await content() }
        catch { throw PetFailure.captureFailed }
        guard let display = shareable.displays.first(where: { $0.displayID == displayID })
        else { throw PetFailure.selectedDisplayUnavailable }
        let ownID = Bundle.main.bundleIdentifier
        let ownApps = shareable.applications.filter {
            $0.processID == getpid() || $0.bundleIdentifier == ownID
                || $0.bundleIdentifier == AppMetadata.bundleIdentifier
        }
        let filter = SCContentFilter(
            display: display, excludingApplications: ownApps, exceptingWindows: []
        )
        let size = CaptureSizing.fit(
            width: display.width, height: display.height,
            maximumDimension: maximumDimension
        )
        let configuration = SCStreamConfiguration()
        configuration.width = size.width; configuration.height = size.height
        configuration.showsCursor = true; configuration.capturesAudio = false
        do {
            return try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: configuration
            )
        } catch { throw PetFailure.captureFailed }
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

    private func content() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
    }
}
