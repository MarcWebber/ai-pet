namespace JellyPet.Windows;

internal sealed class SettingsDialog : Form
{
    private const string AutomaticModelLabel = "auto（使用 Runtime 默认模型）";
    private readonly ComboBox runtime = new() { DropDownStyle = ComboBoxStyle.DropDownList };
    private readonly ComboBox model = new() { DropDownStyle = ComboBoxStyle.DropDown };
    private readonly ComboBox effort = new() { DropDownStyle = ComboBoxStyle.DropDownList };
    private readonly TextBox instructions = new() {
        Multiline = true,
        ScrollBars = ScrollBars.Vertical
    };
    private readonly CheckBox takeover = new() {
        Text = "快捷键默认执行屏幕接管（关闭时为截图问答）",
        AutoSize = true
    };
    private readonly ComboBox shortcut = new() { DropDownStyle = ComboBoxStyle.DropDownList };
    private readonly ComboBox answerScroll = new() { DropDownStyle = ComboBoxStyle.DropDownList };
    private readonly ComboBox answerHistory = new() { DropDownStyle = ComboBoxStyle.DropDownList };
    private readonly ComboBox screen = new() { DropDownStyle = ComboBoxStyle.DropDownList };
    private readonly TextBox runtimeStatus = new() {
        ReadOnly = true,
        Multiline = true,
        ScrollBars = ScrollBars.Vertical
    };
    private readonly IReadOnlyList<AgentRuntimeInfo> detectedRuntimes;

