namespace UniBridge.Core.Models;

public enum EndpointPlatform
{
    WindowsPC,
    Pendrive,
    AndroidMTP,
    AndroidADB,
    IOSMedia,
    IOSApp
}

public enum SortField
{
    Name,
    Size,
    DateModified,
    Kind
}

public enum TransferMode
{
    Copy,
    Move
}

public enum ConflictPolicy
{
    AskEachTime,
    ReplaceExisting,
    SkipExisting,
    KeepBoth
}

public enum ConflictResolution
{
    Replace,
    Skip,
    KeepBoth,
    CancelAll
}

public enum TransferState
{
    Queued,
    Preparing,
    Transferring,
    Paused,
    Completed,
    CompletedWithSkips,
    Cancelled,
    Failed
}

public sealed record DriveInfoModel
{
    public required string Id { get; init; }
    public required string Name { get; init; }
    public required string RootPath { get; init; }
    public string ConnectionLabel { get; init; } = "USB / OTG";
    public string FileSystemName { get; init; } = "exFAT";
    public long TotalBytes { get; init; }
    public long AvailableBytes { get; init; }
    public bool IsReadOnly { get; init; }
    public bool IsCustomFolder { get; init; }

    public long UsedBytes => Math.Max(0, TotalBytes - AvailableBytes);
    public double UsageFraction => TotalBytes > 0 ? Math.Clamp((double)UsedBytes / TotalBytes, 0.0, 1.0) : 0.0;
    public bool IsFAT32 => FileSystemName.Contains("FAT32", StringComparison.OrdinalIgnoreCase);
}

public sealed record RemoteLocation
{
    public required EndpointPlatform Platform { get; init; }
    public required string DeviceId { get; init; }
    public required string Path { get; init; }
    public string? AppBundleId { get; init; }

    public bool IsLocal => Platform is EndpointPlatform.WindowsPC or EndpointPlatform.Pendrive;

    public static RemoteLocation Local(EndpointPlatform platform, string fullPath) =>
        new() { Platform = platform, DeviceId = "local", Path = fullPath };
}

public sealed record StorageEndpoint
{
    public required string Id { get; init; }
    public required EndpointPlatform Platform { get; init; }
    public required string Name { get; init; }
    public required string Subtitle { get; init; }
    public required string DetailBadge { get; init; }
    public long TotalBytes { get; init; }
    public long AvailableBytes { get; init; }
    public bool IsReadOnly { get; init; }
    public bool RequiresAttention { get; init; }
    public string? StatusMessage { get; init; }
    public required RemoteLocation RootLocation { get; init; }
    public DriveInfoModel? Drive { get; init; }

    public long UsedBytes => Math.Max(0, TotalBytes - AvailableBytes);
    public double UsageFraction => TotalBytes > 0 ? Math.Clamp((double)UsedBytes / TotalBytes, 0.0, 1.0) : 0.0;

    public static StorageEndpoint WindowsHome()
    {
        var userRoot = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var driveRoot = Path.GetPathRoot(userRoot) ?? @"C:\";
        long total = 0, avail = 0;
        try
        {
            var di = new DriveInfo(driveRoot);
            if (di.IsReady)
            {
                total = di.TotalSize;
                avail = di.AvailableFreeSpace;
            }
        }
        catch
        {
            // Ignore restricted drive query errors
        }

        return new StorageEndpoint
        {
            Id = "win::local",
            Platform = EndpointPlatform.WindowsPC,
            Name = "This PC",
            Subtitle = Environment.MachineName,
            DetailBadge = "Windows",
            TotalBytes = total,
            AvailableBytes = avail,
            RootLocation = RemoteLocation.Local(EndpointPlatform.WindowsPC, userRoot)
        };
    }

    public static StorageEndpoint FromDrive(DriveInfoModel drive) =>
        new()
        {
            Id = $"drive::{drive.Id}",
            Platform = EndpointPlatform.Pendrive,
            Name = drive.Name,
            Subtitle = $"{drive.ConnectionLabel} • {drive.FileSystemName}",
            DetailBadge = drive.IsReadOnly ? $"{drive.FileSystemName} (Read-Only)" : drive.FileSystemName,
            TotalBytes = drive.TotalBytes,
            AvailableBytes = drive.AvailableBytes,
            IsReadOnly = drive.IsReadOnly,
            StatusMessage = drive.IsFAT32 ? "FAT32: 4 GB max per file" : null,
            RootLocation = RemoteLocation.Local(EndpointPlatform.Pendrive, drive.RootPath),
            Drive = drive
        };
}

