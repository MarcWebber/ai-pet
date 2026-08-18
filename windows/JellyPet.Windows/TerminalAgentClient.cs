using System.Diagnostics;
using System.Text;
using System.Text.Json;

namespace JellyPet.Windows;

internal sealed class TerminalAgentClient : IAgentClient
{
    private readonly AppSettings settings;
    private readonly AgentRuntimeInfo runtime;
    private readonly string workingDirectory;
    private readonly object processLock = new();
    private readonly object pendingLock = new();
    private readonly List<string> history = [];
    private readonly List<string> pendingInstructions = [];
    private Process? activeProcess;
    private string? configuration;

    internal TerminalAgentClient(AppSettings settings, AgentRuntimeInfo runtime)
    {
        this.settings = settings;
        this.runtime = runtime;
        workingDirectory = Path.Combine(
            Path.GetTempPath(),
            $"JellyPet-Agent-{runtime.Kind}-{Guid.NewGuid():N}"
        );
    }

    public string CustomInstructions => settings.CustomInstructions;
    public string RuntimeDisplayName => runtime.DisplayName;

    public Task<string> AskAsync(
        string imagePath,
        string prompt,
        Action<string> onTextDelta,
        CancellationToken cancellationToken) => RespondAsync(
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
        var currentConfiguration = settings.Model + "|" + settings.ReasoningEffort;
        if (configuration != currentConfiguration)
        {
            history.Clear();
            configuration = currentConfiguration;
        }
        if (screenToolHandler != null)
            return await RunTakeoverAsync(
                prompt,
                onTextDelta,
                screenToolHandler,
                cancellationToken
            );
        var answer = await InvokeAsync(prompt, imagePath, cancellationToken);
        onTextDelta(answer);
        return answer;
    }

    public void Steer(string instruction)
    {
        var value = instruction.Trim();
        if (value.Length == 0) return;
        value = value[..Math.Min(4_000, value.Length)];
        lock (pendingLock) pendingInstructions.Add(value);
    }

    public void Cancel()
    {
        Process? process;
        lock (processLock) process = activeProcess;
        if (process is not { HasExited: false }) return;
        try { process.Kill(true); }
        catch (InvalidOperationException) { }
    }

    public Task ResetSessionAsync()
    {
        Cancel();
        history.Clear();
        configuration = null;
        lock (pendingLock) pendingInstructions.Clear();
        return Task.CompletedTask;
    }

    private async Task<string> RunTakeoverAsync(
        string task,
        Action<string> onTextDelta,
        ScreenToolHandler screenToolHandler,
        CancellationToken cancellationToken)
    {
        var empty = JsonSerializer.SerializeToElement(new { });
        for (var step = 1; step <= 40; step++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var observation = await screenToolHandler(
                "observe",
                empty,
                cancellationToken
            );
            if (!observation.Success)
                throw new InvalidOperationException(observation.Message);
            string? imagePath = null;
            if (observation.ScreenshotPng != null)
            {
                Directory.CreateDirectory(workingDirectory);
                imagePath = Path.Combine(workingDirectory, $"observation-{step}.png");
                await File.WriteAllBytesAsync(
                    imagePath,
                    observation.ScreenshotPng,
                    cancellationToken
                );
            }
            try
            {
                var additions = TakePendingInstructions();
                var prompt = $$$"""
                    你正在通过 JellyPet 接管当前界面。不得调用终端、文件编辑器或 Runtime 自带的电脑工具；只能根据本轮观察选择 JellyPet 动作。
                    用户任务：{{{task}}}
                    {{{(additions.Count == 0 ? "" : "用户最新补充：" + string.Join("\n", additions))}}}
                    第 {{{step}}} 轮当前观察：
                    {{{observation.Message}}}

                    只返回一个 JSON 对象，不要代码围栏：
                    - 继续操作：{"type":"action","tool":"click","arguments":{...}}
                    - 已完成：{"type":"final","message":"给用户的简短结果"}
                    tool 仅可为 observe、click、double_click、drag、type_text、key_press、navigate、scroll、wait；视觉坐标为 0 到 1000。每次只给一个动作，动作后会重新观察。
                    """;
                var raw = await InvokeAsync(prompt, imagePath, cancellationToken);
                if (!TryDirective(raw, out var type, out var message, out var tool, out var arguments))
                {
                    onTextDelta(raw);
                    return raw;
                }
                if (type == "final")
                {
                    var answer = string.IsNullOrWhiteSpace(message)
                        ? "任务已完成。" : message.Trim();
                    onTextDelta(answer);
                    return answer;
                }
                if (type != "action" || string.IsNullOrWhiteSpace(tool))
                    throw new InvalidOperationException("Agent 返回的动作 JSON 无效。");
                var result = await screenToolHandler(
                    tool,
                    arguments,
                    cancellationToken
                );
                AddHistory("JellyPet 动作结果：" + result.Message);
            }
            finally
            {
                if (imagePath != null) TryDelete(imagePath);
            }
        }
        throw new InvalidOperationException("连续操作达到 40 次，已停止以避免失控。");
    }

