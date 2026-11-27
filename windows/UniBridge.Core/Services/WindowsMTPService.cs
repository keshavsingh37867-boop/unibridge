using MediaDevices;
using UniBridge.Core.Models;

namespace UniBridge.Core.Services;

/// <summary>
/// Manages Android MTP devices (and iOS WPD photo storage fallback) via Windows Portable Devices (WPD).
/// </summary>
public sealed class WindowsMTPService
{
    private readonly SemaphoreSlim _lock = new(1, 1);

    public async Task<List<StorageEndpoint>> DiscoverEndpointsAsync(CancellationToken ct = default)
    {
        await _lock.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            return await Task.Run(() => DiscoverSync(), ct).ConfigureAwait(false);
        }
        finally
        {
            _lock.Release();
        }
    }

    private static List<StorageEndpoint> DiscoverSync()
    {
        var results = new List<StorageEndpoint>();
        IEnumerable<MediaDevice> devices;
        try
        {
            devices = MediaDeviceManager.Instance.GetDevices();
        }
        catch
        {
            return results;
        }

        foreach (var device in devices)
        {
            using (device)
            {
                var deviceId = device.DeviceId ?? Guid.NewGuid().ToString("N");
                var friendly = !string.IsNullOrWhiteSpace(device.FriendlyName)
                    ? device.FriendlyName
                    : (!string.IsNullOrWhiteSpace(device.Model) ? device.Model : device.Description ?? "Portable Device");

                bool isApple = (device.Manufacturer ?? string.Empty).Contains("Apple", StringComparison.OrdinalIgnoreCase)
                               || friendly.Contains("iPhone", StringComparison.OrdinalIgnoreCase)
                               || friendly.Contains("iPad", StringComparison.OrdinalIgnoreCase);

                try
                {
                    device.Connect();
                    var drives = device.GetDrives().ToArray();

                    if (drives.Length == 0)
                    {
                        results.Add(new StorageEndpoint
                        {
                            Id = $"wpd::{deviceId}::locked",
                            Platform = isApple ? EndpointPlatform.IOSMedia : EndpointPlatform.AndroidMTP,
                            Name = friendly,
                            Subtitle = isApple ? "iOS USB (Locked)" : "Android MTP (Locked)",
                            DetailBadge = "Action Needed",
                            IsReadOnly = true,
                            RequiresAttention = true,
                            StatusMessage = isApple
                                ? "Unlock your iPhone/iPad and tap 'Trust This Computer'."
                                : "Unlock your Android phone and switch USB mode to 'File Transfer (MTP)'.",
                            RootLocation = new RemoteLocation
                            {
                                Platform = isApple ? EndpointPlatform.IOSMedia : EndpointPlatform.AndroidMTP,
                                DeviceId = deviceId,
                                Path = @"\"
                            }
                        });
                    }
                    else
                    {
                        foreach (var drive in drives)
                        {
                            var rootPath = drive.RootDirectory?.FullName ?? @"\";
                            var storageName = string.IsNullOrWhiteSpace(drive.Name)
                                ? Path.GetFileName(rootPath.TrimEnd('\\'))
                                : drive.Name;
                            if (string.IsNullOrWhiteSpace(storageName)) storageName = "Internal Storage";

                            var displayName = drives.Length > 1 ? $"{friendly} — {storageName}" : friendly;
                            long total = drive.TotalSize > 0 ? (long)Math.Min(long.MaxValue, drive.TotalSize) : 0;
                            long free = drive.AvailableFreeSpace > 0 ? (long)Math.Min(long.MaxValue, drive.AvailableFreeSpace) : 0;

                            results.Add(new StorageEndpoint
                            {
                                Id = $"wpd::{deviceId}::{rootPath}",
                                Platform = isApple ? EndpointPlatform.IOSMedia : EndpointPlatform.AndroidMTP,
                                Name = isApple ? $"{friendly} (Photos / DCIM)" : displayName,
                                Subtitle = isApple ? "Windows WPD • Read-Only DCIM" : $"{storageName} • Android MTP (WPD)",
                                DetailBadge = isApple ? "iOS Photos" : "MTP USB",
                                TotalBytes = total,
                                AvailableBytes = free,
                                IsReadOnly = isApple,
                                RequiresAttention = false,
                                StatusMessage = isApple ? "Copy photos/videos from iPhone DCIM (install Apple Devices/iTunes for full AFC & App Documents)." : null,
                                RootLocation = new RemoteLocation
                                {
                                    Platform = isApple ? EndpointPlatform.IOSMedia : EndpointPlatform.AndroidMTP,
                                    DeviceId = deviceId,
                                    Path = rootPath
                                }
                            });
                        }
                    }

                    device.Disconnect();
                }
                catch (Exception ex)
                {
                    results.Add(new StorageEndpoint
                    {
                        Id = $"wpd::{deviceId}::err",
                        Platform = isApple ? EndpointPlatform.IOSMedia : EndpointPlatform.AndroidMTP,
                        Name = friendly,
                        Subtitle = "Portable Device (Busy or Locked)",
                        DetailBadge = "Action Needed",
                        IsReadOnly = true,
                        RequiresAttention = true,
                        StatusMessage = $"Could not open MTP session: {ex.Message}",
                        RootLocation = new RemoteLocation
                        {
                            Platform = isApple ? EndpointPlatform.IOSMedia : EndpointPlatform.AndroidMTP,
                            DeviceId = deviceId,
                            Path = @"\"
                        }
                    });
                }
            }
        }

        return results;
    }

    public async Task<List<BrowserEntry>> ListDirectoryAsync(
        string deviceId,
        EndpointPlatform platform,
        string path,
        bool showHidden,
        SortField sortBy,
        bool ascending,
        CancellationToken ct = default)
    {
        await _lock.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            return await Task.Run(() =>
            {
                using var device = ConnectDevice(deviceId);
                var dir = device.GetDirectoryInfo(path);
                var entries = new List<BrowserEntry>();

                foreach (var sub in dir.EnumerateDirectories())
                {
                    bool hidden = sub.Name.StartsWith('.');
                    if (!showHidden && hidden) continue;

                    entries.Add(new BrowserEntry
                    {
                        Id = $"wpd::{deviceId}::{sub.FullName}",
                        Name = sub.Name,
                        IsDirectory = true,
                        Size = 0,
                        ModifiedDate = sub.LastWriteTime ?? sub.CreationTime ?? DateTime.MinValue,
                        IsHidden = hidden,
                        Location = new RemoteLocation { Platform = platform, DeviceId = deviceId, Path = sub.FullName }
                    });
                }

                foreach (var file in dir.EnumerateFiles())
                {
                    bool hidden = file.Name.StartsWith('.');
                    if (!showHidden && hidden) continue;

                    entries.Add(new BrowserEntry
                    {
                        Id = $"wpd::{deviceId}::{file.FullName}",
                        Name = file.Name,
                        IsDirectory = false,
                        Size = (long)Math.Min(long.MaxValue, file.Length),
                        ModifiedDate = file.LastWriteTime ?? file.CreationTime ?? DateTime.MinValue,
                        IsHidden = hidden,
                        Location = new RemoteLocation { Platform = platform, DeviceId = deviceId, Path = file.FullName }
                    });
                }

                device.Disconnect();
                return FormattingHelpers.SortEntries(entries, sortBy, ascending);
            }, ct).ConfigureAwait(false);
        }
        finally
        {
            _lock.Release();
        }
    }

    public async Task CreateDirectoryAsync(string deviceId, string remotePath, CancellationToken ct = default)
    {
        await _lock.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            await Task.Run(() =>
            {
                using var device = ConnectDevice(deviceId);
                if (!device.DirectoryExists(remotePath))
                {
                    device.CreateDirectory(remotePath);
                }
                device.Disconnect();
            }, ct).ConfigureAwait(false);
        }
        finally
        {
            _lock.Release();
        }
    }

    public async Task RenameAsync(string deviceId, string remotePath, string newName, CancellationToken ct = default)
    {
        await _lock.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            await Task.Run(() =>
            {
                using var device = ConnectDevice(deviceId);
                device.Rename(remotePath, newName);
                device.Disconnect();
            }, ct).ConfigureAwait(false);
        }
        finally
        {
            _lock.Release();
        }
    }

    public async Task DeleteAsync(string deviceId, string remotePath, bool isDirectory, CancellationToken ct = default)
    {
        await _lock.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            await Task.Run(() =>
            {
                using var device = ConnectDevice(deviceId);
                if (isDirectory)
                {
                    device.DeleteDirectory(remotePath, true);
                }
                else
                {
                    device.DeleteFile(remotePath);
                }
                device.Disconnect();
            }, ct).ConfigureAwait(false);
        }
        finally
        {
            _lock.Release();
        }
    }

    public async Task DownloadFileAsync(
        string deviceId,
        string remotePath,
        string localPath,
        long expectedSize,
        TransferControl control,
        Action<long> onProgress)
    {
        await _lock.WaitAsync(control.Token).ConfigureAwait(false);
        try
        {
            await Task.Run(() =>
            {
                using var device = ConnectDevice(deviceId);
                using var fs = new FileStream(localPath, FileMode.Create, FileAccess.Write, FileShare.None);
                using var progressStream = new ProgressReportingStream(fs, expectedSize, control, onProgress);
                device.DownloadFile(remotePath, progressStream);
                device.Disconnect();
            }, control.Token).ConfigureAwait(false);
        }
        finally
        {
            _lock.Release();
        }
    }

    public async Task UploadFileAsync(
        string deviceId,
        string localPath,
        string remotePath,
        long fileSize,
        TransferControl control,
        Action<long> onProgress)
    {
        await _lock.WaitAsync(control.Token).ConfigureAwait(false);
        try
        {
            await Task.Run(() =>
            {
                using var device = ConnectDevice(deviceId);
                if (device.FileExists(remotePath))
                {
                    device.DeleteFile(remotePath);
                }
                using var fs = new FileStream(localPath, FileMode.Open, FileAccess.Read, FileShare.Read);
                using var progressStream = new ProgressReportingStream(fs, fileSize, control, onProgress);
                device.UploadFile(progressStream, remotePath);
                device.Disconnect();
            }, control.Token).ConfigureAwait(false);
        }
        finally
        {
            _lock.Release();
        }
    }

    private static MediaDevice ConnectDevice(string deviceId)
    {
        var dev = MediaDeviceManager.Instance.GetDevices().FirstOrDefault(d => string.Equals(d.DeviceId, deviceId, StringComparison.OrdinalIgnoreCase))
                  ?? throw new IOException("MTP device disconnected or is no longer available.");
        dev.Connect();
        return dev;
    }

    private sealed class ProgressReportingStream(
        Stream inner,
        long totalBytes,
        TransferControl control,
        Action<long> onProgress) : Stream
    {
        private long _transferred;

        public override bool CanRead => inner.CanRead;
        public override bool CanSeek => inner.CanSeek;
        public override bool CanWrite => inner.CanWrite;
        public override long Length => inner.Length;
        public override long Position
        {
            get => inner.Position;
            set => inner.Position = value;
        }

        public override void Flush() => inner.Flush();

        public override int Read(byte[] buffer, int offset, int count)
        {
            control.WaitIfPausedAsync().GetAwaiter().GetResult();
            int n = inner.Read(buffer, offset, count);
            if (n > 0)
            {
                _transferred += n;
                onProgress(_transferred);
            }
            return n;
        }

        public override long Seek(long offset, SeekOrigin origin) => inner.Seek(offset, origin);
        public override void SetLength(long value) => inner.SetLength(value);

        public override void Write(byte[] buffer, int offset, int count)
        {
            control.WaitIfPausedAsync().GetAwaiter().GetResult();
            inner.Write(buffer, offset, count);
            _transferred += count;
            onProgress(totalBytes > 0 ? Math.Min(totalBytes, _transferred) : _transferred);
        }
    }
}
