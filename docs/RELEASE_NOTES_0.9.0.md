# JellyPet 0.9.0 发布说明

发布日期：2026-08-18

0.9.0 是 JellyPet 第一个同时提供 macOS 与 Windows 测试包的版本。重点是恢复完整的
截图问答与聊天体验，并把 AI 后端从单一 Codex 扩展为可自动探测的本地 Agent Runtime。

## 发布文件

| 文件 | SHA-256 |
| --- | --- |
| `JellyPet-0.9.0-macos.dmg` | `cc17e3e381bb51e7c8199f96ba68f2197f4067c5d9b9eac1d2bdb50a47224136` |
| `JellyPet-0.9.0-windows-x64-test.zip` | `f7487f8b3f4c122f61907c1b70f1a67838da27880fa79941b46e8a653d7984c8` |

下载后可以执行：

```bash
shasum -a 256 -c JellyPet-0.9.0-macos.dmg.sha256
shasum -a 256 -c JellyPet-0.9.0-windows-x64-test.zip.sha256
```

## 主要变化

- 支持 Codex、TraeX、Claude Code/`cc` 和 OpenCode。
- 自动探测 Runtime 路径，设置页可选择 Runtime、默认模型或自定义模型 ID。
- 修复桌面启动时 Node 不在 `PATH`、进而误报 Codex 未登录的问题。
- 多道题截图可以一次完整回答。
- 保存最近 8 次问题与回答，支持快捷键切换和滚动。
- 接管过程中输入框保持可用，移动鼠标不会退出。
- 删除 JellyPet 自己的敏感操作认证流程。
- 增加 Windows x64 自包含测试包。

完整变化见 [CHANGELOG.md](../CHANGELOG.md)。

## 安装前要求

- 至少安装并登录 Codex、TraeX、Claude Code 或 OpenCode 中的一种。
- macOS 需要 14 或更高版本，并在首次使用时允许屏幕录制与辅助功能权限。
- Windows 需要 Windows 10/11 x64；压缩包已自带 .NET 运行时。

## 验证结果

| 验证项 | 结果 |
| --- | --- |
| macOS Release 构建与 App 结构 | 通过 |
| macOS 代码签名完整性 | 通过，ad-hoc 签名 |
| `JellyBehaviorChecks` | 通过 |
| Codex 真实 app-server 模型往返 | 通过 |
| TraeX 真实 app-server 模型往返 | 通过 |
| Claude Code CLI 探测和适配 | 通过；真实模型往返受测试机网络影响 |
| OpenCode 适配 | 编译和受控 CLI 测试通过；测试机未安装 OpenCode |
| Windows Release 编译 | 通过，0 warning / 0 error |
| Windows 自包含发布与 PE x64 架构 | 通过 |
| Windows 真机桌面端到端 | 待测试者验证 |

## 分发状态

- macOS DMG 尚未使用 Developer ID 签名或 Apple notarization，只适合受信任测试。
- Windows 包尚未代码签名，系统可能显示来源未知提示。
- 两个平台都应先核对 SHA-256，再运行测试包。

## 升级说明

- 0.9.0 会继续读取已有的屏幕、模型、快捷键与回答历史设置。
- 旧模型设置仍会保留；首次切换 Runtime 时会自动改用该 Runtime 的默认模型。
- 请先退出旧 JellyPet，再安装新版本，避免同时运行多个实例。
