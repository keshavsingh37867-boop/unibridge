using System.Management;
using System.Runtime.InteropServices;
using UniBridge.Core.Models;

namespace UniBridge.Core.Services;

/// <summary>
/// Detects USB/OTG pendrives, SD cards, and external USB drives on Windows,
/// and supports safe hardware ejection via Win32 DeviceIoControl.
/// </summary>
public sealed class WindowsDriveMonitor
{
    private readonly List<DriveInfoModel> _customFolders = [];

    public IReadOnlyList<DriveInfoModel> DiscoverRemovableDrives()
    {
        var usbDriveLetters = QueryUSBFixedDriveLetters();
        var results = new List<DriveInfoModel>();

        foreach (var di in DriveInfo.GetDrives())
        {
            try
            {
                if (!di.IsReady) continue;

                bool isRemovable = di.DriveType == DriveType.Removable;
                var letter = di.Name.TrimEnd('\\').ToUpperInvariant();
                bool isUsbFixed = di.DriveType == DriveType.Fixed && usbDriveLetters.Contains(letter);

                if (!isRemovable && !isUsbFixed)
                {
                    continue;
                }

                var label = string.IsNullOrWhiteSpace(di.VolumeLabel) ? $"USB Drive ({letter})" : $"{di.VolumeLabel} ({letter})";
                results.Add(new DriveInfoModel
                {
                    Id = letter,
                    Name = label,
                    RootPath = di.Name,
                    ConnectionLabel = isRemovable ? "USB / OTG" : "External USB",
                    FileSystemName = di.DriveFormat,
                    TotalBytes = di.TotalSize,
                    AvailableBytes = di.AvailableFreeSpace,
                    IsReadOnly = false,
                    IsCustomFolder = false
                });
            }
            catch
            {
                // Skip unreadable or transitioning drives
            }
        }

        results.AddRange(_customFolders);
        return results;
    }

    public void AddCustomFolderTarget(string folderPath)
    {
        var space = FileBrowserService.GetVolumeSpaceInfo(folderPath);
        var model = new DriveInfoModel
        {
            Id = $"custom::{folderPath}",
            Name = Path.GetFileName(folderPath.TrimEnd('\\', '/')) is { Length: > 0 } n ? n : folderPath,
            RootPath = folderPath,
            ConnectionLabel = "Custom Folder",
            FileSystemName = space.fileSystem,
            TotalBytes = space.total,
            AvailableBytes = space.available,
            IsCustomFolder = true
        };
        _customFolders.RemoveAll(d => string.Equals(d.Id, model.Id, StringComparison.OrdinalIgnoreCase));
        _customFolders.Add(model);
    }

    public void RemoveCustomFolderTarget(DriveInfoModel drive)
    {
        _customFolders.RemoveAll(d => string.Equals(d.Id, drive.Id, StringComparison.OrdinalIgnoreCase));
    }

    public Task EjectDriveAsync(DriveInfoModel drive)
    {
        if (drive.IsCustomFolder)
        {
            RemoveCustomFolderTarget(drive);
            return Task.CompletedTask;
        }

        return Task.Run(() =>
        {
            var letter = drive.RootPath.TrimEnd('\\', '/');
            var devicePath = $@"\\.\{letter}";

            var handle = CreateFileW(
                devicePath,
                GENERIC_READ | GENERIC_WRITE,
                FILE_SHARE_READ | FILE_SHARE_WRITE,
                IntPtr.Zero,
                OPEN_EXISTING,
                0,
                IntPtr.Zero);

            if (handle == IntPtr.Zero || handle == new IntPtr(-1))
            {
                throw new IOException($"Could not access drive {letter} for ejection (error {Marshal.GetLastWin32Error()}).");
            }

            try
            {
                uint bytesReturned = 0;
                if (!DeviceIoControl(handle, FSCTL_LOCK_VOLUME, IntPtr.Zero, 0, IntPtr.Zero, 0, ref bytesReturned, IntPtr.Zero))
                {
                    throw new IOException($"Drive {letter} is currently in use by another program.");
                }
                DeviceIoControl(handle, FSCTL_DISMOUNT_VOLUME, IntPtr.Zero, 0, IntPtr.Zero, 0, ref bytesReturned, IntPtr.Zero);
                if (!DeviceIoControl(handle, IOCTL_STORAGE_EJECT_MEDIA, IntPtr.Zero, 0, IntPtr.Zero, 0, ref bytesReturned, IntPtr.Zero))
                {
                    throw new IOException($"Drive {letter} dismounted, but hardware eject returned error {Marshal.GetLastWin32Error()}.");
                }
            }
            finally
            {
                CloseHandle(handle);
            }
        });
    }

    private static HashSet<string> QueryUSBFixedDriveLetters()
    {
        var set = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        try
        {
            using var diskSearcher = new ManagementObjectSearcher("SELECT DeviceID, InterfaceType FROM Win32_DiskDrive WHERE InterfaceType='USB'");
            foreach (ManagementObject disk in diskSearcher.Get())
            {
                var deviceId = disk["DeviceID"]?.ToString();
                if (string.IsNullOrEmpty(deviceId)) continue;
                var escapedId = deviceId.Replace(@"\", @"\\");
                using var partSearcher = new ManagementObjectSearcher(
                    $"ASSOCIATORS OF {{Win32_DiskDrive.DeviceID='{escapedId}'}} WHERE AssocClass=Win32_DiskDriveToDiskPartition");
                foreach (ManagementObject partition in partSearcher.Get())
                {
                    var partId = partition["DeviceID"]?.ToString();
                    if (string.IsNullOrEmpty(partId)) continue;
                    using var logicalSearcher = new ManagementObjectSearcher(
                        $"ASSOCIATORS OF {{Win32_DiskPartition.DeviceID='{partId}'}} WHERE AssocClass=Win32_LogicalDiskToPartition");
                    foreach (ManagementObject logical in logicalSearcher.Get())
                    {
                        var letter = logical["DeviceID"]?.ToString();
                        if (!string.IsNullOrEmpty(letter))
                        {
                            set.Add(letter.ToUpperInvariant());
                        }
                    }
                }
            }
        }
        catch
        {
            // Fallback gracefully if WMI service is unavailable
        }
        return set;
    }

    private const uint GENERIC_READ = 0x80000000;
    private const uint GENERIC_WRITE = 0x40000000;
    private const uint FILE_SHARE_READ = 0x00000001;
    private const uint FILE_SHARE_WRITE = 0x00000002;
    private const uint OPEN_EXISTING = 3;
    private const uint FSCTL_LOCK_VOLUME = 0x00090018;
    private const uint FSCTL_DISMOUNT_VOLUME = 0x00090020;
    private const uint IOCTL_STORAGE_EJECT_MEDIA = 0x002D4808;

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateFileW(
        string lpFileName,
        uint dwDesiredAccess,
        uint dwShareMode,
        IntPtr lpSecurityAttributes,
        uint dwCreationDisposition,
        uint dwFlagsAndAttributes,
        IntPtr hTemplateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool DeviceIoControl(
        IntPtr hDevice,
        uint dwIoControlCode,
        IntPtr lpInBuffer,
        uint nInBufferSize,
        IntPtr lpOutBuffer,
        uint nOutBufferSize,
        ref uint lpBytesReturned,
        IntPtr lpOverlapped);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr hObject);
}
