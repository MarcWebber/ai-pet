# JellyPet / 果冻

<p align="center">
  <img src="Resources/AppIcon-source.png" width="128" alt="JellyPet icon">
</p>

JellyPet 是一个面向 macOS 的本地 AI 桌宠。它会调用本机已经安装并登录的
Agent CLI，截取你选择的屏幕后回答问题，并在本地保留可配置数量的最近对话。

当前版本：**0.9.2**

开发平台：**macOS 14+ / Apple Silicon**

> JellyPet 不提供模型账号，也不会把 Runtime 的认证信息打包进应用。
> 屏幕接管默认开启，但仍明确标记为 Beta；聊天窗口会一直保留“截图问答 / 屏幕接管 · Beta”模式 Tab，可随时切换。

## 主要能力

- 截图问答：按页面顺序回答屏幕中全部可读题目，而不只回答第一题。
- 连续上下文：再次截图或追问时复用最近对话，保留轮数可配置为 1–50。
- 回答历史：问题和回答保存在本机，可用快捷键查看上一条、下一条。
- 本地 Runtime：自动探测 Codex、TraeX、Claude Code 和 OpenCode。
- 模型配置：支持 Runtime 默认模型、探测到的模型或完整手工模型 ID。
- 自定义外形：导入一张 8×8 PNG 精灵图即可替换 8 种状态动画。
- 全局滚动：不移动鼠标也能上下滚动当前回答。
- Beta 接管：默认工作模式，可在聊天窗口 Tab 或设置页切回纯截图问答。

## Runtime

JellyPet 至少需要一种已安装且已登录的本地 Runtime：

| Runtime | 命令 | 接入方式 |
| --- | --- | --- |
| Codex | `codex` | 常驻 app-server |
| TraeX | `traex`、`traecli` 或 `trae` | 常驻 app-server |
| Claude Code | `claude` | 非交互终端适配 |
| OpenCode | `opencode` | 非交互终端适配 |

自动选择顺序为 Codex → TraeX → Claude Code → OpenCode。JellyPet 从当前
`PATH`、`~/.local/bin`、`~/.npm-global/bin`、`/opt/homebrew/bin` 和
`/usr/local/bin` 探测命令，不再读取旧的专用路径变量或 App 内置 CLI 路径。
`cc` 不再是 Claude Code 的别名，也永远不会被当作 Agent Runtime。

## 安装与使用

