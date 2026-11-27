using System.Security.Cryptography;
using System.Text;
using UniBridge.Core.Models;
using UniBridge.Core.Services;
using Xunit;

namespace UniBridge.Tests;

public sealed class UniBridgeCoreTests : IDisposable
{
    private readonly string _rootDir;
    private readonly string _srcDir;
    private readonly string _dstDir;

    public UniBridgeCoreTests()
    {
        _rootDir = Path.Combine(Path.GetTempPath(), $"UniBridgeTests-{Guid.NewGuid():N}");
        _srcDir = Path.Combine(_rootDir, "src");
        _dstDir = Path.Combine(_rootDir, "dst");
        Directory.CreateDirectory(_srcDir);
        Directory.CreateDirectory(_dstDir);
    }

    public void Dispose()
    {
        try
        {
            if (Directory.Exists(_rootDir))
            {
                Directory.Delete(_rootDir, recursive: true);
            }
        }
        catch
        {
            // Best-effort cleanup
        }
    }

    private static string Sha256Hex(string path)
    {
        using var fs = File.OpenRead(path);
        return Convert.ToHexString(SHA256.HashData(fs));
    }

    private static byte[] MakeDeterministicBytes(int length, byte seed)
    {
        var data = new byte[length];
        for (int i = 0; i < length; i++)
        {
            data[i] = (byte)((i * 31 + seed) & 0xFF);
        }
        return data;
    }

    [Fact]
    public async Task ChunkedCopy_PreservesSha256IntegrityAndProgressMonotonicity()
    {
        var nested = Path.Combine(_srcDir, "bundle", "nested");
        Directory.CreateDirectory(nested);
        var fileA = Path.Combine(_srcDir, "bundle", "video.bin");
        var fileB = Path.Combine(nested, "note.txt");
        await File.WriteAllBytesAsync(fileA, MakeDeterministicBytes(1_500_000, 7));
        await File.WriteAllTextAsync(fileB, "Hello UniBridge Windows!", Encoding.UTF8);

        var engine = new LocalTransferEngine(chunkSize: 65_536);
        var control = new TransferControl();
        var observedBytes = new List<long>();

        var (completed, skipped) = await engine.ExecuteAsync(
            [Path.Combine(_srcDir, "bundle")],
            _dstDir,
            TransferMode.Copy,
            ConflictPolicy.AskEachTime,
            null,
            control,
            snap =>
            {
                observedBytes.Add(snap.BytesTransferred);
                return Task.CompletedTask;
            },
            _ => Task.FromResult(new ConflictDecision(ConflictResolution.CancelAll, false)));

        Assert.Equal(2, completed);
        Assert.Equal(0, skipped);
        Assert.Equal(Sha256Hex(fileA), Sha256Hex(Path.Combine(_dstDir, "bundle", "video.bin")));
        Assert.Equal(Sha256Hex(fileB), Sha256Hex(Path.Combine(_dstDir, "bundle", "nested", "note.txt")));

        for (int i = 1; i < observedBytes.Count; i++)
        {
            Assert.True(observedBytes[i] >= observedBytes[i - 1], "Progress should be monotonically non-decreasing.");
        }
    }

    [Fact]
    public async Task CrossVolumeChunkedMove_CopiesDeletesSourcesAndPreservesIntegrity()
    {
        var folder = Path.Combine(_srcDir, "move_me");
        Directory.CreateDirectory(folder);
        var file = Path.Combine(folder, "payload.dat");
        await File.WriteAllBytesAsync(file, MakeDeterministicBytes(400_000, 19));
        var expectedHash = Sha256Hex(file);

        var engine = new LocalTransferEngine(chunkSize: 65_536, allowSameVolumeMoveShortcut: false);
        var (completed, skipped) = await engine.ExecuteAsync(
            [folder],
            _dstDir,
            TransferMode.Move,
            ConflictPolicy.AskEachTime,
            null,
            new TransferControl(),
            _ => Task.CompletedTask,
            _ => Task.FromResult(new ConflictDecision(ConflictResolution.CancelAll, false)));

        Assert.Equal(1, completed);
        Assert.Equal(0, skipped);
        Assert.False(Directory.Exists(folder));
        Assert.Equal(expectedHash, Sha256Hex(Path.Combine(_dstDir, "move_me", "payload.dat")));
    }

