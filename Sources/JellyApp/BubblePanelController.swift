import AppKit
import JellyCore
import SwiftUI

private final class JellyBubblePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private enum BubblePurpose { case screenQuestion, followUp, takeover }

private struct BubbleState {
    var title = "果冻"
    var badge = "默认配置"
    var body = ""
    var size = NSSize(width: 400, height: 260)
    var placeholder: String?
    var working = false
    var purpose = BubblePurpose.followUp
    var takeover = false
    var shortcutLabel = AppMetadata.shortcutLabel
}

@MainActor
private final class BubbleModel: ObservableObject {
    @Published var state = BubbleState()
    @Published var input = ""
    @Published var focusInput = false
    var onSubmit: ((BubblePurpose, String) -> Void)?
    var onToggle: ((Bool, String) -> Void)?
    var onClose: (() -> Void)?
    func submit() {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        input = ""
        onSubmit?(state.purpose, value)
    }
}

@MainActor
private final class ScrollBox {
    weak var view: NSScrollView?
}

private struct AnswerTextView: NSViewRepresentable {
    let value: String
    let box: ScrollBox
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let text = scroll.documentView as! NSTextView
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.font = .systemFont(ofSize: 14)
        text.textContainerInset = NSSize(width: 3, height: 5)
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.setAccessibilityLabel("回答内容")
        box.view = scroll
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? NSTextView, text.string != value else { return }
        text.string = value
        text.scrollToEndOfDocument(nil)
    }
}

private struct BubbleRoot: View {
    @ObservedObject var model: BubbleModel
    let scrollBox: ScrollBox
    @FocusState private var focused: Bool
    private var color: Color {
        model.state.working && model.state.purpose == .takeover
            ? .orange : model.state.takeover ? .green : .gray
    }
    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 7) {
                Text("🪼").font(.title2)
                Text(model.state.title).font(.subheadline.weight(.semibold)).foregroundStyle(.purple)
                Text(model.state.badge).font(.caption2.weight(.semibold))
                    .foregroundStyle(.purple).padding(.horizontal, 7).padding(.vertical, 3)
                    .background(.purple.opacity(0.1), in: Capsule())
                Spacer()
                if model.state.working { ProgressView().controlSize(.small) }
                Button { model.onClose?() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            }

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(takeoverTitle).font(.caption.weight(.bold)).foregroundStyle(color)
                    Text(takeoverHint).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { model.state.takeover },
                    set: { model.state.takeover = $0; model.onToggle?($0, model.input) }
                )).labelsHidden()
            }
            .padding(.horizontal, 9).padding(.vertical, 7)
            .background(color.opacity(model.state.takeover ? 0.16 : 0.06), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(color.opacity(0.75), lineWidth: model.state.takeover ? 2 : 1))

            AnswerTextView(value: model.state.body, box: scrollBox)

            if let placeholder = model.state.placeholder {
                HStack(spacing: 8) {
                    TextField(placeholder, text: $model.input)
                        .textFieldStyle(.roundedBorder).focused($focused)
                        .onSubmit { model.submit() }
                    Button { model.submit() } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.title2)
                    }.buttonStyle(.plain).foregroundStyle(.purple)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(.purple.opacity(0.18)))
        .padding(5)
        .onChange(of: model.focusInput) { _, value in focused = value }
    }
    private var takeoverTitle: String {
        model.state.working && model.state.purpose == .takeover
            ? "接管进行中" : model.state.takeover ? "接管已开启" : "接管已关闭"
    }
    private var takeoverHint: String {
        model.state.working && model.state.purpose == .takeover
            ? "快速退出：\(model.state.shortcutLabel) 或关闭开关"
            : model.state.takeover
                ? "开始后按 \(model.state.shortcutLabel) 快速退出"
                : "开启后果冻可以操作当前屏幕"
    }
}

