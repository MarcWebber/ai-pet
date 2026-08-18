namespace JellyPet.Windows;

internal sealed class LocalAgentClient : IAgentClient
{
    private readonly AppSettings settings;
    private readonly IReadOnlyList<AgentRuntimeInfo> runtimes;
    private IAgentClient? active;
    private string? activeKind;

    internal LocalAgentClient(AppSettings settings)
    {
        this.settings = settings;
        runtimes = AgentRuntimeLocator.Detect();
    }

    public string CustomInstructions => settings.CustomInstructions;

    public string RuntimeDisplayName => AgentRuntimeLocator.Resolve(
        settings.Runtime,
        runtimes
    )?.DisplayName ?? (settings.Runtime == "automatic"
        ? "未找到 Runtime" : settings.Runtime);

    public Task<string> AskAsync(
        string imagePath,
        string prompt,
        Action<string> onTextDelta,
        CancellationToken cancellationToken) => Client().AskAsync(
            imagePath,
            prompt,
            onTextDelta,
            cancellationToken
        );

    public Task<string> RespondAsync(
        string prompt,
        string? imagePath,
        Action<string> onTextDelta,
        ScreenToolHandler? screenToolHandler,
        CancellationToken cancellationToken) => Client().RespondAsync(
            prompt,
            imagePath,
            onTextDelta,
            screenToolHandler,
            cancellationToken
        );

    public void Steer(string instruction) => Client().Steer(instruction);
    public void Cancel() => active?.Cancel();
    public Task ResetSessionAsync() => active?.ResetSessionAsync()
        ?? Task.CompletedTask;

    private IAgentClient Client()
    {
        var runtime = AgentRuntimeLocator.Resolve(settings.Runtime, runtimes)
            ?? throw new InvalidOperationException(
                "没有找到可用的本地 Agent Runtime。支持 Codex、TraeX、Claude Code/cc、OpenCode；请在设置中选择已探测到的 Runtime。"
            );
        if (activeKind == runtime.Kind && active != null) return active;
        active?.Dispose();
        active = runtime.UsesAppServer
            ? new CodexClient(settings, runtime)
            : new TerminalAgentClient(settings, runtime);
        activeKind = runtime.Kind;
        return active;
    }

    public void Dispose()
    {
        active?.Dispose();
        active = null;
        activeKind = null;
    }
}
