using System.Diagnostics;
using UniBridge.Core.Models;

namespace UniBridge.Core.Services;

public sealed class UnifiedTransferService
{
    private readonly LocalTransferEngine _localEngine = new();
    private readonly WindowsMTPService _mtpService;
    private readonly AndroidADBService _adbService;
    private readonly WindowsIOSService _iosService;

    public UnifiedTransferService(
        WindowsMTPService mtpService,
        AndroidADBService adbService,
        WindowsIOSService iosService)
    {
        _mtpService = mtpService;
        _adbService = adbService;
        _iosService = iosService;
    }

    public Task<List<BrowserEntry>> ListEntriesAsync(
        RemoteLocation location,
        bool showHidden,
        SortField sortBy,
        bool ascending,
        CancellationToken ct = default)
    {
        return location.Platform switch
        {
            EndpointPlatform.WindowsPC or EndpointPlatform.Pendrive =>
                Task.FromResult(FileBrowserService.ListContents(location.Path, location.Platform, showHidden, sortBy, ascending)),
            EndpointPlatform.AndroidMTP or EndpointPlatform.IOSMedia when location.DeviceId is not "local" && location.AppBundleId is null && location.Path.StartsWith('\\') =>
                _mtpService.ListDirectoryAsync(location.DeviceId, location.Platform, location.Path, showHidden, sortBy, ascending, ct),
            EndpointPlatform.AndroidADB =>
                _adbService.ListDirectoryAsync(location.DeviceId, location.Path, showHidden, sortBy, ascending, ct),
            EndpointPlatform.IOSMedia or EndpointPlatform.IOSApp =>
                _iosService.ListDirectoryAsync(location.DeviceId, location.AppBundleId, location.Path, showHidden, sortBy, ascending, ct),
            _ => Task.FromResult(new List<BrowserEntry>())
        };
    }

    public async Task CreateFolderAsync(RemoteLocation parent, string name, CancellationToken ct = default)
    {
        var trimmed = name.Trim();
        if (!FileBrowserService.IsValidFileName(trimmed))
        {
            throw new ArgumentException("Folder name cannot be empty or contain invalid characters.");
        }

        switch (parent.Platform)
        {
            case EndpointPlatform.WindowsPC:
            case EndpointPlatform.Pendrive:
                FileBrowserService.CreateFolder(parent.Path, trimmed);
                break;
            case EndpointPlatform.AndroidMTP:
                await _mtpService.CreateDirectoryAsync(parent.DeviceId, JoinWindowsMtpPath(parent.Path, trimmed), ct).ConfigureAwait(false);
                break;
            case EndpointPlatform.AndroidADB:
                await _adbService.CreateDirectoryAsync(parent.DeviceId, JoinUnixPath(parent.Path, trimmed), ct).ConfigureAwait(false);
                break;
            case EndpointPlatform.IOSMedia:
            case EndpointPlatform.IOSApp:
                if (parent.Path.StartsWith('\\'))
                    await _mtpService.CreateDirectoryAsync(parent.DeviceId, JoinWindowsMtpPath(parent.Path, trimmed), ct).ConfigureAwait(false);
                else
                    await _iosService.CreateDirectoryAsync(parent.DeviceId, parent.AppBundleId, JoinUnixPath(parent.Path, trimmed), ct).ConfigureAwait(false);
                break;
        }
    }

