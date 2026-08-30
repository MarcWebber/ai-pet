import AppKit
import Darwin
import JellyCore
import JellyMac

@main
private enum JellyPetMain {
    private static var instanceLock: Int32 = -1
    @MainActor
    static func main() {
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
