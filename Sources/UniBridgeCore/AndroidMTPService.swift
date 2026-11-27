import CDeviceBridge
import Foundation

public enum AndroidMTPError: LocalizedError, Sendable {
    case connectionFailed(String)
    case operationFailed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .connectionFailed(let msg), .operationFailed(let msg):
            return msg
        case .cancelled:
            return "Transfer cancelled."
        }
    }
}

private final class MTPProgressContext: @unchecked Sendable {
    let control: TransferControl
    let callback: @Sendable (Int64, Int64) -> Void

    init(control: TransferControl, callback: @escaping @Sendable (Int64, Int64) -> Void) {
        self.control = control
        self.callback = callback
    }
}

private func mtpCProgressCallback(transferred: UInt64, total: UInt64, context: UnsafeMutableRawPointer?) -> Int32 {
    guard let context else { return 0 }
    let box = Unmanaged<MTPProgressContext>.fromOpaque(context).takeUnretainedValue()
    if box.control.isCancelled {
        return 1
    }
    box.callback(Int64(clamping: transferred), Int64(clamping: total))
    return box.control.isCancelled ? 1 : 0
}

/// Thread-safe, persistent-session Android MTP manager backed by `libmtp`.
public final class AndroidMTPService: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.keshav.UniBridge.mtp", qos: .userInitiated)
    private var openHandles: [String: UnsafeMutableRawPointer] = [:]
    private var openFriendlyNames: [String: String] = [:]
    public var isTransferring: Bool {
        transferLock.withLock { activeTransferCount > 0 }
    }
    private let transferLock = NSLock()
    private var activeTransferCount = 0

    public init() {}

    deinit {
        for handle in openHandles.values {
            pt_mtp_close(handle)
        }
        openHandles.removeAll()
    }

    private func deviceKey(bus: UInt32, dev: UInt8) -> String {
        "\(bus):\(dev)"
    }

    public func closeAllSessions() async {
        await runOnQueue {
            for handle in self.openHandles.values {
                pt_mtp_close(handle)
            }
            self.openHandles.removeAll()
            self.openFriendlyNames.removeAll()
        }
    }

    public func discoverEndpoints() async -> [StorageEndpoint] {
        if isTransferring {
            // Avoid interrupting an active MTP USB session with a bus rescan.
            return []
        }

        return await runOnQueue {
            var rawPtr: UnsafeMutablePointer<PTMTPDeviceInfo>?
            var count: Int32 = 0
            var errPtr: UnsafeMutablePointer<CChar>?

            let rc = pt_mtp_detect_devices(&rawPtr, &count, &errPtr)
            defer {
                if let rawPtr { pt_mtp_free_devices(rawPtr, count) }
                if let errPtr { pt_free_string(errPtr) }
            }

            guard rc == 0, let rawPtr, count > 0 else {
                // Close any stale open sessions when no MTP device is attached.
                for handle in self.openHandles.values {
                    pt_mtp_close(handle)
                }
                self.openHandles.removeAll()
                self.openFriendlyNames.removeAll()
                return []
            }

            var activeKeys = Set<String>()
            var endpoints: [StorageEndpoint] = []

            for i in 0..<Int(count) {
                let info = rawPtr[i]
                let key = self.deviceKey(bus: info.bus_location, dev: info.devnum)
                activeKeys.insert(key)

                let vendor = info.vendor_name.map { String(cString: $0) } ?? "Android"
                let product = info.product_name.map { String(cString: $0) } ?? "MTP Device"

                do {
                    let (handle, friendlyName) = try self.ensureOpenLocked(bus: info.bus_location, dev: info.devnum)
                    var storages = try self.fetchStoragesLocked(handle: handle)

                    // If an earlier pre-permission session returned empty storages, reopen fresh once
                    // in case the user just tapped "File Transfer (MTP)" on their Android phone.
                    if storages.isEmpty {
                        self.closeSessionLocked(key: key)
                        let reopened = try self.ensureOpenLocked(bus: info.bus_location, dev: info.devnum)
                        storages = try self.fetchStoragesLocked(handle: reopened.0)
                    }

                    if storages.isEmpty {
                        // Never keep a locked/empty MTP handle open, or Android / libusb cannot reclaim cleanly.
                        self.closeSessionLocked(key: key)
                        endpoints.append(
                            StorageEndpoint(
                                id: "mtp::\(key)::locked",
                                platform: .androidMTP,
                                name: friendlyName.isEmpty ? product : friendlyName,
                                subtitle: "\(vendor) • Android MTP",
                                detailBadge: "Locked / No Storage",
                                isReadOnly: true,
                                requiresAttention: true,
                                statusMessage: "Unlock your Android phone and switch USB mode to 'File Transfer (MTP)'.",
                                rootLocation: .mtp(
                                    busLocation: info.bus_location,
                                    devNum: info.devnum,
                                    storageID: 0,
                                    folderID: 0,
                                    trail: []
                                ),
                                mtpBusLocation: info.bus_location,
                                mtpDevNum: info.devnum,
                                mtpStorageID: 0
                            )
                        )
                    } else {
                        for storage in storages {
                            let labelName = friendlyName.isEmpty ? product : friendlyName
                            let displayTitle = storages.count > 1 ? "\(labelName) — \(storage.description)" : labelName
                            endpoints.append(
                                StorageEndpoint(
                                    id: "mtp::\(key)::\(storage.id)",
                                    platform: .androidMTP,
                                    name: displayTitle,
                                    subtitle: "\(storage.description) • Android MTP",
                                    detailBadge: "MTP USB",
                                    totalBytes: Int64(clamping: storage.maxCapacity),
                                    availableBytes: Int64(clamping: storage.freeSpace),
                                    isReadOnly: false,
                                    requiresAttention: false,
                                    statusMessage: nil,
                                    rootLocation: .mtp(
                                        busLocation: info.bus_location,
                                        devNum: info.devnum,
                                        storageID: storage.id,
                                        folderID: 0,
                                        trail: []
                                    ),
                                    mtpBusLocation: info.bus_location,
                                    mtpDevNum: info.devnum,
                                    mtpStorageID: storage.id
                                )
                            )
                        }
                    }
                } catch {
                    self.closeSessionLocked(key: key)
                    endpoints.append(
                        StorageEndpoint(
                            id: "mtp::\(key)::attention",
                            platform: .androidMTP,
                            name: "\(vendor) \(product)",
                            subtitle: "Android MTP (USB Busy or Locked)",
                            detailBadge: "Action Needed",
                            isReadOnly: true,
                            requiresAttention: true,
                            statusMessage: error.localizedDescription,
                            rootLocation: .mtp(
                                busLocation: info.bus_location,
                                devNum: info.devnum,
                                storageID: 0,
                                folderID: 0,
                                trail: []
                            ),
                            mtpBusLocation: info.bus_location,
                            mtpDevNum: info.devnum,
                            mtpStorageID: 0
                        )
                    )
                }
            }

            for existingKey in Array(self.openHandles.keys) where !activeKeys.contains(existingKey) {
                if let handle = self.openHandles.removeValue(forKey: existingKey) {
                    pt_mtp_close(handle)
                }
                self.openFriendlyNames.removeValue(forKey: existingKey)
            }

            return endpoints
        }
    }

    public func listFolder(
        busLocation: UInt32,
        devNum: UInt8,
        storageID: UInt32,
        folderID: UInt32,
        trail: [MTPPathSegment],
        showHidden: Bool,
        sortBy: SortField,
        ascending: Bool
    ) async throws -> [BrowserEntry] {
        try await runOnQueueThrowing {
            let (handle, _) = try self.ensureOpenLocked(bus: busLocation, dev: devNum)
            var itemsPtr: UnsafeMutablePointer<PTMTPItem>?
            var count: Int32 = 0
            var errPtr: UnsafeMutablePointer<CChar>?

            let rc = pt_mtp_list_folder(handle, storageID, folderID, &itemsPtr, &count, &errPtr)
            defer {
                if let itemsPtr { pt_mtp_free_items(itemsPtr, count) }
                if let errPtr { pt_free_string(errPtr) }
            }

            if rc != 0 {
                let msg = errPtr.map { String(cString: $0) } ?? "Failed to read Android folder."
                throw AndroidMTPError.operationFailed(msg)
            }

            var entries: [BrowserEntry] = []
            if let itemsPtr, count > 0 {
                for i in 0..<Int(count) {
                    let item = itemsPtr[i]
                    let name = item.name.map { String(cString: $0) } ?? "Unnamed"
                    let hidden = name.hasPrefix(".")
                    if !showHidden && hidden {
                        continue
                    }

                    let childTrail: [MTPPathSegment]
                    let childLoc: RemoteLocation
                    if item.is_folder {
                        childTrail = trail + [MTPPathSegment(folderID: item.item_id, name: name)]
                        childLoc = .mtp(
                            busLocation: busLocation,
                            devNum: devNum,
                            storageID: storageID,
                            folderID: item.item_id,
                            trail: childTrail
                        )
                    } else {
                        childLoc = .mtp(
                            busLocation: busLocation,
                            devNum: devNum,
                            storageID: storageID,
                            folderID: folderID,
                            trail: trail
                        )
                    }

                    entries.append(
                        BrowserEntry(
                            id: "mtp::\(storageID)::\(item.item_id)",
                            name: name,
                            isDirectory: item.is_folder,
                            isPackage: false,
                            size: item.is_folder ? 0 : Int64(clamping: item.size),
                            modifiedDate: item.modified_timestamp > 0
                                ? Date(timeIntervalSince1970: TimeInterval(item.modified_timestamp))
                                : Date.distantPast,
                            isHidden: hidden,
                            location: childLoc,
                            mtpObjectID: item.item_id,
                            remotePath: (trail.map(\.name) + [name]).joined(separator: "/")
                        )
                    )
                }
            }

            return FormattingHelpers.sortBrowserEntries(entries, by: sortBy, ascending: ascending)
        }
    }

    public func createFolder(
        busLocation: UInt32,
        devNum: UInt8,
        storageID: UInt32,
        parentFolderID: UInt32,
        name: String
    ) async throws -> UInt32 {
        try await runOnQueueThrowing {
            let (handle, _) = try self.ensureOpenLocked(bus: busLocation, dev: devNum)
            var createdID: UInt32 = 0
            var errPtr: UnsafeMutablePointer<CChar>?
            let rc = name.withCString { cName in
                pt_mtp_create_folder(handle, storageID, parentFolderID, cName, &createdID, &errPtr)
            }
            defer { if let errPtr { pt_free_string(errPtr) } }
            if rc != 0 {
                throw AndroidMTPError.operationFailed(errPtr.map { String(cString: $0) } ?? "Failed to create folder.")
            }
            return createdID
        }
    }

    public func renameObject(
        busLocation: UInt32,
        devNum: UInt8,
        objectID: UInt32,
        newName: String
    ) async throws {
        try await runOnQueueThrowing {
            let (handle, _) = try self.ensureOpenLocked(bus: busLocation, dev: devNum)
            var errPtr: UnsafeMutablePointer<CChar>?
            let rc = newName.withCString { cName in
                pt_mtp_rename_object(handle, objectID, cName, &errPtr)
            }
            defer { if let errPtr { pt_free_string(errPtr) } }
            if rc != 0 {
                throw AndroidMTPError.operationFailed(errPtr.map { String(cString: $0) } ?? "Failed to rename item.")
            }
        }
    }

    public func deleteObject(
        busLocation: UInt32,
        devNum: UInt8,
        objectID: UInt32
    ) async throws {
        try await runOnQueueThrowing {
            let (handle, _) = try self.ensureOpenLocked(bus: busLocation, dev: devNum)
            var errPtr: UnsafeMutablePointer<CChar>?
            let rc = pt_mtp_delete_object(handle, objectID, &errPtr)
            defer { if let errPtr { pt_free_string(errPtr) } }
            if rc != 0 {
                throw AndroidMTPError.operationFailed(errPtr.map { String(cString: $0) } ?? "Failed to delete item.")
            }
        }
    }

    public func downloadFile(
        busLocation: UInt32,
        devNum: UInt8,
        objectID: UInt32,
        toLocalURL localURL: URL,
        control: TransferControl,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        transferLock.withLock { activeTransferCount += 1 }
        defer { transferLock.withLock { activeTransferCount = max(0, activeTransferCount - 1) } }

        try await runOnQueueThrowing {
            let (handle, _) = try self.ensureOpenLocked(bus: busLocation, dev: devNum)
            let box = MTPProgressContext(control: control, callback: onProgress)
            let retained = Unmanaged.passRetained(box)
            defer { retained.release() }

            var errPtr: UnsafeMutablePointer<CChar>?
            let rc = localURL.path.withCString { cPath in
                pt_mtp_download_file(handle, objectID, cPath, mtpCProgressCallback, retained.toOpaque(), &errPtr)
            }
            defer { if let errPtr { pt_free_string(errPtr) } }

            if control.isCancelled {
                throw AndroidMTPError.cancelled
            }
            if rc != 0 {
                throw AndroidMTPError.operationFailed(errPtr.map { String(cString: $0) } ?? "MTP download failed.")
            }
        }
    }

    public func uploadFile(
        busLocation: UInt32,
        devNum: UInt8,
        storageID: UInt32,
        parentFolderID: UInt32,
        fromLocalURL localURL: URL,
        filename: String,
        fileSize: Int64,
        control: TransferControl,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> UInt32 {
        transferLock.withLock { activeTransferCount += 1 }
        defer { transferLock.withLock { activeTransferCount = max(0, activeTransferCount - 1) } }

        return try await runOnQueueThrowing {
            let (handle, _) = try self.ensureOpenLocked(bus: busLocation, dev: devNum)
            let box = MTPProgressContext(control: control, callback: onProgress)
            let retained = Unmanaged.passRetained(box)
            defer { retained.release() }

            var createdID: UInt32 = 0
            var errPtr: UnsafeMutablePointer<CChar>?
            let rc = localURL.path.withCString { cPath in
                filename.withCString { cName in
                    pt_mtp_upload_file(
                        handle,
                        storageID,
                        parentFolderID,
                        cPath,
                        cName,
                        UInt64(max(0, fileSize)),
                        mtpCProgressCallback,
                        retained.toOpaque(),
                        &createdID,
                        &errPtr
                    )
                }
            }
            defer { if let errPtr { pt_free_string(errPtr) } }

            if control.isCancelled {
                if createdID != 0 {
                    var delErr: UnsafeMutablePointer<CChar>?
                    _ = pt_mtp_delete_object(handle, createdID, &delErr)
                    if let delErr { pt_free_string(delErr) }
                }
                throw AndroidMTPError.cancelled
            }
            if rc != 0 {
                throw AndroidMTPError.operationFailed(errPtr.map { String(cString: $0) } ?? "MTP upload failed.")
            }
            return createdID
        }
    }

    // MARK: - Private Serialized Helpers

    private func closeSessionLocked(key: String) {
        if let handle = openHandles.removeValue(forKey: key) {
            pt_mtp_close(handle)
        }
        openFriendlyNames.removeValue(forKey: key)
    }

    private func ensureOpenLocked(bus: UInt32, dev: UInt8) throws -> (UnsafeMutableRawPointer, String) {
        let key = deviceKey(bus: bus, dev: dev)
        if let existing = openHandles[key] {
            return (existing, openFriendlyNames[key] ?? "Android Device")
        }

        var friendlyPtr: UnsafeMutablePointer<CChar>?
        var errPtr: UnsafeMutablePointer<CChar>?
        let handle = pt_mtp_open(bus, dev, &friendlyPtr, &errPtr)
        let friendly = friendlyPtr.map { String(cString: $0) } ?? "Android Device"
        if let friendlyPtr { pt_free_string(friendlyPtr) }
        defer { if let errPtr { pt_free_string(errPtr) } }

        guard let handle else {
            let msg = errPtr.map { String(cString: $0) } ?? "Could not connect to Android MTP device."
            throw AndroidMTPError.connectionFailed(msg)
        }
        openHandles[key] = handle
        openFriendlyNames[key] = friendly
        return (handle, friendly)
    }

    private func fetchStoragesLocked(handle: UnsafeMutableRawPointer) throws -> [(id: UInt32, description: String, maxCapacity: UInt64, freeSpace: UInt64)] {
        var storagesPtr: UnsafeMutablePointer<PTMTPStorageInfo>?
        var count: Int32 = 0
        var errPtr: UnsafeMutablePointer<CChar>?

        let rc = pt_mtp_get_storages(handle, &storagesPtr, &count, &errPtr)
        defer {
            if let storagesPtr { pt_mtp_free_storages(storagesPtr, count) }
            if let errPtr { pt_free_string(errPtr) }
        }

        if rc != 0 {
            throw AndroidMTPError.connectionFailed(errPtr.map { String(cString: $0) } ?? "Cannot query MTP storage.")
        }
        guard let storagesPtr, count > 0 else { return [] }

        var list: [(UInt32, String, UInt64, UInt64)] = []
        for i in 0..<Int(count) {
            let s = storagesPtr[i]
            let desc = s.description.map { String(cString: $0) } ?? "Internal Storage"
            list.append((s.storage_id, desc, s.max_capacity, s.free_space))
        }
        return list
    }

    private func runOnQueue<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: work())
            }
        }
    }

    private func runOnQueueThrowing<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            queue.async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
