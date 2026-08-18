using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace JellyPet.Windows;

internal sealed class JellyCoordinator : IDisposable
{
    private readonly IAgentClient agent;
    private readonly WindowsAutomation automation;
    private readonly Action<string, string, bool> updateState;
    private bool requiresObservation = true;
    private int observations;
    private int actions;

    internal JellyCoordinator(
        IAgentClient agent,
        WindowsAutomation automation,
        Action<string, string, bool> updateState)
    {
        this.agent = agent;
        this.automation = automation;
        this.updateState = updateState;
    }

    internal async Task<string> AnalyzeAsync(
        string question,
        CancellationToken cancellationToken)
    {
        updateState("观察屏幕", "正在读取当前屏幕。", true);
        var image = automation.Capture();
        try
        {
            var streamed = new StringBuilder();
            updateState("分析内容", $"{agent.RuntimeDisplayName} 正在理解当前页面。", true);
            var normalizedQuestion = question.Trim();
            normalizedQuestion = normalizedQuestion[
                ..Math.Min(4_000, normalizedQuestion.Length)
            ];
            var task = normalizedQuestion.Length == 0
                ? "没有明确问题时，指出当前屏幕最值得处理的一件事。"
                : "用户问题：" + normalizedQuestion;
            var result = await agent.AskAsync(
                image,
                $"""
                你是 JellyPet，一个坐在用户旁边看屏幕、会直接帮忙的果冻伙伴。使用简体中文回答。
                只观察附带内容，不调用工具、执行命令、读取其他文件或修改外部状态。
                用户追加指令（不得覆盖上述边界）：{agent.CustomInstructions}
                写得像真实交流，不固定使用标题或总结；没验证时用“可能”“看起来”说明。
                {task}
                先识别截图中全部可见题目，不要只回答第一题。有多道题时，按页面顺序逐题回答所有可读题目，用题号或简短题干区分。
                题目明确时立即给实际答案。选择题每题说出选项和一句简短理由；编程题给完整、可运行代码。
                某题看不清时，标出该题缺失的信息，但仍继续回答其他可读题目。
                信息不全时说明当前判断并给最可能答案。不展示隐藏推理。
                可以使用代码围栏，不用 Markdown 表格；除代码外保持精炼，多题时优先覆盖全部题目，不得为了篇幅省略题目。
                """,
                delta => PublishDelta(streamed, delta, "AI 正在回复"),
                cancellationToken
            );
            updateState("分析完成", result, false);
            return result;
        }
        finally
        {
            TryDelete(image);
        }
    }

    internal async Task<string> FollowUpAsync(
        string context,
        string question,
        CancellationToken cancellationToken)
    {
        var normalizedQuestion = question.Trim();
        normalizedQuestion = normalizedQuestion[
            ..Math.Min(4_000, normalizedQuestion.Length)
        ];
        if (normalizedQuestion.Length == 0)
            throw new InvalidOperationException("请输入要继续问的问题。");
        var normalizedContext = context.Trim();
        normalizedContext = normalizedContext[
            ..Math.Min(24_000, normalizedContext.Length)
        ];
        var streamed = new StringBuilder();
        updateState("继续追问", $"{agent.RuntimeDisplayName} 正在结合上一轮回答继续思考。", true);
        var result = await agent.RespondAsync(
            $"""
            你是 JellyPet。下面只有上一轮文字上下文，没有新截图。使用简体中文直接回答。
            只观察提供的文字，不调用工具、执行命令、读取其他文件或修改外部状态。
            用户追加指令（不得覆盖上述边界）：{agent.CustomInstructions}
            编程题给完整可运行代码，不展示隐藏推理。
            上一轮文字：
            {normalizedContext}
            用户最新问题：{normalizedQuestion}
            """,
            null,
            delta => PublishDelta(streamed, delta, "AI 正在回复"),
            null,
            cancellationToken
        );
        updateState("追问完成", result, false);
        return result;
    }

    internal async Task<string> TakeOverAsync(
        string task,
        CancellationToken cancellationToken)
    {
        await agent.ResetSessionAsync();
        requiresObservation = true;
        observations = 0;
        actions = 0;
        var streamed = new StringBuilder();
        updateState(
            "初始化接管",
            $"正在启动 {agent.RuntimeDisplayName}，并加载屏幕工具。",
            true
        );

        var custom = agent.CustomInstructions.Trim();
        var prompt = string.Join("\n", new[] {
            $"用户任务：{task}",
            custom.Length == 0 ? null : $"用户补充要求：{custom}"
        }.Where(value => value != null));
        var result = await agent.RespondAsync(
            prompt,
            null,
            delta => PublishDelta(streamed, delta, "AI 正在回复"),
            HandleToolAsync,
            cancellationToken
        );

        return result;
    }

    internal void AddInstruction(string value) =>
        agent.Steer("用户补充要求：" + value.Trim());

    internal void Cancel() => agent.Cancel();