    public async Task RenameAsync(BrowserEntry entry, RemoteLocation parent, string newName, CancellationToken ct = default)
    {
        var trimmed = newName.Trim();
        if (!FileBrowserService.IsValidFileName(trimmed))
        {
            throw new ArgumentException("Name cannot be empty or contain invalid characters.");
        }

        switch (parent.Platform)
        {
            case EndpointPlatform.WindowsPC:
            case EndpointPlatform.Pendrive:
                FileBrowserService.RenameItem(entry.Location.Path, trimmed);
                break;
            case EndpointPlatform.AndroidMTP:
                await _mtpService.RenameAsync(parent.DeviceId, entry.Location.Path, trimmed, ct).ConfigureAwait(false);
                break;
            case EndpointPlatform.AndroidADB:
                await _adbService.RenameAsync(parent.DeviceId, entry.Location.Path, JoinUnixPath(parent.Path, trimmed), ct).ConfigureAwait(false);
                break;
            case EndpointPlatform.IOSMedia:
            case EndpointPlatform.IOSApp:
                if (entry.Location.Path.StartsWith('\\'))
                    await _mtpService.RenameAsync(parent.DeviceId, entry.Location.Path, trimmed, ct).ConfigureAwait(false);
                else
                    await _iosService.RenameAsync(parent.DeviceId, parent.AppBundleId, entry.Location.Path, JoinUnixPath(parent.Path, trimmed), ct).ConfigureAwait(false);
                break;
        }
    }

    public async Task DeleteAsync(IReadOnlyList<BrowserEntry> entries, RemoteLocation parent, bool permanentIfNeeded, CancellationToken ct = default)
    {
        foreach (var entry in entries)
        {
            switch (parent.Platform)
            {
                case EndpointPlatform.WindowsPC:
                case EndpointPlatform.Pendrive:
                    FileBrowserService.RemoveItem(entry.Location.Path, permanentIfNeeded);
                    break;
                case EndpointPlatform.AndroidMTP:
                    await _mtpService.DeleteAsync(parent.DeviceId, entry.Location.Path, entry.IsDirectory, ct).ConfigureAwait(false);
                    break;
                case EndpointPlatform.AndroidADB:
                    await _adbService.DeleteAsync(parent.DeviceId, entry.Location.Path, ct).ConfigureAwait(false);
                    break;
                case EndpointPlatform.IOSMedia:
                case EndpointPlatform.IOSApp:
                    if (entry.Location.Path.StartsWith('\\'))
                        await _mtpService.DeleteAsync(parent.DeviceId, entry.Location.Path, entry.IsDirectory, ct).ConfigureAwait(false);
                    else
                        await _iosService.DeleteAsync(parent.DeviceId, parent.AppBundleId, entry.Location.Path, ct).ConfigureAwait(false);
                    break;
            }
        }
    }