public sealed record BrowserEntry
{
    public required string Id { get; init; }
    public required string Name { get; init; }
    public required bool IsDirectory { get; init; }
    public required long Size { get; init; }
    public required DateTime ModifiedDate { get; init; }
    public bool IsHidden { get; init; }
    public required RemoteLocation Location { get; init; }

    public string FileExtension => Path.GetExtension(Name).TrimStart('.').ToLowerInvariant();

    public string KindDescription =>
        IsDirectory ? "Folder"
        : string.IsNullOrEmpty(FileExtension) ? "File"
        : $"{FileExtension.ToUpperInvariant()} File";
}

public sealed record ConflictPrompt
{
    public required string SourceName { get; init; }
    public required string DestinationPathDisplay { get; init; }
    public required long SourceSize { get; init; }
    public required long DestinationSize { get; init; }
    public DateTime? SourceDate { get; init; }
    public DateTime? DestinationDate { get; init; }
}

public sealed record ConflictDecision(ConflictResolution Resolution, bool ApplyToAll);

public sealed record TransferProgressSnapshot
{
    public required long TotalBytes { get; init; }
    public required long BytesTransferred { get; init; }
    public required int TotalFiles { get; init; }
    public required int FilesCompleted { get; init; }
    public required int FilesSkipped { get; init; }
    public required string CurrentFileName { get; init; }
    public required double SpeedBytesPerSecond { get; init; }
    public double? EstimatedSecondsRemaining { get; init; }
}

public static class FormattingHelpers
{
    private static readonly string[] Units = ["B", "KB", "MB", "GB", "TB"];

    public static string FormatByteCount(long bytes)
    {
        if (bytes < 0) bytes = 0;
        double value = bytes;
        int unitIndex = 0;
        while (value >= 1024.0 && unitIndex < Units.Length - 1)
        {
            value /= 1024.0;
            unitIndex++;
        }
        return unitIndex == 0 ? $"{bytes} B" : $"{value:0.##} {Units[unitIndex]}";
    }

    public static string FormatSpeed(double bytesPerSecond)
    {
        if (bytesPerSecond <= 0 || double.IsNaN(bytesPerSecond) || double.IsInfinity(bytesPerSecond))
        {
            return "--";
        }
        return $"{FormatByteCount((long)bytesPerSecond)}/s";
    }

    public static string FormatDuration(double? seconds)
    {
        if (seconds is null || double.IsNaN(seconds.Value) || double.IsInfinity(seconds.Value) || seconds.Value < 0)
        {
            return "--";
        }
        var total = (int)Math.Round(seconds.Value);
        var h = total / 3600;
        var m = (total % 3600) / 60;
        var s = total % 60;
        return h > 0 ? $"{h}:{m:D2}:{s:D2}" : $"{m}:{s:D2}";
    }

    public static List<BrowserEntry> SortEntries(IEnumerable<BrowserEntry> items, SortField field, bool ascending)
    {
        var list = items.ToList();
        list.Sort((a, b) =>
        {
            if ((field == SortField.Name || field == SortField.Kind) && a.IsDirectory != b.IsDirectory)
            {
                return a.IsDirectory ? -1 : 1;
            }

            int cmp = field switch
            {
                SortField.Name => StringComparer.CurrentCultureIgnoreCase.Compare(a.Name, b.Name),
                SortField.Size => a.Size != b.Size
                    ? a.Size.CompareTo(b.Size)
                    : StringComparer.CurrentCultureIgnoreCase.Compare(a.Name, b.Name),
                SortField.DateModified => a.ModifiedDate != b.ModifiedDate
                    ? a.ModifiedDate.CompareTo(b.ModifiedDate)
                    : StringComparer.CurrentCultureIgnoreCase.Compare(a.Name, b.Name),
                SortField.Kind => StringComparer.CurrentCultureIgnoreCase.Compare(a.KindDescription, b.KindDescription) is int k && k != 0
                    ? k
                    : StringComparer.CurrentCultureIgnoreCase.Compare(a.Name, b.Name),
                _ => 0
            };
            return ascending ? cmp : -cmp;
        });
        return list;
    }
}