    private async Task<string> InvokeAsync(
        string prompt,
        string? sourceImage,
        CancellationToken cancellationToken)
    {
        Directory.CreateDirectory(workingDirectory);
        string? localImage = null;
        if (sourceImage != null)
        {
            localImage = Path.Combine(
                workingDirectory,
                $"input-{Guid.NewGuid():N}{Path.GetExtension(sourceImage)}"
            );
            File.Copy(sourceImage, localImage, true);
        }
        try
        {
            var context = string.Join("\n\n", history.TakeLast(12));
            var fullPrompt = context.Length == 0
                ? prompt
                : $"此前对话（仅作上下文）：\n{context}\n\n当前请求：\n{prompt}";
            var (arguments, input) = BuildCommand(fullPrompt, localImage);
            var result = await RunAsync(arguments, input, cancellationToken);
            if (result.ExitCode != 0)
                throw new InvalidOperationException(
                    result.StandardError.Length == 0
                        ? $"{runtime.DisplayName} CLI 退出码 {result.ExitCode}"
                        : result.StandardError
                );
            var answer = ParseAnswer(result.StandardOutput);
            AddHistory("用户：" + prompt);
            AddHistory("助手：" + answer);
            return answer;
        }
        finally
        {
            if (localImage != null) TryDelete(localImage);
        }
    }

    private (IReadOnlyList<string> Arguments, string Input) BuildCommand(
        string prompt,
        string? imagePath)
    {
        if (runtime.Kind == "claudeCode")
        {
            var arguments = new List<string> {
                "--print", "--output-format", "json",
                "--permission-mode", "dontAsk", "--tools", "Read",
                "--no-session-persistence", "--effort", settings.ReasoningEffort
            };
            if (settings.Model != "auto")
                arguments.AddRange(["--model", settings.Model]);
            var imageInstruction = imagePath == null
                ? ""
                : $"\n截图位于 {imagePath}。必须先用 Read 工具读取这张图片再回答。";
            return (arguments, prompt + imageInstruction);
        }
        if (runtime.Kind == "openCode")
        {
            var arguments = new List<string> { "run" };
            if (settings.Model != "auto")
                arguments.AddRange(["--model", settings.Model]);
            if (imagePath != null) arguments.AddRange(["--file", imagePath]);
            arguments.Add(prompt);
            return (arguments, "");
        }
        throw new InvalidOperationException($"不支持的终端 Runtime：{runtime.DisplayName}");
    }

