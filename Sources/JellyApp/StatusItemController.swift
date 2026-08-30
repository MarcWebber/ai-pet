import AppKit
import JellyCore

@MainActor
final class StatusItemController: NSObject {
    enum Action: String { case primary, pet, mute, settings, quit }
    var onAction: ((Action) -> Void)?
    private let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var items: [Action: NSMenuItem] = [:]
    override init() {
        super.init()
        status.button?.image = NSImage(
            systemSymbolName: "sparkles", accessibilityDescription: "果冻"
        )
        status.button?.contentTintColor = .systemPurple
        let menu = NSMenu()
        add(.primary, "分析当前屏幕", to: menu)
        add(.pet, "最小化果冻", to: menu)
        add(.mute, "静音", to: menu)
        menu.addItem(.separator())
        add(.settings, "设置…", key: ",", to: menu)
        menu.addItem(.separator())
        add(.quit, "退出果冻", key: "q", to: menu)
        status.menu = menu
        update(
            isPetVisible: true, isMuted: false, isTakeoverEnabled: false,
            isTakingOver: false, takeoverStatus: nil,
            shortcutLabel: AppMetadata.shortcutLabel
        )
    }
    func update(
        isPetVisible: Bool,
        isMuted: Bool,
        isTakeoverEnabled: Bool,
        isTakingOver: Bool,
        takeoverStatus: String?,
        shortcutLabel: String
    ) {
        items[.primary]?.title = isTakingOver ? "取消接管"
            : isTakeoverEnabled ? "接管当前屏幕（Beta）" : "分析当前屏幕"
        items[.pet]?.title = isPetVisible ? "最小化果冻" : "显示宠物"
        items[.pet]?.isEnabled = !isTakingOver
        items[.settings]?.isEnabled = !isTakingOver
        items[.mute]?.title = isMuted ? "恢复音效" : "静音"
        status.button?.toolTip = isTakingOver
            ? "\(takeoverStatus ?? "接管中") · \(shortcutLabel) 停止"
            : "果冻 · \(shortcutLabel)"
    }
    func showMenu() { status.button?.performClick(nil) }
    private func add(_ action: Action, _ title: String, key: String = "", to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: #selector(handleAction), keyEquivalent: key)
        item.target = self
        item.representedObject = action.rawValue
        items[action] = item
        menu.addItem(item)
    }
    @objc private func handleAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let action = Action(rawValue: raw)
        else { return }
        onAction?(action)
    }
}
