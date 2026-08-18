using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace JellyPet.Windows;

internal sealed record ScreenToolResult(
    bool Success,
    string Message,
    byte[]? ScreenshotPng = null
);

internal delegate Task<ScreenToolResult> ScreenToolHandler(
    string tool,
    JsonElement arguments,
    CancellationToken cancellationToken
);

internal sealed class CodexClient : IAgentClient
{
    private const string SkillName = "human-exam-taking";
    private static readonly string[] AppServerArguments = [
        "app-server", "--stdio",
        "--disable", "apps",
        "--disable", "goals",
        "--disable", "multi_agent",
        "--disable", "shell_tool",
        "--disable", "plugins",
        "--config", "mcp_servers={}"
    ];
    private readonly AppSettings settings;
    private readonly AgentRuntimeInfo runtime;
    private readonly string sourceSkillPath;
    private readonly string workingDirectory;
    private readonly object sendLock = new();
    private readonly StringBuilder standardError = new();
    private readonly Dictionary<string, List<JsonElement>> bufferedTurnEvents = [];
    private Process? process;
    private StreamWriter? input;
    private StreamReader? output;
    private int requestID;
    private bool initialized;
    private bool responseInFlight;
    private bool cancelRequested;
    private string? threadID;
    private string? activeTurnID;
    private string? runtimeSkillPath;
    private bool skillPending = true;
    private bool? threadUsesScreenTools;

