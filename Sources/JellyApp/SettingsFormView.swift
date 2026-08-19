import AppKit
import JellyCore

@MainActor
final class SettingsFormView: NSView, NSTextFieldDelegate, NSTextViewDelegate {
    enum Action {
        case display(UInt32)
        case assistant(AssistantPreferences)
        case takeover(Bool)
        case activityDetails(Bool)
        case shortcut(GlobalShortcut)
        case answerScrollShortcut(AnswerScrollShortcut)
        case answerHistoryShortcut(AnswerHistoryShortcut)
        case chooseSprite
        case resetSprite
        case revealConfiguration
        case finish
    }

    override var isFlipped: Bool { true }
    var onAction: ((Action) -> Void)?

    private let mark = JellyMarkView(size: 56)
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(wrappingLabelWithString: "")
    private let display = NSPopUpButton()
    private let displayDetail = NSTextField(labelWithString: "")
    private let runtime = NSPopUpButton()
    private let modelSuggestions = NSPopUpButton()
    private let modelField = NSTextField()
    private let effort = NSPopUpButton()
    private let historyField = NSTextField()
    private let historyStepper = NSStepper()
    private let takeover = NSSwitch()
    private let activityDetails = NSSwitch()
    private let custom = NSTextView()
    private let customScroll = NSScrollView()
    private let shortcut = NSPopUpButton()
    private let answerScrollShortcut = NSPopUpButton()
    private let answerHistoryShortcut = NSPopUpButton()
    private let runtimeStatus = NSTextField(wrappingLabelWithString: "检查中…")
    private let spriteStatus = NSTextField(wrappingLabelWithString: "使用内置外形")
    private let configurationStatus = NSTextField(wrappingLabelWithString: "")
    private let chooseSprite = NSButton()
    private let resetSprite = NSButton()
    private let revealConfiguration = NSButton()
    private let done = NSButton()
    private var displays: [DisplayDescriptor] = []
    private var assistant = AssistantPreferences.default
    private var cartoonCards: [CartoonCardView] = []
    private let automaticModelLabel = "自动（使用 Runtime 默认模型）"

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildContent()
    }

    required init?(coder: NSCoder) { nil }

    func verifyEditableLayout() -> (passed: Bool, message: String) {
        layoutSubtreeIfNeeded()
        customScroll.layoutSubtreeIfNeeded()
        let modelRect = convert(modelField.bounds, from: modelField)
        let customRect = convert(customScroll.bounds, from: customScroll)
        let cardRects = cartoonCards.map { convert($0.bounds, from: $0) }
        let cardsAreVisible = cardRects.allSatisfy {
            $0.width >= 600
                && $0.height >= 90
                && $0.minX >= bounds.minX
                && $0.maxX <= bounds.maxX
                && $0.minY >= bounds.minY
                && $0.maxY <= bounds.maxY
        }
        let cardsAreOrdered = zip(cardRects, cardRects.dropFirst())
            .allSatisfy { pair in pair.0.maxY < pair.1.minY }
        let actionButtons = [
            chooseSprite,
            resetSprite,
            revealConfiguration,
            done
        ]
        let buttonsAreStyled = actionButtons.allSatisfy {
            !$0.isBordered
                && $0.image != nil
                && ($0.layer?.cornerRadius ?? 0) >= 10
                && $0.bounds.height >= 30
        }
        let passed = modelField.bounds.width >= 340
            && customScroll.bounds.width >= 380
            && customScroll.bounds.height >= 96
            && custom.bounds.width >= 360
            && cartoonCards.count == 4
            && cardsAreVisible
            && cardsAreOrdered
            && buttonsAreStyled
            && modelRect.minX >= bounds.minX
            && modelRect.maxX <= bounds.maxX
            && customRect.minX >= bounds.minX
            && customRect.maxX <= bounds.maxX
        let message = [
            "cards=\(cardRects.map { Int($0.height) })",
            "buttons=\(actionButtons.count)",
            "model=\(Int(modelField.bounds.width))px",
            "custom=\(Int(customScroll.bounds.width))×\(Int(customScroll.bounds.height))px"
        ].joined(separator: ", ")
        return (passed, message)
    }

    func render(_ state: SettingsViewState) {
        assistant = state.assistantPreferences
        title.stringValue = "果冻的小窝"
        subtitle.stringValue = "工作模式、模型和外形，都可以在这里慢慢调整"
        done.title = "完成设置"
        renderDisplays(state)
        renderRuntimes(state)
        renderModels(state)
        select(state.assistantPreferences.reasoningEffort.rawValue, in: effort)
        select(state.globalShortcut.rawValue, in: shortcut)
        select(state.answerScrollShortcut.rawValue, in: answerScrollShortcut)
        select(state.answerHistoryShortcut.rawValue, in: answerHistoryShortcut)
        takeover.state = state.takeoverEnabled ? .on : .off
        activityDetails.state = state.showActivityDetails ? .on : .off
        if historyField.currentEditor() == nil {
            historyField.integerValue = state.assistantPreferences
                .conversationHistoryTurns
        }
        historyStepper.integerValue = state.assistantPreferences
            .conversationHistoryTurns
        if custom.window?.firstResponder !== custom {
            custom.string = state.assistantPreferences.customInstructions
        }
        runtimeStatus.stringValue = state.runtimeText
        runtimeStatus.toolTip = state.runtimeText
        spriteStatus.stringValue = state.spriteSheetURL.map {
            "自定义造型 · \($0.lastPathComponent)"
        } ?? "内置果冻 · 8 种状态 × 8 帧"
        resetSprite.isEnabled = state.spriteSheetURL != nil
        try? mark.setSpriteSheet(at: state.spriteSheetURL)
        configurationStatus.stringValue = [
            Optional(state.configurationURL.path),
            state.configurationError
        ].compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: "\n")
        configurationStatus.toolTip = configurationStatus.stringValue
        done.isEnabled = true
    }

    private func buildContent() {
        let backdrop = CartoonBackdropView()
        title.font = roundedFont(ofSize: 27, weight: .bold)
        title.textColor = .systemPurple
        subtitle.font = roundedFont(ofSize: 13, weight: .medium)
        subtitle.textColor = .secondaryLabelColor
        let heading = stack(
            [mark, stack([title, subtitle], .vertical, 4)],
            .horizontal,
            14
        )

        configure(display, action: #selector(displayChanged))
        configure(
            runtime,
            values: AgentRuntimeKind.allCases,
            title: \.displayName,
            action: #selector(runtimeChanged)
        )
        configure(modelSuggestions, action: #selector(modelSuggestionChanged))
        modelField.placeholderString = "模型 ID，例如 gpt-5.6-luna；留空表示自动"
        modelField.delegate = self
        modelField.target = self
        modelField.action = #selector(modelFieldChanged)
        modelField.toolTip = "可以从建议中选择，也可以完整输入 Runtime 支持的模型 ID。"
        configure(
            effort,
            values: ReasoningEffort.allCases,
            title: \.displayName,
            action: #selector(effortChanged)
        )
        historyField.delegate = self
        historyField.alignment = .right
        historyField.formatter = Self.historyFormatter()
        historyStepper.minValue = Double(
            JellyConfiguration.Conversation.minimumHistoryTurns
        )
        historyStepper.maxValue = Double(
            JellyConfiguration.Conversation.maximumHistoryTurns
        )
        historyStepper.increment = 1
        configure(historyStepper, action: #selector(historyStepperChanged))

        configure(
            shortcut,
            values: GlobalShortcut.allCases,
            title: \.label,
            action: #selector(shortcutChanged)
        )
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

        custom.delegate = self
        custom.isRichText = false
        custom.isAutomaticQuoteSubstitutionEnabled = false
        custom.isAutomaticDashSubstitutionEnabled = false
        custom.font = roundedFont(ofSize: 13, weight: .regular)
        custom.textContainerInset = NSSize(width: 7, height: 7)
        custom.frame = NSRect(x: 0, y: 0, width: 390, height: 104)
        custom.minSize = .zero
        custom.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        custom.autoresizingMask = [.width]
        custom.isVerticallyResizable = true
        custom.isHorizontallyResizable = false
        custom.textContainer?.widthTracksTextView = true
        custom.toolTip = "追加给当前 Agent，不会改变截图问答的只观察边界。"
        customScroll.documentView = custom
        customScroll.hasVerticalScroller = true
        customScroll.autohidesScrollers = true
        customScroll.borderType = .noBorder
        customScroll.drawsBackground = true
        customScroll.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.82)
        customScroll.wantsLayer = true
        customScroll.layer?.cornerRadius = 12
        customScroll.layer?.cornerCurve = .continuous
        customScroll.layer?.borderWidth = 1
        customScroll.layer?.borderColor = NSColor.systemPurple
            .withAlphaComponent(0.22).cgColor

        [display, runtime, modelSuggestions, effort, shortcut,
         answerScrollShortcut, answerHistoryShortcut].forEach {
            $0.controlSize = .large
            $0.font = roundedFont(ofSize: 13, weight: .semibold)
            $0.contentTintColor = .systemPurple
        }
        modelField.controlSize = .large
        modelField.font = roundedFont(ofSize: 13, weight: .medium)
        modelField.bezelStyle = .roundedBezel
        historyField.font = roundedFont(ofSize: 13, weight: .semibold)
        displayDetail.font = roundedFont(ofSize: 12, weight: .medium)
        runtimeStatus.font = roundedFont(ofSize: 12, weight: .medium)
        spriteStatus.font = roundedFont(ofSize: 12.5, weight: .semibold)
        configurationStatus.font = .monospacedSystemFont(
            ofSize: 10.5,
            weight: .regular
        )
        configurationStatus.textColor = .secondaryLabelColor

        configure(
            chooseSprite,
            title: "导入造型",
            action: #selector(chooseSpriteClicked)
        )
        styleActionButton(
            chooseSprite,
            symbolName: "photo.badge.plus",
            color: .systemPink
        )
        configure(
            resetSprite,
            title: "恢复内置",
            action: #selector(resetSpriteClicked)
        )
        styleActionButton(
            resetSprite,
            symbolName: "arrow.counterclockwise",
            color: .systemPurple
        )
        configure(
            revealConfiguration,
            title: "打开配置",
            action: #selector(revealConfigurationClicked)
        )
        styleActionButton(
            revealConfiguration,
            symbolName: "folder.fill",
            color: .systemBlue
        )
        configure(done, title: "完成设置", action: #selector(finishSetup))
        done.keyEquivalent = "\r"
        stylePrimaryButton(done, symbolName: "checkmark.circle.fill")

        let displayBlock = stack([display, displayDetail], .vertical, 3)
        let modelBlock = stack(
            [modelSuggestions, modelField],
            .vertical,
            6
        )
        let historyBlock = stack(
            [historyField, historyStepper, label("轮（1–50）")],
            .horizontal,
            7
        )
        let betaTitle = stack([
            label("默认进入屏幕接管", color: .labelColor, weight: .bold),
            pill("BETA", color: .systemOrange)
        ], .horizontal, 7)
        let betaDescription = stack([
            betaTitle,
            label("打开聊天时优先选择接管，两个模式仍可随时切换。")
        ], .vertical, 4)
        let betaBlock = stack([
            betaDescription,
            NSView(),
            takeover
        ], .horizontal, 8)
        let activityBlock = stack([
            label("显示观察、工具调用、回复和操作结果"),
            NSView(),
            activityDetails
        ], .horizontal, 8)
        let spriteButtons = stack(
            [chooseSprite, resetSprite],
            .horizontal,
            8
        )
        let spriteBlock = stack(
            [spriteStatus, spriteButtons],
            .vertical,
            6
        )
        let configBlock = stack(
            [configurationStatus, revealConfiguration],
            .vertical,
            6
        )
        let screenCard = sectionCard(
            title: "屏幕观察",
            symbolName: "display",
            subtitle: "选择它截图问答或接管时观察的显示器。",
            tint: .systemBlue,
            rows: [
                row("观察屏幕", displayBlock)
            ]
        )
        let brainCard = sectionCard(
            title: "Agent 大脑",
            symbolName: "brain.head.profile",
            subtitle: "选择运行引擎、模型和果冻能够记住的对话。",
            tint: .systemPurple,
            rows: [
                row("运行引擎", runtime),
                row("使用模型", modelBlock),
                row("思考力度", effort),
                row("记住对话", historyBlock),
                row("自定义指令", customScroll),
                row("连接状态", runtimeStatus)
            ]
        )
        let appearanceCard = sectionCard(
            title: "果冻外形",
            symbolName: "paintpalette.fill",
            subtitle: "可以使用内置造型，也可以导入自己的 8×8 动画图。",
            tint: .systemPink,
            rows: [
                row("当前造型", spriteBlock),
                row("配置位置", configBlock)
            ]
        )
        let controlsCard = sectionCard(
            title: "模式与快捷键",
            symbolName: "sparkles",
            subtitle: "设置默认模式，以及不移动鼠标也能使用的快捷操作。",
            tint: .systemOrange,
            rows: [
                row("默认模式", betaBlock),
                row("过程详情", activityBlock),
                row("唤醒 / 停止", shortcut),
                row("滚动回答", answerScrollShortcut),
                row("切换回答", answerHistoryShortcut)
            ]
        )
        let footer = stack([
            chip("8 种状态 · 每种 8 帧动画", color: .systemPurple),
            NSView(),
            done
        ], .horizontal, 10)
        let content = stack([
            heading,
            screenCard,
            brainCard,
            appearanceCard,
            controlsCard,
            footer
        ], .vertical, 14)

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
            content.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -22),
            heading.widthAnchor.constraint(equalTo: content.widthAnchor),
            screenCard.widthAnchor.constraint(equalTo: content.widthAnchor),
            brainCard.widthAnchor.constraint(equalTo: content.widthAnchor),
            appearanceCard.widthAnchor.constraint(equalTo: content.widthAnchor),
            controlsCard.widthAnchor.constraint(equalTo: content.widthAnchor),
            footer.widthAnchor.constraint(equalTo: content.widthAnchor),
            customScroll.heightAnchor.constraint(equalToConstant: 104),
            modelField.widthAnchor.constraint(greaterThanOrEqualToConstant: 360),
            historyField.widthAnchor.constraint(equalToConstant: 64),
            done.widthAnchor.constraint(greaterThanOrEqualToConstant: 124),
            done.heightAnchor.constraint(equalToConstant: 38)
        ])
    }

    private func sectionCard(
        title value: String,
        symbolName: String,
        subtitle subtitleValue: String,
        tint: NSColor,
        rows: [NSView]
    ) -> CartoonCardView {
        let sectionTitle = label(
            value,
            color: .labelColor,
            weight: .bold,
            size: 15
        )
        let sectionSubtitle = NSTextField(
            wrappingLabelWithString: subtitleValue
        )
        sectionSubtitle.font = roundedFont(ofSize: 12, weight: .medium)
        sectionSubtitle.textColor = .secondaryLabelColor
        let headerText = stack(
            [sectionTitle, sectionSubtitle],
            .vertical,
            3
        )
        headerText.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = stack([
            CartoonIconView(symbolName: symbolName, tint: tint),
            headerText
        ], .horizontal, 11)
        let rowStack = stack(rows, .vertical, 12)
        rowStack.arrangedSubviews.forEach {
            $0.widthAnchor.constraint(equalTo: rowStack.widthAnchor)
                .isActive = true
        }
        let cardContent = stack([
            header,
            rowStack
        ], .vertical, 14)
        let card = CartoonCardView(tint: tint)
        cartoonCards.append(card)
        card.addSubview(cardContent)
        cardContent.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            cardContent.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            cardContent.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
            cardContent.topAnchor.constraint(equalTo: card.topAnchor, constant: 22),
            cardContent.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -18),
            header.widthAnchor.constraint(equalTo: cardContent.widthAnchor),
            rowStack.widthAnchor.constraint(equalTo: cardContent.widthAnchor)
        ])
        return card
    }

    private func row(_ name: String, _ control: NSView) -> NSStackView {
        let name = label(name, weight: .semibold)
        name.widthAnchor.constraint(equalToConstant: 104).isActive = true
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = stack([name, control], .horizontal, 12)
        row.alignment = .top
        control.widthAnchor.constraint(greaterThanOrEqualToConstant: 390)
            .isActive = true
        return row
    }

    private func label(
        _ value: String,
        color: NSColor = .secondaryLabelColor,
        weight: NSFont.Weight = .regular,
        size: CGFloat = 12
    ) -> NSTextField {
        let field = NSTextField(labelWithString: value)
        field.font = roundedFont(ofSize: size, weight: weight)
        field.textColor = color
        return field
    }

    private func pill(_ value: String, color: NSColor) -> NSTextField {
        let field = label(value, color: color, weight: .bold, size: 9)
        field.alignment = .center
        field.wantsLayer = true
        field.layer?.cornerRadius = 8
        field.layer?.backgroundColor = color.withAlphaComponent(0.14).cgColor
        field.layer?.borderWidth = 1
        field.layer?.borderColor = color.withAlphaComponent(0.30).cgColor
        field.widthAnchor.constraint(equalToConstant: 42).isActive = true
        field.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return field
    }

    private func chip(_ value: String, color: NSColor) -> NSTextField {
        let field = label(value, color: color, weight: .semibold, size: 11)
        field.alignment = .center
        field.wantsLayer = true
        field.layer?.cornerRadius = 11
        field.layer?.backgroundColor = color.withAlphaComponent(0.10).cgColor
        field.layer?.borderWidth = 1
        field.layer?.borderColor = color.withAlphaComponent(0.22).cgColor
        field.widthAnchor.constraint(equalToConstant: 168).isActive = true
        field.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return field
    }

    private func stack(
        _ views: [NSView],
        _ orientation: NSUserInterfaceLayoutOrientation,
        _ spacing: CGFloat
    ) -> NSStackView {
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

    private func configure(
        _ button: NSButton,
        title: String,
        action: Selector
    ) {
        button.title = title
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = roundedFont(ofSize: 12, weight: .semibold)
        button.contentTintColor = .systemPurple
        configure(button, action: action)
    }

    private func styleActionButton(
        _ button: NSButton,
        symbolName: String,
        color: NSColor
    ) {
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 11
        button.layer?.cornerCurve = .continuous
        button.layer?.backgroundColor = color.withAlphaComponent(0.13).cgColor
        button.layer?.borderWidth = 1
        button.layer?.borderColor = color.withAlphaComponent(0.28).cgColor
        button.contentTintColor = color
        button.font = roundedFont(ofSize: 12, weight: .semibold)
        button.image = symbolImage(symbolName, pointSize: 12)
        button.imagePosition = .imageLeading
        button.imageScaling = .scaleProportionallyDown
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 104)
            .isActive = true
    }

    private func stylePrimaryButton(
        _ button: NSButton,
        symbolName: String
    ) {
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 12
        button.layer?.cornerCurve = .continuous
        button.layer?.backgroundColor = NSColor.systemPurple.cgColor
        button.layer?.shadowColor = NSColor.systemPurple.cgColor
        button.layer?.shadowOpacity = 0.18
        button.layer?.shadowRadius = 5
        button.layer?.shadowOffset = NSSize(width: 0, height: -2)
        button.contentTintColor = .white
        button.font = roundedFont(ofSize: 13, weight: .bold)
        button.image = symbolImage(symbolName, pointSize: 13)
        button.imagePosition = .imageLeading
        button.imageScaling = .scaleProportionallyDown
    }

    private func symbolImage(
        _ name: String,
        pointSize: CGFloat
    ) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(
            pointSize: pointSize,
            weight: .semibold
        )
        return NSImage(
            systemSymbolName: name,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(configuration)
    }

    private func roundedFont(
        ofSize size: CGFloat,
        weight: NSFont.Weight
    ) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded),
              let font = NSFont(descriptor: descriptor, size: size)
        else {
            return base
        }
        return font
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
        popup.select(popup.itemArray.first {
            ($0.representedObject as? String) == rawValue
        })
    }

    private func selected<Value: RawRepresentable>(
        _ popup: NSPopUpButton
    ) -> Value? where Value.RawValue == String {
        (popup.selectedItem?.representedObject as? String)
            .flatMap(Value.init(rawValue:))
    }

    private func publishAssistant(
        runtime: AgentRuntimeKind? = nil,
        model: String? = nil,
        effort: ReasoningEffort? = nil,
        customInstructions: String? = nil,
        historyTurns: Int? = nil
    ) {
        assistant = AssistantPreferences(
            runtime: runtime ?? assistant.runtime,
            model: model ?? assistant.model,
            reasoningEffort: effort ?? assistant.reasoningEffort,
            customInstructions:
                customInstructions ?? assistant.customInstructions,
            conversationHistoryTurns:
                historyTurns ?? assistant.conversationHistoryTurns
        )
        onAction?(.assistant(assistant))
    }

    @objc private func displayChanged() {
        guard let id = (display.selectedItem?.representedObject as? NSNumber)?
            .uint32Value else { return }
        displayDetail.stringValue = detail(
            for: displays.first { $0.id == id }
        )
        onAction?(.display(id))
    }

    @objc private func runtimeChanged() {
        guard let value: AgentRuntimeKind = selected(runtime) else { return }
        publishAssistant(
            runtime: value,
            model: AssistantPreferences.automaticModel
        )
    }

    @objc private func modelSuggestionChanged() {
        let value = modelSuggestions.selectedItem?.representedObject as? String
            ?? AssistantPreferences.automaticModel
        modelField.stringValue = value == AssistantPreferences.automaticModel
            ? "" : value
        publishAssistant(model: value)
    }

    @objc private func modelFieldChanged() {
        publishAssistant(model: normalizedModel(modelField.stringValue))
    }

    @objc private func effortChanged() {
        publishAssistant(effort: selected(effort))
    }

    @objc private func historyStepperChanged() {
        historyField.integerValue = historyStepper.integerValue
        publishAssistant(historyTurns: historyStepper.integerValue)
    }

    @objc private func takeoverChanged() {
        onAction?(.takeover(takeover.state == .on))
    }

    @objc private func activityDetailsChanged() {
        onAction?(.activityDetails(activityDetails.state == .on))
    }

    @objc private func shortcutChanged() {
        if let value: GlobalShortcut = selected(shortcut) {
            onAction?(.shortcut(value))
        }
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

    @objc private func chooseSpriteClicked() {
        onAction?(.chooseSprite)
    }

    @objc private func resetSpriteClicked() {
        onAction?(.resetSprite)
    }

    @objc private func revealConfigurationClicked() {
        onAction?(.revealConfiguration)
    }

    @objc private func finishSetup() {
        publishCustomInstructions()
        onAction?(.finish)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field === modelField {
            modelFieldChanged()
        } else if field === historyField {
            let value = min(
                max(
                    historyField.integerValue,
                    JellyConfiguration.Conversation.minimumHistoryTurns
                ),
                JellyConfiguration.Conversation.maximumHistoryTurns
            )
            historyField.integerValue = value
            historyStepper.integerValue = value
            publishAssistant(historyTurns: value)
        }
    }

    func textDidEndEditing(_ notification: Notification) {
        guard notification.object as? NSTextView === custom else { return }
        publishCustomInstructions()
    }

    private func publishCustomInstructions() {
        let value = custom.string.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if value != assistant.customInstructions {
            publishAssistant(customInstructions: value)
        }
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
            displayDetail.stringValue = detail(
                for: displays.first { $0.id == id }
            )
        } else {
            display.selectItem(at: 0)
            displayDetail.stringValue = displays.isEmpty
                ? "授权后会列出可用屏幕" : "请选择一个屏幕"
        }
        display.isEnabled = !displays.isEmpty
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
                  let kind = AgentRuntimeKind(rawValue: rawValue) else {
                continue
            }
            if kind == .automatic {
                let resolved = automaticRuntime.map {
                    " · \($0.displayName)"
                } ?? ""
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
        modelSuggestions.removeAllItems()
        modelSuggestions.addItem(withTitle: automaticModelLabel)
        modelSuggestions.lastItem?.representedObject =
            AssistantPreferences.automaticModel
        for option in state.modelOptions {
            modelSuggestions.addItem(withTitle: option)
            modelSuggestions.lastItem?.representedObject = option
        }
        if let item = modelSuggestions.itemArray.first(where: {
            ($0.representedObject as? String) == current
        }) {
            modelSuggestions.select(item)
        } else {
            modelSuggestions.selectItem(at: 0)
        }
        if modelField.currentEditor() == nil {
            modelField.stringValue = current == AssistantPreferences.automaticModel
                ? "" : current
        }
    }

    private func normalizedModel(_ value: String) -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? AssistantPreferences.automaticModel
            : String(value.prefix(200))
    }

    private func detail(for display: DisplayDescriptor?) -> String {
        guard let display else { return "请选择一个屏幕" }
        return "\(display.width) × \(display.height)\(display.isPrimary ? " · 主屏幕" : "")"
    }

    private static func historyFormatter() -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.allowsFloats = false
        formatter.minimum = NSNumber(
            value: JellyConfiguration.Conversation.minimumHistoryTurns
        )
        formatter.maximum = NSNumber(
            value: JellyConfiguration.Conversation.maximumHistoryTurns
        )
        return formatter
    }
}