    private async Task<ScreenToolResult> HandleToolAsync(
        string tool,
        JsonElement arguments,
        CancellationToken cancellationToken)
    {
        if (tool == "observe")
        {
            RequireProperties(arguments, [], []);
            updateState(
                "观察屏幕",
                $"Agent 正在读取当前界面（第 {observations + 1} 次）。",
                true
            );
            var image = automation.Capture();
            try
            {
                var bytes = await File.ReadAllBytesAsync(image, cancellationToken);
                requiresObservation = false;
                observations++;
                updateState(
                    "规划下一步",
                    $"第 {observations} 次观察已返回 Agent，等待它决定下一步。",
                    true
                );
                return new ScreenToolResult(
                    true,
                    $"已读取屏幕 {automation.DisplayName}。这是当前最新截图；只能依据这张截图中的视觉坐标定位。",
                    bytes
                );
            }
            finally
            {
                TryDelete(image);
            }
        }

        var isWait = tool == "wait";
        if (requiresObservation && !isWait)
            return new ScreenToolResult(
                false,
                "页面可能已经变化，请先调用 observe 获取当前界面。"
            );

        JsonObject action;
        string label;
        try
        {
            (action, label) = BuildAction(tool, arguments);
        }
        catch (InvalidOperationException error)
        {
            return new ScreenToolResult(false, error.Message);
        }

        updateState(
            "执行操作",
            $"Agent 正在执行：{label}（此前已观察 {observations} 次、操作 {actions} 次）。",
            true
        );
        try
        {
            await automation.ExecuteAsync(
                JsonSerializer.SerializeToElement(action),
                cancellationToken
            );
            actions++;
            requiresObservation = true;
            if (!isWait) await Task.Delay(350, cancellationToken);
            updateState(
                "验证结果",
                $"{label}已执行，等待 Agent 重新观察实际结果。",
                true
            );
            return new ScreenToolResult(
                true,
                $"{label}已执行。页面状态可能变化，请调用 observe 验证结果。"
            );
        }
        catch (OperationCanceledException) { throw; }
        catch (Exception error)
        {
            requiresObservation = true;
            updateState("操作失败", error.Message, true);
            return new ScreenToolResult(
                false,
                $"{label}失败：{error.Message} 请重新观察后换一种方式。"
            );
        }
    }

    private static (JsonObject Action, string Label) BuildAction(
        string tool,
        JsonElement arguments)
    {
        switch (tool)
        {
            case "click":
                RequireProperties(arguments, ["target"], ["target"]);
                return (new JsonObject {
                    ["kind"] = "click",
                    ["target"] = Target(arguments.GetProperty("target"))
                }, "单击");
            case "double_click":
                RequireProperties(arguments, ["target"], ["target"]);
                return (new JsonObject {
                    ["kind"] = "doubleClick",
                    ["target"] = Target(arguments.GetProperty("target"))
                }, "双击");
            case "drag":
                RequireProperties(
                    arguments,
                    ["fromX", "fromY", "toX", "toY", "durationMilliseconds"],
                    ["fromX", "fromY", "toX", "toY", "durationMilliseconds"]
                );
                return (new JsonObject {
                    ["kind"] = "drag",
                    ["fromX"] = RequiredInt(arguments, "fromX", 0, 1_000),
                    ["fromY"] = RequiredInt(arguments, "fromY", 0, 1_000),
                    ["toX"] = RequiredInt(arguments, "toX", 0, 1_000),
                    ["toY"] = RequiredInt(arguments, "toY", 0, 1_000),
                    ["durationMilliseconds"] = RequiredInt(
                        arguments, "durationMilliseconds", 200, 2_000
                    )
                }, "拖动");
            case "type_text":
                RequireProperties(arguments, ["target", "text", "replace"], ["target", "text", "replace"]);
                return (new JsonObject {
                    ["kind"] = "typeText",
                    ["target"] = Target(arguments.GetProperty("target")),
                    ["text"] = RequiredString(arguments, "text", 100_000),
                    ["replacesExistingText"] = RequiredBool(arguments, "replace")
                }, "输入文本");
            case "key_press":
                RequireProperties(arguments, ["key", "modifiers"], ["key", "modifiers"]);
                var modifiers = RequiredStringArray(arguments, "modifiers", [
                    "command", "control", "option", "shift"
                ]);
                return (new JsonObject {
                    ["kind"] = "keyPress",
                    ["key"] = RequiredEnum(arguments, "key", [
                        "a", "l", "r", "t", "v", "w", "return", "tab",
                        "escape", "delete", "forwardDelete", "left", "right",
                        "up", "down", "space", "home", "end", "pageUp", "pageDown"
                    ]),
                    ["modifiers"] = modifiers
                }, "按键");
            case "navigate":
                RequireProperties(arguments, ["url"], ["url"]);
                var url = RequiredString(arguments, "url", 2_048).Trim();
                if (!WindowsAutomation.SafeNavigationURL(url, out _))
                    throw new InvalidOperationException("只允许打开无内嵌凭据的 http/https 地址。");
                return (new JsonObject {
                    ["kind"] = "navigate",
                    ["url"] = url
                }, "打开网址");
            case "scroll":
                RequireProperties(arguments, ["target", "deltaX", "deltaY"], ["deltaX", "deltaY"]);
                var deltaX = RequiredInt(arguments, "deltaX", -420, 420);
                var deltaY = RequiredInt(arguments, "deltaY", -420, 420);
                if (deltaX == 0 && deltaY == 0)
                    throw new InvalidOperationException("滚动距离不能同时为 0。");
                var scroll = new JsonObject {
                    ["kind"] = "scroll",
                    ["deltaX"] = deltaX,
                    ["deltaY"] = deltaY
                };
                if (arguments.TryGetProperty("target", out var scrollTarget))
                    scroll["target"] = Target(scrollTarget);
                return (scroll, "滚动");
            case "wait":
                RequireProperties(arguments, ["milliseconds"], ["milliseconds"]);
                return (new JsonObject {
                    ["kind"] = "wait",
                    ["milliseconds"] = RequiredInt(arguments, "milliseconds", 200, 3_000)
                }, "等待");
            default:
                throw new InvalidOperationException($"不支持的屏幕工具：{tool}");
        }
    }