    internal CodexClient(AppSettings settings, AgentRuntimeInfo runtime)
    {
        this.settings = settings;
        this.runtime = runtime;
        sourceSkillPath = Path.Combine(
            AppContext.BaseDirectory,
            "Skills",
            SkillName,
            "SKILL.md"
        );
        workingDirectory = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "JellyPet",
            "CodexWorkspace"
        );
    }

    public string CustomInstructions => settings.CustomInstructions;
    public string RuntimeDisplayName => runtime.DisplayName;

    public async Task<string> AskAsync(
        string imagePath,
        string prompt,
        Action<string> onTextDelta,
        CancellationToken cancellationToken) => await RespondAsync(
            prompt,
            imagePath,
            onTextDelta,
            null,
            cancellationToken
        );

    public async Task<string> RespondAsync(
        string prompt,
        string? imagePath,
        Action<string> onTextDelta,
        ScreenToolHandler? screenToolHandler,
        CancellationToken cancellationToken)
    {
        if (responseInFlight)
            throw new InvalidOperationException("Agent 已经在处理另一个请求。");
        responseInFlight = true;
        cancelRequested = false;
        try
        {
            await PrepareAsync(cancellationToken);
            var usesScreenTools = screenToolHandler != null;
            var currentThread = await EnsureThreadAsync(
                usesScreenTools,
                cancellationToken
            );
            cancellationToken.ThrowIfCancellationRequested();

            var attachedSkill = usesScreenTools && skillPending
                ? runtimeSkillPath ?? throw new InvalidOperationException(
                    "包内 human-exam-taking Skill 不可用。"
                )
                : null;
            var turnResult = await RpcAsync(
                "turn/start",
                new JsonObject {
                    ["threadId"] = currentThread,
                    ["input"] = BuildInput(prompt, imagePath, attachedSkill)
                },
                cancellationToken
            );
            if (attachedSkill != null) skillPending = false;
            var turn = RequiredObject(turnResult, "turn");
            var turnID = RequiredString(turn, "id");
            activeTurnID = turnID;
            using var registration = cancellationToken.Register(() => Interrupt());
            if (cancelRequested) throw new OperationCanceledException(cancellationToken);
            return await WaitForTurnAsync(
                turnID,
                onTextDelta,
                screenToolHandler,
                cancellationToken
            );
        }
        finally
        {
            activeTurnID = null;
            responseInFlight = false;
        }
    }

    public void Steer(string instruction)
    {
        var value = instruction.Trim();
        if (!responseInFlight || threadID == null || activeTurnID == null
            || value.Length == 0)
            throw new InvalidOperationException("当前没有可接收补充要求的 Agent turn。");
        Send(new JsonObject {
            ["id"] = NextRequestID(),
            ["method"] = "turn/steer",
            ["params"] = new JsonObject {
                ["threadId"] = threadID,
                ["expectedTurnId"] = activeTurnID,
                ["input"] = new JsonArray {
                    new JsonObject { ["type"] = "text", ["text"] = value }
                }
            }
        });
    }

    public void Cancel()
    {
        cancelRequested = true;
        Interrupt();
    }

    public Task ResetSessionAsync()
    {
        if (responseInFlight)
            throw new InvalidOperationException("不能在 Agent 正在响应时重置会话。");
        if (threadID != null && process is { HasExited: false })
        {
            try
            {
                Send(new JsonObject {
                    ["id"] = NextRequestID(),
                    ["method"] = "thread/unsubscribe",
                    ["params"] = new JsonObject { ["threadId"] = threadID }
                });
            }
            catch (IOException) { }
        }
        threadID = null;
        threadUsesScreenTools = null;
        bufferedTurnEvents.Clear();
        return Task.CompletedTask;
    }

    private async Task PrepareAsync(CancellationToken cancellationToken)
    {
        if (initialized && process is { HasExited: false }) return;
        StopProcess();
        StartProcess();
        await RpcAsync(
            "initialize",
            new JsonObject {
                ["clientInfo"] = new JsonObject {
                    ["name"] = "JellyPet",
                    ["version"] = typeof(CodexClient).Assembly
                        .GetName().Version?.ToString(3) ?? "dev"
                },
                ["capabilities"] = new JsonObject { ["experimentalApi"] = true }
            },
            cancellationToken
        );
        Send(new JsonObject { ["method"] = "initialized" });
        await DiscoverSkillAsync(cancellationToken);
        initialized = true;
    }

    private async Task DiscoverSkillAsync(CancellationToken cancellationToken)
    {
        var result = await RpcAsync(
            "skills/list",
            new JsonObject {
                ["cwds"] = new JsonArray { workingDirectory },
                ["forceReload"] = true
            },
            cancellationToken
        );
        if (!result.TryGetProperty("data", out var data)
            || data.ValueKind != JsonValueKind.Array)
            throw new InvalidOperationException("Agent 未返回 Skill 列表。");
        var expected = Path.GetFullPath(runtimeSkillPath!);
        foreach (var entry in data.EnumerateArray())
        {
            if (!entry.TryGetProperty("skills", out var skills)
                || skills.ValueKind != JsonValueKind.Array) continue;
            foreach (var skill in skills.EnumerateArray())
            {
                if (OptionalString(skill, "name") != SkillName
                    || !skill.TryGetProperty("enabled", out var enabled)
                    || enabled.ValueKind != JsonValueKind.True
                    || OptionalString(skill, "path") is not { } path
                    || !string.Equals(
                        Path.GetFullPath(path),
                        expected,
                        StringComparison.OrdinalIgnoreCase
                    )) continue;
                return;
            }
        }
        throw new InvalidOperationException("Agent 没有发现包内 human-exam-taking Skill。");
    }

    private async Task<string> EnsureThreadAsync(
        bool usesScreenTools,
        CancellationToken cancellationToken)
    {
        if (threadID != null && threadUsesScreenTools == usesScreenTools)
            return threadID;
        if (threadID != null) await ResetSessionAsync();
        var parameters = new JsonObject {
            ["cwd"] = workingDirectory,
            ["approvalPolicy"] = "never",
            ["sandbox"] = "danger-full-access",
            ["ephemeral"] = false,
            ["baseInstructions"] = usesScreenTools
                ? "你是 JellyPet 的 Windows 界面操作 Agent。使用 jellypet 命名空间工具观察并操作当前屏幕，根据每次真实工具结果继续工作，不返回动作 JSON。不得使用 Shell、文件修改或未提供的外部工具。"
                : "你是 JellyPet 的屏幕问答助手。只回答用户的问题，不执行界面操作、文件修改或外部命令。",
            ["config"] = new JsonObject {
                ["model_reasoning_effort"] = settings.ReasoningEffort
            }
        };
        if (settings.Model != "auto") parameters["model"] = settings.Model;
        if (usesScreenTools) parameters["dynamicTools"] = BuildDynamicTools();
        var result = await RpcAsync("thread/start", parameters, cancellationToken);
        var thread = RequiredObject(result, "thread");
        threadID = RequiredString(thread, "id");
        threadUsesScreenTools = usesScreenTools;
        skillPending = true;
        return threadID;
    }

    private async Task<JsonElement> RpcAsync(
        string method,
        JsonObject parameters,
        CancellationToken cancellationToken)
    {
        var id = NextRequestID();
        Send(new JsonObject {
            ["id"] = id,
            ["method"] = method,
            ["params"] = parameters
        });
        while (true)
        {
            var message = await NextMessageAsync(cancellationToken);
            if (message.TryGetProperty("id", out var responseID)
                && responseID.ValueKind == JsonValueKind.Number
                && responseID.TryGetInt32(out var value)
                && value == id
                && !message.TryGetProperty("method", out _))
            {
                if (message.TryGetProperty("error", out var error))
                    throw new InvalidOperationException(ErrorMessage(error));
                if (!message.TryGetProperty("result", out var result)
                    || result.ValueKind != JsonValueKind.Object)
                    throw new InvalidOperationException("Agent app-server 响应格式无效。");
                return result.Clone();
            }
            BufferTurnEvent(message);
        }
    }

    private async Task<string> WaitForTurnAsync(
        string turnID,
        Action<string> onTextDelta,
        ScreenToolHandler? screenToolHandler,
        CancellationToken cancellationToken)
    {
        var text = new StringBuilder();
        if (bufferedTurnEvents.Remove(turnID, out var buffered))
        {
            foreach (var message in buffered)
            {
                if (await HandleToolRequestAsync(
                    message, turnID, screenToolHandler, cancellationToken
                )) continue;
                var result = ConsumeTurnEvent(message, turnID, text, onTextDelta);
                if (result != null) return result;
            }
        }
        while (true)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var message = await NextMessageAsync(cancellationToken);
            if (await HandleToolRequestAsync(
                message, turnID, screenToolHandler, cancellationToken
            )) continue;
            var result = ConsumeTurnEvent(message, turnID, text, onTextDelta);
            if (result != null) return result;
        }
    }

    private async Task<bool> HandleToolRequestAsync(
        JsonElement message,
        string turnID,
        ScreenToolHandler? screenToolHandler,
        CancellationToken cancellationToken)
    {
        if (OptionalString(message, "method") != "item/tool/call"
            || !message.TryGetProperty("params", out var parameters)
            || OptionalString(parameters, "turnId") != turnID)
            return false;
        if (!message.TryGetProperty("id", out var requestIDValue))
            throw new InvalidOperationException("动态工具请求缺少 id。");

        ScreenToolResult result;
        try
        {
            if (screenToolHandler == null)
                throw new InvalidOperationException("当前会话没有启用屏幕工具。");
            if (OptionalString(parameters, "namespace") != "jellypet"
                || OptionalString(parameters, "tool") is not { } tool
                || !parameters.TryGetProperty("arguments", out var arguments)
                || arguments.ValueKind != JsonValueKind.Object)
                throw new InvalidOperationException("动态工具参数格式无效。");
            result = await screenToolHandler(tool, arguments.Clone(), cancellationToken);
        }
        catch (OperationCanceledException) { throw; }
        catch (Exception error)
        {
            result = new ScreenToolResult(false, error.Message);
        }

        Send(new JsonObject {
            ["id"] = JsonNode.Parse(requestIDValue.GetRawText()),
            ["result"] = BuildToolResponse(result)
        });
        return true;
    }

    private static string? ConsumeTurnEvent(
        JsonElement message,
        string turnID,
        StringBuilder text,
        Action<string> onTextDelta)
    {
        var method = OptionalString(message, "method");
        if (!message.TryGetProperty("params", out var parameters)) return null;
        if (method == "error"
            && OptionalString(parameters, "turnId") == turnID
            && (!parameters.TryGetProperty("willRetry", out var retry)
                || retry.ValueKind != JsonValueKind.True))
        {
            var error = parameters.TryGetProperty("error", out var value)
                ? value : default;
            throw new InvalidOperationException(ErrorMessage(error));
        }
        if (method == "item/agentMessage/delta"
            && OptionalString(parameters, "turnId") == turnID
            && OptionalString(parameters, "delta") is { Length: > 0 } delta)
        {
            if (text.Length + delta.Length > 200_000)
                throw new InvalidOperationException("Agent 回复过大。");
            text.Append(delta);
            onTextDelta(delta);
            return null;
        }
        if (method != "turn/completed"
            || !parameters.TryGetProperty("turn", out var turn)
            || OptionalString(turn, "id") != turnID)
            return null;
        var status = OptionalString(turn, "status");
        if (status == "interrupted") throw new OperationCanceledException();
        if (status != "completed")
        {
            var error = turn.TryGetProperty("error", out var value)
                ? value : default;
            throw new InvalidOperationException(ErrorMessage(error));
        }
        var answer = text.ToString().Trim();
        return answer.Length == 0
            ? throw new InvalidOperationException("Agent 没有返回可显示的回答。")
            : answer;
    }

    private void BufferTurnEvent(JsonElement message)
    {
        var method = OptionalString(message, "method");
        if (method is not ("item/agentMessage/delta" or "item/tool/call"
            or "error" or "turn/completed")
            || !message.TryGetProperty("params", out var parameters)) return;
        var turnID = OptionalString(parameters, "turnId");
        if (turnID == null && parameters.TryGetProperty("turn", out var turn))
            turnID = OptionalString(turn, "id");
        if (turnID == null) return;
        if (!bufferedTurnEvents.TryGetValue(turnID, out var values))
        {
            values = [];
            bufferedTurnEvents[turnID] = values;
        }
        if (values.Count < 128) values.Add(message.Clone());
    }

    private void Interrupt()
    {
        if (threadID == null || activeTurnID == null
            || process is not { HasExited: false }) return;
        try
        {
            Send(new JsonObject {
                ["id"] = NextRequestID(),
                ["method"] = "turn/interrupt",
                ["params"] = new JsonObject {
                    ["threadId"] = threadID,
                    ["turnId"] = activeTurnID
                }
            });
        }
        catch (IOException) { }
    }

    private void StartProcess()
    {
        if (!File.Exists(sourceSkillPath))
            throw new InvalidOperationException(
                "安装包缺少 Skills\\human-exam-taking\\SKILL.md。"
            );
        Directory.CreateDirectory(workingDirectory);
        runtimeSkillPath = Path.Combine(
            workingDirectory,
            ".agents",
            "skills",
            SkillName,
            "SKILL.md"
        );
        Directory.CreateDirectory(Path.GetDirectoryName(runtimeSkillPath)!);
        File.Copy(sourceSkillPath, runtimeSkillPath, true);

        var executable = runtime.ExecutablePath;
        var isBatchFile = Path.GetExtension(executable).Equals(
            ".cmd",
            StringComparison.OrdinalIgnoreCase
        ) || Path.GetExtension(executable).Equals(
            ".bat",
            StringComparison.OrdinalIgnoreCase
        );
        var start = new ProcessStartInfo {
            FileName = isBatchFile
                ? Environment.GetEnvironmentVariable("ComSpec") ?? "cmd.exe"
                : executable,
            WorkingDirectory = workingDirectory,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true
        };
        AddRuntimePath(start, executable);
        if (isBatchFile)
        {
            start.ArgumentList.Add("/d");
            start.ArgumentList.Add("/s");
            start.ArgumentList.Add("/c");
            start.ArgumentList.Add(
                "call \"" + executable + "\" "
                + string.Join(" ", AppServerArgumentsForRuntime().Select(
                    argument => "\"" + argument + "\""
                ))
            );
        }
        else
        {
            foreach (var argument in AppServerArgumentsForRuntime())
                start.ArgumentList.Add(argument);
        }
        standardError.Clear();
        process = new Process { StartInfo = start, EnableRaisingEvents = true };
        process.ErrorDataReceived += (_, eventArgs) => {
            if (eventArgs.Data == null) return;
            lock (standardError)
            {
                standardError.AppendLine(eventArgs.Data);
                if (standardError.Length > 8_000)
                    standardError.Remove(0, standardError.Length - 8_000);
            }
        };
        if (!process.Start())
            throw new InvalidOperationException($"无法启动 {runtime.DisplayName} CLI。");
        process.BeginErrorReadLine();
        input = process.StandardInput;
        input.AutoFlush = true;
        output = process.StandardOutput;
    }

    private IReadOnlyList<string> AppServerArgumentsForRuntime()
    {
        if (runtime.Kind == "traex")
            return ["app-server", "--listen", "stdio://", "--config", "mcp_servers={}"];
        return AppServerArguments;
    }

    private static void AddRuntimePath(ProcessStartInfo start, string executable)
    {
        var directories = new List<string> { Path.GetDirectoryName(executable)! };
        var programFiles = Environment.GetFolderPath(
            Environment.SpecialFolder.ProgramFiles
        );
        if (!string.IsNullOrWhiteSpace(programFiles))
            directories.Add(Path.Combine(programFiles, "nodejs"));
        directories.AddRange((start.Environment["PATH"] ?? "").Split(
            Path.PathSeparator,
            StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries
        ));
        start.Environment["PATH"] = string.Join(
            Path.PathSeparator,
            directories.Distinct(StringComparer.OrdinalIgnoreCase)
        );
    }

    private async Task<JsonElement> NextMessageAsync(
        CancellationToken cancellationToken)
    {
        while (true)
        {
            if (output == null) throw DisconnectedError();
            var line = await output.ReadLineAsync(cancellationToken);
            if (line == null) throw DisconnectedError();
            if (string.IsNullOrWhiteSpace(line)) continue;
            try
            {
                using var document = JsonDocument.Parse(line);
                if (document.RootElement.ValueKind != JsonValueKind.Object)
                    throw new JsonException();
                return document.RootElement.Clone();
            }
            catch (JsonException)
            {
                throw new InvalidOperationException(
                    "Agent app-server 返回了无效 JSON。"
                );
            }
        }
    }

    private void Send(JsonObject message)
    {
        lock (sendLock)
        {
            if (input == null || process is not { HasExited: false })
                throw DisconnectedError();
            input.WriteLine(message.ToJsonString());
        }
    }

    private int NextRequestID() => Interlocked.Increment(ref requestID);

    private InvalidOperationException DisconnectedError()
    {
        string detail;
        lock (standardError) detail = standardError.ToString().Trim();
        return new InvalidOperationException(
            detail.Length == 0
                ? "Agent app-server 已断开。"
                : "Agent app-server 已断开：" + detail
        );
    }

    private void StopProcess()
    {
        if (process is { HasExited: false })
        {
            try { process.Kill(true); }
            catch (InvalidOperationException) { }
        }
        input?.Dispose();
        output?.Dispose();
        process?.Dispose();
        input = null;
        output = null;
        process = null;
        initialized = false;
        threadID = null;
        activeTurnID = null;
        threadUsesScreenTools = null;
        runtimeSkillPath = null;
        skillPending = true;
        bufferedTurnEvents.Clear();
    }

    private static JsonArray BuildInput(
        string prompt,
        string? imagePath,
        string? skillPath)
    {
        var text = skillPath == null ? prompt : $"${SkillName}\n{prompt}";
        var input = new JsonArray {
            new JsonObject { ["type"] = "text", ["text"] = text }
        };
        if (skillPath != null)
            input.Add(new JsonObject {
                ["type"] = "skill",
                ["name"] = SkillName,
                ["path"] = skillPath
            });
        if (imagePath != null)
            input.Add(new JsonObject { ["type"] = "localImage", ["path"] = imagePath });
        return input;
    }

    private static JsonObject BuildToolResponse(ScreenToolResult result)
    {
        var content = new JsonArray {
            new JsonObject { ["type"] = "inputText", ["text"] = result.Message }
        };
        if (result.ScreenshotPng != null)
            content.Add(new JsonObject {
                ["type"] = "inputImage",
                ["imageUrl"] = "data:image/png;base64,"
                    + Convert.ToBase64String(result.ScreenshotPng)
            });
        return new JsonObject {
            ["contentItems"] = content,
            ["success"] = result.Success
        };
    }

    private static JsonArray BuildDynamicTools()
    {
        var coordinate = new JsonObject {
            ["type"] = "integer", ["minimum"] = 0, ["maximum"] = 1000
        };
        JsonObject Target() => Schema(
            new JsonObject {
                ["x"] = coordinate.DeepClone(),
                ["y"] = coordinate.DeepClone()
            },
            "x", "y"
        );
        return new JsonArray {
            new JsonObject {
                ["type"] = "namespace",
                ["name"] = "jellypet",
                ["description"] = "观察并操作 JellyPet 当前接管的 Windows 屏幕。",
                ["tools"] = new JsonArray {
                    Tool("observe", "读取当前 Windows 屏幕截图。开始任务以及每次操作后都调用。", Schema(new JsonObject())),
                    Tool("click", "单击当前截图中的视觉坐标。", Schema(new JsonObject { ["target"] = Target() }, "target")),
                    Tool("double_click", "双击当前截图中的视觉坐标。", Schema(new JsonObject { ["target"] = Target() }, "target")),
                    Tool("drag", "在当前截图上拖动。", Schema(new JsonObject {
                        ["fromX"] = coordinate.DeepClone(), ["fromY"] = coordinate.DeepClone(),
                        ["toX"] = coordinate.DeepClone(), ["toY"] = coordinate.DeepClone(),
                        ["durationMilliseconds"] = new JsonObject {
                            ["type"] = "integer", ["minimum"] = 200, ["maximum"] = 2000
                        }
                    }, "fromX", "fromY", "toX", "toY", "durationMilliseconds")),
                    Tool("type_text", "点击目标并一次性输入完整文本，不故意逐字伪装人工。", Schema(new JsonObject {
                        ["target"] = Target(),
                        ["text"] = new JsonObject { ["type"] = "string", ["minLength"] = 1, ["maxLength"] = 100000 },
                        ["replace"] = new JsonObject { ["type"] = "boolean" }
                    }, "target", "text", "replace")),
                    Tool("key_press", "发送一个按键及可选组合键。", Schema(new JsonObject {
                        ["key"] = new JsonObject { ["type"] = "string", ["enum"] = Strings(
                            "a", "l", "r", "t", "v", "w", "return", "tab", "escape",
                            "delete", "forwardDelete", "left", "right", "up", "down",
                            "space", "home", "end", "pageUp", "pageDown"
                        ) },
                        ["modifiers"] = new JsonObject {
                            ["type"] = "array", ["uniqueItems"] = true,
                            ["items"] = new JsonObject { ["type"] = "string", ["enum"] = Strings(
                                "command", "control", "option", "shift"
                            ) }
                        }
                    }, "key", "modifiers")),
                    Tool("navigate", "在当前浏览器地址栏打开无内嵌凭据的 HTTP 或 HTTPS 网址。", Schema(new JsonObject {
                        ["url"] = new JsonObject { ["type"] = "string", ["minLength"] = 1, ["maxLength"] = 2048 }
                    }, "url")),
                    Tool("scroll", "滚动当前页面或指定视觉坐标；负 deltaY 向下，绝对值不超过 420。", Schema(new JsonObject {
                        ["target"] = Target(),
                        ["deltaX"] = new JsonObject { ["type"] = "integer", ["minimum"] = -420, ["maximum"] = 420 },
                        ["deltaY"] = new JsonObject { ["type"] = "integer", ["minimum"] = -420, ["maximum"] = 420 }
                    }, "deltaX", "deltaY")),
                    Tool("wait", "等待页面短暂加载、运行或判题，之后重新观察。", Schema(new JsonObject {
                        ["milliseconds"] = new JsonObject { ["type"] = "integer", ["minimum"] = 200, ["maximum"] = 3000 }
                    }, "milliseconds"))
                }
            }
        };
    }

    private static JsonObject Tool(
        string name,
        string description,
        JsonObject inputSchema) => new() {
            ["type"] = "function",
            ["name"] = name,
            ["description"] = description,
            ["inputSchema"] = inputSchema
        };

    private static JsonObject Schema(
        JsonObject properties,
        params string[] required) => new() {
            ["type"] = "object",
            ["properties"] = properties,
            ["required"] = Strings(required),
            ["additionalProperties"] = false
        };

    private static JsonArray Strings(params string[] values)
    {
        var result = new JsonArray();
        foreach (var value in values) result.Add(value);
        return result;
    }

    private static JsonElement RequiredObject(JsonElement value, string property) =>
        value.TryGetProperty(property, out var result)
            && result.ValueKind == JsonValueKind.Object
            ? result
            : throw new InvalidOperationException($"Agent 响应缺少 {property}。");

    private static string RequiredString(JsonElement value, string property) =>
        OptionalString(value, property) is { Length: > 0 } result
            ? result
            : throw new InvalidOperationException($"Agent 响应缺少 {property}。");

    private static string? OptionalString(JsonElement value, string property) =>
        value.ValueKind == JsonValueKind.Object
            && value.TryGetProperty(property, out var result)
            && result.ValueKind == JsonValueKind.String
                ? result.GetString() : null;

    private static string ErrorMessage(JsonElement error)
    {
        if (error.ValueKind == JsonValueKind.Object)
        {
            var values = new[] {
                OptionalString(error, "message"),
                OptionalString(error, "additionalDetails")
            }.Where(value => !string.IsNullOrWhiteSpace(value));
            var result = string.Join("；", values);
            if (result.Length > 0) return result[..Math.Min(2000, result.Length)];
        }
        if (error.ValueKind is JsonValueKind.Undefined or JsonValueKind.Null)
            return "Agent app-server 返回了未知错误。";
        var raw = error.GetRawText();
        return raw[..Math.Min(2000, raw.Length)];
    }

    public void Dispose()
    {
        Cancel();
        StopProcess();
    }
}
