import AppKit
import JellyCore

private final class JellyBubblePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private final class BubbleInput: NSTextField {
    override var needsPanelToBecomeKey: Bool { true }
}

@MainActor
final class BubblePanelController: NSObject {
    private enum Purpose { case screenQuestion, followUp, takeover }

    let panel: NSPanel
    var onQuestionSubmit: ((String) -> Void)?
    var onSubmit: ((String) -> Void)?
    var onTakeoverSubmit: ((String) -> Void)?
    var onTakeoverToggle: ((Bool, String) -> Void)?
    var onClose: (() -> Void)?

    private let title = NSTextField(labelWithString: "果冻")
    private let badge = NSTextField(labelWithString: "")
    private let text: NSTextView
    private let scroll: NSScrollView
    private let input = BubbleInput()
    private let send = NSButton()
    private let spinner = NSProgressIndicator()
    private let takeoverSwitch = NSSwitch()
    private let takeoverTitle = NSTextField(labelWithString: "接管")
    private let takeoverHint = NSTextField(labelWithString: "开启后果冻可以操作当前屏幕")
    private let takeoverBeta = NSTextField(labelWithString: "BETA")
    private let takeoverRow = NSStackView()
    private let footer = NSStackView()
    private var purpose = Purpose.followUp
    private var takeoverShortcutLabel = AppMetadata.shortcutLabel
    private var escapeMonitor: Any?

