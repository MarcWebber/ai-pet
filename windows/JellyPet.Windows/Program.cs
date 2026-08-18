namespace JellyPet.Windows;

internal static class Program
{
    [STAThread]
    private static void Main(string[] arguments)
    {
        if (arguments.Length == 1
            && arguments[0] == "--sweep-temporary-artifacts")
        {
            TemporaryArtifactSweeper.RemoveAll();
            return;
        }
        ApplicationConfiguration.Initialize();
        using var singleInstance = new Mutex(
            initiallyOwned: true,
            name: @"Local\JellyPet.com.local.JellyPet",
            createdNew: out var isFirstInstance
        );
        if (!isFirstInstance)
        {
            Environment.ExitCode = 2;
            return;
        }
        Application.Run(new JellyApplication());
    }
}