    [Fact]
    public async Task MoveWithSkipConflict_PreservesExistingAndKeepsSourceIntact()
    {
        var srcFolder = Path.Combine(_srcDir, "sync");
        var dstFolder = Path.Combine(_dstDir, "sync");
        Directory.CreateDirectory(srcFolder);
        Directory.CreateDirectory(dstFolder);

        var srcFile = Path.Combine(srcFolder, "photo.jpg");
        var dstFile = Path.Combine(dstFolder, "photo.jpg");
        await File.WriteAllTextAsync(srcFile, "NEW_VERSION");
        await File.WriteAllTextAsync(dstFile, "OLD_VERSION");

        var engine = new LocalTransferEngine(allowSameVolumeMoveShortcut: false);
        var (completed, skipped) = await engine.ExecuteAsync(
            [srcFolder],
            _dstDir,
            TransferMode.Move,
            ConflictPolicy.SkipExisting,
            null,
            new TransferControl(),
            _ => Task.CompletedTask,
            _ => Task.FromResult(new ConflictDecision(ConflictResolution.CancelAll, false)));

        Assert.Equal(0, completed);
        Assert.Equal(1, skipped);
        Assert.Equal("OLD_VERSION", await File.ReadAllTextAsync(dstFile));
        Assert.True(File.Exists(srcFile), "Skipped source file must not be deleted during move.");
    }

    [Fact]
    public async Task ConflictKeepBothAndReplace_BehaveCorrectly()
    {
        var srcFile = Path.Combine(_srcDir, "doc.txt");
        var dstFile = Path.Combine(_dstDir, "doc.txt");
        await File.WriteAllTextAsync(srcFile, "UPDATED");
        await File.WriteAllTextAsync(dstFile, "ORIGINAL");

        var engine = new LocalTransferEngine();

        var (c1, s1) = await engine.ExecuteAsync(
            [srcFile],
            _dstDir,
            TransferMode.Copy,
            ConflictPolicy.KeepBoth,
            null,
            new TransferControl(),
            _ => Task.CompletedTask,
            _ => Task.FromResult(new ConflictDecision(ConflictResolution.CancelAll, false)));

        Assert.Equal(1, c1);
        Assert.Equal(0, s1);
        Assert.Equal("ORIGINAL", await File.ReadAllTextAsync(dstFile));
        Assert.Equal("UPDATED", await File.ReadAllTextAsync(Path.Combine(_dstDir, "doc (2).txt")));

        var (c2, _) = await engine.ExecuteAsync(
            [srcFile],
            _dstDir,
            TransferMode.Copy,
            ConflictPolicy.ReplaceExisting,
            null,
            new TransferControl(),
            _ => Task.CompletedTask,
            _ => Task.FromResult(new ConflictDecision(ConflictResolution.CancelAll, false)));

        Assert.Equal(1, c2);
        Assert.Equal("UPDATED", await File.ReadAllTextAsync(dstFile));
    }

    [Fact]
    public async Task SelfNestingCopy_ThrowsTransferException()
    {
        var parent = Path.Combine(_srcDir, "parent");
        var child = Path.Combine(parent, "child");
        Directory.CreateDirectory(child);
        await File.WriteAllTextAsync(Path.Combine(parent, "item.txt"), "abc");

        var engine = new LocalTransferEngine();
        await Assert.ThrowsAsync<TransferException>(() =>
            engine.ExecuteAsync(
                [parent],
                child,
                TransferMode.Copy,
                ConflictPolicy.AskEachTime,
                null,
                new TransferControl(),
                _ => Task.CompletedTask,
                _ => Task.FromResult(new ConflictDecision(ConflictResolution.CancelAll, false))));
    }

