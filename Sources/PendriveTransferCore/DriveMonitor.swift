import AppKit
import DiskArbitration
import Foundation

public enum DriveError: LocalizedError, Sendable {
    case ejectFailed(String)

    public var errorDescription: String? {
        switch self {
        case .ejectFailed(let message):
            return "Could not safely eject pendrive: \(message)"
        }
    }
}

/// Monitors connected USB, USB-C OTG, SD Card, and external storage volumes in real time
/// using DiskArbitration and NSWorkspace mount/unmount notifications.
@MainActor
public final class DriveMonitor: ObservableObject {
    @Published public private(set) var drives: [DriveInfo] = []
    @Published public private(set) var customFolders: [DriveInfo] = []
    @Published public private(set) var lastUpdated: Date = Date()

    private var daSession: DASession?
    private var observers: [NSObjectProtocol] = []
    private var isStarted = false

    public init() {}

    public func start() {
        guard !isStarted else { return }
        isStarted = true

        if let session = DASessionCreate(kCFAllocatorDefault) {
            daSession = session
            DASessionSetDispatchQueue(session, DispatchQueue.main)
            let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

            DARegisterDiskAppearedCallback(session, nil, { _, ctx in
                guard let ctx else { return }
                let monitor = Unmanaged<DriveMonitor>.fromOpaque(ctx).takeUnretainedValue()
                Task { @MainActor in
                    monitor.refreshDrives()
                }
            }, context)

            DARegisterDiskDisappearedCallback(session, nil, { _, ctx in
                guard let ctx else { return }
                let monitor = Unmanaged<DriveMonitor>.fromOpaque(ctx).takeUnretainedValue()
                Task { @MainActor in
                    monitor.refreshDrives()
                }
            }, context)

            DARegisterDiskDescriptionChangedCallback(session, nil, nil, { _, _, ctx in
                guard let ctx else { return }
                let monitor = Unmanaged<DriveMonitor>.fromOpaque(ctx).takeUnretainedValue()
                Task { @MainActor in
                    monitor.refreshDrives()
                }
            }, context)
        }

        let wsCenter = NSWorkspace.shared.notificationCenter
        let notifications: [Notification.Name] = [
            NSWorkspace.didMountNotification,
            NSWorkspace.didUnmountNotification,
            NSWorkspace.didRenameVolumeNotification
        ]
        for name in notifications {
            let token = wsCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.refreshDrives()
                }
            }
            observers.append(token)
        }

        refreshDrives()
    }

    public func stop() {
        for token in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        observers.removeAll()

        if let session = daSession {
            DASessionSetDispatchQueue(session, nil)
            daSession = nil
        }
        isStarted = false
    }

    public func refreshDrives() {
        let detected = Self.discoverRemovableDrives(using: daSession)
        let combined = detected + customFolders
        if combined != drives {
            drives = combined
            lastUpdated = Date()
        }
    }

    /// Optional manual folder mount target (helpful when testing without physical hardware or using a custom mount).
    public func addCustomFolderTarget(_ folderURL: URL) {
        let space = FileBrowserService.volumeSpaceInfo(for: folderURL)
        let info = DriveInfo(
            id: "custom::\(folderURL.path)",
            name: folderURL.lastPathComponent,
            volumeURL: folderURL,
            deviceBSDName: nil,
            busProtocol: "Custom Folder",
            connectionKind: .customFolder,
            fileSystemName: space.fileSystem,
            vendorName: nil,
            modelName: folderURL.path,
            totalBytes: space.total,
            availableBytes: space.available,
            isReadOnly: space.readOnly,
            isRemovable: false,
            isEjectable: false,
            isCustomFolder: true
        )
        customFolders.removeAll { $0.id == info.id }
        customFolders.append(info)
        refreshDrives()
    }

    public func removeCustomFolderTarget(_ drive: DriveInfo) {
        customFolders.removeAll { $0.id == drive.id }
        refreshDrives()
    }

    public func eject(drive: DriveInfo) async throws {
        if drive.isCustomFolder {
            removeCustomFolderTarget(drive)
            return
        }

        let volumeURL = drive.volumeURL
        do {
            try await Task.detached(priority: .userInitiated) {
                try NSWorkspace.shared.unmountAndEjectDevice(at: volumeURL)
            }.value
            refreshDrives()
        } catch {
            throw DriveError.ejectFailed(error.localizedDescription)
        }
    }

    private static func discoverRemovableDrives(using existingSession: DASession?) -> [DriveInfo] {
        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeIsRemovableKey,
            .volumeIsEjectableKey,
            .volumeIsInternalKey,
            .volumeIsLocalKey,
            .volumeIsReadOnlyKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
            .volumeLocalizedFormatDescriptionKey,
            .volumeIsBrowsableKey
        ]

        guard let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) else {
            return []
        }

        let session = existingSession ?? DASessionCreate(kCFAllocatorDefault)

        var results: [DriveInfo] = []
        for url in urls {
            let path = url.path
            if path == "/" || path.hasPrefix("/System/Volumes") || path.hasPrefix("/private/") {
                continue
            }

            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.volumeIsBrowsable == false {
                continue
            }

            var diskDesc: [String: Any] = [:]
            if let session, let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL) {
                if let cfDesc = DADiskCopyDescription(disk) as? [String: Any] {
                    diskDesc = cfDesc
                }
            }

            let daInternal = diskDesc[kDADiskDescriptionDeviceInternalKey as String] as? Bool
            let isInternal = daInternal ?? (values?.volumeIsInternal ?? false)
            if isInternal {
                continue
            }

            let busProtocol = (diskDesc[kDADiskDescriptionDeviceProtocolKey as String] as? String) ?? ""
            let modelName = (diskDesc[kDADiskDescriptionDeviceModelKey as String] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let vendorName = (diskDesc[kDADiskDescriptionDeviceVendorKey as String] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let mediaName = (diskDesc[kDADiskDescriptionMediaNameKey as String] as? String) ?? ""

            // Ignore mounted .dmg disk images unless they explicitly present as physical USB/SD hardware.
            if busProtocol.localizedCaseInsensitiveContains("Disk Image")
                || modelName?.localizedCaseInsensitiveContains("Disk Image") == true
                || mediaName.localizedCaseInsensitiveContains("Disk Image")
            {
                continue
            }

            let isRemovable = (diskDesc[kDADiskDescriptionMediaRemovableKey as String] as? Bool)
                ?? (values?.volumeIsRemovable ?? false)
            let isEjectable = (diskDesc[kDADiskDescriptionMediaEjectableKey as String] as? Bool)
                ?? (values?.volumeIsEjectable ?? false)
            let isLocal = values?.volumeIsLocal ?? true

            let looksLikeUSBOrSD = busProtocol.localizedCaseInsensitiveContains("USB")
                || busProtocol.localizedCaseInsensitiveContains("Secure Digital")
                || busProtocol.localizedCaseInsensitiveContains("Thunderbolt")

            guard isLocal && (isRemovable || isEjectable || looksLikeUSBOrSD) else {
                continue
            }

            let isWritableDA = diskDesc[kDADiskDescriptionMediaWritableKey as String] as? Bool
            let isReadOnly = (values?.volumeIsReadOnly ?? false) || (isWritableDA == false)

            let volumeKind = (diskDesc[kDADiskDescriptionVolumeKindKey as String] as? String) ?? ""
            let localizedFormat = values?.volumeLocalizedFormatDescription ?? ""
            let fsName = normalizeFileSystemName(volumeKind: volumeKind, localizedFormat: localizedFormat)

            let connectionKind = classifyConnection(
                busProtocol: busProtocol,
                vendor: vendorName,
                model: modelName,
                isRemovable: isRemovable
            )

            let name = values?.volumeName
                ?? (diskDesc[kDADiskDescriptionVolumeNameKey as String] as? String)
                ?? url.lastPathComponent
            let bsdName = diskDesc[kDADiskDescriptionMediaBSDNameKey as String] as? String
            let fsAttrs = try? FileManager.default.attributesOfFileSystem(forPath: url.path)
            let rawTotal = Int64(values?.volumeTotalCapacity ?? 0)
            let total = rawTotal > 0 ? rawTotal : ((fsAttrs?[.systemSize] as? NSNumber)?.int64Value ?? 0)
            let availableImportant = values?.volumeAvailableCapacityForImportantUsage ?? 0
            let availableStandard = values?.volumeAvailableCapacity.map(Int64.init) ?? 0
            let fsFree = (fsAttrs?[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
            let available = availableImportant > 0
                ? availableImportant
                : (availableStandard > 0 ? availableStandard : fsFree)

            results.append(
                DriveInfo(
                    id: bsdName ?? url.path,
                    name: name,
                    volumeURL: url,
                    deviceBSDName: bsdName,
                    busProtocol: busProtocol.isEmpty ? "External" : busProtocol,
                    connectionKind: connectionKind,
                    fileSystemName: fsName,
                    vendorName: vendorName,
                    modelName: modelName,
                    totalBytes: total,
                    availableBytes: available,
                    isReadOnly: isReadOnly,
                    isRemovable: isRemovable,
                    isEjectable: isEjectable,
                    isCustomFolder: false
                )
            )
        }

        return results.sorted {
            if $0.isRemovable != $1.isRemovable {
                return $0.isRemovable && !$1.isRemovable
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private static func classifyConnection(
        busProtocol: String,
        vendor: String?,
        model: String?,
        isRemovable: Bool
    ) -> DriveConnectionKind {
        let protoLower = busProtocol.lowercased()
        let hardwareText = "\(vendor ?? "") \(model ?? "")".lowercased()

        if protoLower.contains("secure digital") || protoLower.contains("sd") {
            return .sdCard
        }
        if protoLower.contains("usb") {
            if isRemovable
                || hardwareText.contains("otg")
                || hardwareText.contains("dual")
                || hardwareText.contains("flash")
                || hardwareText.contains("pendrive")
                || hardwareText.contains("type-c")
            {
                return .usbOTG
            }
            return .usb
        }
        if protoLower.contains("thunderbolt") {
            return .thunderbolt
        }
        return .external
    }

    private static func normalizeFileSystemName(volumeKind: String, localizedFormat: String) -> String {
        let kind = volumeKind.lowercased()
        switch kind {
        case "exfat":
            return "exFAT"
        case "msdos":
            return localizedFormat.isEmpty ? "FAT32 (MS-DOS)" : localizedFormat
        case "apfs":
            return "APFS"
        case "hfs":
            return "Mac OS Extended"
        case "ntfs":
            return "NTFS"
        default:
            return localizedFormat.isEmpty ? (volumeKind.isEmpty ? "Unknown" : volumeKind.uppercased()) : localizedFormat
        }
    }
}
