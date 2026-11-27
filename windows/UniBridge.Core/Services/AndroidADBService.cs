using System.Diagnostics;
using System.Globalization;
using System.Text;
using UniBridge.Core.Models;

namespace UniBridge.Core.Services;

/// <summary>
/// Manages Android devices connected via ADB (USB Debugging) on Windows.
/// </summary>
public sealed class AndroidADBService
{
    public static string? LocateAdbBinary()
    {
        var baseDir = AppContext.BaseDirectory;
        var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        string[] candidates =
        [
            Path.Combine(baseDir, "Helpers", "adb.exe"),
            Path.Combine(baseDir, "adb.exe"),
            Path.Combine(localAppData, "Android", "Sdk", "platform-tools", "adb.exe"),
            @"C:\platform-tools\adb.exe"
        ];

        foreach (var path in candidates)
        {
            if (File.Exists(path)) return path;
        }

        var pathEnv = Environment.GetEnvironmentVariable("PATH") ?? string.Empty;
        foreach (var dir in pathEnv.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
        {
            var candidate = Path.Combine(dir.Trim(), "adb.exe");
            if (File.Exists(candidate)) return candidate;
        }

        return null;
    }

    public static string ShellQuote(string value) =>
        "'" + value.Replace("'", "'\"'\"'") + "'";

    public async Task<List<StorageEndpoint>> DiscoverEndpointsAsync(CancellationToken ct = default)
    {
        var adb = LocateAdbBinary();
        if (adb is null) return [];

        string output;
        try
        {
            output = await RunAdbAsync(adb, ["devices", "-l"], TimeSpan.FromSeconds(4), ct).ConfigureAwait(false);
        }
        catch
        {
            return [];
        }

        var list = new List<StorageEndpoint>();
        foreach (var raw in output.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries))
        {
            var line = raw.Trim();
            if (line.StartsWith("List of devices", StringComparison.OrdinalIgnoreCase) || line.StartsWith('*'))
            {
                continue;
            }

            var parts = line.Split([' ', '\t'], StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length < 2) continue;

            var serial = parts[0];
            var state = parts[1];
            var model = serial;
            foreach (var tok in parts.Skip(2))
            {
                if (tok.StartsWith("model:", StringComparison.Ordinal))
                {
                    model = tok["model:".Length..].Replace('_', ' ');
                }
            }

            if (state == "device")
            {
                var (total, avail) = await FetchStorageInfoAsync(adb, serial, ct).ConfigureAwait(false);
                list.Add(new StorageEndpoint
                {
                    Id = $"adb::{serial}",
                    Platform = EndpointPlatform.AndroidADB,
                    Name = $"{model} (ADB)",
                    Subtitle = "Android USB Debugging • /sdcard",
                    DetailBadge = "ADB Fast",
                    TotalBytes = total,
                    AvailableBytes = avail,
                    RootLocation = new RemoteLocation
                    {
                        Platform = EndpointPlatform.AndroidADB,
                        DeviceId = serial,
                        Path = "/sdcard"
                    }
                });
            }
            else if (state == "unauthorized")
            {
                list.Add(new StorageEndpoint
                {
                    Id = $"adb::{serial}::unauth",
                    Platform = EndpointPlatform.AndroidADB,
                    Name = $"{model} (ADB)",
                    Subtitle = "Android USB Debugging",
                    DetailBadge = "Authorize on Phone",
                    IsReadOnly = true,
                    RequiresAttention = true,
                    StatusMessage = "Tap 'Allow USB debugging' on your Android phone, then click Rescan.",
                    RootLocation = new RemoteLocation
                    {
                        Platform = EndpointPlatform.AndroidADB,
                        DeviceId = serial,
                        Path = "/sdcard"
                    }
                });
            }
        }

        return list;
    }

