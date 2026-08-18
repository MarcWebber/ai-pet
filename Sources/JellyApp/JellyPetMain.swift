import AppKit
import CoreGraphics
import Darwin
import JellyCore
import JellyMac

@main
private enum JellyPetMain {
    private static var instanceLock: Int32 = -1

    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--print-main-display-id") {
            print(CGMainDisplayID())
            exit(EXIT_SUCCESS)
        }

        if CommandLine.arguments.contains("--verify-resources") {
            let message = JellyView.verifyBehaviorConfiguration()
            print(message)
            exit(message.hasSuffix("passed.") ? EXIT_SUCCESS : EXIT_FAILURE)
        }

        if CommandLine.arguments.contains("--verify-visuals") {
            let result = VisualVerifier.verifyPetTransparency()
            print(result.message)
            exit(result.passed ? EXIT_SUCCESS : EXIT_FAILURE)
        }

        if CommandLine.arguments.contains("--sweep-temporary-artifacts") {
            TemporaryArtifactSweeper().removeAll()
            print("Temporary JellyPet artifacts removed.")
            exit(EXIT_SUCCESS)
        }

        guard acquireInstanceLock() else {
            NSRunningApplication.runningApplications(
                withBundleIdentifier: AppMetadata.bundleIdentifier
            ).first?.activate(options: [])
            exit(EXIT_SUCCESS)
        }

        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }

    private static func acquireInstanceLock() -> Bool {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("JellyPet-single-instance.lock")
        instanceLock = Darwin.open(path, O_CREAT | O_RDWR, 0o600)
        return instanceLock >= 0
            && flock(instanceLock, LOCK_EX | LOCK_NB) == 0
    }

}
