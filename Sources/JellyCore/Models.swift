import Foundation

public enum PetFailure: Error, Equatable, Sendable {
    case selectedDisplayUnavailable
    case noDisplaysAvailable
    case captureFailed
    case codexUnavailable
    case codexFailed(String)
    case agentRuntimeUnavailable(String)
    case agentRuntimeFailed(String, String)
    case invalidCodexOutput
    case shortcutUnavailable
    case answerScrollShortcutUnavailable
    case answerHistoryShortcutUnavailable
    case invalidScreenAction
    case semanticTargetUnavailable
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
        case .codexUnavailable:
            return "Codex CLI 未找到或无法启动，请在设置中检查 CLI 路径。"
        case let .codexFailed(message):
            return "Codex 运行失败：\(message)"
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
            return "AI 连续引用了当前页面快照中不存在的元素，接管已停止。"
        case .screenActionFailed:
            return "无法执行鼠标或键盘动作，接管已停止。"
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
