using System.ComponentModel;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;

namespace JellyPet.Windows;

internal sealed record BubbleRequest(
    bool Takeover,
    bool FollowUp,
    string Text
);

internal sealed class JellyApplication : ApplicationContext
{
    private const string DefaultTakeoverTask =
        "观察当前屏幕，识别当前最需要完成的任务并完成它。";
    private static readonly string AppVersion =
        typeof(JellyApplication).Assembly.GetName().Version?.ToString(3)
        ?? "unknown";

    private readonly PetForm pet = new();
    private readonly BubbleForm bubble = new();
    private readonly AnswerHistoryStore history = new();
    private readonly NotifyIcon tray;
    private HotkeyWindow? hotkey;
    private JellyCoordinator coordinator;
    private AppSettings settings;
    private CancellationTokenSource? activeTask;
    private bool takeoverActive;
    private int historyIndex = -1;

    internal JellyApplication()
    {
        TemporaryArtifactSweeper.RemoveAll();
        settings = AppSettings.Load();
        coordinator = CreateCoordinator();

        bubble.SubmitRequested += HandleSubmit;
        bubble.ModeChanged += SaveMode;
        pet.ActivatedByUser += OpenComposer;
        pet.TakeoverRequested += () => OpenComposer(takeover: true);
        pet.ExitRequested += Exit;
        PlacePet();
        pet.Show();

        var menu = new ContextMenuStrip();
        menu.Items.Add("打开果冻", null, (_, _) => OpenComposer());
        menu.Items.Add("立即截图问答", null, (_, _) => Analyze(""));
        menu.Items.Add("接管当前任务", null, (_, _) => OpenComposer(takeover: true));
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("上一次回答", null, (_, _) => MoveHistory(-1));
        menu.Items.Add("下一次回答", null, (_, _) => MoveHistory(1));
        menu.Items.Add("停止当前任务", null, (_, _) => Stop());
        menu.Items.Add("设置…", null, (_, _) => OpenSettings());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("退出", null, (_, _) => Exit());
        tray = new NotifyIcon {
            Icon = SystemIcons.Information,
            Text = $"JellyPet {AppVersion}",
            ContextMenuStrip = menu,
            Visible = true
        };
        tray.DoubleClick += (_, _) => OpenComposer();
        TryRegisterHotkeys(settings, showError: true);
    }

    private void OpenComposer() => OpenComposer(settings.TakeoverEnabled);

    private void OpenComposer(bool takeover)
    {
        if (activeTask != null)
        {
            bubble.BringToFront();
            return;
        }
        bubble.ShowComposer(takeover, ModelLabel(), pet.Bounds);
    }

    private void HandleSubmit(BubbleRequest request)
    {
        var text = request.Text.Trim();
        text = text[..Math.Min(4_000, text.Length)];
        if (activeTask != null)
        {
            if (!takeoverActive || text.Length == 0) return;
            try
            {
                coordinator.AddInstruction(text);
                UpdateState("已收到补充要求", text, true);
                bubble.ClearInput();
            }
            catch (Exception error)
            {
                UpdateState("补充要求未发送", error.Message, true);
            }
            return;
        }
        if (request.Takeover)
        {
            StartTakeover(text.Length == 0 ? DefaultTakeoverTask : text);
            return;
        }
        if (request.FollowUp && text.Length > 0 && history.Entries.Count > 0)
        {
            FollowUp(text);
            return;
        }
        Analyze(text);
    }

    private async void Analyze(string question)
    {
        if (!BeginTask()) return;
        try
        {
            var answer = await coordinator.AnalyzeAsync(question, activeTask!.Token);
            history.Add(question, answer);
            historyIndex = history.Entries.Count - 1;
            ShowHistory();
        }
        catch (OperationCanceledException)
        {
            UpdateState("已停止", "任务已由你取消。", false);
        }
        catch (Exception error)
        {
            UpdateState("失败", error.Message, false);
        }
        finally { EndTask(); }
    }