    public async Task<List<BrowserEntry>> ListDirectoryAsync(
        string serial,
        string path,
        bool showHidden,
        SortField sortBy,
        bool ascending,
        CancellationToken ct = default)
    {
        var adb = LocateAdbBinary() ?? throw new InvalidOperationException("adb.exe not found.");
        var quoted = ShellQuote(path);
        var script =
            $"DIR={quoted}; " +
            "if [ ! -d \"$DIR\" ]; then echo \"__ERR__Folder not found\"; exit 1; fi; " +
            "for f in \"$DIR\"/* \"$DIR\"/.*; do " +
            "[ -e \"$f\" ] || [ -L \"$f\" ] || continue; " +
            "b=$(basename \"$f\"); [ \"$b\" = \".\" ] || [ \"$b\" = \"..\" ] && continue; " +
            "if [ -d \"$f\" ]; then t=\"D\"; else t=\"F\"; fi; " +
            "s=$(stat -c \"%s|%Y\" \"$f\" 2>/dev/null || echo \"0|0\"); " +
            "printf \"%s|%s|%s\\n\" \"$t\" \"$s\" \"$b\"; done";

        var output = await RunAdbAsync(adb, ["-s", serial, "shell", script], TimeSpan.FromSeconds(15), ct).ConfigureAwait(false);
        return ParseDirectoryListing(serial, path, output, showHidden, sortBy, ascending);
    }

    public static List<BrowserEntry> ParseDirectoryListing(
        string serial,
        string parentPath,
        string output,
        bool showHidden,
        SortField sortBy,
        bool ascending)
    {
        var entries = new List<BrowserEntry>();
        foreach (var raw in output.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries))
        {
            if (raw.StartsWith("__ERR__", StringComparison.Ordinal))
            {
                throw new DirectoryNotFoundException(raw["__ERR__".Length..]);
            }

            var fields = raw.Split('|', 4);
            if (fields.Length < 4) continue;

            bool isDir = fields[0] == "D";
            long.TryParse(fields[1], NumberStyles.Integer, CultureInfo.InvariantCulture, out long size);
            long.TryParse(fields[2], NumberStyles.Integer, CultureInfo.InvariantCulture, out long unixSec);
            var name = fields[3];
            bool hidden = name.StartsWith('.');
            if (!showHidden && hidden) continue;

            var childPath = parentPath == "/" ? $"/{name}" : $"{parentPath.TrimEnd('/')}/{name}";
            entries.Add(new BrowserEntry
            {
                Id = $"adb::{serial}::{childPath}",
                Name = name,
                IsDirectory = isDir,
                Size = isDir ? 0 : size,
                ModifiedDate = unixSec > 0 ? DateTimeOffset.FromUnixTimeSeconds(unixSec).LocalDateTime : DateTime.MinValue,
                IsHidden = hidden,
                Location = new RemoteLocation
                {
                    Platform = EndpointPlatform.AndroidADB,
                    DeviceId = serial,
                    Path = childPath
                }
            });
        }