1. 安装并登录至少一个受支持的 Agent CLI。
2. 从 [GitHub Releases](https://github.com/MarcWebber/ai-pet/releases) 下载
   `JellyPet-0.9.2-macos.dmg`，将应用拖入“应用程序”。
3. 首次截图时，在系统设置中允许屏幕录制；Beta 接管还需要辅助功能权限。
4. 单击果冻，输入问题并发送。

默认快捷键：

| 操作 | 快捷键 |
| --- | --- |
| 唤醒 / 停止 | `Control + Option + Space` |
| 回答向上 / 向下滚动 | `Control + Option + ↑ / ↓` |
| 上一次 / 下一次回答 | `Control + Option + ← / →` |

快捷键可在设置页修改。移动鼠标不会结束任务；再次按唤醒快捷键才会停止。

当前公开包使用 ad-hoc 签名，尚未 notarize。若 macOS 阻止首次启动，请只在确认
下载来源与 SHA-256 后，通过“系统设置 → 隐私与安全性”允许打开。

## 配置文件

首次启动会创建：

```text
~/Library/Application Support/JellyPet/config.json
```

设置页和手工编辑都使用这一份配置。重新打开设置页会重新读取文件；新配置从下一轮
请求生效。

```json
{
  "schemaVersion": 2,
  "conversation": {
    "historyTurns": 8
  },
  "assistant": {
    "runtime": "automatic",
    "model": "auto",
    "reasoningEffort": "high",
    "customInstructions": ""
  },
  "appearance": {
    "spriteSheet": null
  },
  "beta": {
    "screenTakeover": true
  }
}
```

- `historyTurns`：模型上下文与本地回答历史的保留轮数，范围 1–50。
- `runtime`：`automatic`、`codex`、`traex`、`claudeCode` 或 `openCode`。
- `model`：`auto` 或 Runtime 支持的完整模型 ID。
- `reasoningEffort`：`low`、`medium`、`high` 或 `xhigh`。
- `customInstructions`：最多 4000 个字符。
- `spriteSheet`：相对配置目录或绝对路径的 PNG；设置页导入时会自动管理。
- `screenTakeover`：启动聊天窗口时默认选择的模式，`true` 表示屏幕接管；默认 `true`。

屏幕选择、快捷键和活动详情属于本机界面偏好，仍由 macOS 偏好系统保存。

## 自定义 8×8 宠物外形

设置页选择一张透明 PNG。文件必须是正方形，宽高都能被 8 整除。整张图固定为
8 行 × 8 列：每行一种状态，每列为该状态的第 1–8 帧。

| 行（从上到下） | 状态 |
| --- | --- |
| 1 | 空闲 `idle` |
| 2 | 观察 `observing` |
| 3 | 思考 `thinking` |
| 4 | 定位 `locating` |
| 5 | 操作 `acting` |
| 6 | 验证 `verifying` |
| 7 | 完成 `success` |
| 8 | 失败 `failure` |

导入后，JellyPet 会把文件复制到配置目录的 `PetSprites.png`，因此原文件可以移动。
“恢复默认”会删除这份副本并重新使用内置外形。

## 屏幕接管（Beta）

接管现在是默认工作模式，但模式名称始终带有 `Beta` 标记。聊天窗口会一直显示
“截图问答 / 屏幕接管 · Beta”两个 Tab；设置页的开关只决定下次打开聊天窗口时默认
选择哪一个，不会隐藏功能入口。接管可能点击、输入、按键、滚动、拖动和导航；
请只在可信任务中使用，并用唤醒快捷键停止。旧的 schema 1 配置会在首次读取时迁移到
schema 2，并把默认模式切换为接管；之后仍可在设置页关闭默认选择。

macOS 当前前台为 Chrome 或 Edge 时，Beta 接管会依次尝试 Playwright、可发现的
Chrome DevTools Protocol 端点，最后回退到 Accessibility、截图和 CGEvent。

## 隐私与安全边界

- 只在用户触发截图问答或 Beta 接管时观察屏幕，空闲时不会持续截图。
- 截图存放在系统临时目录，回答后删除；启动时也会清理残留临时截图。
- 最近问题与回答以文字形式保存在本机，不保存对应截图。
- Agent 子进程继承当前用户的登录环境和认证状态；JellyPet 不复制认证令牌。
- macOS 屏幕录制、辅助功能、文件权限和安全桌面仍是最终系统边界。
- 页面内容是不可信输入；账号、付款或删除数据等操作仍需用户检查。

安全问题请参阅 [SECURITY.md](SECURITY.md)。

## 从源码构建

要求：macOS 14+、Swift 5.10 工具链，以及至少一种本地 Agent CLI。

```bash
bash scripts/build-app.sh
JELLY_SKIP_GUI_VERIFY=1 bash scripts/verify-app.sh
bash scripts/package-macos.sh
```

行为检查：

```bash
swift run --disable-sandbox JellyBehaviorChecks
```

产物：

- `dist/JellyPet.app`
- `dist/JellyPet-<version>-macos.dmg`
- `dist/JellyPet-<version>-macos.dmg.sha256`

## 代码结构

- `Sources/JellyCore/`：配置模型、回答提示、动作和会话状态。
- `Sources/JellyMac/`：配置存储、截图、Accessibility、浏览器、输入与 Runtime 适配。
- `Sources/JellyApp/`：应用生命周期、桌宠、聊天框、设置页和快捷键。
- `Tests/JellyBehaviorChecks/`：不打开桌面的核心行为检查。

## 当前限制

- 公测包尚未使用 Developer ID 签名与 notarization。
- Claude Code 和 OpenCode 的非交互参数可能随 CLI 版本变化。
- Beta 接管不属于稳定能力，浏览器扩展、远程桌面、DRM 内容、安全桌面和快速变化
  页面可能无法观察或操作。
- 构建和无窗口行为检查不能替代真实桌面、真实模型与真实页面的端到端验收。

版本变化见 [CHANGELOG.md](CHANGELOG.md)。当前仓库尚未声明开源许可证；在许可证
明确前，默认保留全部权利。
