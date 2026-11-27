using UniBridge.Core.Models;

namespace UniBridge.Core.Services;

/// <summary>
/// Coordinates discovery of Windows PC folders, USB/OTG pendrives, Android (MTP & ADB), and iOS devices.
/// </summary>
public sealed class DeviceManager
{
    public WindowsDriveMonitor DriveMonitor { get; } = new();
    public WindowsMTPService MTPService { get; } = new();
    public AndroidADBService ADBService { get; } = new();
    public WindowsIOSService IOSService { get; } = new();

    public async Task<List<StorageEndpoint>> DiscoverAllEndpointsAsync(CancellationToken ct = default)
    {
        var pc = StorageEndpoint.WindowsHome();
        var pendrives = DriveMonitor.DiscoverRemovableDrives().Select(StorageEndpoint.FromDrive).ToList();

        var iosTask = IOSService.DiscoverEndpointsAsync(ct);
        var adbTask = ADBService.DiscoverEndpointsAsync(ct);
        var wpdTask = MTPService.DiscoverEndpointsAsync(ct);

        await Task.WhenAll(iosTask, adbTask, wpdTask).ConfigureAwait(false);

        var iosFull = iosTask.Result;
        var adb = adbTask.Result;
        var wpd = wpdTask.Result;

        // If libimobiledevice already discovered a trusted iOS device, suppress the duplicate read-only WPD DCIM entry.
        bool hasFullIOS = iosFull.Any(e => !e.RequiresAttention);
        var filteredWpd = hasFullIOS
            ? wpd.Where(e => e.Platform != EndpointPlatform.IOSMedia).ToList()
            : wpd;

        var combined = new List<StorageEndpoint> { pc };
        combined.AddRange(pendrives);
        combined.AddRange(filteredWpd);
        combined.AddRange(adb);
        combined.AddRange(iosFull);
        return combined;
    }
}