    private async Task<CommandResult> RunAsync(
        IReadOnlyList<string> arguments,
        string input,
        CancellationToken cancellationToken)
    {
        var isBatch = Path.GetExtension(runtime.ExecutablePath).Equals(
            ".cmd",
            StringComparison.OrdinalIgnoreCase
        ) || Path.GetExtension(runtime.ExecutablePath).Equals(
            ".bat",
            StringComparison.OrdinalIgnoreCase
        );
        var start = new ProcessStartInfo {
            FileName = isBatch
                ? Environment.GetEnvironmentVariable("ComSpec") ?? "cmd.exe"
                : runtime.ExecutablePath,
            WorkingDirectory = workingDirectory,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true
        };
        AddRuntimePath(start);
        if (isBatch)
        {
            start.ArgumentList.Add("/d");
            start.ArgumentList.Add("/s");
            start.ArgumentList.Add("/c");
            start.ArgumentList.Add(
                "call \"" + runtime.ExecutablePath + "\" "
                + string.Join(" ", arguments.Select(Quote))
            );
        }
        else
        {
            foreach (var argument in arguments) start.ArgumentList.Add(argument);
        }
        using var process = new Process { StartInfo = start };
        if (!process.Start())
            throw new InvalidOperationException($"无法启动 {runtime.DisplayName} CLI。");
        lock (processLock) activeProcess = process;
        try
        {
            var stdout = process.StandardOutput.ReadToEndAsync(cancellationToken);
            var stderr = process.StandardError.ReadToEndAsync(cancellationToken);
            await process.StandardInput.WriteAsync(input.AsMemory(), cancellationToken);
            process.StandardInput.Close();
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(
                cancellationToken
            );
            timeout.CancelAfter(TimeSpan.FromMinutes(3));
            await process.WaitForExitAsync(timeout.Token);
            return new CommandResult(
                process.ExitCode,
                (await stdout).Trim(),
                (await stderr).Trim()
            );
        }
        catch (OperationCanceledException)
        {
            if (!process.HasExited) process.Kill(true);
            throw;
        }
        finally
        {
            lock (processLock)
                if (ReferenceEquals(activeProcess, process)) activeProcess = null;
        }
    }

    private string ParseAnswer(string output)
    {
        var value = output.Trim();
        if (value.Length == 0)
            throw new InvalidOperationException("Agent 没有返回可显示的回答。");
        if (runtime.Kind == "claudeCode")
        {
            try
            {
                using var document = JsonDocument.Parse(value);
                var root = document.RootElement;
                if (root.TryGetProperty("is_error", out var isError)
                    && isError.ValueKind == JsonValueKind.True)
                    throw new InvalidOperationException(
                        root.TryGetProperty("result", out var error)
                            ? error.GetString() ?? "Claude Code 返回错误。"
                            : "Claude Code 返回错误。"
                    );
                if (root.TryGetProperty("result", out var result)
                    && result.GetString() is { Length: > 0 } answer)
                    return answer[..Math.Min(200_000, answer.Length)];
            }
            catch (JsonException) { }
        }
        return value[..Math.Min(200_000, value.Length)];
    }

    private static bool TryDirective(
        string output,
        out string type,
        out string message,
        out string tool,
        out JsonElement arguments)
    {
        type = message = tool = "";
        arguments = JsonSerializer.SerializeToElement(new { });
        var value = output.Trim();
        var first = value.IndexOf('{');
        var last = value.LastIndexOf('}');
        if (first < 0 || last <= first) return false;
        try
        {
            using var document = JsonDocument.Parse(value[first..(last + 1)]);
            var root = document.RootElement;
            type = root.TryGetProperty("type", out var typeValue)
                ? typeValue.GetString() ?? "" : "";
            message = root.TryGetProperty("message", out var messageValue)
                ? messageValue.GetString() ?? "" : "";
            tool = root.TryGetProperty("tool", out var toolValue)
                ? toolValue.GetString() ?? "" : "";
            if (root.TryGetProperty("arguments", out var argumentValue))
                arguments = argumentValue.Clone();
            return type.Length > 0;
        }
        catch (JsonException) { return false; }
    }

    private List<string> TakePendingInstructions()
    {
        lock (pendingLock)
        {
            var values = pendingInstructions.ToList();
            pendingInstructions.Clear();
            return values;
        }
    }

    private void AddHistory(string value)
    {
        history.Add(value[..Math.Min(8_000, value.Length)]);
        while (history.Count > 12 || history.Sum(item => item.Length) > 24_000)
            history.RemoveAt(0);
    }

    private void AddRuntimePath(ProcessStartInfo start)
    {
        var directories = new List<string> {
            Path.GetDirectoryName(runtime.ExecutablePath)!
        };
        var programFiles = Environment.GetFolderPath(
            Environment.SpecialFolder.ProgramFiles
        );
        if (programFiles.Length > 0)
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

    private static string Quote(string value) =>
        "\"" + value.Replace("\"", "\\\"") + "\"";

    private static void TryDelete(string path)
    {
        try { File.Delete(path); }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    public void Dispose()
    {
        Cancel();
        try { if (Directory.Exists(workingDirectory)) Directory.Delete(workingDirectory, true); }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    private sealed record CommandResult(
        int ExitCode,
        string StandardOutput,
        string StandardError
    );
}