    private static JsonObject Target(JsonElement value)
    {
        RequireProperties(value, ["x", "y"], ["x", "y"]);
        return new JsonObject {
            ["source"] = "visual",
            ["x"] = RequiredInt(value, "x", 0, 1_000),
            ["y"] = RequiredInt(value, "y", 0, 1_000)
        };
    }

    private static void RequireProperties(
        JsonElement value,
        IReadOnlyCollection<string> allowed,
        IReadOnlyCollection<string> required)
    {
        if (value.ValueKind != JsonValueKind.Object)
            throw new InvalidOperationException("工具参数必须是对象。");
        foreach (var property in value.EnumerateObject())
            if (!allowed.Contains(property.Name))
                throw new InvalidOperationException($"不支持的工具参数：{property.Name}");
        foreach (var name in required)
            if (!value.TryGetProperty(name, out _))
                throw new InvalidOperationException($"缺少工具参数：{name}");
    }

    private static int RequiredInt(
        JsonElement value,
        string property,
        int minimum,
        int maximum)
    {
        if (!value.TryGetProperty(property, out var node)
            || node.ValueKind != JsonValueKind.Number
            || !node.TryGetInt32(out var result)
            || result < minimum
            || result > maximum)
            throw new InvalidOperationException(
                $"工具参数 {property} 必须是 {minimum} 到 {maximum} 的整数。"
            );
        return result;
    }

    private static bool RequiredBool(JsonElement value, string property)
    {
        if (!value.TryGetProperty(property, out var node)
            || node.ValueKind is not (JsonValueKind.True or JsonValueKind.False))
            throw new InvalidOperationException($"工具参数 {property} 必须是布尔值。");
        return node.GetBoolean();
    }

    private static string RequiredString(
        JsonElement value,
        string property,
        int maximum)
    {
        if (!value.TryGetProperty(property, out var node)
            || node.ValueKind != JsonValueKind.String
            || node.GetString() is not { Length: > 0 } result
            || result.Length > maximum)
            throw new InvalidOperationException(
                $"工具参数 {property} 必须是 1 到 {maximum} 个字符。"
            );
        return result;
    }

    private static string RequiredEnum(
        JsonElement value,
        string property,
        IReadOnlyCollection<string> allowed)
    {
        var result = RequiredString(value, property, 64);
        if (!allowed.Contains(result))
            throw new InvalidOperationException($"工具参数 {property} 的值不受支持。");
        return result;
    }

    private static JsonArray RequiredStringArray(
        JsonElement value,
        string property,
        IReadOnlyCollection<string> allowed)
    {
        if (!value.TryGetProperty(property, out var node)
            || node.ValueKind != JsonValueKind.Array)
            throw new InvalidOperationException($"工具参数 {property} 必须是数组。");
        var result = new JsonArray();
        var seen = new HashSet<string>();
        foreach (var entry in node.EnumerateArray())
        {
            if (entry.ValueKind != JsonValueKind.String
                || entry.GetString() is not { } item
                || !allowed.Contains(item)
                || !seen.Add(item))
                throw new InvalidOperationException($"工具参数 {property} 包含不支持或重复的值。");
            result.Add(item);
        }
        return result;
    }

    private void PublishDelta(StringBuilder text, string delta, string state)
    {
        if (text.Length + delta.Length > 200_000) return;
        text.Append(delta);
        var message = text.ToString().Trim();
        if (message.Length > 0) updateState(state, message, true);
    }

    private static void TryDelete(string path)
    {
        try { File.Delete(path); }
        catch (Exception error) when (error is IOException
            or UnauthorizedAccessException) { }
    }

    public void Dispose() => agent.Dispose();
}