    private SettingsDialog(AppSettings value)
    {
        detectedRuntimes = AgentRuntimeLocator.Detect();
        Text = "JellyPet 设置";
        Width = 620;
        Height = 700;
        StartPosition = FormStartPosition.CenterScreen;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        Font = new Font("Microsoft YaHei UI", 9);

        runtime.Items.Add(new RuntimeChoice("automatic", "自动选择"));
        foreach (var item in detectedRuntimes)
            runtime.Items.Add(new RuntimeChoice(item.Kind, item.DisplayName));
        runtime.SelectedItem = runtime.Items.Cast<RuntimeChoice>()
            .FirstOrDefault(item => item.Value == value.Runtime)
            ?? runtime.Items.Cast<RuntimeChoice>().First();
        runtime.SelectedIndexChanged += (_, _) => RefreshModels("auto");
        RefreshModels(value.Model);
        effort.Items.AddRange(["low", "medium", "high", "xhigh"]);
        effort.SelectedItem = value.ReasoningEffort;
        instructions.Text = value.CustomInstructions;
        takeover.Checked = value.TakeoverEnabled;
        shortcut.Items.AddRange([
            new ShortcutChoice("controlOptionSpace", "Ctrl + Alt + Space"),
            new ShortcutChoice("controlOptionJ", "Ctrl + Alt + J"),
            new ShortcutChoice("controlShiftSpace", "Ctrl + Shift + Space"),
            new ShortcutChoice("commandShiftSpace", "Win + Shift + Space")
        ]);
        shortcut.SelectedItem = shortcut.Items.Cast<ShortcutChoice>()
            .First(item => item.Value == value.GlobalShortcut);
        AddArrowChoices(answerScroll);
        AddArrowChoices(answerHistory);
        answerScroll.SelectedItem = answerScroll.Items.Cast<ShortcutChoice>()
            .First(item => item.Value == value.AnswerScrollShortcut);
        answerHistory.SelectedItem = answerHistory.Items.Cast<ShortcutChoice>()
            .First(item => item.Value == value.AnswerHistoryShortcut);
        foreach (var display in Screen.AllScreens)
            screen.Items.Add(new ScreenChoice(
                display.DeviceName,
                $"{display.DeviceName} · {display.Bounds.Width}×{display.Bounds.Height}"
                    + (display.Primary ? " · 主屏" : "")
            ));
        screen.SelectedItem = screen.Items.Cast<ScreenChoice>().FirstOrDefault(
            item => item.Value == value.SelectedScreen
        ) ?? screen.Items.Cast<ScreenChoice>().First(item =>
            Screen.AllScreens.First(display => display.DeviceName == item.Value).Primary
        );
        runtimeStatus.Text = detectedRuntimes.Count == 0
            ? "未发现兼容 CLI。支持 Codex、TraeX、Claude Code/cc、OpenCode。"
            : string.Join(
                Environment.NewLine,
                detectedRuntimes.Select(item =>
                    $"{item.DisplayName} · {item.ExecutablePath}"
                )
            );

        var table = new TableLayoutPanel {
            Dock = DockStyle.Fill,
            Padding = new Padding(18),
            ColumnCount = 2,
            RowCount = 11
        };
        table.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 130));
        table.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        AddRow(table, 0, "Agent Runtime", runtime);
        AddRow(table, 1, "模型", model);
        AddRow(table, 2, "推理强度", effort);
        AddRow(table, 3, "追加指令", instructions, 100);
        AddRow(table, 4, "默认模式", takeover);
        AddRow(table, 5, "唤醒/停止", shortcut);
        AddRow(table, 6, "滚动回答", answerScroll);
        AddRow(table, 7, "切换回答", answerHistory);
        AddRow(table, 8, "观察屏幕", screen);
        AddRow(table, 9, "探测结果", runtimeStatus, 72);

        var okay = new Button { Text = "保存", DialogResult = DialogResult.OK, Width = 90 };
        var cancel = new Button { Text = "取消", DialogResult = DialogResult.Cancel, Width = 90 };
        var buttons = new FlowLayoutPanel {
            Dock = DockStyle.Fill,
            FlowDirection = FlowDirection.RightToLeft
        };
        buttons.Controls.Add(okay);
        buttons.Controls.Add(cancel);
        table.Controls.Add(buttons, 0, 10);
        table.SetColumnSpan(buttons, 2);
        Controls.Add(table);
        AcceptButton = okay;
        CancelButton = cancel;
    }

    internal static AppSettings? Edit(AppSettings value)
    {
        using var dialog = new SettingsDialog(value);
        if (dialog.ShowDialog() != DialogResult.OK) return null;
        return value with {
            Runtime = ((RuntimeChoice)dialog.runtime.SelectedItem!).Value,
            Model = dialog.model.Text == AutomaticModelLabel
                ? "auto" : dialog.model.Text.Trim(),
            ReasoningEffort = (string)dialog.effort.SelectedItem!,
            CustomInstructions = dialog.instructions.Text.Trim(),
            TakeoverEnabled = dialog.takeover.Checked,
            GlobalShortcut = ((ShortcutChoice)dialog.shortcut.SelectedItem!).Value,
            AnswerScrollShortcut = ((ShortcutChoice)dialog.answerScroll.SelectedItem!).Value,
            AnswerHistoryShortcut = ((ShortcutChoice)dialog.answerHistory.SelectedItem!).Value,
            SelectedScreen = ((ScreenChoice)dialog.screen.SelectedItem!).Value
        };
    }

    private void RefreshModels(string selected)
    {
        var choice = runtime.SelectedItem as RuntimeChoice;
        var target = choice?.Value ?? "automatic";
        var selectedRuntime = AgentRuntimeLocator.Resolve(target, detectedRuntimes);
        model.Items.Clear();
        model.Items.Add(AutomaticModelLabel);
        if (selectedRuntime != null)
            foreach (var item in selectedRuntime.SuggestedModels) model.Items.Add(item);
        model.Text = selected == "auto" ? AutomaticModelLabel : selected;
    }

    private static void AddArrowChoices(ComboBox combo)
    {
        combo.Items.AddRange([
            new ShortcutChoice("controlOptionArrows", "Ctrl + Alt + 方向键"),
            new ShortcutChoice("controlShiftArrows", "Ctrl + Shift + 方向键"),
            new ShortcutChoice("commandOptionArrows", "Win + Alt + 方向键")
        ]);
    }

    private static void AddRow(
        TableLayoutPanel table,
        int row,
        string title,
        Control control,
        int height = 38)
    {
        table.RowStyles.Add(new RowStyle(SizeType.Absolute, height));
        var label = new Label { Text = title, AutoSize = true, Anchor = AnchorStyles.Left };
        control.Dock = DockStyle.Fill;
        table.Controls.Add(label, 0, row);
        table.Controls.Add(control, 1, row);
    }

    private sealed record ShortcutChoice(string Value, string Label)
    {
        public override string ToString() => Label;
    }

    private sealed record RuntimeChoice(string Value, string Label)
    {
        public override string ToString() => Label;
    }

    private sealed record ScreenChoice(string Value, string Label)
    {
        public override string ToString() => Label;
    }
}