    public async Task<(int filesCompleted, int filesSkipped)> ExecuteAsync(
        IReadOnlyList<BrowserEntry> entries,
        StorageEndpoint sourceEndpoint,
        RemoteLocation sourceParent,
        StorageEndpoint destinationEndpoint,
        RemoteLocation destinationDirectory,
        TransferMode mode,
        ConflictPolicy conflictPolicy,
        TransferControl control,
        Func<TransferProgressSnapshot, Task> onProgress,
        Func<ConflictPrompt, Task<ConflictDecision>> onConflict)
    {
        if (entries.Count == 0) throw new TransferException("No items selected.");
        if (destinationEndpoint.isReadOnlyFlag()) throw new TransferException($"'{destinationEndpoint.Name}' is read-only.");
        if (mode == TransferMode.Move && sourceEndpoint.IsReadOnly)
        {
            throw new TransferException($"'{sourceEndpoint.Name}' is read-only; cannot move items. Use Copy instead.");
        }

        if (destinationDirectory.IsLocal && entries.All(e => e.Location.IsLocal))
        {
            var localPaths = entries.Select(e => e.Location.Path).ToList();
            return await _localEngine.ExecuteAsync(
                localPaths,
                destinationDirectory.Path,
                mode,
                conflictPolicy,
                destinationEndpoint.Drive?.FileSystemName,
                control,
                onProgress,
                onConflict).ConfigureAwait(false);
        }

        var plan = await ExpandPlanAsync(entries, control.Token).ConfigureAwait(false);
        long totalBytes = plan.Files.Sum(f => f.Size);
        if (destinationEndpoint.AvailableBytes > 0 && totalBytes > destinationEndpoint.AvailableBytes)
        {
            throw new TransferException($"Insufficient free space on '{destinationEndpoint.Name}'.");
        }

        var policy = conflictPolicy;
        long bytesCompletedBeforeFile = 0;
        int filesCompleted = 0;
        int filesSkipped = 0;
        double emaSpeed = 0;
        var sampleWatch = Stopwatch.StartNew();
        long lastSampleBytes = 0;
        var movedSources = new List<PlannedItem>();
        var skippedRoots = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        await onProgress(MakeSnapshot(totalBytes, 0, plan.Files.Count, 0, 0, plan.Files.FirstOrDefault()?.Name ?? "", 0)).ConfigureAwait(false);

        var dirCache = new Dictionary<string, RemoteLocation>(StringComparer.OrdinalIgnoreCase) { [""] = destinationDirectory };
        foreach (var dir in plan.Directories)
        {
            await control.WaitIfPausedAsync().ConfigureAwait(false);
            await EnsureRemoteDirectoryAsync(dir.RelativeComponents, destinationDirectory, dirCache, control.Token).ConfigureAwait(false);
        }

        var stagingRoot = Path.Combine(Path.GetTempPath(), $"UniBridgeStage-{Guid.NewGuid():N}");
        Directory.CreateDirectory(stagingRoot);
        try
        {
            foreach (var file in plan.Files)
            {
                await control.WaitIfPausedAsync().ConfigureAwait(false);

                var destFolder = await EnsureRemoteDirectoryAsync(file.ParentComponents, destinationDirectory, dirCache, control.Token).ConfigureAwait(false);
                var targetName = file.Name;

                var existing = await FindExistingAsync(destFolder, targetName, control.Token).ConfigureAwait(false);
                if (existing is not null)
                {
                    ConflictResolution resolution;
                    if (policy == ConflictPolicy.AskEachTime)
                    {
                        var decision = await onConflict(new ConflictPrompt
                        {
                            SourceName = file.Name,
                            DestinationPathDisplay = $"{destinationEndpoint.Name}: {destFolder.Path}/{targetName}",
                            SourceSize = file.Size,
                            DestinationSize = existing.Size,
                            SourceDate = file.ModifiedDate,
                            DestinationDate = existing.ModifiedDate
                        }).ConfigureAwait(false);

                        resolution = decision.Resolution;
                        if (decision.ApplyToAll)
                        {
                            policy = resolution switch
                            {
                                ConflictResolution.Replace => ConflictPolicy.ReplaceExisting,
                                ConflictResolution.Skip => ConflictPolicy.SkipExisting,
                                ConflictResolution.KeepBoth => ConflictPolicy.KeepBoth,
                                _ => policy
                            };
                        }
                    }
                    else
                    {
                        resolution = policy switch
                        {
                            ConflictPolicy.ReplaceExisting => ConflictResolution.Replace,
                            ConflictPolicy.SkipExisting => ConflictResolution.Skip,
                            ConflictPolicy.KeepBoth => ConflictResolution.KeepBoth,
                            _ => ConflictResolution.Skip
                        };
                    }

                    switch (resolution)
                    {
                        case ConflictResolution.CancelAll:
                            control.Cancel();
                            throw new OperationCanceledException();
                        case ConflictResolution.Skip:
                            filesSkipped++;
                            bytesCompletedBeforeFile += file.Size;
                            skippedRoots.Add(file.RootEntryId);
                            await onProgress(MakeSnapshot(totalBytes, bytesCompletedBeforeFile, plan.Files.Count, filesCompleted, filesSkipped, file.Name, emaSpeed)).ConfigureAwait(false);
                            continue;
                        case ConflictResolution.KeepBoth:
                            targetName = await UniqueTargetNameAsync(destFolder, targetName, control.Token).ConfigureAwait(false);
                            break;
                        case ConflictResolution.Replace:
                            if (!destFolder.IsLocal)
                            {
                                await DeleteAsync([existing], destFolder, true, control.Token).ConfigureAwait(false);
                            }
                            break;
                    }
                }

                long fileStart = bytesCompletedBeforeFile;
                void ReportProgress(long fileBytes)
                {
                    long totalNow = Math.Min(totalBytes, fileStart + fileBytes);
                    double dt = sampleWatch.Elapsed.TotalSeconds;
                    if (dt >= 0.15)
                    {
                        var delta = Math.Max(0, totalNow - lastSampleBytes);
                        var instant = delta / dt;
                        emaSpeed = emaSpeed == 0 ? instant : (0.3 * instant + 0.7 * emaSpeed);
                        lastSampleBytes = totalNow;
                        sampleWatch.Restart();
                        _ = onProgress(MakeSnapshot(totalBytes, totalNow, plan.Files.Count, filesCompleted, filesSkipped, file.Name, emaSpeed));
                    }
                }

                await TransferSingleAsync(file, targetName, destFolder, stagingRoot, control, ReportProgress).ConfigureAwait(false);
                bytesCompletedBeforeFile += file.Size;
                filesCompleted++;
                movedSources.Add(file);

                await onProgress(MakeSnapshot(totalBytes, bytesCompletedBeforeFile, plan.Files.Count, filesCompleted, filesSkipped, file.Name, emaSpeed)).ConfigureAwait(false);
            }

            if (mode == TransferMode.Move)
            {
                foreach (var item in movedSources)
                {
                    await DeleteAsync([item.OriginalEntry], sourceParent, true, control.Token).ConfigureAwait(false);
                }
                foreach (var root in entries.Where(e => e.IsDirectory && !skippedRoots.Contains(e.Id)))
                {
                    try { await DeleteAsync([root], sourceParent, true, control.Token).ConfigureAwait(false); } catch { }
                }
            }

            return (filesCompleted, filesSkipped);
        }
        finally
        {
            try { Directory.Delete(stagingRoot, recursive: true); } catch { }
        }
    }

