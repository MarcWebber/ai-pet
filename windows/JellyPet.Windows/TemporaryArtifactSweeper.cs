namespace JellyPet.Windows;

internal static class TemporaryArtifactSweeper
{
    private static readonly TimeSpan MinimumAge = TimeSpan.FromHours(1);

    internal static void RemoveAll()
    {
        var root = Path.GetTempPath();
        try
        {
            foreach (var path in Directory.EnumerateFiles(
                root,
                "JellyPet-Capture-*.png",
                SearchOption.TopDirectoryOnly
            ))
                if (IsStale(File.GetLastWriteTimeUtc(path))) TryDeleteFile(path);
            foreach (var pattern in new[] {
                "JellyPet-Codex-*", "JellyPet-Agent-*"
            })
                foreach (var path in Directory.EnumerateDirectories(
                    root,
                    pattern,
                    SearchOption.TopDirectoryOnly
                ))
                    if (IsStale(Directory.GetLastWriteTimeUtc(path)))
                        TryDeleteDirectory(path);
        }
        catch (Exception error) when (error is IOException
            or UnauthorizedAccessException) { }
    }

    private static bool IsStale(DateTime modified) =>
        DateTime.UtcNow - modified >= MinimumAge;

    private static void TryDeleteFile(string path)
    {
        try { File.Delete(path); } catch { }
    }

    private static void TryDeleteDirectory(string path)
    {
        try { Directory.Delete(path, true); } catch { }
    }
}
