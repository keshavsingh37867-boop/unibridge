import CDeviceBridge
import Foundation

public enum IOSDeviceError: LocalizedError, Sendable {
    case deviceUnavailable(String)
    case operationFailed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .deviceUnavailable(let msg), .operationFailed(let msg):
            return msg
        case .cancelled:
            return "Transfer cancelled."
        }
    }
}

private final class IOSProgressContext: @unchecked Sendable {
    let control: TransferControl
    let callback: @Sendable (Int64, Int64) -> Void

    init(control: TransferControl, callback: @escaping @Sendable (Int64, Int64) -> Void) {
        self.control = control
        self.callback = callback
    }
}

private func iosCProgressCallback(transferred: UInt64, total: UInt64, context: UnsafeMutableRawPointer?) -> Int32 {
    guard let context else { return 0 }
    let box = Unmanaged<IOSProgressContext>.fromOpaque(context).takeUnretainedValue()
    while box.control.isPaused && !box.control.isCancelled {
        usleep(50_000)
    }
    if box.control.isCancelled {
        return 1
    }
    box.callback(Int64(clamping: transferred), Int64(clamping: total))
    return box.control.isCancelled ? 1 : 0
}

/// Manages iPhone & iPad USB connections via `libimobiledevice` (AFC Media & App File Sharing).
public final class IOSDeviceService: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.keshav.UniBridge.ios", qos: .userInitiated)
    private var eventSubscription: UnsafeMutableRawPointer?
    private let eventCallbackLock = NSLock()
    private var onDeviceChangeHandler: (@Sendable () -> Void)?

    public init() {}

    deinit {
        if let sub = eventSubscription {
            pt_ios_unsubscribe_events(sub)
            eventSubscription = nil
        }
    }

    public func startMonitoring(onDeviceChange: @escaping @Sendable () -> Void) {
        eventCallbackLock.withLock {
            onDeviceChangeHandler = onDeviceChange
        }
        guard eventSubscription == nil else { return }
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        eventSubscription = pt_ios_subscribe_events({ _, _, ctx in
            guard let ctx else { return }
            let service = Unmanaged<IOSDeviceService>.fromOpaque(ctx).takeUnretainedValue()
            service.notifyDeviceChanged()
        }, selfPtr)
    }

    public func stopMonitoring() {
        if let sub = eventSubscription {
            pt_ios_unsubscribe_events(sub)
            eventSubscription = nil
        }
        eventCallbackLock.withLock {
            onDeviceChangeHandler = nil
        }
    }

    private func notifyDeviceChanged() {
        let handler = eventCallbackLock.withLock { onDeviceChangeHandler }
        handler?()
    }

    public func discoverEndpoints() async -> [StorageEndpoint] {
        await runOnQueue {
            var devPtr: UnsafeMutablePointer<PTIOSDeviceInfo>?
            var count: Int32 = 0
            let rc = pt_ios_list_devices(&devPtr, &count)
            defer {
                if let devPtr { pt_ios_free_devices(devPtr, count) }
            }
            guard rc == 0, let devPtr, count > 0 else {
                return []
            }

            var endpoints: [StorageEndpoint] = []

            for i in 0..<Int(count) {
                let d = devPtr[i]
                guard let udidC = d.udid else { continue }
                let udid = String(cString: udidC)
                let name = d.device_name.map { String(cString: $0) } ?? "iPhone / iPad"
                let osVersion = d.product_version.map { String(cString: $0) } ?? ""
                let connLabel = d.is_usb ? "USB" : "Wi-Fi"
                let versionLabel = osVersion.isEmpty ? "iOS" : "iOS \(osVersion)"

                if !d.is_paired {
                    let msg = d.status_message.map { String(cString: $0) }
                        ?? "Unlock your iPhone/iPad and tap 'Trust This Computer'."
                    endpoints.append(
                        StorageEndpoint(
                            id: "ios::\(udid)::unpaired",
                            platform: .iosMedia,
                            name: name,
                            subtitle: "\(versionLabel) • \(connLabel)",
                            detailBadge: "Tap Trust",
                            isReadOnly: true,
                            requiresAttention: true,
                            statusMessage: msg,
                            rootLocation: .ios(udid: udid, appBundleID: nil, path: "/"),
                            iosUDID: udid,
                            iosAppBundleID: nil
                        )
                    )
                    continue
                }

                // 1. iOS Media & Photos (AFC: /DCIM, /Downloads, /Books, etc.)
                var totalBytes: UInt64 = 0
                var freeBytes: UInt64 = 0
                var storageErr: UnsafeMutablePointer<CChar>?
                _ = udid.withCString { cUdid in
                    pt_ios_get_storage_info(cUdid, nil, &totalBytes, &freeBytes, &storageErr)
                }
                if let storageErr { pt_free_string(storageErr) }

                endpoints.append(
                    StorageEndpoint(
                        id: "ios::\(udid)::media",
                        platform: .iosMedia,
                        name: "\(name) — Media & Photos",
                        subtitle: "\(versionLabel) • \(connLabel) (DCIM & Media)",
                        detailBadge: "iOS Media",
                        totalBytes: Int64(clamping: totalBytes),
                        availableBytes: Int64(clamping: freeBytes),
                        isReadOnly: false,
                        requiresAttention: false,
                        statusMessage: nil,
                        rootLocation: .ios(udid: udid, appBundleID: nil, path: "/"),
                        iosUDID: udid,
                        iosAppBundleID: nil
                    )
                )

                // 2. Installed Apps supporting USB File Sharing (House Arrest /Documents)
                var appsPtr: UnsafeMutablePointer<PTIOSAppInfo>?
                var appCount: Int32 = 0
                var appsErr: UnsafeMutablePointer<CChar>?
                let appRC = udid.withCString { cUdid in
                    pt_ios_list_file_sharing_apps(cUdid, &appsPtr, &appCount, &appsErr)
                }
                if let appsErr { pt_free_string(appsErr) }

                if appRC == 0, let appsPtr, appCount > 0 {
                    var appPairs: [(bundleID: String, displayName: String)] = []
                    for idx in 0..<Int(appCount) {
                        let a = appsPtr[idx]
                        if let b = a.bundle_id, let dn = a.display_name {
                            appPairs.append((String(cString: b), String(cString: dn)))
                        }
                    }
                    pt_ios_free_apps(appsPtr, appCount)

                    appPairs.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
                    for app in appPairs {
                        endpoints.append(
                            StorageEndpoint(
                                id: "ios::\(udid)::app::\(app.bundleID)",
                                platform: .iosApp,
                                name: "\(name) — \(app.displayName)",
                                subtitle: "iOS App Documents • \(app.bundleID)",
                                detailBadge: "iOS App",
                                totalBytes: Int64(clamping: totalBytes),
                                availableBytes: Int64(clamping: freeBytes),
                                isReadOnly: false,
                                requiresAttention: false,
                                statusMessage: nil,
                                rootLocation: .ios(udid: udid, appBundleID: app.bundleID, path: "/Documents"),
                                iosUDID: udid,
                                iosAppBundleID: app.bundleID
                            )
                        )
                    }
                } else if let appsPtr {
                    pt_ios_free_apps(appsPtr, appCount)
                }
            }

            return endpoints
        }
    }

    public func listDirectory(
        udid: String,
        appBundleID: String?,
        path: String,
        showHidden: Bool,
        sortBy: SortField,
        ascending: Bool
    ) async throws -> [BrowserEntry] {
        try await runOnQueueThrowing {
            var entriesPtr: UnsafeMutablePointer<PTIOSFileEntry>?
            var count: Int32 = 0
            var errPtr: UnsafeMutablePointer<CChar>?

            let rc = udid.withCString { cUdid in
                path.withCString { cPath in
                    if let appBundleID {
                        return appBundleID.withCString { cBundle in
                            pt_ios_list_directory(cUdid, cBundle, cPath, &entriesPtr, &count, &errPtr)
                        }
                    } else {
                        return pt_ios_list_directory(cUdid, nil, cPath, &entriesPtr, &count, &errPtr)
                    }
                }
            }

            defer {
                if let entriesPtr { pt_ios_free_entries(entriesPtr, count) }
                if let errPtr { pt_free_string(errPtr) }
            }

            if rc != 0 {
                let msg = errPtr.map { String(cString: $0) } ?? "Failed to read iOS folder."
                throw IOSDeviceError.operationFailed(msg)
            }

            var items: [BrowserEntry] = []
            if let entriesPtr, count > 0 {
                for i in 0..<Int(count) {
                    let e = entriesPtr[i]
                    let name = e.name.map { String(cString: $0) } ?? "Unnamed"
                    let hidden = name.hasPrefix(".")
                    if !showHidden && hidden {
                        continue
                    }

                    let childPath = path == "/" ? "/\(name)" : "\(path)/\(name)"
                    items.append(
                        BrowserEntry(
                            id: "ios::\(udid)::\(appBundleID ?? "afc")::\(childPath)",
                            name: name,
                            isDirectory: e.is_directory,
                            isPackage: false,
                            size: e.is_directory ? 0 : Int64(clamping: e.size),
                            modifiedDate: e.modified_timestamp > 0
                                ? Date(timeIntervalSince1970: TimeInterval(e.modified_timestamp))
                                : Date.distantPast,
                            isHidden: hidden,
                            location: .ios(udid: udid, appBundleID: appBundleID, path: childPath),
                            remotePath: childPath
                        )
                    )
                }
            }

            return FormattingHelpers.sortBrowserEntries(items, by: sortBy, ascending: ascending)
        }
    }

    public func createDirectory(udid: String, appBundleID: String?, remotePath: String) async throws {
        try await runOnQueueThrowing {
            var errPtr: UnsafeMutablePointer<CChar>?
            let rc = udid.withCString { cUdid in
                remotePath.withCString { cPath in
                    if let appBundleID {
                        return appBundleID.withCString { cBundle in
                            pt_ios_create_directory(cUdid, cBundle, cPath, &errPtr)
                        }
                    } else {
                        return pt_ios_create_directory(cUdid, nil, cPath, &errPtr)
                    }
                }
            }
            defer { if let errPtr { pt_free_string(errPtr) } }
            if rc != 0 {
                throw IOSDeviceError.operationFailed(errPtr.map { String(cString: $0) } ?? "Could not create iOS folder.")
            }
        }
    }

    public func rename(udid: String, appBundleID: String?, fromPath: String, toPath: String) async throws {
        try await runOnQueueThrowing {
            var errPtr: UnsafeMutablePointer<CChar>?
            let rc = udid.withCString { cUdid in
                fromPath.withCString { cFrom in
                    toPath.withCString { cTo in
                        if let appBundleID {
                            return appBundleID.withCString { cBundle in
                                pt_ios_rename_path(cUdid, cBundle, cFrom, cTo, &errPtr)
                            }
                        } else {
                            return pt_ios_rename_path(cUdid, nil, cFrom, cTo, &errPtr)
                        }
                    }
                }
            }
            defer { if let errPtr { pt_free_string(errPtr) } }
            if rc != 0 {
                throw IOSDeviceError.operationFailed(errPtr.map { String(cString: $0) } ?? "Could not rename iOS item.")
            }
        }
    }

    public func delete(udid: String, appBundleID: String?, remotePath: String) async throws {
        try await runOnQueueThrowing {
            var errPtr: UnsafeMutablePointer<CChar>?
            let rc = udid.withCString { cUdid in
                remotePath.withCString { cPath in
                    if let appBundleID {
                        return appBundleID.withCString { cBundle in
                            pt_ios_delete_path(cUdid, cBundle, cPath, &errPtr)
                        }
                    } else {
                        return pt_ios_delete_path(cUdid, nil, cPath, &errPtr)
                    }
                }
            }
            defer { if let errPtr { pt_free_string(errPtr) } }
            if rc != 0 {
                throw IOSDeviceError.operationFailed(errPtr.map { String(cString: $0) } ?? "Could not delete iOS item.")
            }
        }
    }

    public func downloadFile(
        udid: String,
        appBundleID: String?,
        remotePath: String,
        toLocalURL localURL: URL,
        expectedSize: Int64,
        control: TransferControl,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        try await runOnQueueThrowing {
            let box = IOSProgressContext(control: control, callback: onProgress)
            let retained = Unmanaged.passRetained(box)
            defer { retained.release() }

            var errPtr: UnsafeMutablePointer<CChar>?
            let rc = udid.withCString { cUdid in
                remotePath.withCString { cRemote in
                    localURL.path.withCString { cLocal in
                        if let appBundleID {
                            return appBundleID.withCString { cBundle in
                                pt_ios_download_file(
                                    cUdid,
                                    cBundle,
                                    cRemote,
                                    cLocal,
                                    UInt64(max(0, expectedSize)),
                                    iosCProgressCallback,
                                    retained.toOpaque(),
                                    &errPtr
                                )
                            }
                        } else {
                            return pt_ios_download_file(
                                cUdid,
                                nil,
                                cRemote,
                                cLocal,
                                UInt64(max(0, expectedSize)),
                                iosCProgressCallback,
                                retained.toOpaque(),
                                &errPtr
                            )
                        }
                    }
                }
            }
            defer { if let errPtr { pt_free_string(errPtr) } }

            if rc == -2 || control.isCancelled {
                throw IOSDeviceError.cancelled
            }
            if rc != 0 {
                throw IOSDeviceError.operationFailed(errPtr.map { String(cString: $0) } ?? "iOS download failed.")
            }
        }
    }

    public func uploadFile(
        udid: String,
        appBundleID: String?,
        fromLocalURL localURL: URL,
        remotePath: String,
        fileSize: Int64,
        control: TransferControl,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        try await runOnQueueThrowing {
            let box = IOSProgressContext(control: control, callback: onProgress)
            let retained = Unmanaged.passRetained(box)
            defer { retained.release() }

            var errPtr: UnsafeMutablePointer<CChar>?
            let rc = udid.withCString { cUdid in
                localURL.path.withCString { cLocal in
                    remotePath.withCString { cRemote in
                        if let appBundleID {
                            return appBundleID.withCString { cBundle in
                                pt_ios_upload_file(
                                    cUdid,
                                    cBundle,
                                    cLocal,
                                    cRemote,
                                    UInt64(max(0, fileSize)),
                                    iosCProgressCallback,
                                    retained.toOpaque(),
                                    &errPtr
                                )
                            }
                        } else {
                            return pt_ios_upload_file(
                                cUdid,
                                nil,
                                cLocal,
                                cRemote,
                                UInt64(max(0, fileSize)),
                                iosCProgressCallback,
                                retained.toOpaque(),
                                &errPtr
                            )
                        }
                    }
                }
            }
            defer { if let errPtr { pt_free_string(errPtr) } }

            if rc == -2 || control.isCancelled {
                throw IOSDeviceError.cancelled
            }
            if rc != 0 {
                throw IOSDeviceError.operationFailed(errPtr.map { String(cString: $0) } ?? "iOS upload failed.")
            }
        }
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
