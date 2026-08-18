namespace JellyPet.Windows;

internal sealed record AppSettings
{
    public string Runtime { get; init; } = "automatic";
    public string Model { get; init; } = "auto";
    public string ReasoningEffort { get; init; } = "high";
    public string CustomInstructions { get; init; } = "";
    public bool TakeoverEnabled { get; init; }
    public string GlobalShortcut { get; init; } = "controlOptionSpace";
    public string AnswerScrollShortcut { get; init; } = "controlOptionArrows";
    public string AnswerHistoryShortcut { get; init; } = "controlOptionArrows";
    public string SelectedScreen { get; init; } = "";

    internal static string PathName => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        "JellyPet",
        "settings.json"
    );

    internal static AppSettings Load()
    {
        try
        {
            if (File.Exists(PathName))
                return Normalize(JsonFileStore.Read<AppSettings>(PathName) ?? Default);
            Default.Save();
        }
        catch (Exception error) when (error is IOException
            or UnauthorizedAccessException
            or System.Text.Json.JsonException) { }
        return Default;
    }

    internal void Save() => JsonFileStore.Write(PathName, Normalize(this));

    private static AppSettings Normalize(AppSettings value) => value with {
        Runtime = value.Runtime is "automatic" or "codex" or "traex"
            or "claudeCode" or "openCode" ? value.Runtime : Default.Runtime,
        Model = NormalizeModel(value.Model),
        ReasoningEffort = value.ReasoningEffort is
            "low" or "medium" or "high" or "xhigh"
                ? value.ReasoningEffort : Default.ReasoningEffort,
        CustomInstructions = (value.CustomInstructions ?? "")[
            ..Math.Min(4000, (value.CustomInstructions ?? "").Length)],
        GlobalShortcut = value.GlobalShortcut is
            "controlOptionSpace" or "controlOptionJ" or
            "controlShiftSpace" or "commandShiftSpace"
                ? value.GlobalShortcut : Default.GlobalShortcut,
        AnswerScrollShortcut = NormalizeArrowShortcut(
            value.AnswerScrollShortcut,
            Default.AnswerScrollShortcut
        ),
        AnswerHistoryShortcut = NormalizeArrowShortcut(
            value.AnswerHistoryShortcut,
            Default.AnswerHistoryShortcut
        ),
        SelectedScreen = (value.SelectedScreen ?? "").Trim()
    };

    private static string NormalizeArrowShortcut(string? value, string fallback) =>
        value is "controlOptionArrows" or "controlShiftArrows"
            or "commandOptionArrows"
            ? value : fallback;

    private static string NormalizeModel(string? value)
    {
        var model = (value ?? "").Trim();
        if (model.Length == 0) return "auto";
        return model[..Math.Min(200, model.Length)];
    }

    private static AppSettings Default => new();
}