@MainActor
final class BubblePanelController {
    let panel: NSPanel
    var onQuestionSubmit: ((String) -> Void)?
    var onSubmit: ((String) -> Void)?
    var onTakeoverSubmit: ((String) -> Void)?
    var onTakeoverToggle: ((Bool, String) -> Void)?
    var onClose: (() -> Void)?
    var anchor: () -> (NSRect, NSScreen?) = { (.zero, .main) }
    private let model = BubbleModel()
    private let scrollBox = ScrollBox()
    private var shortcutLabel = AppMetadata.shortcutLabel
    private var escapeMonitor: Any?
    init() {
        panel = JellyBubblePanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 260),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = NSHostingView(rootView: BubbleRoot(model: model, scrollBox: scrollBox))
        model.onSubmit = { [weak self] purpose, value in
            switch purpose {
            case .screenQuestion: self?.onQuestionSubmit?(value)
            case .followUp: self?.onSubmit?(value)
            case .takeover: self?.onTakeoverSubmit?(value)
            }
        }
        model.onToggle = { [weak self] in self?.onTakeoverToggle?($0, $1) }
        model.onClose = { [weak self] in self?.onClose?() }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard event.keyCode == 53, self?.panel.isVisible == true else { return event }
            self?.onClose?(); return nil
        }
    }
    deinit { if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) } }
    func showQuestionComposer(initialQuestion: String = "") {
        model.input = String(initialQuestion.prefix(4_000))
        show(.init(
            title: "问果冻当前屏幕", badge: "截图问答",
            body: "输入问题并发送，果冻会截取所选屏幕后回答；它不会操作页面。",
            size: NSSize(width: 420, height: 286),
            placeholder: "例如：这个页面现在需要我做什么？", purpose: .screenQuestion
        ), activates: true)
    }
    func showAnswer(
        _ message: String, question: String?,
        historyPosition: (current: Int, total: Int)?,
        preferences: AssistantPreferences
    ) {
        let position = historyPosition.map { " · \($0.current)/\($0.total)" } ?? ""
        show(.init(
            title: "果冻看到了这些\(position)", badge: preferences.compactLabel,
            body: answerBody(message, question), size: NSSize(width: 430, height: 318),
            placeholder: "继续问一句…"
        ), activates: true)
    }
    func showWorking(
        previousMessage: String?, preferences: AssistantPreferences, takeoverEnabled: Bool
    ) {
        show(.init(
            title: "果冻正在想…", badge: preferences.compactLabel,
            body: previousMessage?.isEmpty == false ? previousMessage! : "正在观察屏幕，很快回来。",
            size: NSSize(width: 420, height: 286), working: true, takeover: takeoverEnabled
        ))
    }
    func showError(
        _ message: String, preferences: AssistantPreferences, takeoverEnabled: Bool
    ) {
        show(.init(
            title: "果冻需要一点帮助", badge: preferences.compactLabel,
            body: message, size: NSSize(width: 390, height: 245), takeover: takeoverEnabled
        ))
    }
    func showTakeoverComposer(initialTask: String = "") {
        model.input = String(initialTask.prefix(4_000))
        show(.init(
            title: "告诉果冻要做什么", badge: "屏幕接管",
            body: "输入明确任务后，果冻可以执行鼠标和键盘动作。按 \(shortcutLabel) 可随时退出。",
            size: NSSize(width: 410, height: 230),
            placeholder: "例如：完成这道题并提交", purpose: .takeover, takeover: true
        ), activates: true)
    }
    func showTakeoverResult(
        _ message: String, events: [ActivityEvent], isError: Bool,
        preferences: AssistantPreferences, showsActivityDetails: Bool
    ) {
        show(.init(
            title: isError ? "果冻停下来了" : "果冻完成了",
            badge: preferences.compactLabel,
            body: timeline(events, final: message, detailed: showsActivityDetails),
            size: showsActivityDetails ? NSSize(width: 520, height: 400) : NSSize(width: 410, height: 250),
            placeholder: "页面有变化？告诉果冻继续检查…", purpose: .takeover, takeover: true
        ))
    }
    func showTakeoverProgress(
        _ snapshot: SessionSnapshot, preferences: AssistantPreferences,
        showsActivityDetails: Bool
    ) {
        show(.init(
            title: "果冻 · \(snapshot.activity.label)", badge: preferences.compactLabel,
            body: timeline(snapshot.events, final: snapshot.message, detailed: showsActivityDetails),
            size: showsActivityDetails ? NSSize(width: 520, height: 400) : NSSize(width: 430, height: 304),
            placeholder: "接管中，可补充要求…", working: true,
            purpose: .takeover, takeover: true
        ))
    }
    func setTakeoverShortcutLabel(_ label: String) {
        shortcutLabel = label
        model.state.shortcutLabel = label
    }
    func reposition() { if panel.isVisible { position() } }
    func scrollAnswerUp() -> Bool { scrollAnswer(by: -1) }
    func scrollAnswerDown() -> Bool { scrollAnswer(by: 1) }
    func hide() { panel.orderOut(nil); model.input = "" }
    private func show(_ value: BubbleState, activates: Bool = false) {
        var state = value
        state.shortcutLabel = shortcutLabel
        model.state = state
        panel.setContentSize(state.size)
        position()
        if activates {
            panel.makeKeyAndOrderFront(nil)
            model.focusInput = false
            DispatchQueue.main.async { [weak self] in self?.model.focusInput = true }
        } else {
            panel.orderFrontRegardless()
        }
    }
    private func position() {
        let (pet, preferredScreen) = anchor()
        guard let bounds = (preferredScreen ?? NSScreen.main)?.visibleFrame else { return }
        let size = panel.frame.size, gap: CGFloat = 8
        let left = pet.minX - size.width + pet.width * 0.35
        var point = NSPoint(
            x: left >= bounds.minX ? left : pet.maxX - pet.width * 0.35,
            y: pet.maxY - size.height * 0.35
        )
        point.x = min(max(point.x, bounds.minX + gap), bounds.maxX - size.width - gap)
        point.y = min(max(point.y, bounds.minY + gap), bounds.maxY - size.height - gap)
        panel.setFrameOrigin(point)
    }
    private func scrollAnswer(by pages: CGFloat) -> Bool {
        guard panel.isVisible, let scroll = scrollBox.view,
              let document = scroll.documentView else { return false }
        let clip = scroll.contentView
        let maxY = max(document.bounds.minY, document.bounds.maxY - clip.bounds.height)
        let y = min(max(clip.bounds.origin.y + pages * max(72, clip.bounds.height * 0.82), 0), maxY)
        guard abs(y - clip.bounds.origin.y) > 0.5 else { return false }
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
        scroll.reflectScrolledClipView(clip)
        return true
    }
    private func answerBody(_ answer: String, _ question: String?) -> String {
        let question = question?.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ") ?? ""
        return question.isEmpty ? answer : "你问：\(String(question.prefix(240)))\n\n\(answer)"
    }
    private func timeline(
        _ events: [ActivityEvent], final: String?, detailed: Bool
    ) -> String {
        if !detailed {
            let lines = events.suffix(5).map { "• \($0.activity.label)  \($0.message)" }
            return (lines + (final?.isEmpty == false ? ["", final!] : [])).joined(separator: "\n")
        }
        var sections = events.compactMap { event -> String? in
            guard event.details != nil else { return nil }
            let title: String = switch event.activity {
            case .observing: "观察界面"
            case .acting: "执行动作"
            case .failure: "操作结果"
            case .thinking: "用户补充"
            default: "状态"
            }
            let step = event.sequence.map { "第 \($0) 步 · " } ?? ""
            return (["\(step)\(title)", event.message, event.details]
                .compactMap { $0?.isEmpty == false ? $0 : nil }).joined(separator: "\n")
        }
        if let final, !final.isEmpty { sections.append(final) }
        return sections.joined(separator: "\n\n")
    }
}
