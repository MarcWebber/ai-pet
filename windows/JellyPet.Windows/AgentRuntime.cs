namespace JellyPet.Windows;

internal sealed record AgentRuntimeInfo(
    string Kind,
    string DisplayName,
    string ExecutablePath,
    string CommandName,
    bool UsesAppServer)
{
    internal IReadOnlyList<string> SuggestedModels => Kind switch {
        "codex" => [
            "gpt-5.6-luna", "gpt-5.6-terra", "gpt-5.6-sol",
            "gpt-5.5", "gpt-5.4"
        ],
        "traex" => [
            "gpt-5.4", "gpt-5.6-luna", "gpt-5.6-terra",
            "gpt-5.6-sol", "Doubao-Seed-2.1-Pro",
            "Doubao-Seed-2.1-Turbo", "DeepSeek-V4-Pro",
            "gemini-3.1-pro"
        ],
        "claudeCode" => ["sonnet", "opus", "haiku", "fable"],
        _ => []
    };
}

internal static class AgentRuntimeLocator
{
    internal static IReadOnlyList<AgentRuntimeInfo> Detect()
    {
        var directories = (Environment.GetEnvironmentVariable("PATH") ?? "")
            .Split(
                Path.PathSeparator,
                StringSplitOptions.RemoveEmptyEntries
                    | StringSplitOptions.TrimEntries
            )
            .Select(value => value.Trim('"'))
            .ToList();
        AddDirectory(
            directories,
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "npm"
        );
        AddDirectory(
            directories,
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            ".local", "bin"
        );
        AddDirectory(
            directories,
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            ".npm-global", "bin"
        );

        var runtimes = new List<AgentRuntimeInfo>();
        AddRuntime(
            runtimes, directories, "codex", "Codex", true,
            "JELLY_CODEX_PATH", ["codex"]
        );
        AddRuntime(
            runtimes, directories, "traex", "TraeX", true,
            "JELLY_TRAEX_PATH", ["traex", "traecli", "trae"]
        );
        AddRuntime(
            runtimes, directories, "claudeCode", "Claude Code / cc", false,
            "JELLY_CLAUDE_PATH", ["claude"]
        );
        if (!runtimes.Any(value => value.Kind == "claudeCode"))
        {
            var alias = FindExecutable(directories, ["cc"], null);
            var system = Environment.GetFolderPath(Environment.SpecialFolder.System);
            if (alias != null && !Path.GetDirectoryName(alias)!.Equals(
                system,
                StringComparison.OrdinalIgnoreCase
            ))
                runtimes.Add(new AgentRuntimeInfo(
                    "claudeCode", "Claude Code / cc", alias,
                    Path.GetFileName(alias), false
                ));
        }
        AddRuntime(
            runtimes, directories, "openCode", "OpenCode", false,
            "JELLY_OPENCODE_PATH", ["opencode"]
        );
        return runtimes;
    }

    internal static AgentRuntimeInfo? Resolve(
        string requested,
        IReadOnlyList<AgentRuntimeInfo> runtimes)
    {
        if (requested != "automatic")
            return runtimes.FirstOrDefault(value => value.Kind == requested);
        foreach (var kind in new[] { "codex", "traex", "claudeCode", "openCode" })
        {
            var runtime = runtimes.FirstOrDefault(value => value.Kind == kind);
            if (runtime != null) return runtime;
        }
        return null;
    }

    private static void AddRuntime(
        List<AgentRuntimeInfo> result,
        IReadOnlyList<string> directories,
        string kind,
        string displayName,
        bool usesAppServer,
        string environmentName,
        IReadOnlyList<string> names)
    {
        var configured = Environment.GetEnvironmentVariable(environmentName)
            ?.Trim().Trim('"');
        var path = FindExecutable(directories, names, configured);
        if (path == null) return;
        result.Add(new AgentRuntimeInfo(
            kind,
            displayName,
            path,
            Path.GetFileName(path),
            usesAppServer
        ));
    }

    private static string? FindExecutable(
        IReadOnlyList<string> directories,
        IReadOnlyList<string> names,
        string? configured)
    {
        if (!string.IsNullOrWhiteSpace(configured))
            return File.Exists(configured) ? Path.GetFullPath(configured) : null;
        foreach (var directory in directories.Distinct(
            StringComparer.OrdinalIgnoreCase
        ))
        {
            foreach (var name in names)
            {
                foreach (var extension in new[] { ".exe", ".cmd", ".bat", "" })
                {
                    var candidate = Path.Combine(directory, name + extension);
                    if (File.Exists(candidate)) return Path.GetFullPath(candidate);
                }
            }
        }
        return null;
    }

    private static void AddDirectory(
        List<string> directories,
        string root,
        params string[] components)
    {
        if (string.IsNullOrWhiteSpace(root)) return;
        directories.Add(components.Aggregate(root, Path.Combine));
    }
}

internal interface IAgentClient : IDisposable
{
    string CustomInstructions { get; }
    string RuntimeDisplayName { get; }
    Task<string> AskAsync(
        string imagePath,
        string prompt,
        Action<string> onTextDelta,
        CancellationToken cancellationToken);
    Task<string> RespondAsync(
        string prompt,
        string? imagePath,
        Action<string> onTextDelta,
        ScreenToolHandler? screenToolHandler,
        CancellationToken cancellationToken);
    void Steer(string instruction);
    void Cancel();
    Task ResetSessionAsync();
}