        return FormattingHelpers.SortEntries(entries, sortBy, ascending);
    }

    public static (long total, long available) ParseDfOutput(string output)
    {
        var lines = output.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries);
        if (lines.Length == 0) return (0, 0);
        var cols = lines[^1].Split([' ', '\t'], StringSplitOptions.RemoveEmptyEntries);
        if (cols.Length >= 4
            && long.TryParse(cols[1], NumberStyles.Integer, CultureInfo.InvariantCulture, out long totalKb)
            && long.TryParse(cols[3], NumberStyles.Integer, CultureInfo.InvariantCulture, out long availKb))
        {
            return (totalKb * 1024L, availKb * 1024L);
        }
        return (0, 0);
    }

    public async Task CreateDirectoryAsync(string serial, string remotePath, CancellationToken ct = default)
    {
        var adb = LocateAdbBinary() ?? throw new InvalidOperationException("adb.exe not found.");
        await RunAdbAsync(adb, ["-s", serial, "shell", $"mkdir -p {ShellQuote(remotePath)}"], TimeSpan.FromSeconds(10), ct).ConfigureAwait(false);
    }

    public async Task RenameAsync(string serial, string fromPath, string toPath, CancellationToken ct = default)
    {
        var adb = LocateAdbBinary() ?? throw new InvalidOperationException("adb.exe not found.");
        await RunAdbAsync(adb, ["-s", serial, "shell", $"mv {ShellQuote(fromPath)} {ShellQuote(toPath)}"], TimeSpan.FromSeconds(10), ct).ConfigureAwait(false);
    }

    public async Task DeleteAsync(string serial, string remotePath, CancellationToken ct = default)
    {
        var adb = LocateAdbBinary() ?? throw new InvalidOperationException("adb.exe not found.");
        await RunAdbAsync(adb, ["-s", serial, "shell", $"rm -rf {ShellQuote(remotePath)}"], TimeSpan.FromSeconds(15), ct).ConfigureAwait(false);
    }

    public async Task PullFileAsync(
        string serial,
        string remotePath,
        string localPath,
        long expectedSize,
        TransferControl control,
        Action<long> onProgress)
    {
        var adb = LocateAdbBinary() ?? throw new InvalidOperationException("adb.exe not found.");
        await RunTransferProcessAsync(adb, ["-s", serial, "pull", remotePath, localPath], control, () =>
        {
            if (File.Exists(localPath))
            {
                long len = new FileInfo(localPath).Length;
                onProgress(expectedSize > 0 ? Math.Min(expectedSize, len) : len);
            }
            return Task.CompletedTask;
        }).ConfigureAwait(false);
        onProgress(expectedSize);
    }

    public async Task PushFileAsync(
        string serial,
        string localPath,
        string remotePath,
        long fileSize,
        TransferControl control,
        Action<long> onProgress)
    {
        var adb = LocateAdbBinary() ?? throw new InvalidOperationException("adb.exe not found.");
        await RunTransferProcessAsync(adb, ["-s", serial, "push", localPath, remotePath], control, () => Task.CompletedTask).ConfigureAwait(false);
        onProgress(fileSize);
    }

    private async Task<(long total, long available)> FetchStorageInfoAsync(string adb, string serial, CancellationToken ct)
    {
        try
        {
            var output = await RunAdbAsync(adb, ["-s", serial, "shell", "df -k /sdcard"], TimeSpan.FromSeconds(4), ct).ConfigureAwait(false);
            return ParseDfOutput(output);
        }
        catch
        {
            return (0, 0);
        }
    }

    private static async Task<string> RunAdbAsync(string adbPath, string[] args, TimeSpan timeout, CancellationToken ct)
    {
        var psi = new ProcessStartInfo
        {
            FileName = adbPath,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8
        };
        foreach (var a in args) psi.ArgumentList.Add(a);

        using var proc = Process.Start(psi) ?? throw new InvalidOperationException("Failed to start adb.exe.");
        using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeoutCts.CancelAfter(timeout);

        var outTask = proc.StandardOutput.ReadToEndAsync(timeoutCts.Token);
        var errTask = proc.StandardError.ReadToEndAsync(timeoutCts.Token);
        try
        {
            await proc.WaitForExitAsync(timeoutCts.Token).ConfigureAwait(false);
        }
        catch
        {
            try { proc.Kill(entireProcessTree: true); } catch { }
            throw;
        }

        var stdout = await outTask.ConfigureAwait(false);
        var stderr = await errTask.ConfigureAwait(false);
        if (proc.ExitCode != 0)
        {
            var msg = string.IsNullOrWhiteSpace(stderr) ? $"adb exited with code {proc.ExitCode}" : stderr.Trim();
            throw new IOException(msg);
        }
        return stdout;
    }

    private static async Task RunTransferProcessAsync(
        string adbPath,
        string[] args,
        TransferControl control,
        Func<Task> pollProgress)
    {
        var psi = new ProcessStartInfo
        {
            FileName = adbPath,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true
        };
        foreach (var a in args) psi.ArgumentList.Add(a);

        using var proc = Process.Start(psi) ?? throw new InvalidOperationException("Failed to start adb.exe.");
        while (!proc.HasExited)
        {
            if (control.IsCancelled)
            {
                try { proc.Kill(entireProcessTree: true); } catch { }
                throw new OperationCanceledException();
            }
            await pollProgress().ConfigureAwait(false);
            await Task.Delay(150, control.Token).ConfigureAwait(false);
        }

        if (proc.ExitCode != 0)
        {
            var err = await proc.StandardError.ReadToEndAsync().ConfigureAwait(false);
            throw new IOException(string.IsNullOrWhiteSpace(err) ? "ADB transfer failed." : err.Trim());
        }
    }
}
