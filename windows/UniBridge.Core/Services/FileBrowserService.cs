using Microsoft.VisualBasic.FileIO;
using UniBridge.Core.Models;

namespace UniBridge.Core.Services;

public static class FileBrowserService
{
    private static readonly char[] InvalidFileChars = Path.GetInvalidFileNameChars();

    public static List<BrowserEntry> ListContents(
        string directoryPath,
        EndpointPlatform platform,
        bool showHidden,
        SortField sortBy,
        bool ascending)
    {
        var dirInfo = new DirectoryInfo(directoryPath);
        if (!dirInfo.Exists)
        {
            throw new DirectoryNotFoundException($"Folder not found: {directoryPath}");
        }

        var entries = new List<BrowserEntry>();
        foreach (var fsi in dirInfo.EnumerateFileSystemInfos())
        {
            bool hidden = (fsi.Attributes & FileAttributes.Hidden) != 0
                          || (fsi.Attributes & FileAttributes.System) != 0
                          || fsi.Name.StartsWith('.');
            if (!showHidden && hidden)
            {
                continue;
            }

            bool isDir = (fsi.Attributes & FileAttributes.Directory) != 0;
            long size = 0;
            if (!isDir && fsi is FileInfo fi)
            {
                size = fi.Length;
            }

            entries.Add(new BrowserEntry
            {
                Id = fsi.FullName,
                Name = fsi.Name,
                IsDirectory = isDir,
                Size = size,
                ModifiedDate = fsi.LastWriteTime,
                IsHidden = hidden,
                Location = RemoteLocation.Local(platform, fsi.FullName)
            });
        }

        return FormattingHelpers.SortEntries(entries, sortBy, ascending);
    }

    public static string CreateFolder(string parentDirectory, string rawName)
    {
        var name = rawName.Trim();
        if (!IsValidFileName(name))
        {
            throw new ArgumentException("Folder name is empty or contains invalid Windows filename characters.");
        }

        var target = UniqueDestinationPath(Path.Combine(parentDirectory, name), isDirectory: true);
        Directory.CreateDirectory(target);
        return target;
    }

    public static string RenameItem(string currentPath, string rawNewName)
    {
        var newName = rawNewName.Trim();
        if (!IsValidFileName(newName))
        {
            throw new ArgumentException("Name is empty or contains invalid Windows filename characters.");
        }

        var parent = Path.GetDirectoryName(currentPath) ?? throw new InvalidOperationException("Invalid parent folder.");
        var destination = Path.Combine(parent, newName);
        if (string.Equals(Path.GetFullPath(currentPath), Path.GetFullPath(destination), StringComparison.OrdinalIgnoreCase))
        {
            return currentPath;
        }

        if (Directory.Exists(currentPath))
        {
            Directory.Move(currentPath, destination);
        }
        else
        {
            File.Move(currentPath, destination);
        }
        return destination;
    }

    public static void RemoveItem(string path, bool permanentlyIfRecycleUnavailable)
    {
        bool isDir = Directory.Exists(path);
        try
        {
            if (isDir)
            {
                FileSystem.DeleteDirectory(path, UIOption.OnlyErrorDialogs, RecycleOption.SendToRecycleBin);
            }
            else
            {
                FileSystem.DeleteFile(path, UIOption.OnlyErrorDialogs, RecycleOption.SendToRecycleBin);
            }
        }
        catch
        {
            if (!permanentlyIfRecycleUnavailable)
            {
                throw;
            }

            if (isDir)
            {
                Directory.Delete(path, recursive: true);
            }
            else
            {
                File.Delete(path);
            }
        }
    }

    public static bool IsValidFileName(string name)
    {
        if (string.IsNullOrWhiteSpace(name) || name is "." or "..")
        {
            return false;
        }
        return name.IndexOfAny(InvalidFileChars) < 0 && !name.Contains('/') && !name.Contains('\\');
    }

    public static string UniqueDestinationPath(string preferredPath, bool isDirectory = false)
    {
        if (!File.Exists(preferredPath) && !Directory.Exists(preferredPath))
        {
            return preferredPath;
        }

        var dir = Path.GetDirectoryName(preferredPath) ?? string.Empty;
        var ext = isDirectory ? string.Empty : Path.GetExtension(preferredPath);
        var stem = isDirectory || string.IsNullOrEmpty(ext)
            ? Path.GetFileName(preferredPath)
            : Path.GetFileNameWithoutExtension(preferredPath);

        int counter = 2;
        while (true)
        {
            var candidateName = string.IsNullOrEmpty(ext) ? $"{stem} ({counter})" : $"{stem} ({counter}){ext}";
            var candidate = Path.Combine(dir, candidateName);
            if (!File.Exists(candidate) && !Directory.Exists(candidate))
            {
                return candidate;
            }
            counter++;
        }
    }

    public static (long total, long available, bool readOnly, string fileSystem) GetVolumeSpaceInfo(string path)
    {
        try
        {
            var root = Path.GetPathRoot(Path.GetFullPath(path));
            if (string.IsNullOrEmpty(root))
            {
                return (0, 0, false, "Unknown");
            }
            var di = new DriveInfo(root);
            if (!di.IsReady)
            {
                return (0, 0, false, "Unknown");
            }
            return (di.TotalSize, di.AvailableFreeSpace, false, di.DriveFormat);
        }
        catch
        {
            return (0, 0, false, "Unknown");
        }
    }
}