    [Fact]
    public async Task CancelMidTransfer_ThrowsOperationCanceledAndRemovesStagingPartFiles()
    {
        var bigFile = Path.Combine(_srcDir, "large.bin");
        await File.WriteAllBytesAsync(bigFile, MakeDeterministicBytes(2_500_000, 42));

        var engine = new LocalTransferEngine(chunkSize: 65_536, progressIntervalMs: 0);
        var control = new TransferControl();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            engine.ExecuteAsync(
                [bigFile],
                _dstDir,
                TransferMode.Copy,
                ConflictPolicy.ReplaceExisting,
                null,
                control,
                snap =>
                {
                    if (snap.BytesTransferred >= 131_072)
                    {
                        control.Cancel();
                    }
                    return Task.CompletedTask;
                },
                _ => Task.FromResult(new ConflictDecision(ConflictResolution.CancelAll, false))));

        Assert.False(File.Exists(Path.Combine(_dstDir, "large.bin")));
        Assert.Empty(Directory.GetFiles(_dstDir, "*.part"));
    }

    [Fact]
    public async Task PauseAndResume_CompletesTransfer()
    {
        var file = Path.Combine(_srcDir, "pausable.bin");
        await File.WriteAllBytesAsync(file, MakeDeterministicBytes(500_000, 5));

        var engine = new LocalTransferEngine(chunkSize: 65_536, progressIntervalMs: 0);
        var control = new TransferControl();
        bool pausedOnce = false;

        var task = engine.ExecuteAsync(
            [file],
            _dstDir,
            TransferMode.Copy,
            ConflictPolicy.ReplaceExisting,
            null,
            control,
            snap =>
            {
                if (!pausedOnce && snap.BytesTransferred >= 65_536)
                {
                    pausedOnce = true;
                    control.Pause();
                    _ = Task.Run(async () =>
                    {
                        await Task.Delay(120);
                        control.Resume();
                    });
                }
                return Task.CompletedTask;
            },
            _ => Task.FromResult(new ConflictDecision(ConflictResolution.CancelAll, false)));

        var (completed, _) = await task;
        Assert.True(pausedOnce);
        Assert.Equal(1, completed);
        Assert.Equal(Sha256Hex(file), Sha256Hex(Path.Combine(_dstDir, "pausable.bin")));
    }

    [Fact]
    public void FileBrowserService_ListsFiltersCreatesRenamesAndGeneratesUniquePaths()
    {
        File.WriteAllText(Path.Combine(_srcDir, "alpha.txt"), "a");
        File.WriteAllText(Path.Combine(_srcDir, ".hidden_dot"), "h");
        var created = FileBrowserService.CreateFolder(_srcDir, "Projects");
        Assert.True(Directory.Exists(created));

        var withoutHidden = FileBrowserService.ListContents(_srcDir, EndpointPlatform.WindowsPC, showHidden: false, SortField.Name, ascending: true);
        Assert.Equal(2, withoutHidden.Count);
        Assert.Equal("Projects", withoutHidden[0].Name);
        Assert.True(withoutHidden[0].IsDirectory);
        Assert.Equal("alpha.txt", withoutHidden[1].Name);

        var withHidden = FileBrowserService.ListContents(_srcDir, EndpointPlatform.WindowsPC, showHidden: true, SortField.Name, ascending: true);
        Assert.Equal(3, withHidden.Count);

        var renamed = FileBrowserService.RenameItem(Path.Combine(_srcDir, "alpha.txt"), "beta.txt");
        Assert.True(File.Exists(renamed));
        Assert.False(File.Exists(Path.Combine(_srcDir, "alpha.txt")));

        var unique = FileBrowserService.UniqueDestinationPath(renamed, isDirectory: false);
        Assert.Equal(Path.Combine(_srcDir, "beta (2).txt"), unique);

        Assert.True(FileBrowserService.IsValidFileName("normal_file.pdf"));
        Assert.False(FileBrowserService.IsValidFileName("   "));
        Assert.False(FileBrowserService.IsValidFileName("bad|name.txt"));
    }

    [Fact]
    public void AndroidAdbHelpers_QuoteAndParseCorrectly()
    {
        Assert.Equal("'it'\"'\"'s here'", AndroidADBService.ShellQuote("it's here"));

        const string dfSample = """
            Filesystem     1K-blocks     Used Available Use% Mounted on
            /dev/fuse      115248128 48120000  67128128  42% /storage/emulated
            """;
        var (total, avail) = AndroidADBService.ParseDfOutput(dfSample);
        Assert.Equal(115248128L * 1024L, total);
        Assert.Equal(67128128L * 1024L, avail);

        const string lsSample = """
            D|0|1730000100|DCIM
            F|4096|1730000200|readme.txt
            F|128|1730000300|.nomedia
            """;
        var visible = AndroidADBService.ParseDirectoryListing("SER123", "/sdcard", lsSample, showHidden: false, SortField.Name, ascending: true);
        Assert.Equal(2, visible.Count);
        Assert.Equal("DCIM", visible[0].Name);
        Assert.True(visible[0].IsDirectory);
        Assert.Equal("/sdcard/DCIM", visible[0].Location.Path);
        Assert.Equal("readme.txt", visible[1].Name);
        Assert.Equal(4096, visible[1].Size);

        var all = AndroidADBService.ParseDirectoryListing("SER123", "/sdcard", lsSample, showHidden: true, SortField.Name, ascending: true);
        Assert.Equal(3, all.Count);

        Assert.Throws<DirectoryNotFoundException>(() =>
            AndroidADBService.ParseDirectoryListing("SER123", "/sdcard/missing", "__ERR__No such folder", false, SortField.Name, true));
    }

    [Fact]
    public async Task UnifiedTransferService_LocalRoundTripAndListEntries()
    {
        var file = Path.Combine(_srcDir, "report.csv");
        await File.WriteAllTextAsync(file, "id,name\n1,UniBridge\n");

        var service = new UnifiedTransferService(new WindowsMTPService(), new AndroidADBService(), new WindowsIOSService());
        var pcEndpoint = StorageEndpoint.WindowsHome();
        var srcParent = RemoteLocation.Local(EndpointPlatform.WindowsPC, _srcDir);
        var dstDir = RemoteLocation.Local(EndpointPlatform.WindowsPC, _dstDir);

        var listed = await service.ListEntriesAsync(srcParent, false, SortField.Name, true);
        Assert.Single(listed);

        var (completed, skipped) = await service.ExecuteAsync(
            listed,
            pcEndpoint,
            srcParent,
            pcEndpoint,
            dstDir,
            TransferMode.Copy,
            ConflictPolicy.ReplaceExisting,
            new TransferControl(),
            _ => Task.CompletedTask,
            _ => Task.FromResult(new ConflictDecision(ConflictResolution.CancelAll, false)));

        Assert.Equal(1, completed);
        Assert.Equal(0, skipped);
        Assert.True(File.Exists(Path.Combine(_dstDir, "report.csv")));
    }

    [Fact]
    public void FormattingHelpersAndDriveModel_FormatExpectedStrings()
    {
        Assert.Equal("512 B", FormattingHelpers.FormatByteCount(512));
        Assert.Equal("1 MB", FormattingHelpers.FormatByteCount(1_048_576));
        Assert.Equal("--", FormattingHelpers.FormatSpeed(0));
        Assert.Equal("10 KB/s", FormattingHelpers.FormatSpeed(10_240));
        Assert.Equal("1:05", FormattingHelpers.FormatDuration(65));
        Assert.Equal("1:01:05", FormattingHelpers.FormatDuration(3665));

        var fatDrive = new DriveInfoModel
        {
            Id = "E:",
            Name = "PENDRIVE (E:)",
            RootPath = @"E:\",
            FileSystemName = "FAT32",
            TotalBytes = 16_000_000_000,
            AvailableBytes = 8_000_000_000
        };
        Assert.True(fatDrive.IsFAT32);
        var endpoint = StorageEndpoint.FromDrive(fatDrive);
        Assert.Equal("FAT32: 4 GB max per file", endpoint.StatusMessage);
    }
}