    private async void FollowUp(string question)
    {
        if (history.Entries.Count == 0 || !BeginTask()) return;
        try
        {
            historyIndex = Math.Clamp(
                historyIndex < 0 ? history.Entries.Count - 1 : historyIndex,
                0,
                history.Entries.Count - 1
            );
            var previous = history.Entries[historyIndex];
            var context = (previous.Question.Length == 0
                    ? ""
                    : "用户问题：" + previous.Question + "\n")
                + "果冻回答：" + previous.Answer;
            var answer = await coordinator.FollowUpAsync(
                context,
                question,
                activeTask!.Token
            );
            history.Add(question, answer);
            historyIndex = history.Entries.Count - 1;
            ShowHistory();
        }
        catch (OperationCanceledException)
        {
            UpdateState("已停止", "追问已由你取消。", false);
        }
        catch (Exception error)
        {
            UpdateState("失败", error.Message, false);
        }
        finally { EndTask(); }
    }

    private async void StartTakeover(string task)
    {
        if (!BeginTask()) return;
        takeoverActive = true;
        try
        {
            var normalizedTask = task.Trim();
            normalizedTask = normalizedTask[
                ..Math.Min(4_000, normalizedTask.Length)
            ];
            var result = await coordinator.TakeOverAsync(
                normalizedTask.Length == 0 ? DefaultTakeoverTask : normalizedTask,
                activeTask!.Token
            );
            takeoverActive = false;
            UpdateState("任务完成", result, false);
        }
        catch (OperationCanceledException)
        {
            takeoverActive = false;
            UpdateState("已停止", "接管已由你取消。", false);
        }
        catch (Exception error)
        {
            takeoverActive = false;
            UpdateState("失败", error.Message, false);
        }
        finally
        {
            takeoverActive = false;
            EndTask();
        }
    }

    private bool BeginTask()
    {
        if (activeTask != null) return false;
        activeTask = new CancellationTokenSource();
        return true;
    }

    private void EndTask()
    {
        activeTask?.Dispose();
        activeTask = null;
    }

    private void Stop()
    {
        activeTask?.Cancel();
        coordinator.Cancel();
    }

    private void HandlePrimaryHotkey()
    {
        if (activeTask != null)
        {
            Stop();
            return;
        }
        if (settings.TakeoverEnabled) StartTakeover(DefaultTakeoverTask);
        else Analyze("");
    }

    private void MoveHistory(int offset)
    {
        if (activeTask != null || history.Entries.Count == 0) return;
        if (historyIndex < 0) historyIndex = history.Entries.Count - 1;
        historyIndex = Math.Clamp(
            historyIndex + offset,
            0,
            history.Entries.Count - 1
        );
        ShowHistory();
    }

    private void ShowHistory()
    {
        if (history.Entries.Count == 0) return;
        historyIndex = Math.Clamp(
            historyIndex < 0 ? history.Entries.Count - 1 : historyIndex,
            0,
            history.Entries.Count - 1
        );
        bubble.ShowAnswer(
            history.Entries[historyIndex],
            historyIndex + 1,
            history.Entries.Count,
            ModelLabel(),
            pet.Bounds
        );
    }

    private void SaveMode(bool takeover)
    {
        if (settings.TakeoverEnabled == takeover) return;
        var updated = settings with { TakeoverEnabled = takeover };
        try
        {
            updated.Save();
            settings = updated;
        }
        catch (Exception error) when (error is IOException
            or UnauthorizedAccessException)
        {
            UpdateState("模式未保存", error.Message, false);
        }
    }

    private void OpenSettings()
    {
        if (activeTask != null) return;
        var updated = SettingsDialog.Edit(settings);
        if (updated == null) return;

        hotkey?.Dispose();
        hotkey = null;
        try
        {
            hotkey = CreateHotkeyWindow(updated);
            updated.Save();
        }
        catch (Exception error)
        {
            hotkey?.Dispose();
            hotkey = null;
            TryRegisterHotkeys(settings, showError: false);
            UpdateState("设置未保存", error.Message, false);
            return;
        }

        settings = AppSettings.Load();
        PlacePet();
        coordinator.Dispose();
        coordinator = CreateCoordinator();
        UpdateState("设置已保存", "新配置会从下一次问答或接管开始生效。", false);
    }