    private sealed record PlannedDir(string[] RelativeComponents);
    private sealed record PlannedItem(string RootEntryId, string Name, long Size, DateTime ModifiedDate, string[] ParentComponents, BrowserEntry OriginalEntry);

    private async Task<(List<PlannedDir> Directories, List<PlannedItem> Files)> ExpandPlanAsync(IReadOnlyList<BrowserEntry> entries, CancellationToken ct)
    {
        var dirs = new List<PlannedDir>();
        var files = new List<PlannedItem>();

        async Task WalkAsync(BrowserEntry entry, string[] parentComps, string rootId)
        {
            ct.ThrowIfCancellationRequested();
            if (!entry.IsDirectory)
            {
                files.Add(new PlannedItem(rootId, entry.Name, entry.Size, entry.ModifiedDate, parentComps, entry));
                return;
            }

            var curComps = parentComps.Append(entry.Name).ToArray();
            dirs.Add(new PlannedDir(curComps));
            var children = await ListEntriesAsync(entry.Location, true, SortField.Name, true, ct).ConfigureAwait(false);
            foreach (var child in children)
            {
                await WalkAsync(child, curComps, rootId).ConfigureAwait(false);
            }
        }

        foreach (var e in entries)
        {
            await WalkAsync(e, [], e.Id).ConfigureAwait(false);
        }
        return (dirs, files);
    }

