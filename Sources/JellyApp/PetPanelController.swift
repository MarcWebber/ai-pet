import AppKit
import JellyCore

@MainActor
final class PetPanelController {
    let panel: NSPanel
    let jellyView: JellyView
    var onClick: (() -> Void)?
    var onRightClick: (() -> Void)?
    var onDock: (() -> Void)?
    var onFrameChange: (() -> Void)?
    private var dragStart = (mouse: NSPoint.zero, origin: NSPoint.zero)
    private var placed = false

    init() {
        panel = NSPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: JellyView.panelWidth,
                height: JellyView.panelHeight
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        jellyView = JellyView(frame: panel.contentView?.bounds ?? .zero)
        jellyView.autoresizingMask = [.width, .height]
        panel.contentView = jellyView
        jellyView.onClick = { [weak self] in self?.onClick?() }
        jellyView.onRightClick = { [weak self] _ in self?.onRightClick?() }
        jellyView.onDragBegan = { [weak self] in self?.beginDrag($0) }
        jellyView.onDragChanged = { [weak self] in self?.drag($0) }
        jellyView.onDragEnded = { [weak self] in self?.finishDrag() }
    }

    func show(on screen: NSScreen? = nil) {
        if !placed { placeAtBottomRight(of: screen ?? .main); placed = true }
        panel.orderFrontRegardless()
    }
    func hide() { panel.orderOut(nil) }
    func setClickThrough(_ enabled: Bool) { panel.ignoresMouseEvents = enabled }

    func placeAtBottomRight(of screen: NSScreen?) {
        guard let screen else { panel.center(); return }
        panel.setFrameOrigin(NSPoint(
            x: screen.visibleFrame.maxX - panel.frame.width - 28,
            y: screen.visibleFrame.minY + 28
        ))
        onFrameChange?()
    }

    private func beginDrag(_ point: NSPoint) {
        dragStart = (point, panel.frame.origin)
    }

    private func drag(_ point: NSPoint) {
        panel.setFrameOrigin(NSPoint(
            x: dragStart.origin.x + point.x - dragStart.mouse.x,
            y: dragStart.origin.y + point.y - dragStart.mouse.y
        ))
        onFrameChange?()
    }

    private func finishDrag() {
        let screen = NSScreen.screens.first { $0.frame.intersects(panel.frame) }
            ?? panel.screen ?? .main
        guard let screen else { return }
        let result = EdgeSnapCalculator().snap(
            pet: Rect(panel.frame), screen: Rect(screen.visibleFrame)
        )
        panel.setFrame(result.frame.nsRect, display: true, animate: true)
        if result.edge != nil { onDock?() }
        onFrameChange?()
    }
}

private extension Rect {
    init(_ rect: NSRect) {
        self.init(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
    }
    var nsRect: NSRect { NSRect(x: x, y: y, width: width, height: height) }
}
