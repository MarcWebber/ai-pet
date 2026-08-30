import AppKit
import JellyCore
import SwiftUI

@MainActor
enum SettingsAction {
    case display(UInt32)
    case assistant(AssistantPreferences)
    case activityDetails(Bool)
    case typingSpeed(Int)
    case shortcut(GlobalShortcut)
    case answerScrollShortcut(ArrowShortcut)
    case answerHistoryShortcut(ArrowShortcut)
    case chooseSprite, resetSprite, revealConfiguration, finish
}

@MainActor
private final class SettingsModel: ObservableObject {
    @Published var state = SettingsViewState.placeholder
    var onAction: ((SettingsAction) -> Void)?
    func assistant(
        model: String? = nil,
        effort: ReasoningEffort? = nil,
        instructions: String? = nil,
        turns: Int? = nil
    ) {
        let old = state.assistantPreferences
        let value = AssistantPreferences(
            model: model ?? old.model,
            reasoningEffort: effort ?? old.reasoningEffort,
            customInstructions: instructions ?? old.customInstructions,
            conversationHistoryTurns: turns ?? old.conversationHistoryTurns
        )
        state.assistantPreferences = value
        onAction?(.assistant(value))
    }
}

@MainActor
final class SettingsFormView: NSHostingView<SettingsRoot> {
    typealias Action = SettingsAction
    private let model: SettingsModel
    var onAction: ((Action) -> Void)? {
        get { model.onAction }
        set { model.onAction = newValue }
    }
    init() {
        let model = SettingsModel()
        self.model = model
        super.init(rootView: SettingsRoot(model: model))
    }
    @available(*, unavailable)
    required init(rootView: SettingsRoot) { fatalError() }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
    func render(_ state: SettingsViewState) { model.state = state }
}

