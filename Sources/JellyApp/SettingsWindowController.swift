import AppKit
import JellyCore

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    let window: NSWindow
    let form = SettingsFormView()
    private let scrollView = NSScrollView()

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
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        form.frame = NSRect(x: 0, y: 0, width: 700, height: 1_400)
        form.autoresizingMask = [.width]
        scrollView.documentView = form
        window.contentView = scrollView
        window.center()
    }

    func update(_ state: SettingsViewState) {
        window.title = "果冻设置"
        form.render(state)
    }

    func show() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func hide() {
        window.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
