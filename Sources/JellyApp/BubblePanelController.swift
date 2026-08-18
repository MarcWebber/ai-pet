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
    var onModeChange: ((Bool, String) -> Void)?
    var onClose: (() -> Void)?

    private let title = NSTextField(labelWithString: "果冻")
    private let badge = NSTextField(labelWithString: "")
    private let text: NSTextView
    private let scroll: NSScrollView
    private let input = BubbleInput()
    private let send = NSButton()
    private let spinner = NSProgressIndicator()
    private let mode = NSSegmentedControl(
        labels: ["截图问答", "屏幕接管"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let footer = NSStackView()
    private var purpose = Purpose.followUp
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
            size: NSSize(width: 410, height: 254),
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
            size: NSSize(width: 420, height: 286),
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
        petFrame: NSRect,
        screen: NSScreen?
    ) {
        show(
            title: "果冻正在想…",
            badge: preferences?.compactLabel ?? "默认配置",
            body: previousMessage?.isEmpty == false ? previousMessage! : "正在观察屏幕，很快回来。",
            size: NSSize(width: 420, height: 286),
            working: true,
            near: petFrame,
            on: screen
        )
    }

    func showError(
        _ message: String,
        preferences: AssistantPreferences?,
        petFrame: NSRect,
        screen: NSScreen?
    ) {
        show(
            title: "果冻需要一点帮助",
            badge: preferences?.compactLabel ?? "错误",
            body: message,
            size: NSSize(width: 390, height: 245),
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
            badge: "接管任务",
            body: "输入明确任务；留空并按快捷键也可以让果冻识别当前屏幕。",
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
            near: petFrame,
            on: screen
        )
    }

    func reposition(petFrame: NSRect, screen: NSScreen?) {
        if panel.isVisible { position(near: petFrame, on: screen) }
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
        takeoverEnabled: Bool? = nil,
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
        mode.isHidden = takeoverEnabled == nil
        if let takeoverEnabled {
            mode.selectedSegment = takeoverEnabled ? 1 : 0
        }
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
        mode.segmentStyle = .rounded
        mode.setAccessibilityLabel("工作模式")
        mode.target = self
        mode.action = #selector(modeChanged)

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
        let content = stack([header, mode, scroll, footer], .vertical, 10)
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
            mode.widthAnchor.constraint(equalTo: content.widthAnchor),
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

    @objc private func modeChanged() {
        onModeChange?(mode.selectedSegment == 1, input.stringValue)
    }

    @objc private func closeBubble() { onClose?() }
}
