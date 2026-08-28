import Foundation

public enum PetFailure: Error, Equatable, Sendable {
    case selectedDisplayUnavailable
    case noDisplaysAvailable
    case captureFailed
    case screenCapturePermissionRequired
    case editorTextUnavailable
    case agentRuntimeUnavailable(String)
    case agentRuntimeFailed(String, String)
    case invalidCodexOutput
    case shortcutUnavailable
    case answerScrollShortcutUnavailable
    case answerHistoryShortcutUnavailable
    case invalidScreenAction
    case semanticTargetUnavailable
    case semanticLocatorFailed(String)
    case inputFocusChanged
    case screenActionFailed
}

extension PetFailure: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .selectedDisplayUnavailable:
            return "之前选择的屏幕已断开，请确认新的目标屏幕后重试。"
        case .noDisplaysAvailable:
            return "当前没有可捕获的屏幕。"
        case .captureFailed:
            return "无法捕获所选屏幕，请稍后重试。"
        case .screenCapturePermissionRequired:
            return "JellyPet 还没有屏幕录制权限。请先在系统设置的“隐私与安全性 → 屏幕与系统音频录制”中允许 JellyPet；本次不会打开选区截图。"
        case .editorTextUnavailable:
            return "暂时无法读取编辑器内容，请重新观察并再次定位编辑器。"
        case let .agentRuntimeUnavailable(runtime):
            return "没有找到 \(runtime) 的本地 CLI，请在设置中选择已探测到的 Runtime。"
        case let .agentRuntimeFailed(runtime, message):
            return "\(runtime) 运行失败：\(message)"
        case .invalidCodexOutput:
            return "Agent 没有返回可显示的回答，请重试。"
        case .shortcutUnavailable:
            return "所选快捷键已被其他应用占用，可从菜单栏手动分析屏幕。"
        case .answerScrollShortcutUnavailable:
            return "所选回答滚动快捷键已被其他应用占用，请在设置中换一组。"
        case .answerHistoryShortcutUnavailable:
            return "所选回答切换快捷键已被其他应用占用，请在设置中换一组。"
        case .invalidScreenAction:
            return "Agent 返回的鼠标或键盘参数无效。"
        case .semanticTargetUnavailable:
            return "当前页面快照里没有这个元素，请重新观察后定位。"
        case let .semanticLocatorFailed(message):
            return "无法在当前界面唯一定位目标元素：\(message)"
        case .inputFocusChanged:
            return "输入目标没有获得焦点，或输入过程中前台窗口发生了变化；请重新观察并继续。"
        case .screenActionFailed:
            return "这次鼠标或键盘动作没有执行成功，请重新观察并继续。"
        }
    }
}

public struct AnswerHistoryEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let question: String?
    public let answer: String
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        question: String?,
        answer: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.question = question
        self.answer = answer
        self.createdAt = createdAt
    }
}