    override init() {
        let answerScroll = NSTextView.scrollableTextView()
        guard let answerText = answerScroll.documentView as? NSTextView else {
            preconditionFailure("NSTextView.scrollableTextView() must provide an NSTextView")
        }
        text = answerText
        scroll = answerScroll
        panel = JellyBubblePanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 260),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        buildContent()
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard event.keyCode == 53, self?.panel.isVisible == true else { return event }
            self?.onClose?()
            return nil
        }
    }

    deinit {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
    }

    func showQuestionComposer(
        initialQuestion: String = "",
        petFrame: NSRect,
        screen: NSScreen?
    ) {
        input.stringValue = String(initialQuestion.prefix(4_000))
        show(
            title: "问果冻当前屏幕",
            badge: "截图问答",
            body: "输入问题并发送，果冻会截取所选屏幕后回答；它不会操作页面。",
            size: NSSize(width: 420, height: 286),
            inputPlaceholder: "例如：这个页面现在需要我做什么？",
            purpose: .screenQuestion,
            takeoverEnabled: false,
            activates: true,
            near: petFrame,
            on: screen
        )
    }

    func showAnswer(
        _ message: String,
        question: String? = nil,
        historyPosition: (current: Int, total: Int)? = nil,
        preferences: AssistantPreferences?,
        petFrame: NSRect,
        screen: NSScreen?
    ) {
        let position = historyPosition.map {
            " · \($0.current)/\($0.total)"
        } ?? ""
        show(
            title: "果冻看到了这些\(position)",
            badge: preferences?.compactLabel ?? "默认配置",
            body: answerBody(message, question: question),
            size: NSSize(width: 430, height: 318),
            inputPlaceholder: "继续问一句…",
            takeoverEnabled: false,
            activates: true,
            near: petFrame,
            on: screen
        )
    }

    func showWorking(
        previousMessage: String?,
        preferences: AssistantPreferences?,
        takeoverEnabled: Bool,
        petFrame: NSRect,
        screen: NSScreen?
    ) {
        show(
            title: "果冻正在想…",
            badge: preferences?.compactLabel ?? "默认配置",
            body: previousMessage?.isEmpty == false ? previousMessage! : "正在观察屏幕，很快回来。",
            size: NSSize(width: 420, height: 286),
            working: true,
            takeoverEnabled: takeoverEnabled,
            near: petFrame,
            on: screen
        )
    }

    func showError(
        _ message: String,
        preferences: AssistantPreferences?,
        takeoverEnabled: Bool,
        petFrame: NSRect,
        screen: NSScreen?
    ) {
        show(
            title: "果冻需要一点帮助",
            badge: preferences?.compactLabel ?? "错误",
            body: message,
            size: NSSize(width: 390, height: 245),
            takeoverEnabled: takeoverEnabled,
            near: petFrame,
            on: screen
        )
    }

    func showTakeoverComposer(
        initialTask: String = "",
        petFrame: NSRect,
        screen: NSScreen?
    ) {
        input.stringValue = String(initialTask.prefix(4_000))
        show(
            title: "告诉果冻要做什么",
            badge: "屏幕接管 · Beta",
            body: "Beta 功能：输入明确任务后，果冻可能执行鼠标和键盘动作。开始后按 \(takeoverShortcutLabel) 可随时快速退出。",
            size: NSSize(width: 390, height: 224),
            inputPlaceholder: "例如：完成这道题并提交",
            purpose: .takeover,
            takeoverEnabled: true,
            activates: true,
            near: petFrame,
            on: screen
        )
    }

    func showTakeoverResult(
        _ message: String,
        events: [TakeoverEvent] = [],
        isError: Bool,
        preferences: AssistantPreferences?,
        showsActivityDetails: Bool,
        petFrame: NSRect,
        screen: NSScreen?
    ) {
        show(
            title: isError ? "果冻停下来了" : "果冻完成了",
            badge: preferences?.compactLabel ?? "默认配置",
            body: timeline(
                events,
                final: message,
                showsActivityDetails: showsActivityDetails
            ),
            size: showsActivityDetails
                ? NSSize(width: 520, height: 400)
                : NSSize(width: 390, height: 240),
            takeoverEnabled: true,
            near: petFrame,
            on: screen
        )
    }

    func showTakeoverProgress(
        _ snapshot: TakeoverSnapshot,
        preferences: AssistantPreferences,
        showsActivityDetails: Bool,
        petFrame: NSRect,
        screen: NSScreen?
    ) {
        let metrics = snapshot.metrics.map {
            "操作 \($0.actionCount) · 观察 \($0.observationCount) · \(Int($0.durationSeconds)) 秒"
        }
        show(
            title: "果冻 · \(snapshot.activity.label)",
            badge: preferences.compactLabel,
            body: timeline(
                snapshot.events,
                final: [snapshot.message, metrics]
                    .compactMap { $0 }.joined(separator: "\n"),
                showsActivityDetails: showsActivityDetails
            ),
            size: showsActivityDetails
                ? NSSize(width: 520, height: 400)
                : NSSize(width: 430, height: 304),
            inputPlaceholder: "接管中，可补充要求…",
            working: snapshot.isActive,
            purpose: .takeover,
            takeoverEnabled: true,
            near: petFrame,
            on: screen
        )
    }

    func reposition(petFrame: NSRect, screen: NSScreen?) {
        if panel.isVisible { position(near: petFrame, on: screen) }
    }

    func setTakeoverShortcutLabel(_ label: String) {
        takeoverShortcutLabel = label
    }

    func verifyTakeoverToggleLayout() -> (passed: Bool, message: String) {
        panel.setContentSize(NSSize(width: 420, height: 286))
        panel.contentView?.layoutSubtreeIfNeeded()
        takeoverRow.layoutSubtreeIfNeeded()
        let switchFrame = takeoverRow.convert(
            takeoverSwitch.bounds,
            from: takeoverSwitch
        )
        let betaFrame = takeoverRow.convert(
            takeoverBeta.bounds,
            from: takeoverBeta
        )
        let rowBounds = takeoverRow.bounds
        let switchFits = rowBounds.insetBy(dx: -1, dy: -1)
            .contains(switchFrame)
        let betaFits = rowBounds.insetBy(dx: -1, dy: -1)
            .contains(betaFrame)
        let accessibilityLabel = takeoverSwitch.accessibilityLabel()
        let passed = rowBounds.width >= 360
            && rowBounds.height >= 20
            && switchFits
            && betaFits
            && switchFrame.width >= 30
            && accessibilityLabel == "屏幕接管"
        return (
            passed,
            "row=\(Int(rowBounds.width))×\(Int(rowBounds.height)), switch=\(Int(switchFrame.minX)),\(Int(switchFrame.minY)) \(Int(switchFrame.width))×\(Int(switchFrame.height)) fits=\(switchFits), beta=\(Int(betaFrame.minX)),\(Int(betaFrame.minY)) \(Int(betaFrame.width))×\(Int(betaFrame.height)) fits=\(betaFits), label=\(accessibilityLabel ?? "nil")"
        )
    }

    @discardableResult
    func scrollAnswerUp() -> Bool {
        scrollAnswer(pageOffset: -1)
    }

    @discardableResult
    func scrollAnswerDown() -> Bool {
        scrollAnswer(pageOffset: 1)
    }

    func hide() {
        spinner.stopAnimation(nil)
        panel.orderOut(nil)
        input.stringValue = ""
        panel.ignoresMouseEvents = false
        purpose = .followUp
    }

    private func show(
        title titleValue: String,
        badge badgeValue: String,
        body: String,
        size: NSSize,
        inputPlaceholder: String? = nil,
        working: Bool = false,
        purpose: Purpose = .followUp,
        takeoverEnabled: Bool,
        activates: Bool = false,
        ignoresMouse: Bool = false,
        near petFrame: NSRect,
        on screen: NSScreen?
    ) {
        title.stringValue = titleValue
        badge.stringValue = badgeValue
        text.string = body
        input.placeholderString = inputPlaceholder
        input.isHidden = inputPlaceholder == nil
        send.isHidden = inputPlaceholder == nil
        footer.isHidden = inputPlaceholder == nil
        takeoverSwitch.state = takeoverEnabled ? .on : .off
        takeoverSwitch.isEnabled = !working
            || (purpose == .takeover && takeoverEnabled)
        takeoverSwitch.toolTip = working
            && purpose == .takeover
            && takeoverEnabled
            ? "关闭开关会立即停止当前接管。"
            : "Beta：开启后允许果冻执行鼠标、键盘和浏览器操作。"
        takeoverHint.stringValue = takeoverEnabled
            ? working && purpose == .takeover
                ? "快速退出：\(takeoverShortcutLabel) · 或关闭开关"
                : "开始后按 \(takeoverShortcutLabel) 快速退出"
            : "开启后果冻可以操作当前屏幕"
        working ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
        spinner.isHidden = !working
        panel.ignoresMouseEvents = ignoresMouse
        panel.setContentSize(size)
        panel.contentView?.layoutSubtreeIfNeeded()
        text.scrollToEndOfDocument(nil)
        self.purpose = purpose
        position(near: petFrame, on: screen)
        if activates {
            panel.makeKeyAndOrderFront(nil)
            panel.orderFrontRegardless()
            panel.makeFirstResponder(input)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.panel.isVisible, !self.input.isHidden else { return }
                self.panel.makeKey()
                self.input.selectText(nil)
            }
        } else {
            panel.orderFrontRegardless()
        }
    }

    private func scrollAnswer(pageOffset: CGFloat) -> Bool {
        guard panel.isVisible, let document = scroll.documentView else {
            return false
        }
        panel.contentView?.layoutSubtreeIfNeeded()
        let clipView = scroll.contentView
        let visibleHeight = clipView.bounds.height
        let minimumY = document.bounds.minY
        let maximumY = max(
            minimumY,
            document.bounds.maxY - visibleHeight
        )
        guard maximumY - minimumY > 1 else { return false }
        let pageHeight = max(72, visibleHeight * 0.82)
        let targetY = min(
            max(
                clipView.bounds.origin.y + pageOffset * pageHeight,
                minimumY
            ),
            maximumY
        )
        guard abs(targetY - clipView.bounds.origin.y) > 0.5 else {
            return false
        }
        clipView.scroll(to: NSPoint(
            x: clipView.bounds.origin.x,
            y: targetY
        ))
        scroll.reflectScrolledClipView(clipView)
        return true
    }

    private func answerBody(_ answer: String, question: String?) -> String {
        let question = question?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ") ?? ""
        guard !question.isEmpty else { return answer }
        return "你问：\(String(question.prefix(240)))\n\n\(answer)"
    }

    private func buildContent() {
        let root = NSView()
        let glass = SoftGlassView(cornerRadius: 22)
        let mark = JellyMarkView(size: 30)
        let close = NSButton(
            image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "关闭")!,
            target: self,
            action: #selector(closeBubble)
        )
        [glass, mark].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        close.isBordered = false
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .systemPurple
        badge.font = .systemFont(ofSize: 10, weight: .semibold)
        badge.textColor = .systemPurple
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        takeoverTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        takeoverTitle.textColor = .labelColor
        takeoverHint.font = .systemFont(ofSize: 10, weight: .medium)
        takeoverHint.textColor = .secondaryLabelColor
        takeoverBeta.font = .systemFont(ofSize: 8, weight: .bold)
        takeoverBeta.textColor = .systemOrange
        takeoverBeta.alignment = .center
        takeoverBeta.wantsLayer = true
        takeoverBeta.layer?.cornerRadius = 7
        takeoverBeta.layer?.backgroundColor = NSColor.systemOrange
            .withAlphaComponent(0.14).cgColor
        takeoverBeta.layer?.borderWidth = 1
        takeoverBeta.layer?.borderColor = NSColor.systemOrange
            .withAlphaComponent(0.30).cgColor
        takeoverSwitch.setAccessibilityLabel("屏幕接管")
        takeoverSwitch.target = self
        takeoverSwitch.action = #selector(takeoverChanged)
        let takeoverTitleLine = stack(
            [takeoverTitle, takeoverBeta],
            .horizontal,
            6
        )
        let takeoverText = stack(
            [takeoverTitleLine, takeoverHint],
            .vertical,
            1
        )
        takeoverRow.orientation = .horizontal
        takeoverRow.alignment = .centerY
        takeoverRow.spacing = 7
        let takeoverTrailingPadding = NSView()
        [takeoverTitle, takeoverHint].forEach {
            $0.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        [takeoverText, NSView(), takeoverSwitch,
         takeoverTrailingPadding].forEach {
            takeoverRow.addArrangedSubview($0)
        }
        takeoverTrailingPadding.widthAnchor.constraint(equalToConstant: 4)
            .isActive = true

        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.font = .systemFont(ofSize: 14)
        text.textContainerInset = NSSize(width: 3, height: 5)
        scroll.setAccessibilityLabel("回答内容")
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        input.font = .systemFont(ofSize: 13)
        input.focusRingType = .none
        input.bezelStyle = .roundedBezel
        input.target = self
        input.action = #selector(submit)
        send.image = NSImage(systemSymbolName: "arrow.up.circle.fill", accessibilityDescription: "发送")
        send.isBordered = false
        send.target = self
        send.action = #selector(submit)

        let header = stack([mark, title, badge, NSView(), spinner, close], .horizontal, 7)
        footer.addArrangedSubview(input)
        footer.addArrangedSubview(send)
        footer.orientation = .horizontal
        footer.spacing = 8
        let content = stack([header, takeoverRow, scroll, footer], .vertical, 10)
        content.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(glass)
        glass.addSubview(content)
        panel.contentView = root
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 5),
            glass.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -5),
            glass.topAnchor.constraint(equalTo: root.topAnchor, constant: 5),
            glass.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -5),
            content.leadingAnchor.constraint(equalTo: glass.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: glass.trailingAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: glass.topAnchor, constant: 13),
            content.bottomAnchor.constraint(equalTo: glass.bottomAnchor, constant: -14),
            header.widthAnchor.constraint(equalTo: content.widthAnchor),
            takeoverRow.widthAnchor.constraint(equalTo: content.widthAnchor),
            takeoverBeta.widthAnchor.constraint(equalToConstant: 40),
            takeoverBeta.heightAnchor.constraint(equalToConstant: 16),
            scroll.widthAnchor.constraint(equalTo: content.widthAnchor),
            footer.widthAnchor.constraint(equalTo: content.widthAnchor),
            input.heightAnchor.constraint(equalToConstant: 30),
            mark.widthAnchor.constraint(equalToConstant: 30),
            mark.heightAnchor.constraint(equalToConstant: 30)
        ])
    }

    private func stack(_ views: [NSView], _ orientation: NSUserInterfaceLayoutOrientation, _ spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = orientation
        stack.alignment = orientation == .horizontal ? .centerY : .leading
        stack.spacing = spacing
        return stack
    }

    private func timeline(
        _ events: [TakeoverEvent],
        final: String?,
        showsActivityDetails: Bool
    ) -> String {
        guard showsActivityDetails else {
            let lines = events.suffix(5).map {
                "• \($0.activity.label)  \($0.message)"
            }
            return (lines + (final?.isEmpty == false ? ["", final!] : []))
                .joined(separator: "\n")
        }

        var sections = events.compactMap { event -> String? in
            guard event.kind != .status else { return nil }
            let sequence = event.sequence.map { "第 \($0) 步 · " } ?? ""
            let title = switch event.kind {
            case .observation: "观察界面"
            case .action: "执行动作"
            case .outcome: "操作结果"
            case .userInstruction: "用户补充"
            case .status: "状态"
            }
            return (["\(sequence)\(title)", event.message, event.details]
                .compactMap { $0?.isEmpty == false ? $0 : nil })
                .joined(separator: "\n")
        }
        if let status = events.last(where: { $0.kind == .status }) {
            sections.append("当前状态 · \(status.activity.label)\n\(status.message)")
        }
        if let final, !final.isEmpty { sections.append(final) }
        return sections.joined(separator: "\n\n")
    }

    private func position(near petFrame: NSRect, on screen: NSScreen?) {
        guard let screen = screen ?? NSScreen.main else { return }
        let frame = BubbleLayout.frame(
            pet: Rect(x: petFrame.minX, y: petFrame.minY, width: petFrame.width, height: petFrame.height),
            bubbleSize: PixelSize(width: Int(panel.frame.width), height: Int(panel.frame.height)),
            screen: Rect(x: screen.visibleFrame.minX, y: screen.visibleFrame.minY, width: screen.visibleFrame.width, height: screen.visibleFrame.height)
        )
        panel.setFrame(NSRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height), display: true)
    }

    @objc private func submit() {
        let value = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        input.stringValue = ""
        switch purpose {
        case .screenQuestion: onQuestionSubmit?(value)
        case .followUp: onSubmit?(value)
        case .takeover: onTakeoverSubmit?(value)
        }
    }

    @objc private func takeoverChanged() {
        onTakeoverToggle?(takeoverSwitch.state == .on, input.stringValue)
    }

    @objc private func closeBubble() { onClose?() }
}
