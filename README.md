# JellyPet / 果冻

<p align="center">
  <img src="Resources/AppIcon-source.png" width="128" alt="JellyPet icon">
</p>

JellyPet 是一个常驻桌面的本地 AI 助手。它可以观察当前屏幕、回答截图中的问题，
也可以在用户主动开启接管后，通过鼠标、键盘和浏览器语义完成界面任务。

当前版本：**0.9.0**

> JellyPet 会调用本机已经安装并登录的 Agent CLI。它不提供模型账号，
> 也不会把 Runtime 的认证信息打包进应用。

## 主要能力

- 截图问答：识别当前屏幕，并按页面顺序回答多道可读题目。
- 连续对话：保留最近文字上下文，再次截图或追问时不会立即丢失前一轮信息。
- 回答历史：本地保存最近 8 次问题与回答，可用快捷键前后切换。
- 屏幕接管：在用户开启接管后执行点击、输入、按键、滚动、拖动和导航。
- 可观察过程：显示观察、Runtime 回复、工具调用、执行结果和最终回答。
- 多 Runtime：自动探测 Codex、TraeX、Claude Code/`cc` 和 OpenCode。
- 模型选择：使用 Runtime 默认模型、探测到的模型，或手动输入模型 ID。
- macOS 浏览器语义：优先使用 Playwright DOM，失败时回退 Accessibility、截图和 CGEvent。
- Windows 测试版：提供统一问答框、截图/接管切换、历史记录和全局快捷键。

## 平台与状态

| 平台 | 要求 | 当前状态 |
| --- | --- | --- |
| macOS | macOS 14+，Apple Silicon | 主要开发与验证平台 |
| Windows | Windows 10/11 x64 | 0.9.0 测试版，需继续真机验证 |

JellyPet 至少需要下面一种已安装且已登录的本地 Runtime：

| Runtime | 执行方式 | 自动模型目录 |
| --- | --- | --- |
| Codex | 常驻 app-server | 内置常用模型建议 |
| TraeX | 常驻 app-server | 从 CLI 实时读取 |
| Claude Code / `cc` | 非交互终端适配 | 内置常用模型别名 |
| OpenCode | 非交互终端适配 | 从 CLI 实时读取 |

自动选择顺序是 Codex → TraeX → Claude Code → OpenCode。切换 Runtime 时模型会恢复为
`auto`，由对应 CLI 使用自己的默认模型。系统 `/usr/bin/cc` 会被排除，避免误认 C 编译器。

## 下载与安装