    private void TryRegisterHotkeys(AppSettings value, bool showError)
    {
        try { hotkey = CreateHotkeyWindow(value); }
        catch (Exception error)
        {
            hotkey = null;
            if (showError)
                UpdateState(
                    "快捷键不可用",
                    error.Message + " 可从托盘菜单继续使用。",
                    false
                );
        }
    }

    private HotkeyWindow CreateHotkeyWindow(AppSettings value) => new(
        value,
        HandlePrimaryHotkey,
        () => bubble.ScrollAnswer(up: true),
        () => bubble.ScrollAnswer(up: false),
        () => MoveHistory(-1),
        () => MoveHistory(1)
    );

    private JellyCoordinator CreateCoordinator() => new(
        new LocalAgentClient(settings),
        new WindowsAutomation(settings.SelectedScreen),
        UpdateState
    );

    private string ModelLabel()
    {
        var runtime = AgentRuntimeLocator.Resolve(
            settings.Runtime,
            AgentRuntimeLocator.Detect()
        )?.DisplayName ?? "未找到 Runtime";
        var model = settings.Model == "auto" ? "默认模型" : settings.Model;
        return $"{runtime} · {model} · {settings.ReasoningEffort}";
    }

    private void PlacePet()
    {
        var screen = Screen.AllScreens.FirstOrDefault(
            value => value.DeviceName == settings.SelectedScreen
        ) ?? Screen.PrimaryScreen;
        if (screen == null) return;
        pet.Location = new Point(
            screen.WorkingArea.Right - pet.Width - 24,
            screen.WorkingArea.Bottom - pet.Height - 24
        );
    }

    private void UpdateState(string state, string message, bool working)
    {
        if (pet.InvokeRequired)
        {
            pet.BeginInvoke(() => UpdateState(state, message, working));
            return;
        }
        bubble.ShowState(
            state,
            message,
            working,
            takeoverActive,
            ModelLabel(),
            pet.Bounds
        );
        pet.Activity = state;
        pet.Invalidate();
    }

    private void Exit()
    {
        Stop();
        ExitThread();
    }

    protected override void ExitThreadCore()
    {
        hotkey?.Dispose();
        coordinator.Dispose();
        tray.Visible = false;
        tray.Dispose();
        bubble.Dispose();
        pet.Dispose();
        base.ExitThreadCore();
    }
}

internal sealed class PetForm : Form
{
    internal event Action? ActivatedByUser;
    internal event Action? TakeoverRequested;
    internal event Action? ExitRequested;

    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    internal string Activity { get; set; } = "空闲";

    private Point dragOrigin;
    private bool dragged;

    internal PetForm()
    {
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        TopMost = true;
        Width = 112;
        Height = 112;
        BackColor = Color.Magenta;
        TransparencyKey = Color.Magenta;
        DoubleBuffered = true;

        var menu = new ContextMenuStrip();
        menu.Items.Add("打开果冻", null, (_, _) => ActivatedByUser?.Invoke());
        menu.Items.Add("接管任务", null, (_, _) => TakeoverRequested?.Invoke());
        menu.Items.Add("退出", null, (_, _) => ExitRequested?.Invoke());
        ContextMenuStrip = menu;

        MouseDown += (_, eventArgs) => {
            if (eventArgs.Button != MouseButtons.Left) return;
            dragOrigin = eventArgs.Location;
            dragged = false;
        };
        MouseMove += (_, eventArgs) => {
            if (eventArgs.Button != MouseButtons.Left) return;
            if (Math.Abs(eventArgs.X - dragOrigin.X) > 3
                || Math.Abs(eventArgs.Y - dragOrigin.Y) > 3)
                dragged = true;
            if (!dragged) return;
            Location = new Point(
                Left + eventArgs.X - dragOrigin.X,
                Top + eventArgs.Y - dragOrigin.Y
            );
        };
        MouseUp += (_, eventArgs) => {
            if (eventArgs.Button == MouseButtons.Left && !dragged)
                ActivatedByUser?.Invoke();
        };
    }

