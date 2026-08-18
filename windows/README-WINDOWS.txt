JellyPet 0.9.0 Windows x64 测试包

运行条件

- Windows 10 或 Windows 11 x64。
- 至少安装并登录一种本地 Agent Runtime：Codex、TraeX、Claude Code/cc 或
  OpenCode。先在 PowerShell 中确认对应 CLI 的 --version 与登录状态可用。
- JellyPet 会自动检查 PATH、%APPDATA%\npm 和用户 .local\bin。特殊安装位置可用
  JELLY_CODEX_PATH、JELLY_TRAEX_PATH、JELLY_CLAUDE_PATH 或
  JELLY_OPENCODE_PATH 指定完整路径。
- 本包已自带 .NET 运行时，不需要另外安装 .NET。

安装与启动

1. 解压整个目录，不要只单独复制 JellyPet.exe。
2. 可以直接运行 JellyPet.exe；也可以在 PowerShell 中运行：
     .\install.ps1 -Launch
   安装脚本会复制到 %LOCALAPPDATA%\Programs\JellyPet 并创建开始菜单快捷方式。
3. Windows 若提示来源未知，是因为当前测试包没有代码签名；请只使用可信来源的包。

截图问答

- 单击桌面果冻或双击托盘图标，打开可输入的问答框。
- 选择“截图问答”，输入问题后发送；留空发送会直接分析当前屏幕。
- 截图里有多道题时，果冻会按页面顺序回答全部可读题目，而不是只答第一题。
- 连续截图会沿用当前 Runtime 的会话或 JellyPet 保存的最近文字上下文；回答框中的
  后续输入可以继续追问。
- 本地保留最近 8 次问题和回答文字，不保存截图。
- 回答顶部会简短显示本次输入的问题。

屏幕接管

- 在回答框切换到“屏幕接管”，输入明确任务后发送。
- 接管中输入框仍可输入补充要求，并通过 turn/steer 送入当前 Agent。
- 移动鼠标不会停止任务。再次按“唤醒/停止”快捷键才会停止当前问答或接管。
- 接管不再针对所谓敏感操作弹出 JellyPet 自己的认证或确认步骤。

默认快捷键（都可以在设置中修改）

- Ctrl + Alt + Space：空闲时按当前模式开始；工作中再次按下则停止。
- Ctrl + Alt + Up / Down：不移动鼠标，向上或向下翻动回答。
- Ctrl + Alt + Left / Right：切换上一次或下一次回答。

Agent Runtime 可观测性

- JellyPet 直接继承当前 Windows 用户的 PATH、HOME、USERPROFILE、各 Runtime 的认证目录和 hooks，
  不创建隔离认证环境，也不覆盖这些环境变量。
- Codex/TraeX 使用 app-server 持久 thread；Claude Code/OpenCode 使用非交互终端
  适配并由 JellyPet 保留最近对话上下文。
- JellyPet 仍只给接管 Agent 注册屏幕观察、单击、双击、拖动、一次性文本输入、按键、
  打开网址、滚动和等待等界面工具。

已知边界

- 当前接管只读取所选屏幕截图并使用视觉坐标，没有 UI Automation、DOM 或 Playwright
  语义定位；复杂编辑器、远程桌面和快速变化页面的可靠性会更低。
- Windows DRM/受保护内容、某些管理员权限窗口或安全桌面可能无法截图或操作。
- Codex/TraeX app-server 动态工具及其他 Runtime 的终端参数可能随 CLI 版本变化；
  连接失败时先升级对应 CLI，并查看果冻显示的真实 stderr。
- 此包从 macOS 交叉编译，已验证源码编译、发布内容和 PE x64 格式，但尚未代替测试者
  完成 Windows 真机启动、各 Runtime 登录、截图以及鼠标键盘端到端验证。

数据与卸载

- 设置：%APPDATA%\JellyPet\settings.json
- 回答历史：%APPDATA%\JellyPet\answer-history.json
- app-server Skill 工作目录：%LOCALAPPDATA%\JellyPet\CodexWorkspace
- 截图只放在系统临时目录，完成后删除；启动时会清理遗留的旧截图。
- 运行 .\uninstall.ps1 -RemoveUserData 可以连同设置和回答历史一起删除。