发布包位于 [GitHub Releases](https://github.com/MarcWebber/ai-pet/releases)。
0.9.0 的完整说明和校验值见 [发布说明](docs/RELEASE_NOTES_0.9.0.md)。

### macOS

1. 安装并登录至少一个受支持的 Agent CLI。
2. 下载 `JellyPet-0.9.0-macos.dmg`，将 `JellyPet.app` 拖入“应用程序”。
3. 首次使用截图或接管时，在系统设置中允许屏幕录制和辅助功能权限。
4. 打开设置，确认 Runtime 探测路径、模型、观察屏幕和快捷键。

当前公开测试 DMG 使用 ad-hoc 签名，尚未 notarize。macOS 若阻止首次启动，
请只在确认下载来源与 SHA-256 后，通过“系统设置 → 隐私与安全性”允许打开。

### Windows

1. 下载并完整解压 `JellyPet-0.9.0-windows-x64-test.zip`。
2. 安装并登录至少一个受支持的 Agent CLI。
3. 直接运行 `JellyPet.exe`，或在 PowerShell 中运行 `.\install.ps1 -Launch`。
4. 在设置中确认 Runtime、模型、屏幕和快捷键。

Windows 测试包自带 .NET 运行时，但暂未代码签名。详细说明见压缩包内的
`README-WINDOWS.txt`。

## 基本使用

1. 单击果冻打开输入框。
2. 选择“截图问答”或“屏幕接管”。
3. 输入问题或任务；截图问答也可以留空，让果冻直接分析当前屏幕。
4. 接管进行中可以继续输入补充要求。
5. 工作中再次按唤醒快捷键可停止当前任务；移动鼠标不会停止。

macOS 默认快捷键：

| 操作 | 快捷键 |
| --- | --- |
| 唤醒 / 停止 | `Control + Option + Space` |
| 回答向上 / 向下滚动 | `Control + Option + ↑ / ↓` |
| 上一次 / 下一次回答 | `Control + Option + ← / →` |

快捷键都可以在设置中修改。Windows 使用对应的 `Ctrl + Alt` 组合。

## 权限、隐私与安全边界

- JellyPet 只在用户触发截图问答或活动接管任务时观察屏幕，不会在空闲状态持续截图。
- 截图存放在系统临时目录，完成后删除；启动时会清理残留的 JellyPet 临时截图。
- 最近 8 次问题与回答以文字形式保存在本机，不保存对应截图。
- Agent 子进程继承当前用户的登录环境、认证目录和 Hooks；JellyPet 不读取或复制认证令牌。
- 接管模式可以控制鼠标和键盘。只对可信任务开启接管，并随时使用快捷键停止。
- macOS 权限最终由系统控制；JellyPet 不绕过屏幕录制、辅助功能或安全桌面限制。
- 页面内容可能包含误导 Agent 的文字。涉及账号、付款、删除数据等操作时，用户仍应主动检查。

安全问题请参阅 [SECURITY.md](SECURITY.md)。

## 浏览器接管

macOS 当前前台是 Chrome 或 Edge 时，JellyPet 会依次尝试：

1. Playwright Extension；
2. 可发现的 Chrome DevTools Protocol 端点；
3. Accessibility + 截图 + CGEvent 原生兜底。

DOM 模式能读取当前页面的可操作元素并在每次动作后重新观察。Canvas、Safari、
系统窗口以及无法附着的浏览器继续使用原生视觉路径。Windows 0.9.0 尚未提供
Playwright 或 UI Automation 语义定位，只使用截图和 Win32 输入。

## 从源码构建

### macOS

要求：macOS 14+、Swift 5.10 工具链，以及至少一种本地 Agent CLI。
浏览器 DOM 接管还需要本机 `playwright-cli`；构建过程不会通过 `npx` 自动下载它。

```bash
bash scripts/build-app.sh
bash scripts/verify-app.sh
bash scripts/package-macos.sh
```

产物：

- `dist/JellyPet.app`
- `dist/JellyPet-<version>-macos.dmg`
- `dist/JellyPet-<version>-macos.dmg.sha256`

无桌面行为检查：

```bash
swift run --disable-sandbox JellyBehaviorChecks
```

如果默认 SDK 与 Swift 编译器版本不兼容，可使用构建脚本采用的兼容 SDK：

```bash
mkdir -p /private/tmp/jellypet-clang-cache /private/tmp/jellypet-swiftpm-cache
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk \
CLANG_MODULE_CACHE_PATH=/private/tmp/jellypet-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/jellypet-swiftpm-cache \
swift run --disable-sandbox JellyBehaviorChecks
```

### Windows x64

要求：.NET 10 SDK。macOS 可以交叉编译 Windows 包，但不能代替 Windows 真机验收。

```bash
bash scripts/build-windows.sh
```

Windows 也可以执行：

```powershell
./scripts/build-windows.ps1
```

产物位于 `dist/windows/`。

## Codex 插件

仓库还包含独立的 `jellypet-takeover` Codex 插件。它与桌面 App 是两条独立运行轨道。
从仓库根目录安装：

```bash
codex plugin marketplace add .
codex plugin add jellypet-takeover@jellypet-local
```

插件会根据宿主提供的 Browser、Chrome、Computer 或 Playwright MCP 能力执行界面任务；
桌面 App 不会加载该插件。

## 架构

```text
JellyApp → AppCoordinator → TakeoverCoordinator ⇄ LocalAgentResponder
              │                    ↑              ├─ Codex / TraeX app-server
              │                    │              └─ Claude / OpenCode terminal
              └─ Surface Router ───┴─ Playwright DOM 或 AX / 截图 / CGEvent
```

- `Sources/JellyCore/`：模型、回答提示、屏幕动作和接管会话。
- `Sources/JellyMac/`：macOS 截图、Accessibility、浏览器、输入和 Runtime 适配。
- `Sources/JellyApp/`：应用生命周期、桌宠、聊天框、设置和快捷键。
- `windows/JellyPet.Windows/`：Windows x64 WinForms 测试版。
- `plugins/jellypet-takeover/`：独立 Codex 插件。
- `Tests/JellyBehaviorChecks/`：不打开桌面的核心行为检查。

## 当前限制

- macOS 公测包尚未使用 Developer ID 签名与 notarization。
- Windows 公测包尚未签名，并且仍需 Windows 真机覆盖不同 Runtime。
- Claude Code 和 OpenCode 的非交互命令参数可能随 CLI 版本变化。
- 浏览器扩展、远程桌面、DRM 内容、安全桌面和快速变化页面可能无法观察或操作。
- 构建与无窗口行为检查不能替代真实桌面、真实模型和真实页面的端到端验收。

## 版本记录

见 [CHANGELOG.md](CHANGELOG.md)。

## 许可证

当前仓库尚未声明开源许可证。在许可证明确前，默认保留全部权利。