    protected override void OnHandleCreated(EventArgs eventArgs)
    {
        base.OnHandleCreated(eventArgs);
        CaptureExclusion.Apply(Handle);
    }

    protected override void OnPaint(PaintEventArgs eventArgs)
    {
        base.OnPaint(eventArgs);
        var graphics = eventArgs.Graphics;
        graphics.SmoothingMode = SmoothingMode.AntiAlias;
        using var body = new LinearGradientBrush(
            new Rectangle(10, 8, 92, 91),
            Color.FromArgb(210, 166, 255),
            Color.FromArgb(114, 69, 210),
            90
        );
        graphics.FillEllipse(body, 10, 9, 92, 86);
        graphics.FillEllipse(Brushes.White, 36, 43, 10, 13);
        graphics.FillEllipse(Brushes.White, 66, 43, 10, 13);
        graphics.FillEllipse(Brushes.Black, 39, 47, 4, 7);
        graphics.FillEllipse(Brushes.Black, 69, 47, 4, 7);
        using var font = new Font("Microsoft YaHei UI", 8, FontStyle.Bold);
        var activity = Activity[..Math.Min(7, Activity.Length)];
        var size = graphics.MeasureString(activity, font);
        graphics.DrawString(
            activity,
            font,
            Brushes.White,
            (Width - size.Width) / 2,
            82
        );
    }
}

internal sealed class BubbleForm : Form
{
    private enum Purpose { Composer, FollowUp, State }

    internal event Action<BubbleRequest>? SubmitRequested;
    internal event Action<bool>? ModeChanged;

    private readonly Label state = new();
    private readonly Label config = new();
    private readonly ComboBox mode = new() {
        DropDownStyle = ComboBoxStyle.DropDownList
    };
    private readonly TextBox message = new();
    private readonly ProgressBar progress = new();
    private readonly TextBox input = new();
    private readonly Button send = new();
    private Purpose purpose;
    private bool changingMode;

    internal BubbleForm()
    {
        FormBorderStyle = FormBorderStyle.FixedToolWindow;
        ShowInTaskbar = false;
        TopMost = true;
        ClientSize = new Size(500, 360);
        MinimumSize = new Size(420, 310);
        Text = "JellyPet";
        Font = new Font("Microsoft YaHei UI", 9);

        state.SetBounds(16, 14, 260, 26);
        state.Font = new Font("Microsoft YaHei UI", 11, FontStyle.Bold);
        config.SetBounds(280, 16, 204, 22);
        config.TextAlign = ContentAlignment.MiddleRight;
        config.ForeColor = Color.FromArgb(130, 75, 190);

        mode.SetBounds(16, 48, 156, 28);
        mode.Items.AddRange(["截图问答", "屏幕接管"]);
        mode.SelectedIndexChanged += (_, _) => {
            if (changingMode || mode.SelectedIndex < 0) return;
            ModeChanged?.Invoke(mode.SelectedIndex == 1);
            if (purpose == Purpose.Composer)
                message.Text = mode.SelectedIndex == 1
                    ? "输入明确任务并发送，果冻会观察并操作当前屏幕。"
                    : "输入问题并发送，果冻会截取所选屏幕后回答；不会操作页面。";
        };

        message.SetBounds(16, 84, 468, 208);
        message.Multiline = true;
        message.ReadOnly = true;
        message.ScrollBars = ScrollBars.Vertical;
        message.BackColor = SystemColors.Window;
        message.Anchor = AnchorStyles.Top | AnchorStyles.Bottom
            | AnchorStyles.Left | AnchorStyles.Right;

        progress.SetBounds(16, 300, 468, 7);
        progress.Style = ProgressBarStyle.Marquee;
        progress.Anchor = AnchorStyles.Bottom | AnchorStyles.Left | AnchorStyles.Right;

        input.SetBounds(16, 318, 378, 28);
        input.Anchor = AnchorStyles.Bottom | AnchorStyles.Left | AnchorStyles.Right;
        input.PlaceholderText = "输入问题…";
        input.KeyDown += (_, eventArgs) => {
            if (eventArgs.KeyCode != Keys.Enter) return;
            eventArgs.SuppressKeyPress = true;
            Submit();
        };
        send.SetBounds(402, 317, 82, 30);
        send.Text = "发送";
        send.Anchor = AnchorStyles.Bottom | AnchorStyles.Right;
        send.Click += (_, _) => Submit();

        Controls.AddRange([state, config, mode, message, progress, input, send]);
    }

