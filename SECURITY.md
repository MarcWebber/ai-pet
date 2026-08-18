# Security Policy

## Supported versions

当前只维护最新的 `0.9.x` 测试版本。更早的预览包不会继续接收安全修复。

## Reporting a vulnerability

请优先使用 GitHub 仓库的 **Security → Report a vulnerability** 私密报告入口。
在修复发布前，请不要在公开 Issue 中披露可被直接利用的细节、凭据或个人截图。

报告中建议包含：

- 受影响的 JellyPet、操作系统和 Agent Runtime 版本；
- 最小复现步骤；
- 实际行为与预期行为；
- 是否涉及截图、输入控制、认证环境、临时文件或本地历史；
- 已脱敏的日志或截图。

## Product security boundary

JellyPet 是能够观察屏幕并控制鼠标、键盘的本地工具。使用者需要明确了解：

- 只有在可信环境中才应启用屏幕接管；
- 工作中可随时通过全局唤醒快捷键停止；
- 本地 Agent Runtime 继承当前用户的认证状态与 Hooks；
- JellyPet 不会把 Runtime 凭据写入发布包，但 Runtime 自身仍可能访问其账号能力；
- 系统屏幕录制、辅助功能、安全桌面和文件权限仍是最终边界；
- 网页和文档内容是不可信输入，可能尝试诱导 Agent 执行偏离用户目标的动作。

截图存放在系统临时目录并在任务结束后删除。最近问题与回答以文字形式保存在本机；
删除应用不会自动删除所有用户数据。Windows 可使用 `uninstall.ps1 -RemoveUserData`；
macOS 可执行 `defaults delete com.local.JellyPet` 清除偏好后再移除应用。
