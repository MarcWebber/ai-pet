import AppKit
import JellyCore

@MainActor
final class SettingsFormView: NSView, NSTextFieldDelegate, NSComboBoxDelegate {
    enum Action {
        case display(UInt32)
        case assistant(AssistantPreferences)
        case takeover(Bool)
        case activityDetails(Bool)
        case shortcut(GlobalShortcut)
        case answerScrollShortcut(AnswerScrollShortcut)
        case answerHistoryShortcut(AnswerHistoryShortcut)
        case finish
    }
    override var isFlipped: Bool { true }
    var onAction: ((Action) -> Void)?

    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(wrappingLabelWithString: "")
    private let display = NSPopUpButton()
    private let displayDetail = NSTextField(labelWithString: "")
    private let runtime = NSPopUpButton()
    private let model = NSComboBox()
    private let effort = NSPopUpButton()
    private let takeover = NSSwitch()
    private let activityDetails = NSSwitch()
    private let custom = NSTextField()
    private let shortcut = NSPopUpButton()
    private let answerScrollShortcut = NSPopUpButton()
    private let answerHistoryShortcut = NSPopUpButton()
    private let runtimeStatus = NSTextField(wrappingLabelWithString: "检查中…")
    private let done = NSButton()
    private var displays: [DisplayDescriptor] = []
    private var assistant = AssistantPreferences.default
    private let automaticModelLabel = "自动（使用 Runtime 默认模型）"

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildContent()
    }

    required init?(coder: NSCoder) { nil }

    func render(_ state: SettingsViewState) {
        assistant = state.assistantPreferences
        title.stringValue = "果冻设置"
        subtitle.stringValue = "配置屏幕、本地 Agent Runtime 与工作模式；新配置从下一轮生效。"
        done.title = "完成"
        renderDisplays(state)
        renderRuntimes(state)
        renderModels(state)
        select(state.assistantPreferences.reasoningEffort.rawValue, in: effort)
        select(state.globalShortcut.rawValue, in: shortcut)
        select(state.answerScrollShortcut.rawValue, in: answerScrollShortcut)
        select(state.answerHistoryShortcut.rawValue, in: answerHistoryShortcut)
        takeover.state = state.takeoverEnabled ? .on : .off
        activityDetails.state = state.showActivityDetails ? .on : .off
        if custom.currentEditor() == nil {
            custom.stringValue = state.assistantPreferences.customInstructions
        }
        runtimeStatus.stringValue = state.runtimeText
        runtimeStatus.toolTip = state.runtimeText
        done.isEnabled = true
    }

    private func renderDisplays(_ state: SettingsViewState) {
        displays = state.displays
        display.removeAllItems()
        display.addItem(withTitle: "选择果冻要观察的屏幕…")
        for item in displays {
            display.addItem(withTitle: item.name)
            display.lastItem?.representedObject = NSNumber(value: item.id)
        }
        if let id = state.selectedDisplayID,
           let item = display.itemArray.first(where: {
               ($0.representedObject as? NSNumber)?.uint32Value == id
           }) {
            display.select(item)
            displayDetail.stringValue = detail(for: displays.first { $0.id == id })
        } else {
            display.selectItem(at: 0)
            displayDetail.stringValue = displays.isEmpty
                ? "授权后会列出可用屏幕" : "请选择一个屏幕"
        }
        display.isEnabled = !displays.isEmpty
    }

    private func buildContent() {
        let backdrop = NSVisualEffectView()
        backdrop.material = .sidebar
        backdrop.blendingMode = .behindWindow
        let mark = JellyMarkView(size: 56)
        title.font = .systemFont(ofSize: 25, weight: .bold)
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        let heading = stack([mark, stack([title, subtitle], .vertical, 4)], .horizontal, 14)

        configure(display, action: #selector(displayChanged))
        configure(
            runtime,
            values: AgentRuntimeKind.allCases,
            title: \.displayName,
            action: #selector(runtimeChanged)
        )
        model.usesDataSource = false
        model.completes = true
        model.delegate = self
        configure(model, action: #selector(modelChanged))
        configure(effort, values: ReasoningEffort.allCases, title: \.displayName, action: #selector(effortChanged))
        configure(shortcut, values: GlobalShortcut.allCases, title: \.label, action: #selector(shortcutChanged))
        configure(
            answerScrollShortcut,
            values: AnswerScrollShortcut.allCases,
            title: \.label,
            action: #selector(answerScrollShortcutChanged)
        )
        answerScrollShortcut.toolTip = "回答打开时，上箭头向上翻页，下箭头向下翻页。"
        configure(
            answerHistoryShortcut,
            values: AnswerHistoryShortcut.allCases,
            title: \.label,
            action: #selector(answerHistoryShortcutChanged)
        )
        answerHistoryShortcut.toolTip = "左箭头查看上一次回答，右箭头返回下一次回答。"
        configure(takeover, action: #selector(takeoverChanged))
        configure(activityDetails, action: #selector(activityDetailsChanged))
        custom.placeholderString = "自定义指令，例如：检查结果后再提交"
        custom.delegate = self
        custom.toolTip = "追加给当前 Agent，不会覆盖截图问答边界。"

        configure(done, title: "完成", action: #selector(finishSetup))
        done.keyEquivalent = "\r"

        let displayBlock = stack([display, displayDetail], .vertical, 3)
        let modelBlock = stack([model, effort], .horizontal, 8)
        let takeoverBlock = stack([label("允许果冻执行鼠标和键盘动作"), NSView(), takeover], .horizontal, 8)
        let activityBlock = stack([label("显示观察、工具调用、回复和操作结果"), NSView(), activityDetails], .horizontal, 8)
        let rows = stack([
            row("观察屏幕", displayBlock),
            row("Agent Runtime", runtime),
            row("模型配置", modelBlock),
            row("自定义指令", custom),
            row("运行模式", takeoverBlock),
            row("聊天记录", activityBlock),
            row("探测结果", runtimeStatus),
            row("唤醒快捷键", shortcut),
            row("回答滚动", answerScrollShortcut),
            row("回答切换", answerHistoryShortcut)
        ], .vertical, 10)
        let card = SoftGlassView(cornerRadius: 22)
        card.addSubview(rows)
        rows.translatesAutoresizingMaskIntoConstraints = false
        let footer = stack([
            label("右键果冻打开菜单，拖到边缘会自动吸附。", color: .tertiaryLabelColor),
            NSView(), done
        ], .horizontal, 10)
        let content = stack([heading, card, footer], .vertical, 14)

        [backdrop, content].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 30),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -30),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            heading.widthAnchor.constraint(equalTo: content.widthAnchor),
            card.widthAnchor.constraint(equalTo: content.widthAnchor),
            footer.widthAnchor.constraint(equalTo: content.widthAnchor),
            rows.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            rows.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
            rows.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            rows.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
            custom.widthAnchor.constraint(greaterThanOrEqualToConstant: 300),
            model.widthAnchor.constraint(greaterThanOrEqualToConstant: 230),
            done.widthAnchor.constraint(greaterThanOrEqualToConstant: 110)
        ])
    }

    private func row(_ name: String, _ control: NSView) -> NSStackView {
        let name = label(name, weight: .semibold)
        name.widthAnchor.constraint(equalToConstant: 100).isActive = true
        let row = stack([name, control], .horizontal, 12)
        row.widthAnchor.constraint(greaterThanOrEqualToConstant: 480).isActive = true
        return row
    }

    private func label(
        _ value: String,
        color: NSColor = .secondaryLabelColor,
        weight: NSFont.Weight = .regular
    ) -> NSTextField {
        let field = NSTextField(labelWithString: value)
        field.font = .systemFont(ofSize: 12, weight: weight)
        field.textColor = color
        return field
    }

    private func stack(_ views: [NSView], _ orientation: NSUserInterfaceLayoutOrientation, _ spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = orientation
        stack.alignment = orientation == .horizontal ? .centerY : .leading
        stack.spacing = spacing
        return stack
    }

    private func configure(_ control: NSControl, action: Selector) {
        control.target = self
        control.action = action
    }

    private func configure(_ button: NSButton, title: String, action: Selector) {
        button.title = title
        button.bezelStyle = .rounded
        button.controlSize = .small
        configure(button, action: action)
    }

    private func configure<Value: RawRepresentable>(
        _ popup: NSPopUpButton,
        values: [Value],
        title: KeyPath<Value, String>,
        action: Selector
    ) where Value.RawValue == String {
        for value in values {
            popup.addItem(withTitle: value[keyPath: title])
            popup.lastItem?.representedObject = value.rawValue
        }
        configure(popup, action: action)
    }

    private func select(_ rawValue: String, in popup: NSPopUpButton) {
        popup.select(popup.itemArray.first { ($0.representedObject as? String) == rawValue })
    }

    private func selected<Value: RawRepresentable>(_ popup: NSPopUpButton) -> Value? where Value.RawValue == String {
        (popup.selectedItem?.representedObject as? String).flatMap(Value.init(rawValue:))
    }

    private func publishAssistant(
        runtime: AgentRuntimeKind? = nil,
        model: String? = nil,
        effort: ReasoningEffort? = nil,
        customInstructions: String? = nil
    ) {
        assistant = AssistantPreferences(
            runtime: runtime ?? assistant.runtime,
            model: model ?? assistant.model,
            reasoningEffort: effort ?? assistant.reasoningEffort,
            customInstructions: customInstructions ?? assistant.customInstructions
        )
        onAction?(.assistant(assistant))
    }

    @objc private func displayChanged() {
        guard let id = (display.selectedItem?.representedObject as? NSNumber)?.uint32Value else { return }
        displayDetail.stringValue = detail(for: displays.first { $0.id == id })
        onAction?(.display(id))
    }

    @objc private func runtimeChanged() {
        guard let value: AgentRuntimeKind = selected(runtime) else { return }
        publishAssistant(
            runtime: value,
            model: AssistantPreferences.automaticModel
        )
    }
    @objc private func modelChanged() {
        publishAssistant(model: normalizedModel(model.stringValue))
    }
    @objc private func effortChanged() { publishAssistant(effort: selected(effort)) }
    @objc private func takeoverChanged() {
        onAction?(.takeover(takeover.state == .on))
    }
    @objc private func activityDetailsChanged() {
        onAction?(.activityDetails(activityDetails.state == .on))
    }
    @objc private func shortcutChanged() {
        if let value: GlobalShortcut = selected(shortcut) { onAction?(.shortcut(value)) }
    }
    @objc private func answerScrollShortcutChanged() {
        if let value: AnswerScrollShortcut = selected(answerScrollShortcut) {
            onAction?(.answerScrollShortcut(value))
        }
    }
    @objc private func answerHistoryShortcutChanged() {
        if let value: AnswerHistoryShortcut = selected(answerHistoryShortcut) {
            onAction?(.answerHistoryShortcut(value))
        }
    }
    @objc private func finishSetup() { onAction?(.finish) }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field === custom {
            publishAssistant(customInstructions: custom.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        } else if field === model {
            publishAssistant(model: normalizedModel(model.stringValue))
        }
    }

    private func renderRuntimes(_ state: SettingsViewState) {
        let automaticRuntime = [
            AgentRuntimeKind.codex,
            .traex,
            .claudeCode,
            .openCode
        ].first { state.availableRuntimes.contains($0) }
        for item in runtime.itemArray {
            guard let rawValue = item.representedObject as? String,
                  let kind = AgentRuntimeKind(rawValue: rawValue) else { continue }
            if kind == .automatic {
                let resolved = automaticRuntime.map { " · \($0.displayName)" } ?? ""
                item.title = "自动选择\(resolved)"
                item.isEnabled = true
            } else {
                let installed = state.availableRuntimes.contains(kind)
                item.title = installed
                    ? kind.displayName : "\(kind.displayName)（未找到）"
                item.isEnabled = installed
            }
        }
        select(state.assistantPreferences.runtime.rawValue, in: runtime)
    }

    private func renderModels(_ state: SettingsViewState) {
        let current = state.assistantPreferences.model
        model.removeAllItems()
        model.addItem(withObjectValue: automaticModelLabel)
        model.addItems(withObjectValues: state.modelOptions)
        model.stringValue = current == AssistantPreferences.automaticModel
            ? automaticModelLabel : current
        model.toolTip = "可从探测结果中选择，也可以直接输入 Runtime 支持的模型 ID。"
    }

    private func normalizedModel(_ value: String) -> String {
        let model = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.isEmpty || model == automaticModelLabel
            ? AssistantPreferences.automaticModel
            : String(model.prefix(200))
    }

    private func detail(for display: DisplayDescriptor?) -> String {
        guard let display else { return "请选择一个屏幕" }
        return "\(display.width) × \(display.height)\(display.isPrimary ? " · 主屏幕" : "")"
    }
}