    protected override void OnHandleCreated(EventArgs eventArgs)
    {
        base.OnHandleCreated(eventArgs);
        CaptureExclusion.Apply(Handle);
    }

    protected override void OnFormClosing(FormClosingEventArgs eventArgs)
    {
        if (eventArgs.CloseReason == CloseReason.UserClosing)
        {
            eventArgs.Cancel = true;
            Hide();
            return;
        }
        base.OnFormClosing(eventArgs);
    }

    internal void ShowComposer(bool takeover, string modelLabel, Rectangle petBounds)
    {
        purpose = Purpose.Composer;
        state.Text = "告诉果冻";
        config.Text = modelLabel;
        SetMode(takeover);
        mode.Enabled = true;
        message.Text = takeover
            ? "输入明确任务并发送，果冻会观察并操作当前屏幕。"
            : "输入问题并发送，果冻会截取所选屏幕后回答；不会操作页面。";
        progress.Visible = false;
        input.Enabled = true;
        input.Visible = true;
        send.Enabled = true;
        send.Visible = true;
        input.PlaceholderText = takeover ? "例如：完成这道题并提交" : "例如：把页面上的题都回答一下";
        input.Text = "";
        PositionNear(petBounds);
        ShowAndFocusInput();
    }

    internal void ShowAnswer(
        AnswerHistoryEntry entry,
        int current,
        int total,
        string modelLabel,
        Rectangle petBounds)
    {
        purpose = Purpose.FollowUp;
        state.Text = $"果冻看到了这些 · {current}/{total}";
        config.Text = modelLabel;
        SetMode(takeover: false);
        mode.Enabled = true;
        var question = entry.Question.Replace("\r", " ").Replace("\n", " ").Trim();
        if (question.Length > 240) question = question[..240] + "…";
        message.Text = question.Length == 0
            ? entry.Answer
            : $"你问：{question}\r\n\r\n{entry.Answer}";
        message.SelectionStart = 0;
        message.ScrollToCaret();
        progress.Visible = false;
        input.Enabled = true;
        input.Visible = true;
        send.Enabled = true;
        send.Visible = true;
        input.PlaceholderText = "继续问一句…";
        input.Text = "";
        PositionNear(petBounds);
        ShowAndFocusInput();
    }

    internal void ShowState(
        string stateText,
        string messageText,
        bool working,
        bool allowsInstruction,
        string modelLabel,
        Rectangle petBounds)
    {
        purpose = Purpose.State;
        state.Text = stateText;
        config.Text = modelLabel;
        message.Text = messageText;
        message.SelectionStart = message.TextLength;
        message.ScrollToCaret();
        progress.Visible = working;
        mode.Enabled = false;
        input.Visible = allowsInstruction;
        send.Visible = allowsInstruction;
        input.Enabled = allowsInstruction;
        send.Enabled = allowsInstruction;
        if (allowsInstruction)
        {
            SetMode(takeover: true);
            input.PlaceholderText = "接管中，可补充要求…";
        }
        PositionNear(petBounds);
        if (!Visible) Show();
    }

    internal void ClearInput() => input.Text = "";

    internal bool ScrollAnswer(bool up)
    {
        if (!Visible || message.TextLength == 0) return false;
        SendMessage(
            message.Handle,
            0x0115,
            new IntPtr(up ? 2 : 3),
            IntPtr.Zero
        );
        return true;
    }

    private void Submit()
    {
        var value = input.Text;
        if (purpose == Purpose.FollowUp && value.Trim().Length == 0) return;
        SubmitRequested?.Invoke(new BubbleRequest(
            mode.SelectedIndex == 1,
            purpose == Purpose.FollowUp,
            value
        ));
    }

    private void SetMode(bool takeover)
    {
        changingMode = true;
        mode.SelectedIndex = takeover ? 1 : 0;
        changingMode = false;
    }

