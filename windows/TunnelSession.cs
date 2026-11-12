using System.Diagnostics;
using System.Text.Json;

namespace Sfera.Windows;

internal sealed class TunnelSession : IDisposable
{
    private readonly string directory;
    private readonly Process worker;

    private TunnelSession(string directory, Process worker)
    {
        this.directory = directory;
        this.worker = worker;
    }

    internal bool HasExited => worker.HasExited;

    internal static TunnelSession Start(Profile profile, IReadOnlyList<string> directAddresses)
    {
        var basePath = AppContext.BaseDirectory;
        foreach (var file in new[] { "sfera-net.exe", "wintun.dll", "Connect-Sfera.ps1" })
            if (!File.Exists(Path.Combine(basePath, file)))
                throw new FileNotFoundException($"Не найден {file}. Распакуйте архив SFERA целиком.");

        var directory = Path.Combine(Profile.DataDirectory, "sessions", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try
        {
            File.WriteAllText(Path.Combine(directory, "token"), profile.Token);
            File.WriteAllText(Path.Combine(directory, "connection.json"), JsonSerializer.Serialize(new
            {
                host = profile.Host, peerIP = profile.PeerIP, gateway = profile.Gateway,
                parent = Environment.ProcessId, direct = directAddresses
            }));
            var start = new ProcessStartInfo(Path.Combine(Environment.SystemDirectory,
                "WindowsPowerShell", "v1.0", "powershell.exe"))
            {
                UseShellExecute = false,
                CreateNoWindow = true
            };
            foreach (var argument in new[] {
                "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File",
                Path.Combine(basePath, "Connect-Sfera.ps1"), "-SessionDirectory", directory
            })
                start.ArgumentList.Add(argument);
            return new TunnelSession(directory, Process.Start(start)
                ?? throw new InvalidOperationException("Не удалось запустить VPN."));
        }
        catch
        {
            DeleteDirectory(directory);
            throw;
        }
    }

    internal string Phase => ReadState("phase.json");
    internal string TransportState => ReadState("transport.json");

    private string ReadState(string name)
    {
        try
        {
            using var file = File.Open(Path.Combine(directory, name), FileMode.Open,
                FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            using var reader = new StreamReader(file);
            using var json = JsonDocument.Parse(reader.ReadToEnd());
            return json.RootElement.TryGetProperty("state", out var state) ? state.GetString() ?? "" : "";
        }
        catch (Exception error) when (error is IOException or JsonException) { return ""; }
    }

    internal void Stop() => File.WriteAllText(Path.Combine(directory, "stop"), "");

    public void Dispose()
    {
        worker.Dispose();
        DeleteDirectory(directory);
    }

    private static void DeleteDirectory(string path)
    {
        try { Directory.Delete(path, recursive: true); }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }
}
