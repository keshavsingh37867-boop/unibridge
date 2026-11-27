using System.Collections.ObjectModel;
using System.Globalization;
using iMobileDevice;
using iMobileDevice.Afc;
using iMobileDevice.HouseArrest;
using iMobileDevice.iDevice;
using iMobileDevice.InstallationProxy;
using iMobileDevice.Lockdown;
using iMobileDevice.Plist;
using iMobileDevice.Service;
using UniBridge.Core.Models;

namespace UniBridge.Core.Services;

/// <summary>
/// Manages iPhone and iPad connections on Windows via libimobiledevice (AFC Media & House Arrest App Documents).
/// Gracefully handles systems where Apple Mobile Device Support (iTunes / Apple Devices) is not yet installed.
/// </summary>
public sealed class WindowsIOSService
{
    private readonly SemaphoreSlim _lock = new(1, 1);
    private bool _nativeInitialized;
    private bool _nativeAvailable;

    private bool EnsureNativeLoaded()
    {
        if (_nativeInitialized) return _nativeAvailable;
        _nativeInitialized = true;
        try
        {
            NativeLibraries.Load();
            _nativeAvailable = true;
        }
        catch
        {
            _nativeAvailable = false;
        }
        return _nativeAvailable;
    }

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

    private List<StorageEndpoint> DiscoverSync()
    {
        var endpoints = new List<StorageEndpoint>();
        if (!EnsureNativeLoaded()) return endpoints;

        try
        {
            var iDeviceApi = LibiMobileDevice.Instance.iDevice;
            var lockdownApi = LibiMobileDevice.Instance.Lockdown;

            int count = 0;
            if (iDeviceApi.idevice_get_device_list(out ReadOnlyCollection<string> udids, ref count) != iDeviceError.Success || count == 0)
            {
                return endpoints;
            }

            foreach (var udid in udids.Distinct(StringComparer.OrdinalIgnoreCase))
            {
                if (string.IsNullOrWhiteSpace(udid)) continue;

                if (iDeviceApi.idevice_new(out iDeviceHandle devHandle, udid) != iDeviceError.Success || devHandle is null)
                {
                    continue;
                }

                using (devHandle)
                {
                    var lerr = lockdownApi.lockdownd_client_new_with_handshake(devHandle, out LockdownClientHandle lockdownHandle, "UniBridge");
                    if (lerr != LockdownError.Success || lockdownHandle is null)
                    {
                        lockdownHandle?.Dispose();
                        endpoints.Add(new StorageEndpoint
                        {
                            Id = $"ios::{udid}::unpaired",
                            Platform = EndpointPlatform.IOSMedia,
                            Name = "iPhone / iPad",
                            Subtitle = "iOS USB",
                            DetailBadge = "Tap Trust",
                            IsReadOnly = true,
                            RequiresAttention = true,
                            StatusMessage = "Unlock your iPhone/iPad, tap 'Trust This Computer', and ensure Apple Devices / iTunes is installed.",
                            RootLocation = new RemoteLocation { Platform = EndpointPlatform.IOSMedia, DeviceId = udid, Path = "/" }
                        });
                        continue;
                    }

                    using (lockdownHandle)
                    {
                        var deviceName = ReadLockdownString(lockdownApi, lockdownHandle, "DeviceName") ?? "iPhone / iPad";
                        var iosVersion = ReadLockdownString(lockdownApi, lockdownHandle, "ProductVersion");
                        var versionBadge = string.IsNullOrWhiteSpace(iosVersion) ? "iOS" : $"iOS {iosVersion}";

                        var (total, free) = ReadAfcStorageInfo(devHandle, lockdownApi, lockdownHandle);

                        endpoints.Add(new StorageEndpoint
                        {
                            Id = $"ios::{udid}::media",
                            Platform = EndpointPlatform.IOSMedia,
                            Name = $"{deviceName} — Media & Photos",
                            Subtitle = $"{versionBadge} • USB (DCIM & Media)",
                            DetailBadge = "iOS Media",
                            TotalBytes = total,
                            AvailableBytes = free,
                            RootLocation = new RemoteLocation { Platform = EndpointPlatform.IOSMedia, DeviceId = udid, Path = "/" }
                        });

                        foreach (var (bundleId, displayName) in ListFileSharingApps(devHandle, lockdownApi, lockdownHandle))
                        {
                            endpoints.Add(new StorageEndpoint
                            {
                                Id = $"ios::{udid}::app::{bundleId}",
                                Platform = EndpointPlatform.IOSApp,
                                Name = $"{deviceName} — {displayName}",
                                Subtitle = $"iOS App Documents • {bundleId}",
                                DetailBadge = "iOS App",
                                TotalBytes = total,
                                AvailableBytes = free,
                                RootLocation = new RemoteLocation
                                {
                                    Platform = EndpointPlatform.IOSApp,
                                    DeviceId = udid,
                                    AppBundleId = bundleId,
                                    Path = "/Documents"
                                }
                            });
                        }
                    }
                }
            }
        }
        catch
        {
            // Swallow usbmuxd errors when Apple Mobile Device Service is absent
        }

        return endpoints;
    }