@MainActor
struct SettingsRoot: View {
    @ObservedObject fileprivate var model: SettingsModel
    private var state: SettingsViewState { model.state }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                screenCard
                codexCard
                appearanceCard
                controlsCard
                HStack {
                    Text("8 种状态 · 每种 8 帧动画")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.purple)
                    Spacer()
                    Button("完成设置") { model.onAction?(.finish) }
                        .buttonStyle(.borderedProminent)
                        .tint(.purple)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(28)
        }
        .frame(minWidth: 620, minHeight: 760)
        .background(
            LinearGradient(
                colors: [Color.purple.opacity(0.08), Color.pink.opacity(0.06), .clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }
    private var header: some View {
        HStack(spacing: 14) {
            Text("🪼").font(.system(size: 42))
            VStack(alignment: .leading, spacing: 3) {
                Text("果冻的小窝").font(.system(size: 27, weight: .bold, design: .rounded))
                    .foregroundStyle(.purple)
                Text("模型、外形和快捷键，都可以在这里慢慢调整")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
    private var screenCard: some View {
        card("屏幕观察", icon: "display", tint: .blue) {
            setting("观察屏幕") {
                Picker("", selection: displayBinding) {
                    Text("选择果冻要观察的屏幕…").tag(UInt32?.none)
                    ForEach(state.displays, id: \.id) { display in
                        Text(display.name).tag(Optional(display.id))
                    }
                }
                .labelsHidden()
                Text(displayDetail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var codexCard: some View {
        card("Codex", icon: "brain.head.profile", tint: .purple) {
            setting("使用模型") {
                Picker("", selection: modelPickerBinding) {
                    Text("自动（Codex 默认）").tag(AssistantPreferences.defaultModel)
                    ForEach(state.modelOptions, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                TextField("也可直接输入模型 ID", text: modelTextBinding)
                    .textFieldStyle(.roundedBorder)
            }
            setting("思考力度") {
                Picker("", selection: effortBinding) {
                    ForEach(ReasoningEffort.allCases, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
                .labelsHidden()
            }
            setting("记住对话") {
                Stepper(
                    "\(state.assistantPreferences.conversationHistoryTurns) 轮",
                    value: historyBinding,
                    in: 1...50
                )
            }
            setting("自定义指令") {
                TextEditor(text: instructionsBinding)
                    .font(.body)
                    .frame(minHeight: 92)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color.purple.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            }
            setting("连接状态") {
                Text(state.codexStatusText).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var appearanceCard: some View {
        card("果冻外形", icon: "paintpalette.fill", tint: .pink) {
            setting("当前造型") {
                Text(state.spriteSheetURL.map { "自定义 · \($0.lastPathComponent)" }
                    ?? "内置果冻 · 8×8 动画")
                HStack {
                    Button("导入造型") { model.onAction?(.chooseSprite) }
                    Button("恢复内置") { model.onAction?(.resetSprite) }
                        .disabled(state.spriteSheetURL == nil)
                }
            }
            setting("配置位置") {
                Text(state.configurationURL.path)
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if let error = state.configurationError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Button("在 Finder 中打开") { model.onAction?(.revealConfiguration) }
            }
        }
    }
    private var controlsCard: some View {
        card("显示与快捷键", icon: "keyboard.fill", tint: .orange) {
            setting("过程详情") {
                Toggle("显示观察、动作和结果", isOn: activityBinding)
            }
            setting("键入速度") {
                Stepper(
                    "\(state.typingSpeedPercent)%（数值越低越慢）",
                    value: typingBinding,
                    in: TypingRhythm.minimumSpeedPercent...TypingRhythm.maximumSpeedPercent,
                    step: 5
                )
            }
            setting("唤醒 / 停止") {
                enumPicker(GlobalShortcut.allCases, selection: shortcutBinding)
            }
            setting("滚动回答") {
                enumPicker(ArrowShortcut.allCases, selection: scrollBinding)
            }
            setting("切换回答") {
                enumPicker(ArrowShortcut.allCases, selection: historyShortcutBinding)
            }
        }
    }
    private func card<Content: View>(
        _ title: String,
        icon: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            Label(title, systemImage: icon)
                .font(.headline).foregroundStyle(tint)
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(tint.opacity(0.24)))
    }
    private func setting<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(title).font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary).frame(width: 96, alignment: .leading)
            VStack(alignment: .leading, spacing: 7) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func enumPicker<Value: RawRepresentable & Hashable>(
        _ values: [Value],
        selection: Binding<Value>
    ) -> some View where Value.RawValue == String {
        Picker("", selection: selection) {
            ForEach(values, id: \.self) { value in
                Text((value as? any ShortcutChoice)?.label ?? value.rawValue).tag(value)
            }
        }
        .labelsHidden()
    }
    private var displayBinding: Binding<UInt32?> {
        stateBinding(\.selectedDisplayID) { $0.map(SettingsAction.display) }
    }
    private var modelPickerBinding: Binding<String> { Binding(
        get: { state.assistantPreferences.model },
        set: { model.assistant(model: $0) }
    ) }
    private var modelTextBinding: Binding<String> { Binding(
        get: {
            state.assistantPreferences.model == AssistantPreferences.defaultModel
                ? "" : state.assistantPreferences.model
        },
        set: { model.assistant(model: $0) }
    ) }
    private var effortBinding: Binding<ReasoningEffort> { Binding(
        get: { state.assistantPreferences.reasoningEffort },
        set: { model.assistant(effort: $0) }
    ) }
    private var historyBinding: Binding<Int> { Binding(
        get: { state.assistantPreferences.conversationHistoryTurns },
        set: { model.assistant(turns: $0) }
    ) }
    private var instructionsBinding: Binding<String> { Binding(
        get: { state.assistantPreferences.customInstructions },
        set: { model.assistant(instructions: $0) }
    ) }
    private var activityBinding: Binding<Bool> {
        stateBinding(\.showActivityDetails) { .activityDetails($0) }
    }
    private var typingBinding: Binding<Int> { Binding(
        get: { state.typingSpeedPercent },
        set: {
            let value = TypingRhythm.normalizedSpeedPercent($0)
            model.state.typingSpeedPercent = value
            model.onAction?(.typingSpeed(value))
        }
    ) }
    private var shortcutBinding: Binding<GlobalShortcut> {
        stateBinding(\.globalShortcut) { .shortcut($0) }
    }
    private var scrollBinding: Binding<ArrowShortcut> {
        stateBinding(\.answerScrollShortcut) { .answerScrollShortcut($0) }
    }
    private var historyShortcutBinding: Binding<ArrowShortcut> {
        stateBinding(\.answerHistoryShortcut) { .answerHistoryShortcut($0) }
    }
    private func stateBinding<Value>(
        _ path: WritableKeyPath<SettingsViewState, Value>,
        action: @escaping (Value) -> SettingsAction?
    ) -> Binding<Value> {
        Binding(
            get: { model.state[keyPath: path] },
            set: {
                model.state[keyPath: path] = $0
                if let value = action($0) { model.onAction?(value) }
            }
        )
    }
    private var displayDetail: String {
        guard let id = state.selectedDisplayID,
              let display = state.displays.first(where: { $0.id == id }) else {
            return state.displays.isEmpty ? "授权后会列出可用屏幕" : "请选择一个屏幕"
        }
        return "\(display.width) × \(display.height)\(display.isPrimary ? " · 主屏幕" : "")"
    }
}

private protocol ShortcutChoice { var label: String { get } }
extension GlobalShortcut: ShortcutChoice {}
extension ArrowShortcut: ShortcutChoice {}