    private void PositionNear(Rectangle petBounds)
    {
        var screen = Screen.FromRectangle(petBounds).WorkingArea;
        var maximumLeft = Math.Max(screen.Left, screen.Right - Width);
        var maximumTop = Math.Max(screen.Top, screen.Bottom - Height);
        Left = Math.Clamp(petBounds.Left - Width - 12, screen.Left, maximumLeft);
        Top = Math.Clamp(petBounds.Top, screen.Top, maximumTop);
    }

    private void ShowAndFocusInput()
    {
        if (!Visible) Show();
        BringToFront();
        Activate();
        input.Focus();
    }

    [DllImport("user32.dll")]
    private static extern IntPtr SendMessage(
        IntPtr handle,
        uint message,
        IntPtr word,
        IntPtr data
    );
}

internal sealed class HotkeyWindow : NativeWindow, IDisposable
{
    private const int HotkeyMessage = 0x0312;
    private const uint NoRepeat = 0x4000;
    private readonly Dictionary<int, Action> actions = [];
    private readonly List<int> registered = [];
    private bool disposed;

    internal HotkeyWindow(
        AppSettings settings,
        Action primary,
        Action scrollUp,
        Action scrollDown,
        Action previousAnswer,
        Action nextAnswer)
    {
        CreateHandle(new CreateParams());
        try
        {
            var (primaryModifiers, primaryKey) = Primary(settings.GlobalShortcut);
            Register(1, primaryModifiers, primaryKey, primary);
            var scrollModifiers = ArrowModifiers(settings.AnswerScrollShortcut);
            Register(2, scrollModifiers, 0x26, scrollUp);
            Register(3, scrollModifiers, 0x28, scrollDown);
            var historyModifiers = ArrowModifiers(settings.AnswerHistoryShortcut);
            Register(4, historyModifiers, 0x25, previousAnswer);
            Register(5, historyModifiers, 0x27, nextAnswer);
        }
        catch
        {
            Dispose();
            throw;
        }
    }

    protected override void WndProc(ref Message message)
    {
        if (message.Msg == HotkeyMessage
            && actions.TryGetValue(message.WParam.ToInt32(), out var action))
            action();
        base.WndProc(ref message);
    }

    private void Register(int id, uint modifiers, uint key, Action action)
    {
        if (!RegisterHotKey(Handle, id, modifiers | NoRepeat, key))
            throw new InvalidOperationException(
                "一个或多个全局快捷键已被其他应用占用。"
            );
        registered.Add(id);
        actions[id] = action;
    }

    private static (uint Modifiers, uint Key) Primary(string shortcut) =>
        shortcut switch {
            "controlOptionJ" => (0x0002u | 0x0001u, 0x4Au),
            "controlShiftSpace" => (0x0002u | 0x0004u, 0x20u),
            "commandShiftSpace" => (0x0008u | 0x0004u, 0x20u),
            _ => (0x0002u | 0x0001u, 0x20u)
        };

    private static uint ArrowModifiers(string shortcut) => shortcut switch {
        "controlShiftArrows" => 0x0002u | 0x0004u,
        "commandOptionArrows" => 0x0008u | 0x0001u,
        _ => 0x0002u | 0x0001u
    };

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        foreach (var id in registered) UnregisterHotKey(Handle, id);
        registered.Clear();
        actions.Clear();
        DestroyHandle();
    }

    [DllImport("user32.dll")]
    private static extern bool RegisterHotKey(
        IntPtr handle,
        int id,
        uint modifiers,
        uint key
    );

    [DllImport("user32.dll")]
    private static extern bool UnregisterHotKey(IntPtr handle, int id);
}

internal static class CaptureExclusion
{
    private const uint ExcludeFromCapture = 0x00000011;

    internal static void Apply(IntPtr handle)
    {
        try { SetWindowDisplayAffinity(handle, ExcludeFromCapture); }
        catch { }
    }

    [DllImport("user32.dll")]
    private static extern bool SetWindowDisplayAffinity(IntPtr handle, uint affinity);
}
