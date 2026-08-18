using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text.Json;

namespace JellyPet.Windows;

internal sealed class WindowsAutomation
{
    private readonly string selectedScreen;

    internal WindowsAutomation(string selectedScreen = "") =>
        this.selectedScreen = selectedScreen;

    internal string DisplayName => TargetScreen().DeviceName;

    internal string Capture()
    {
        var bounds = TargetScreen().Bounds;
        var path = Path.Combine(
            Path.GetTempPath(),
            "JellyPet-Capture-" + Guid.NewGuid() + ".png"
        );
        using var bitmap = new Bitmap(bounds.Width, bounds.Height);
        using var graphics = Graphics.FromImage(bitmap);
        graphics.CopyFromScreen(bounds.Location, Point.Empty, bounds.Size);
        bitmap.Save(path, ImageFormat.Png);
        return path;
    }

    internal async Task ExecuteAsync(
        JsonElement action,
        CancellationToken cancellationToken)
    {
        var kind = RequiredString(action, "kind");
        switch (kind)
        {
            case "click":
                Click(ScreenPoint(action.GetProperty("target")), 1);
                return;
            case "doubleClick":
                Click(ScreenPoint(action.GetProperty("target")), 2);
                return;
            case "drag":
                await DragAsync(action, cancellationToken);
                return;
            case "typeText":
                Click(ScreenPoint(action.GetProperty("target")), 1);
                await Task.Delay(80, cancellationToken);
                if (RequiredBool(action, "replacesExistingText"))
                {
                    KeyPress(Keys.A, [Keys.ControlKey]);
                    await Task.Delay(40, cancellationToken);
                }
                TypeUnicode(RequiredString(action, "text"), cancellationToken);
                return;
            case "keyPress":
                var modifiers = action.GetProperty("modifiers")
                    .EnumerateArray()
                    .Select(value => Modifier(value.GetString()))
                    .ToArray();
                KeyPress(Key(RequiredString(action, "key")), modifiers);
                return;
            case "navigate":
                var url = RequiredString(action, "url");
                if (!SafeNavigationURL(url, out _))
                    throw new InvalidOperationException(
                        "只允许打开无内嵌凭据的 http/https 地址。"
                    );
                KeyPress(Keys.L, [Keys.ControlKey]);
                await Task.Delay(80, cancellationToken);
                TypeUnicode(url, cancellationToken);
                KeyPress(Keys.Enter, []);
                return;
            case "scroll":
                var target = action.TryGetProperty("target", out var scrollTarget)
                    ? ScreenPoint(scrollTarget)
                    : Center();
                var deltaX = RequiredInt(action, "deltaX", -420, 420);
                var deltaY = RequiredInt(action, "deltaY", -420, 420);
                if (deltaX == 0 && deltaY == 0)
                    throw new InvalidOperationException("滚动距离不能同时为 0。");
                MoveCursor(target);
                if (deltaX != 0)
                    mouse_event(
                        MouseHorizontalWheel,
                        0,
                        0,
                        unchecked((uint)deltaX),
                        SyntheticMarker
                    );
                if (deltaY != 0)
                    mouse_event(
                        MouseWheel,
                        0,
                        0,
                        unchecked((uint)deltaY),
                        SyntheticMarker
                    );
                return;
            case "wait":
                await Task.Delay(
                    RequiredInt(action, "milliseconds", 200, 3_000),
                    cancellationToken
                );
                return;
            default:
                throw new InvalidOperationException($"不支持的动作：{kind}");
        }
    }

    private async Task DragAsync(
        JsonElement action,
        CancellationToken cancellationToken)
    {
        var start = ScreenPoint(
            RequiredInt(action, "fromX", 0, 1_000),
            RequiredInt(action, "fromY", 0, 1_000)
        );
        var end = ScreenPoint(
            RequiredInt(action, "toX", 0, 1_000),
            RequiredInt(action, "toY", 0, 1_000)
        );
        var duration = RequiredInt(
            action,
            "durationMilliseconds",
            200,
            2_000
        );
        MoveCursor(start);
        mouse_event(LeftDown, 0, 0, 0, SyntheticMarker);
        try
        {
            const int steps = 20;
            for (var index = 1; index <= steps; index++)
            {
                cancellationToken.ThrowIfCancellationRequested();
                MoveCursor(new Point(
                    start.X + (end.X - start.X) * index / steps,
                    start.Y + (end.Y - start.Y) * index / steps
                ));
                await Task.Delay(duration / steps, cancellationToken);
            }
        }
        finally
        {
            mouse_event(LeftUp, 0, 0, 0, SyntheticMarker);
        }
    }

