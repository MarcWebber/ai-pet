import AppKit
import JellyCore

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    let window: NSWindow
    let form = SettingsFormView()
    override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 820),
            styleMask: [
                .titled,
                .closable,
                .miniaturizable,
                .fullSizeContentView
            ],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.delegate = self
        window.title = "果冻设置"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.level = .floating
        window.collectionBehavior = [
            .moveToActiveSpace,
            .fullScreenAuxiliary
        ]
        window.minSize = NSSize(width: 660, height: 650)
        window.contentView = form
        window.center()
    }
    func update(_ state: SettingsViewState) {
        form.render(state)
    }
    func show() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
    func hide() {
        window.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
    }
    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