    private async Task<RemoteLocation> EnsureRemoteDirectoryAsync(
        string[] relativeComponents,
        RemoteLocation root,
        Dictionary<string, RemoteLocation> cache,
        CancellationToken ct)
    {
        if (relativeComponents.Length == 0) return root;
        var key = string.Join('/', relativeComponents);
        if (cache.TryGetValue(key, out var hit)) return hit;

        var parent = await EnsureRemoteDirectoryAsync(relativeComponents[..^1], root, cache, ct).ConfigureAwait(false);
        var folderName = relativeComponents[^1];
        var next = AppendPath(parent, folderName);

        if (parent.IsLocal)
        {
            Directory.CreateDirectory(next.Path);
        }
        else
        {
            var existing = await ListEntriesAsync(parent, true, SortField.Name, true, ct).ConfigureAwait(false);
            if (!existing.Any(x => string.Equals(x.Name, folderName, StringComparison.OrdinalIgnoreCase)))
            {
                await CreateFolderAsync(parent, folderName, ct).ConfigureAwait(false);
            }
        }

        cache[key] = next;
        return next;
    }

    private async Task<BrowserEntry?> FindExistingAsync(RemoteLocation folder, string name, CancellationToken ct)
    {
        if (folder.IsLocal)
        {
            var path = Path.Combine(folder.Path, name);
            if (!File.Exists(path)) return null;
            var fi = new FileInfo(path);
            return new BrowserEntry
            {
                Id = path,
                Name = name,
                IsDirectory = false,
                Size = fi.Length,
                ModifiedDate = fi.LastWriteTime,
                Location = RemoteLocation.Local(folder.Platform, path)
            };
        }

        var items = await ListEntriesAsync(folder, true, SortField.Name, true, ct).ConfigureAwait(false);
        return items.FirstOrDefault(i => string.Equals(i.Name, name, StringComparison.OrdinalIgnoreCase));
    }

    private async Task<string> UniqueTargetNameAsync(RemoteLocation folder, string preferred, CancellationToken ct)
    {
        var items = await ListEntriesAsync(folder, true, SortField.Name, true, ct).ConfigureAwait(false);
        var existing = new HashSet<string>(items.Select(i => i.Name), StringComparer.OrdinalIgnoreCase);
        if (!existing.Contains(preferred)) return preferred;

        var ext = Path.GetExtension(preferred);
        var stem = string.IsNullOrEmpty(ext) ? preferred : Path.GetFileNameWithoutExtension(preferred);
        int i = 2;
        while (true)
        {
            var candidate = string.IsNullOrEmpty(ext) ? $"{stem} ({i})" : $"{stem} ({i}){ext}";
            if (!existing.Contains(candidate)) return candidate;
            i++;
        }
    }

    private async Task TransferSingleAsync(
        PlannedItem file,
        string targetName,
        RemoteLocation destFolder,
        string stagingRoot,
        TransferControl control,
        Action<long> onProgress)
    {
        string localSourcePath;
        string? tempDownload = null;

        if (file.OriginalEntry.Location.IsLocal)
        {
            localSourcePath = file.OriginalEntry.Location.Path;
        }
        else if (destFolder.IsLocal)
        {
            var finalPath = Path.Combine(destFolder.Path, targetName);
            var partPath = Path.Combine(destFolder.Path, $".unibridge.{Guid.NewGuid():N}.part");
            try
            {
                await DownloadRemoteAsync(file.OriginalEntry.Location, partPath, file.Size, control, onProgress).ConfigureAwait(false);
                File.Move(partPath, finalPath, overwrite: true);
            }
            catch
            {
                try { if (File.Exists(partPath)) File.Delete(partPath); } catch { }
                throw;
            }
            return;
        }
        else
        {
            tempDownload = Path.Combine(stagingRoot, $"{Guid.NewGuid():N}-{targetName}");
            await DownloadRemoteAsync(file.OriginalEntry.Location, tempDownload, file.Size, control, b => onProgress(b / 2)).ConfigureAwait(false);
            localSourcePath = tempDownload;
        }

        try
        {
            long uploadSize = new FileInfo(localSourcePath).Length;
            bool isStaged = tempDownload is not null;
            void UploadProgress(long uploaded) => onProgress(isStaged ? (uploadSize / 2 + uploaded / 2) : uploaded);

            var targetLoc = AppendPath(destFolder, targetName);
            switch (destFolder.Platform)
            {
                case EndpointPlatform.AndroidMTP:
                    await _mtpService.UploadFileAsync(destFolder.DeviceId, localSourcePath, targetLoc.Path, uploadSize, control, UploadProgress).ConfigureAwait(false);
                    break;
                case EndpointPlatform.AndroidADB:
                    await _adbService.PushFileAsync(destFolder.DeviceId, localSourcePath, targetLoc.Path, uploadSize, control, UploadProgress).ConfigureAwait(false);
                    break;
                case EndpointPlatform.IOSMedia:
                case EndpointPlatform.IOSApp:
                    if (destFolder.Path.StartsWith('\\'))
                        await _mtpService.UploadFileAsync(destFolder.DeviceId, localSourcePath, targetLoc.Path, uploadSize, control, UploadProgress).ConfigureAwait(false);
                    else
                        await _iosService.UploadFileAsync(destFolder.DeviceId, destFolder.AppBundleId, localSourcePath, targetLoc.Path, uploadSize, control, UploadProgress).ConfigureAwait(false);
                    break;
            }
        }
        finally
        {
            if (tempDownload is not null)
            {
                try { if (File.Exists(tempDownload)) File.Delete(tempDownload); } catch { }
            }
        }
    }

