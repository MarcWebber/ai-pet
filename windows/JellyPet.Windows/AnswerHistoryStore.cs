namespace JellyPet.Windows;

internal sealed record AnswerHistoryEntry(
    DateTimeOffset CreatedAt,
    string Question,
    string Answer
);

internal sealed class AnswerHistoryStore
{
    private const int Limit = 8;
    private readonly List<AnswerHistoryEntry> entries;

    internal AnswerHistoryStore() => entries = LoadEntries();

    internal IReadOnlyList<AnswerHistoryEntry> Entries => entries;

    internal void Add(string question, string answer)
    {
        var normalizedQuestion = Normalize(question, 4_000);
        var normalizedAnswer = Normalize(answer, 200_000);
        if (normalizedAnswer.Length == 0) return;
        entries.Add(new AnswerHistoryEntry(
            DateTimeOffset.UtcNow,
            normalizedQuestion,
            normalizedAnswer
        ));
        if (entries.Count > Limit)
            entries.RemoveRange(0, entries.Count - Limit);
        Save();
    }

    private static string PathName => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        "JellyPet",
        "answer-history.json"
    );

    private static List<AnswerHistoryEntry> LoadEntries()
    {
        try
        {
            if (!File.Exists(PathName)) return [];
            var values = JsonFileStore.Read<List<AnswerHistoryEntry>>(PathName)
                ?? [];
            return values
                .Where(value => !string.IsNullOrWhiteSpace(value.Answer))
                .Select(value => value with {
                    Question = Normalize(value.Question, 4_000),
                    Answer = Normalize(value.Answer, 200_000)
                })
                .TakeLast(Limit)
                .ToList();
        }
        catch (Exception error) when (error is IOException
            or UnauthorizedAccessException
            or System.Text.Json.JsonException)
        {
            return [];
        }
    }

    private void Save()
    {
        try { JsonFileStore.Write(PathName, entries); }
        catch (Exception error) when (error is IOException
            or UnauthorizedAccessException) { }
    }

    private static string Normalize(string? value, int maximum)
    {
        var result = (value ?? "").Trim();
        return result[..Math.Min(maximum, result.Length)];
    }
}