    private static void Click(Point point, int count)
    {
        MoveCursor(point);
        for (var index = 0; index < count; index++)
        {
            mouse_event(LeftDown, 0, 0, 0, SyntheticMarker);
            mouse_event(LeftUp, 0, 0, 0, SyntheticMarker);
        }
    }

    private Point ScreenPoint(JsonElement target)
    {
        if (RequiredString(target, "source") != "visual")
            throw new InvalidOperationException("Windows 版只支持视觉坐标目标。");
        return ScreenPoint(
            RequiredInt(target, "x", 0, 1_000),
            RequiredInt(target, "y", 0, 1_000)
        );
    }

    private Point ScreenPoint(int normalizedX, int normalizedY)
    {
        var bounds = TargetScreen().Bounds;
        return new Point(
            bounds.Left + normalizedX * bounds.Width / 1_000,
            bounds.Top + normalizedY * bounds.Height / 1_000
        );
    }

    private Point Center()
    {
        var bounds = TargetScreen().Bounds;
        return new Point(
            bounds.Left + bounds.Width / 2,
            bounds.Top + bounds.Height / 2
        );
    }

    private Screen TargetScreen()
    {
        if (string.IsNullOrWhiteSpace(selectedScreen))
            return Screen.PrimaryScreen
                ?? throw new InvalidOperationException("找不到主屏幕。");
        return Screen.AllScreens.FirstOrDefault(
            screen => screen.DeviceName == selectedScreen
        ) ?? throw new InvalidOperationException(
            $"之前选择的屏幕 {selectedScreen} 已断开，请在设置中重新选择。"
        );
    }

    private static void KeyPress(Keys key, Keys[] modifiers)
    {
        foreach (var modifier in modifiers)
            keybd_event((byte)modifier, 0, 0, SyntheticMarker);
        keybd_event((byte)key, 0, 0, SyntheticMarker);
        keybd_event((byte)key, 0, KeyUp, SyntheticMarker);
        foreach (var modifier in modifiers.Reverse())
            keybd_event((byte)modifier, 0, KeyUp, SyntheticMarker);
    }

    private static void TypeUnicode(
        string text,
        CancellationToken cancellationToken)
    {
        var normalized = text.Replace("\r\n", "\r").Replace('\n', '\r');
        const int chunkSize = 256;
        for (var offset = 0; offset < normalized.Length; offset += chunkSize)
        {
            cancellationToken.ThrowIfCancellationRequested();
            SendUnicode(normalized.AsSpan(
                offset,
                Math.Min(chunkSize, normalized.Length - offset)
            ));
        }
    }