    private Task DownloadRemoteAsync(RemoteLocation source, string localDest, long expectedSize, TransferControl control, Action<long> onProgress)
    {
        return source.Platform switch
        {
            EndpointPlatform.AndroidMTP =>
                _mtpService.DownloadFileAsync(source.DeviceId, source.Path, localDest, expectedSize, control, onProgress),
            EndpointPlatform.AndroidADB =>
                _adbService.PullFileAsync(source.DeviceId, source.Path, localDest, expectedSize, control, onProgress),
            EndpointPlatform.IOSMedia or EndpointPlatform.IOSApp when source.Path.StartsWith('\\') =>
                _mtpService.DownloadFileAsync(source.DeviceId, source.Path, localDest, expectedSize, control, onProgress),
            EndpointPlatform.IOSMedia or EndpointPlatform.IOSApp =>
                _iosService.DownloadFileAsync(source.DeviceId, source.AppBundleId, source.Path, localDest, expectedSize, control, onProgress),
            _ => throw new NotSupportedException($"Unsupported source platform: {source.Platform}")
        };
    }

    private static RemoteLocation AppendPath(RemoteLocation parent, string child)
    {
        if (parent.IsLocal)
        {
            return parent with { Path = Path.Combine(parent.Path, child) };
        }
        if (parent.Path.StartsWith('\\'))
        {
            return parent with { Path = JoinWindowsMtpPath(parent.Path, child) };
        }
        return parent with { Path = JoinUnixPath(parent.Path, child) };
    }

    private static string JoinWindowsMtpPath(string parent, string child) =>
        parent == @"\" ? $@"\{child}" : $@"{parent.TrimEnd('\\')}\{child}";

    private static string JoinUnixPath(string parent, string child) =>
        parent == "/" ? $"/{child}" : $"{parent.TrimEnd('/')}/{child}";

    private static TransferProgressSnapshot MakeSnapshot(
        long totalBytes, long transferred, int totalFiles, int completed, int skipped, string currentFile, double speed)
    {
        var remaining = Math.Max(0, totalBytes - transferred);
        double? eta = remaining > 0 && speed > 1024 ? remaining / speed : null;
        return new TransferProgressSnapshot
        {
            TotalBytes = totalBytes,
            BytesTransferred = transferred,
            TotalFiles = totalFiles,
            FilesCompleted = completed,
            FilesSkipped = skipped,
            CurrentFileName = currentFile,
            SpeedBytesPerSecond = speed,
            EstimatedSecondsRemaining = eta
        };
    }
}

file static class EndpointExtensions
{
    public static bool isReadOnlyFlag(this StorageEndpoint endpoint) => endpoint.IsReadOnly;
}
