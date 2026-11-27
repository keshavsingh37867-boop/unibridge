using System.Diagnostics;
using UniBridge.Core.Models;

namespace UniBridge.Core.Services;

public sealed class TransferException : Exception
{
    public TransferException(string message) : base(message) { }
}

public sealed class LocalTransferEngine
{
    private const long Fat32MaxFileBytes = 4_294_967_295;
    private readonly int _chunkSize;
    private readonly bool _allowSameVolumeMoveShortcut;
    private readonly int _progressIntervalMs;

    public LocalTransferEngine(
        int chunkSize = 1_048_576,
        bool allowSameVolumeMoveShortcut = true,
        int progressIntervalMs = 80)
    {
        _chunkSize = Math.Max(65_536, chunkSize);
        _allowSameVolumeMoveShortcut = allowSameVolumeMoveShortcut;
        _progressIntervalMs = Math.Max(0, progressIntervalMs);
    }

    public async Task<(int filesCompleted, int filesSkipped)> ExecuteAsync(
        IReadOnlyList<string> sources,
        string destinationDirectory,
        TransferMode mode,
        ConflictPolicy conflictPolicy,
        string? destinationFileSystemHint,
        TransferControl control,
        Func<TransferProgressSnapshot, Task> onProgress,
        Func<ConflictPrompt, Task<ConflictDecision>> onConflict)
    {
        if (sources.Count == 0)
        {
            throw new TransferException("No files or folders selected.");
        }

        var destFull = Path.GetFullPath(destinationDirectory).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        var space = FileBrowserService.GetVolumeSpaceInfo(destinationDirectory);

        foreach (var src in sources)
        {
            var srcFull = Path.GetFullPath(src).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            if (string.Equals(destFull, srcFull, StringComparison.OrdinalIgnoreCase)
                || destFull.StartsWith(srcFull + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
            {
                throw new TransferException($"Cannot transfer '{Path.GetFileName(src)}' into itself or a subfolder.");
            }
        }

        var fsLower = (destinationFileSystemHint ?? space.fileSystem).ToLowerInvariant();
        bool isFat32 = fsLower.Contains("fat32");

        var plan = await Task.Run(() => BuildPlan(sources, destinationDirectory, isFat32), control.Token).ConfigureAwait(false);

        bool sameVolume = AreSameRoot(sources[0], destinationDirectory);
        if (!(mode == TransferMode.Move && sameVolume) && space.total > 0 && plan.TotalBytes > space.available)
        {
            throw new TransferException(
                $"Not enough free space on destination ({FormattingHelpers.FormatByteCount(space.available)} available, {FormattingHelpers.FormatByteCount(plan.TotalBytes)} required).");
        }

        var policy = conflictPolicy;
        long bytesTransferred = 0;
        int filesCompleted = 0;
        int filesSkipped = 0;
        double emaSpeed = 0;
        var lastEmit = Stopwatch.StartNew();
        var movedSourceFiles = new List<string>();
        var skippedRoots = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        await onProgress(MakeSnapshot(plan.TotalBytes, 0, plan.Files.Count, 0, 0, plan.Files.FirstOrDefault()?.Name ?? "", 0)).ConfigureAwait(false);

        foreach (var dir in plan.Directories)
        {
            await control.WaitIfPausedAsync().ConfigureAwait(false);
            Directory.CreateDirectory(dir);
        }

        foreach (var file in plan.Files)
        {
            await control.WaitIfPausedAsync().ConfigureAwait(false);

            var destPath = file.Destination;
            if (string.Equals(Path.GetFullPath(file.Source), Path.GetFullPath(destPath), StringComparison.OrdinalIgnoreCase))
            {
                filesSkipped++;
                skippedRoots.Add(file.RootSource);
                continue;
            }

            if (File.Exists(destPath))
            {
                ConflictResolution resolution;
                if (policy == ConflictPolicy.AskEachTime)
                {
                    var srcInfo = new FileInfo(file.Source);
                    var dstInfo = new FileInfo(destPath);
                    var decision = await onConflict(new ConflictPrompt
                    {
                        SourceName = file.Name,
                        DestinationPathDisplay = destPath,
                        SourceSize = srcInfo.Length,
                        DestinationSize = dstInfo.Length,
                        SourceDate = srcInfo.LastWriteTime,
                        DestinationDate = dstInfo.LastWriteTime
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
                        bytesTransferred += file.Size;
                        skippedRoots.Add(file.RootSource);
                        await onProgress(MakeSnapshot(plan.TotalBytes, bytesTransferred, plan.Files.Count, filesCompleted, filesSkipped, file.Name, emaSpeed)).ConfigureAwait(false);
                        continue;
                    case ConflictResolution.KeepBoth:
                        destPath = FileBrowserService.UniqueDestinationPath(destPath);
                        break;
                    case ConflictResolution.Replace:
                        break;
                }
            }

            var parentDir = Path.GetDirectoryName(destPath)!;
            Directory.CreateDirectory(parentDir);

            if (mode == TransferMode.Move && _allowSameVolumeMoveShortcut && AreSameRoot(file.Source, destPath))
            {
                File.Move(file.Source, destPath, overwrite: true);
                bytesTransferred += file.Size;
                filesCompleted++;
                await onProgress(MakeSnapshot(plan.TotalBytes, bytesTransferred, plan.Files.Count, filesCompleted, filesSkipped, file.Name, emaSpeed)).ConfigureAwait(false);
                continue;
            }

            var tempPath = Path.Combine(parentDir, $".unibridge.{Guid.NewGuid():N}.part");
            try
            {
                await CopyChunkedAsync(file.Source, tempPath, control, async (chunkBytes, seconds) =>
                {
                    bytesTransferred += chunkBytes;
                    if (seconds > 0)
                    {
                        var instant = chunkBytes / seconds;
                        emaSpeed = emaSpeed == 0 ? instant : (0.25 * instant + 0.75 * emaSpeed);
                    }
                    if (_progressIntervalMs == 0 || lastEmit.ElapsedMilliseconds >= _progressIntervalMs)
                    {
                        lastEmit.Restart();
                        await onProgress(MakeSnapshot(plan.TotalBytes, bytesTransferred, plan.Files.Count, filesCompleted, filesSkipped, file.Name, emaSpeed)).ConfigureAwait(false);
                    }
                }).ConfigureAwait(false);

                try
                {
                    File.SetLastWriteTimeUtc(tempPath, File.GetLastWriteTimeUtc(file.Source));
                }
                catch
                {
                    // Ignore timestamp preserve failures on restricted filesystems
                }

                File.Move(tempPath, destPath, overwrite: true);
            }
            catch
            {
                TryDeleteFile(tempPath);
                throw;
            }

            filesCompleted++;
            if (mode == TransferMode.Move)
            {
                movedSourceFiles.Add(file.Source);
            }

            await onProgress(MakeSnapshot(plan.TotalBytes, bytesTransferred, plan.Files.Count, filesCompleted, filesSkipped, file.Name, emaSpeed)).ConfigureAwait(false);
        }

        if (mode == TransferMode.Move)
        {
            foreach (var srcFile in movedSourceFiles)
            {
                TryDeleteFile(srcFile);
            }
            foreach (var root in sources)
            {
                if (!skippedRoots.Contains(root) && Directory.Exists(root))
                {
                    RemoveEmptyDirectories(root);
                }
            }
        }

        return (filesCompleted, filesSkipped);
    }

    private async Task CopyChunkedAsync(
        string sourcePath,
        string tempDestPath,
        TransferControl control,
        Func<int, double, Task> onChunk)
    {
        var buffer = new byte[_chunkSize];
        await using var src = new FileStream(sourcePath, FileMode.Open, FileAccess.Read, FileShare.Read, _chunkSize, useAsync: true);
        await using var dst = new FileStream(tempDestPath, FileMode.Create, FileAccess.Write, FileShare.None, _chunkSize, useAsync: true);

        var sw = new Stopwatch();
        while (true)
        {
            await control.WaitIfPausedAsync().ConfigureAwait(false);
            sw.Restart();
            int read = await src.ReadAsync(buffer.AsMemory(0, buffer.Length), control.Token).ConfigureAwait(false);
            if (read == 0) break;
            await dst.WriteAsync(buffer.AsMemory(0, read), control.Token).ConfigureAwait(false);
            sw.Stop();
            await onChunk(read, sw.Elapsed.TotalSeconds).ConfigureAwait(false);
        }

        await dst.FlushAsync(control.Token).ConfigureAwait(false);
    }

    private sealed record PlannedFile(string RootSource, string Source, string Destination, string Name, long Size);
    private sealed record TransferPlan(List<string> Directories, List<PlannedFile> Files, long TotalBytes);

    private static TransferPlan BuildPlan(IReadOnlyList<string> sources, string destinationDirectory, bool isFat32)
    {
        var dirs = new List<string>();
        var files = new List<PlannedFile>();
        long total = 0;

        foreach (var root in sources)
        {
            var targetRoot = Path.Combine(destinationDirectory, Path.GetFileName(root));
            if (File.Exists(root))
            {
                var fi = new FileInfo(root);
                if (isFat32 && fi.Length > Fat32MaxFileBytes)
                {
                    throw new TransferException($"'{fi.Name}' exceeds the 4 GB FAT32 file size limit. Format drive as exFAT or NTFS.");
                }
                files.Add(new PlannedFile(root, root, targetRoot, fi.Name, fi.Length));
                total += fi.Length;
                continue;
            }

            if (!Directory.Exists(root)) continue;
            dirs.Add(targetRoot);

            foreach (var subDir in Directory.EnumerateDirectories(root, "*", System.IO.SearchOption.AllDirectories))
            {
                var rel = Path.GetRelativePath(root, subDir);
                dirs.Add(Path.Combine(targetRoot, rel));
            }

            foreach (var subFile in Directory.EnumerateFiles(root, "*", System.IO.SearchOption.AllDirectories))
            {
                var fi = new FileInfo(subFile);
                if (isFat32 && fi.Length > Fat32MaxFileBytes)
                {
                    throw new TransferException($"'{fi.Name}' exceeds the 4 GB FAT32 file size limit. Format drive as exFAT or NTFS.");
                }
                var rel = Path.GetRelativePath(root, subFile);
                files.Add(new PlannedFile(root, subFile, Path.Combine(targetRoot, rel), fi.Name, fi.Length));
                total += fi.Length;
            }
        }

        return new TransferPlan(dirs, files, total);
    }

    private static bool AreSameRoot(string pathA, string pathB)
    {
        var rootA = Path.GetPathRoot(Path.GetFullPath(pathA));
        var rootB = Path.GetPathRoot(Path.GetFullPath(pathB));
        return !string.IsNullOrEmpty(rootA) && string.Equals(rootA, rootB, StringComparison.OrdinalIgnoreCase);
    }

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

    private static void TryDeleteFile(string path)
    {
        try
        {
            if (File.Exists(path)) File.Delete(path);
        }
        catch
        {
            // Ignore cleanup failure
        }
    }

    private static void RemoveEmptyDirectories(string root)
    {
        try
        {
            foreach (var dir in Directory.EnumerateDirectories(root))
            {
                RemoveEmptyDirectories(dir);
            }
            if (!Directory.EnumerateFileSystemEntries(root).Any())
            {
                Directory.Delete(root);
            }
        }
        catch
        {
            // Ignore non-empty / locked folders
        }
    }
}
