using System.Text.Json;

namespace JellyPet.Windows;

internal static class JsonFileStore
{
    private static readonly JsonSerializerOptions Options = new() {
        WriteIndented = true
    };

    internal static T? Read<T>(string path) =>
        JsonSerializer.Deserialize<T>(File.ReadAllText(path));

    internal static void Write<T>(string path, T value)
    {
        var directory = Path.GetDirectoryName(path)
            ?? throw new InvalidOperationException("配置路径无效。");
        Directory.CreateDirectory(directory);
        var temporary = Path.Combine(
            directory,
            $".{Path.GetFileName(path)}.{Guid.NewGuid():N}.tmp"
        );
        try
        {
            File.WriteAllText(temporary, JsonSerializer.Serialize(value, Options));
            File.Move(temporary, path, true);
        }
        finally
        {
            try { File.Delete(temporary); } catch { }
        }
    }
}