    public async Task<List<BrowserEntry>> ListDirectoryAsync(
        string udid,
        string? appBundleId,
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
                using var session = OpenAfcSession(udid, appBundleId);
                var afc = LibiMobileDevice.Instance.Afc;
                afc.afc_read_directory(session.Afc, path, out ReadOnlyCollection<string> names).ThrowOnError();

                var platform = string.IsNullOrEmpty(appBundleId) ? EndpointPlatform.IOSMedia : EndpointPlatform.IOSApp;
                var entries = new List<BrowserEntry>();

                foreach (var name in names)
                {
                    if (name is "." or "..") continue;
                    bool hidden = name.StartsWith('.');
                    if (!showHidden && hidden) continue;

                    var fullPath = path == "/" ? $"/{name}" : $"{path.TrimEnd('/')}/{name}";
                    var (isDir, size, modified) = ReadEntryInfo(afc, session.Afc, fullPath);

                    entries.Add(new BrowserEntry
                    {
                        Id = $"ios::{udid}::{appBundleId ?? "afc"}::{fullPath}",
                        Name = name,
                        IsDirectory = isDir,
                        Size = isDir ? 0 : size,
                        ModifiedDate = modified,
                        IsHidden = hidden,
                        Location = new RemoteLocation
                        {
                            Platform = platform,
                            DeviceId = udid,
                            AppBundleId = appBundleId,
                            Path = fullPath
                        }
                    });
                }

                return FormattingHelpers.SortEntries(entries, sortBy, ascending);
            }, ct).ConfigureAwait(false);
        }
        finally
        {
            _lock.Release();
        }
    }

    public async Task CreateDirectoryAsync(string udid, string? appBundleId, string remotePath, CancellationToken ct = default)
    {
        await _lock.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            await Task.Run(() =>
            {
                using var session = OpenAfcSession(udid, appBundleId);
                LibiMobileDevice.Instance.Afc.afc_make_directory(session.Afc, remotePath).ThrowOnError();
            }, ct).ConfigureAwait(false);
        }
        finally
        {
            _lock.Release();
        }
    }

    public async Task RenameAsync(string udid, string? appBundleId, string fromPath, string toPath, CancellationToken ct = default)
    {
        await _lock.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            await Task.Run(() =>
            {
                using var session = OpenAfcSession(udid, appBundleId);
                LibiMobileDevice.Instance.Afc.afc_rename_path(session.Afc, fromPath, toPath).ThrowOnError();
            }, ct).ConfigureAwait(false);
        }
        finally
        {
            _lock.Release();
        }
    }

    public async Task DeleteAsync(string udid, string? appBundleId, string remotePath, CancellationToken ct = default)
    {
        await _lock.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            await Task.Run(() =>
            {
                using var session = OpenAfcSession(udid, appBundleId);
                var afc = LibiMobileDevice.Instance.Afc;
                var err = afc.afc_remove_path_and_contents(session.Afc, remotePath);
                if (err != AfcError.Success)
                {
                    afc.afc_remove_path(session.Afc, remotePath).ThrowOnError();
                }
            }, ct).ConfigureAwait(false);
        }
        finally
        {
            _lock.Release();
        }
    }

    public async Task DownloadFileAsync(
        string udid,
        string? appBundleId,
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
                using var session = OpenAfcSession(udid, appBundleId);
                var afc = LibiMobileDevice.Instance.Afc;
                ulong handle = 0;
                afc.afc_file_open(session.Afc, remotePath, AfcFileMode.FopenRdonly, ref handle).ThrowOnError();
                try
                {
                    const uint chunkSize = 524_288;
                    var buffer = new byte[chunkSize];
                    long totalRead = 0;
                    using var fs = new FileStream(localPath, FileMode.Create, FileAccess.Write, FileShare.None);

                    while (true)
                    {
                        control.WaitIfPausedAsync().GetAwaiter().GetResult();
                        uint bytesRead = 0;
                        afc.afc_file_read(session.Afc, handle, buffer, chunkSize, ref bytesRead).ThrowOnError();
                        if (bytesRead == 0) break;
                        fs.Write(buffer, 0, (int)bytesRead);
                        totalRead += bytesRead;
                        onProgress(expectedSize > 0 ? Math.Min(expectedSize, totalRead) : totalRead);
                    }
                }
                finally
                {
                    afc.afc_file_close(session.Afc, handle);
                }
            }, control.Token).ConfigureAwait(false);
        }
        finally
        {
            _lock.Release();
        }
    }

    public async Task UploadFileAsync(
        string udid,
        string? appBundleId,
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
                using var session = OpenAfcSession(udid, appBundleId);
                var afc = LibiMobileDevice.Instance.Afc;
                ulong handle = 0;
                afc.afc_file_open(session.Afc, remotePath, AfcFileMode.FopenWronly, ref handle).ThrowOnError();
                try
                {
                    const int chunkSize = 524_288;
                    var buffer = new byte[chunkSize];
                    long totalWritten = 0;
                    using var fs = new FileStream(localPath, FileMode.Open, FileAccess.Read, FileShare.Read);

                    while (true)
                    {
                        control.WaitIfPausedAsync().GetAwaiter().GetResult();
                        int read = fs.Read(buffer, 0, buffer.Length);
                        if (read == 0) break;

                        int offset = 0;
                        while (offset < read)
                        {
                            uint written = 0;
                            var slice = offset == 0 ? buffer : buffer[offset..read];
                            afc.afc_file_write(session.Afc, handle, slice, (uint)(read - offset), ref written).ThrowOnError();
                            if (written == 0) throw new IOException("Failed to write data to iOS device.");
                            offset += (int)written;
                        }

                        totalWritten += read;
                        onProgress(fileSize > 0 ? Math.Min(fileSize, totalWritten) : totalWritten);
                    }
                }
                catch
                {
                    try { afc.afc_remove_path(session.Afc, remotePath); } catch { }
                    throw;
                }
                finally
                {
                    afc.afc_file_close(session.Afc, handle);
                }
            }, control.Token).ConfigureAwait(false);
        }
        finally
        {
            _lock.Release();
        }
    }

    private static AfcSessionScope OpenAfcSession(string udid, string? appBundleId)
    {
        var iDeviceApi = LibiMobileDevice.Instance.iDevice;
        var lockdownApi = LibiMobileDevice.Instance.Lockdown;
        var afcApi = LibiMobileDevice.Instance.Afc;
        var houseApi = LibiMobileDevice.Instance.HouseArrest;

        iDeviceApi.idevice_new(out iDeviceHandle dev, udid).ThrowOnError();
        try
        {
            lockdownApi.lockdownd_client_new_with_handshake(dev, out LockdownClientHandle lockdown, "UniBridge").ThrowOnError();
            using (lockdown)
            {
                if (string.IsNullOrEmpty(appBundleId))
                {
                    lockdownApi.lockdownd_start_service(lockdown, "com.apple.afc", out LockdownServiceDescriptorHandle svc).ThrowOnError();
                    using (svc)
                    {
                        afcApi.afc_client_new(dev, svc, out AfcClientHandle afc).ThrowOnError();
                        return new AfcSessionScope(dev, null, afc);
                    }
                }

                lockdownApi.lockdownd_start_service(lockdown, "com.apple.mobile.house_arrest", out LockdownServiceDescriptorHandle haSvc).ThrowOnError();
                using (haSvc)
                {
                    houseApi.house_arrest_client_new(dev, haSvc, out HouseArrestClientHandle houseArrest).ThrowOnError();
                    houseApi.house_arrest_send_command(houseArrest, "VendDocuments", appBundleId).ThrowOnError();
                    houseApi.house_arrest_get_result(houseArrest, out PlistHandle result).ThrowOnError();
                    using (result)
                    {
                        var plist = LibiMobileDevice.Instance.Plist;
                        var statusNode = plist.plist_dict_get_item(result, "Status");
                        string? status = null;
                        if (statusNode is not null && !statusNode.IsInvalid)
                        {
                            plist.plist_get_string_val(statusNode, out status);
                        }
                        if (!string.Equals(status, "Complete", StringComparison.Ordinal))
                        {
                            throw new IOException($"App '{appBundleId}' did not allow USB file sharing.");
                        }
                    }

                    afcApi.afc_client_new_from_house_arrest_client(houseArrest, out AfcClientHandle afc).ThrowOnError();
                    return new AfcSessionScope(dev, houseArrest, afc);
                }
            }
        }
        catch
        {
            dev.Dispose();
            throw;
        }
    }

    private static (long total, long free) ReadAfcStorageInfo(iDeviceHandle dev, ILockdownApi lockdownApi, LockdownClientHandle lockdown)
    {
        try
        {
            lockdownApi.lockdownd_start_service(lockdown, "com.apple.afc", out LockdownServiceDescriptorHandle svc).ThrowOnError();
            using (svc)
            {
                var afc = LibiMobileDevice.Instance.Afc;
                afc.afc_client_new(dev, svc, out AfcClientHandle client).ThrowOnError();
                using (client)
                {
                    afc.afc_get_device_info_key(client, "FSTotalBytes", out string totalStr);
                    afc.afc_get_device_info_key(client, "FSFreeBytes", out string freeStr);
                    long.TryParse(totalStr, NumberStyles.Integer, CultureInfo.InvariantCulture, out long total);
                    long.TryParse(freeStr, NumberStyles.Integer, CultureInfo.InvariantCulture, out long free);
                    return (total, free);
                }
            }
        }
        catch
        {
            return (0, 0);
        }
    }

    private static (bool isDir, long size, DateTime modified) ReadEntryInfo(IAfcApi afc, AfcClientHandle client, string fullPath)
    {
        bool isDir = false;
        long size = 0;
        var modified = DateTime.MinValue;

        if (afc.afc_get_file_info(client, fullPath, out ReadOnlyCollection<string> info) == AfcError.Success && info is not null)
        {
            for (int i = 0; i + 1 < info.Count; i += 2)
            {
                var k = info[i];
                var v = info[i + 1];
                if (k == "st_ifmt" && v == "S_IFDIR") isDir = true;
                else if (k == "st_size") long.TryParse(v, NumberStyles.Integer, CultureInfo.InvariantCulture, out size);
                else if (k == "st_mtime" && long.TryParse(v, NumberStyles.Integer, CultureInfo.InvariantCulture, out long mtime))
                {
                    long secs = mtime > 1_000_000_000_000L ? mtime / 1_000_000_000L : mtime;
                    if (secs > 0) modified = DateTimeOffset.FromUnixTimeSeconds(secs).LocalDateTime;
                }
            }
        }

        return (isDir, isDir ? 0 : size, modified);
    }

    private static List<(string bundleId, string displayName)> ListFileSharingApps(
        iDeviceHandle dev,
        ILockdownApi lockdownApi,
        LockdownClientHandle lockdown)
    {
        var apps = new List<(string, string)>();
        try
        {
            lockdownApi.lockdownd_start_service(lockdown, "com.apple.mobile.installation_proxy", out LockdownServiceDescriptorHandle svc).ThrowOnError();
            using (svc)
            {
                var inst = LibiMobileDevice.Instance.InstallationProxy;
                var plist = LibiMobileDevice.Instance.Plist;

                inst.instproxy_client_new(dev, svc, out InstallationProxyClientHandle client).ThrowOnError();
                using (client)
                {
                    using var opts = plist.plist_new_dict();
                    plist.plist_dict_set_item(opts, "ApplicationType", plist.plist_new_string("User"));
                    inst.instproxy_browse(client, opts, out PlistHandle result).ThrowOnError();
                    using (result)
                    {
                        uint count = plist.plist_array_get_size(result);
                        for (uint i = 0; i < count; i++)
                        {
                            var app = plist.plist_array_get_item(result, i);
                            var sharingNode = plist.plist_dict_get_item(app, "UIFileSharingEnabled");
                            if (sharingNode is null || sharingNode.IsInvalid) continue;

                            byte isShared = 0;
                            plist.plist_get_bool_val(sharingNode, ref isShared);
                            if (isShared == 0) continue;

                            var bidNode = plist.plist_dict_get_item(app, "CFBundleIdentifier");
                            if (bidNode is null || bidNode.IsInvalid) continue;
                            plist.plist_get_string_val(bidNode, out string bundleId);
                            if (string.IsNullOrWhiteSpace(bundleId)) continue;

                            string display = bundleId;
                            var dnNode = plist.plist_dict_get_item(app, "CFBundleDisplayName");
                            if (dnNode is not null && !dnNode.IsInvalid)
                            {
                                plist.plist_get_string_val(dnNode, out display);
                            }
                            else
                            {
                                var nameNode = plist.plist_dict_get_item(app, "CFBundleName");
                                if (nameNode is not null && !nameNode.IsInvalid)
                                {
                                    plist.plist_get_string_val(nameNode, out display);
                                }
                            }

                            apps.Add((bundleId, string.IsNullOrWhiteSpace(display) ? bundleId : display));
                        }
                    }
                }
            }
        }
        catch
        {
            // Ignore installation_proxy unavailability
        }

        return apps.OrderBy(a => a.Item2, StringComparer.CurrentCultureIgnoreCase).ToList();
    }

    private static string? ReadLockdownString(ILockdownApi lockdownApi, LockdownClientHandle lockdown, string key)
    {
        if (lockdownApi.lockdownd_get_value(lockdown, null, key, out PlistHandle node) != LockdownError.Success || node is null || node.IsInvalid)
        {
            node?.Dispose();
            return null;
        }
        using (node)
        {
            LibiMobileDevice.Instance.Plist.plist_get_string_val(node, out string val);
            return val;
        }
    }

    private sealed class AfcSessionScope(
        iDeviceHandle dev,
        HouseArrestClientHandle? houseArrest,
        AfcClientHandle afc) : IDisposable
    {
        public AfcClientHandle Afc => afc;

        public void Dispose()
        {
            afc.Dispose();
            houseArrest?.Dispose();
            dev.Dispose();
        }
    }
}