    private static void SendUnicode(ReadOnlySpan<char> text)
    {
        var inputs = new Input[text.Length * 2];
        for (var index = 0; index < text.Length; index++)
        {
            inputs[index * 2] = Input.Unicode(text[index], keyUp: false);
            inputs[index * 2 + 1] = Input.Unicode(text[index], keyUp: true);
        }
        if (SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<Input>())
            != (uint)inputs.Length)
            throw new InvalidOperationException("无法完整输入文本。");
    }

    private static Keys Modifier(string? value) => value switch {
        "control" or "command" => Keys.ControlKey,
        "option" => Keys.Menu,
        "shift" => Keys.ShiftKey,
        _ => throw new InvalidOperationException("不支持的修饰键。")
    };

    private static Keys Key(string value) => value switch {
        "return" => Keys.Enter,
        "tab" => Keys.Tab,
        "escape" => Keys.Escape,
        "delete" => Keys.Back,
        "forwardDelete" => Keys.Delete,
        "left" => Keys.Left,
        "right" => Keys.Right,
        "up" => Keys.Up,
        "down" => Keys.Down,
        "space" => Keys.Space,
        "home" => Keys.Home,
        "end" => Keys.End,
        "pageUp" => Keys.PageUp,
        "pageDown" => Keys.PageDown,
        "a" => Keys.A,
        "l" => Keys.L,
        "r" => Keys.R,
        "t" => Keys.T,
        "v" => Keys.V,
        "w" => Keys.W,
        _ => throw new InvalidOperationException($"不支持的按键：{value}")
    };

    private static string RequiredString(JsonElement value, string property) =>
        value.TryGetProperty(property, out var result)
            && result.ValueKind == JsonValueKind.String
            && result.GetString() is { Length: > 0 } text
            ? text
            : throw new InvalidOperationException($"缺少字段 {property}。");

    private static bool RequiredBool(JsonElement value, string property)
    {
        if (!value.TryGetProperty(property, out var result)
            || result.ValueKind is not (JsonValueKind.True or JsonValueKind.False))
            throw new InvalidOperationException($"字段 {property} 必须是布尔值。");
        return result.GetBoolean();
    }

    private static int RequiredInt(
        JsonElement value,
        string property,
        int minimum,
        int maximum)
    {
        if (!value.TryGetProperty(property, out var result)
            || result.ValueKind != JsonValueKind.Number
            || !result.TryGetInt32(out var number)
            || number < minimum
            || number > maximum)
            throw new InvalidOperationException(
                $"字段 {property} 必须是 {minimum} 到 {maximum} 的整数。"
            );
        return number;
    }

    internal static bool SafeNavigationURL(string? value, out Uri result)
    {
        result = null!;
        if (string.IsNullOrWhiteSpace(value)
            || value.Length > 2_048
            || value.Any(char.IsControl)
            || !Uri.TryCreate(value, UriKind.Absolute, out var parsed)
            || parsed.Scheme is not ("http" or "https")
            || string.IsNullOrWhiteSpace(parsed.Host)
            || !string.IsNullOrEmpty(parsed.UserInfo))
            return false;
        result = parsed;
        return true;
    }

    private const uint LeftDown = 0x0002;
    private const uint LeftUp = 0x0004;
    private const uint MouseMove = 0x0001;
    private const uint MouseWheel = 0x0800;
    private const uint MouseHorizontalWheel = 0x1000;
    private const uint Absolute = 0x8000;
    private const uint VirtualDesk = 0x4000;
    private const uint KeyUp = 0x0002;
    private const uint KeyboardInput = 1;
    private const uint UnicodeKey = 0x0004;
    private static readonly UIntPtr SyntheticMarker = new(0x4A454C59);

    private static void MoveCursor(Point point)
    {
        var bounds = SystemInformation.VirtualScreen;
        var x = (uint)Math.Clamp(
            (point.X - bounds.Left) * 65_535L / Math.Max(1, bounds.Width - 1),
            0,
            65_535
        );
        var y = (uint)Math.Clamp(
            (point.Y - bounds.Top) * 65_535L / Math.Max(1, bounds.Height - 1),
            0,
            65_535
        );
        mouse_event(MouseMove | Absolute | VirtualDesk, x, y, 0, SyntheticMarker);
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Input
    {
        internal uint Type;
        internal InputUnion Data;

        internal static Input Unicode(char value, bool keyUp) => new() {
            Type = KeyboardInput,
            Data = new InputUnion {
                Keyboard = new KeyboardInputData {
                    VirtualKey = 0,
                    ScanCode = value,
                    Flags = UnicodeKey | (keyUp ? KeyUp : 0),
                    Time = 0,
                    ExtraInfo = SyntheticMarker
                }
            }
        };
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct InputUnion
    {
        [FieldOffset(0)] internal MouseInputData Mouse;
        [FieldOffset(0)] internal KeyboardInputData Keyboard;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MouseInputData
    {
        internal int X;
        internal int Y;
        internal uint MouseData;
        internal uint Flags;
        internal uint Time;
        internal UIntPtr ExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KeyboardInputData
    {
        internal ushort VirtualKey;
        internal ushort ScanCode;
        internal uint Flags;
        internal uint Time;
        internal UIntPtr ExtraInfo;
    }

    [DllImport("user32.dll")]
    private static extern void mouse_event(
        uint flags,
        uint dx,
        uint dy,
        uint data,
        UIntPtr extraInfo
    );

    [DllImport("user32.dll")]
    private static extern void keybd_event(
        byte virtualKey,
        byte scanCode,
        uint flags,
        UIntPtr extraInfo
    );

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(
        uint inputCount,
        Input[] inputs,
        int inputSize
    );
}
