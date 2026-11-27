import Foundation

/// Executes file and folder transfers across any combination of Mac, Pendrives, Android (MTP/ADB), and iOS (Media/Apps).
public final class UnifiedTransferService: Sendable {
    private let localEngine = TransferEngine()
    private let mtpService: AndroidMTPService
    private let adbService: AndroidADBService
    private let iosService: IOSDeviceService

    public init(
        mtpService: AndroidMTPService,
        adbService: AndroidADBService,
        iosService: IOSDeviceService
    ) {
        self.mtpService = mtpService
        self.adbService = adbService
        self.iosService = iosService
    }

    public func listEntries(
        at location: RemoteLocation,
        showHidden: Bool,
        sortBy: SortField,
        ascending: Bool
    ) async throws -> [BrowserEntry] {
        switch location {
        case .local(let url):
            let items = try FileBrowserService.listContents(
                of: url,
                showHidden: showHidden,
                sortBy: sortBy,
                ascending: ascending
            )
            return items.map { BrowserEntry(fileItem: $0) }

        case .mtp(let bus, let dev, let storageID, let folderID, let trail):
            return try await mtpService.listFolder(
                busLocation: bus,
                devNum: dev,
                storageID: storageID,
                folderID: folderID,
                trail: trail,
                showHidden: showHidden,
                sortBy: sortBy,
                ascending: ascending
            )

        case .adb(let serial, let path):
            return try await adbService.listDirectory(
                serial: serial,
                path: path,
                showHidden: showHidden,
                sortBy: sortBy,
                ascending: ascending
            )

        case .ios(let udid, let bundleID, let path):
            return try await iosService.listDirectory(
                udid: udid,
                appBundleID: bundleID,
                path: path,
                showHidden: showHidden,
                sortBy: sortBy,
                ascending: ascending
            )
        }
    }

    public func createFolder(named rawName: String, in parent: RemoteLocation) async throws {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard FileBrowserService.isValidFileName(name) else {
            throw FileBrowserError.invalidName
        }

        switch parent {
        case .local(let url):
            _ = try FileBrowserService.createFolder(named: name, in: url)
        case .mtp(let bus, let dev, let storageID, let folderID, _):
            _ = try await mtpService.createFolder(
                busLocation: bus,
                devNum: dev,
                storageID: storageID,
                parentFolderID: folderID,
                name: name
            )
        case .adb(let serial, let path):
            let child = path == "/" ? "/\(name)" : "\(path)/\(name)"
            try await adbService.createDirectory(serial: serial, remotePath: child)
        case .ios(let udid, let bundleID, let path):
            let child = path == "/" ? "/\(name)" : "\(path)/\(name)"
            try await iosService.createDirectory(udid: udid, appBundleID: bundleID, remotePath: child)
        }
    }

    public func rename(entry: BrowserEntry, in parent: RemoteLocation, to rawNewName: String) async throws {
        let newName = rawNewName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard FileBrowserService.isValidFileName(newName) else {
            throw FileBrowserError.invalidName
        }

        switch parent {
        case .local:
            guard let url = entry.localURL else { return }
            _ = try FileBrowserService.renameItem(at: url, to: newName)
        case .mtp(let bus, let dev, _, _, _):
            guard let objectID = entry.mtpObjectID else { return }
            try await mtpService.renameObject(busLocation: bus, devNum: dev, objectID: objectID, newName: newName)
        case .adb(let serial, let dirPath):
            let fromPath = entry.remotePath ?? (dirPath == "/" ? "/\(entry.name)" : "\(dirPath)/\(entry.name)")
            let toPath = dirPath == "/" ? "/\(newName)" : "\(dirPath)/\(newName)"
            try await adbService.rename(serial: serial, fromPath: fromPath, toPath: toPath)
        case .ios(let udid, let bundleID, let dirPath):
            let fromPath = entry.remotePath ?? (dirPath == "/" ? "/\(entry.name)" : "\(dirPath)/\(entry.name)")
            let toPath = dirPath == "/" ? "/\(newName)" : "\(dirPath)/\(newName)"
            try await iosService.rename(udid: udid, appBundleID: bundleID, fromPath: fromPath, toPath: toPath)
        }
    }

    public func delete(entries: [BrowserEntry], from parent: RemoteLocation, permanentlyIfTrashUnavailable: Bool) async throws {
        for entry in entries {
            switch parent {
            case .local:
                guard let url = entry.localURL else { continue }
                try FileBrowserService.removeItem(at: url, permanentlyIfTrashUnavailable: permanentlyIfTrashUnavailable)
            case .mtp(let bus, let dev, _, _, _):
                guard let objectID = entry.mtpObjectID else { continue }
                try await mtpService.deleteObject(busLocation: bus, devNum: dev, objectID: objectID)
            case .adb(let serial, let dirPath):
                let target = entry.remotePath ?? (dirPath == "/" ? "/\(entry.name)" : "\(dirPath)/\(entry.name)")
                try await adbService.delete(serial: serial, remotePath: target)
            case .ios(let udid, let bundleID, let dirPath):
                let target = entry.remotePath ?? (dirPath == "/" ? "/\(entry.name)" : "\(dirPath)/\(entry.name)")
                try await iosService.delete(udid: udid, appBundleID: bundleID, remotePath: target)
            }
        }
    }

    public func execute(
        entries: [BrowserEntry],
        from sourceEndpoint: StorageEndpoint,
        sourceParent: RemoteLocation,
        to destinationEndpoint: StorageEndpoint,
        destinationDirectory: RemoteLocation,
        mode: TransferMode,
        conflictPolicy: ConflictPolicy,
        control: TransferControl,
        onProgress: @escaping @Sendable (TransferProgressSnapshot) async -> Void,
        onConflict: @escaping @Sendable (ConflictPrompt) async -> (ConflictResolution, applyToAll: Bool)
    ) async throws -> (filesCompleted: Int, filesSkipped: Int) {
        guard !entries.isEmpty else {
            throw TransferError.emptySelection
        }
        if destinationEndpoint.isReadOnly {
            throw TransferError.readOnlyDestination(destinationEndpoint.name)
        }
        if mode == .move && sourceEndpoint.isReadOnly {
            throw TransferError.readOnlyDestination(sourceEndpoint.name)
        }

        // Fast native local-to-local path (Mac <-> Pendrive, Mac <-> Mac, Pendrive <-> Pendrive)
        if let destURL = destinationDirectory.localURL,
           entries.allSatisfy({ $0.localURL != nil })
        {
            let urls = entries.compactMap(\.localURL)
            return try await localEngine.execute(
                sources: urls,
                destinationDirectory: destURL,
                mode: mode,
                conflictPolicy: conflictPolicy,
                destinationFileSystemHint: destinationEndpoint.driveInfo?.fileSystemName,
                control: control,
                onProgress: onProgress,
                onConflict: onConflict
            )
        }

        // Expand source tree across any endpoint type.
        let plan = try await expandSourcePlan(entries: entries, sourceParent: sourceParent)
        let totalBytes = plan.files.reduce(Int64(0)) { $0 + $1.size }
        let totalFiles = plan.files.count

        if destinationEndpoint.availableBytes > 0 && totalBytes > destinationEndpoint.availableBytes {
            throw TransferError.insufficientSpace(required: totalBytes, available: destinationEndpoint.availableBytes)
        }

        var policy = conflictPolicy
        let tracker = UnifiedProgressTracker(totalBytes: totalBytes, totalFiles: totalFiles)
        var successfullyTransferredSources: [PlannedRemoteFile] = []
        var skippedRootIDs: Set<String> = []

        await onProgress(tracker.snapshot(currentFileName: plan.files.first?.name ?? ""))

        // Ensure remote/local subdirectories exist first.
        var createdFolderCache: [String: RemoteLocation] = ["": destinationDirectory]
        for dir in plan.directories {
            try await control.waitIfPaused()
            _ = try await ensureDirectory(
                relativeComponents: dir.relativeComponents,
                under: destinationDirectory,
                cache: &createdFolderCache
            )
        }

        let stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("UniBridgeStage-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stagingRoot) }

        for file in plan.files {
            try await control.waitIfPaused()

            let destFolder = try await ensureDirectory(
                relativeComponents: file.parentComponents,
                under: destinationDirectory,
                cache: &createdFolderCache
            )

            var targetName = file.name
            let existingInfo = try await inspectDestinationEntry(named: targetName, inside: destFolder)
            if let existingInfo {
                let resolution: ConflictResolution
                switch policy {
                case .ask:
                    let dummySrcURL = file.localURL ?? URL(fileURLWithPath: "/\(file.name)")
                    let dummyDstURL = destFolder.localURL?.appendingPathComponent(targetName)
                        ?? URL(fileURLWithPath: "\(destFolder.displayPath)/\(targetName)")
                    let prompt = ConflictPrompt(
                        sourceURL: dummySrcURL,
                        destinationURL: dummyDstURL,
                        sourceName: file.name,
                        destinationPathDisplay: "\(destinationEndpoint.name): \(destFolder.displayPath)/\(targetName)",
                        sourceSize: file.size,
                        destinationSize: existingInfo.size,
                        sourceDate: file.modifiedDate,
                        destinationDate: existingInfo.modifiedDate
                    )
                    let decision = await onConflict(prompt)
                    resolution = decision.0
                    if decision.applyToAll {
                        switch resolution {
                        case .replace: policy = .replace
                        case .skip: policy = .skip
                        case .keepBoth: policy = .keepBoth
                        case .cancelAll: break
                        }
                    }
                case .replace: resolution = .replace
                case .skip: resolution = .skip
                case .keepBoth: resolution = .keepBoth
                }

                switch resolution {
                case .cancelAll:
                    control.cancel()
                    throw TransferError.cancelled
                case .skip:
                    tracker.recordSkip(bytes: file.size)
                    skippedRootIDs.insert(file.rootEntryID)
                    await onProgress(tracker.snapshot(currentFileName: file.name))
                    continue
                case .keepBoth:
                    targetName = try await uniqueRemoteName(for: targetName, inside: destFolder)
                case .replace:
                    // Delete existing entry before uploading/replacing on remote endpoints like MTP.
                    if destFolder.localURL == nil, let existingEntry = existingInfo.entry {
                        try await delete(entries: [existingEntry], from: destFolder, permanentlyIfTrashUnavailable: true)
                    }
                }
            }

            let fileStartOffset = tracker.completedBytes
            let fileName = file.name
            let reportFileBytes: @Sendable (Int64) -> Void = { fileBytes in
                if let snap = tracker.updateCurrentFileProgress(
                    fileStartOffset: fileStartOffset,
                    currentFileBytes: fileBytes,
                    currentFileName: fileName
                ) {
                    Task { await onProgress(snap) }
                }
            }

            try await transferSingleFile(
                file: file,
                targetName: targetName,
                destFolder: destFolder,
                stagingRoot: stagingRoot,
                control: control,
                onFileProgress: reportFileBytes
            )

            tracker.recordFileCompleted(bytes: file.size)
            successfullyTransferredSources.append(file)

            await onProgress(tracker.snapshot(currentFileName: file.name))
        }

        if mode == .move {
            for movedFile in successfullyTransferredSources {
                try await deleteSinglePlannedSource(movedFile)
            }
            for root in entries where root.isDirectory && !skippedRootIDs.contains(root.id) {
                try? await delete(entries: [root], from: sourceParent, permanentlyIfTrashUnavailable: true)
            }
        }

        return tracker.finalCounts()
    }

    // MARK: - Helpers

    private struct PlannedRemoteDir {
        let relativeComponents: [String]
    }

    private struct PlannedRemoteFile {
        let rootEntryID: String
        let name: String
        let size: Int64
        let modifiedDate: Date
        let parentComponents: [String]
        let localURL: URL?
        let mtpSource: (bus: UInt32, dev: UInt8, objectID: UInt32)?
        let adbSource: (serial: String, path: String)?
        let iosSource: (udid: String, bundleID: String?, path: String)?

        var parentRelativePath: String {
            parentComponents.joined(separator: "/")
        }
    }

    private func expandSourcePlan(
        entries: [BrowserEntry],
        sourceParent: RemoteLocation
    ) async throws -> (directories: [PlannedRemoteDir], files: [PlannedRemoteFile]) {
        var directories: [PlannedRemoteDir] = []
        var files: [PlannedRemoteFile] = []

        func walk(entry: BrowserEntry, parentComponents: [String], rootID: String) async throws {
            if !entry.isDirectory || entry.isPackage {
                let mtpTuple: (UInt32, UInt8, UInt32)?
                let adbTuple: (String, String)?
                let iosTuple: (String, String?, String)?

                switch sourceParent {
                case .mtp(let bus, let dev, _, _, _):
                    mtpTuple = entry.mtpObjectID.map { (bus, dev, $0) }
                    adbTuple = nil
                    iosTuple = nil
                case .adb(let serial, _):
                    mtpTuple = nil
                    adbTuple = (serial, entry.remotePath ?? entry.location.displayPath)
                    iosTuple = nil
                case .ios(let udid, let bundleID, _):
                    mtpTuple = nil
                    adbTuple = nil
                    iosTuple = (udid, bundleID, entry.remotePath ?? entry.location.displayPath)
                case .local:
                    mtpTuple = nil
                    adbTuple = nil
                    iosTuple = nil
                }

                // Wait: for local packages (e.g. .app), copy recursively if local, otherwise treat regular files.
                if case .local(let url) = entry.location, entry.isDirectory {
                    // Expand local bundle recursively as directory + files
                    try walkLocalDirectory(url: url, currentComponents: parentComponents + [entry.name], rootID: rootID)
                    return
                }

                files.append(
                    PlannedRemoteFile(
                        rootEntryID: rootID,
                        name: entry.name,
                        size: entry.size,
                        modifiedDate: entry.modifiedDate,
                        parentComponents: parentComponents,
                        localURL: entry.localURL,
                        mtpSource: mtpTuple,
                        adbSource: adbTuple,
                        iosSource: iosTuple
                    )
                )
                return
            }

            let dirComponents = parentComponents + [entry.name]
            directories.append(PlannedRemoteDir(relativeComponents: dirComponents))

            if case .local(let url) = entry.location {
                try walkLocalDirectory(url: url, currentComponents: dirComponents, rootID: rootID)
                return
            }

            let children = try await listEntries(
                at: entry.location,
                showHidden: true,
                sortBy: .name,
                ascending: true
            )
            for child in children {
                try await walk(entry: child, parentComponents: dirComponents, rootID: rootID)
            }
        }

        func walkLocalDirectory(url: URL, currentComponents: [String], rootID: String) throws {
            let children = try FileBrowserService.listContents(of: url, showHidden: true, sortBy: .name, ascending: true)
            for item in children {
                if item.isDirectory {
                    let sub = currentComponents + [item.name]
                    directories.append(PlannedRemoteDir(relativeComponents: sub))
                    try walkLocalDirectory(url: item.url, currentComponents: sub, rootID: rootID)
                } else {
                    files.append(
                        PlannedRemoteFile(
                            rootEntryID: rootID,
                            name: item.name,
                            size: item.size,
                            modifiedDate: item.modifiedDate,
                            parentComponents: currentComponents,
                            localURL: item.url,
                            mtpSource: nil,
                            adbSource: nil,
                            iosSource: nil
                        )
                    )
                }
            }
        }

        for entry in entries {
            try await walk(entry: entry, parentComponents: [], rootID: entry.id)
        }
        return (directories, files)
    }

    private func ensureDirectory(
        relativeComponents: [String],
        under root: RemoteLocation,
        cache: inout [String: RemoteLocation]
    ) async throws -> RemoteLocation {
        if relativeComponents.isEmpty {
            return root
        }
        let key = relativeComponents.joined(separator: "/")
        if let hit = cache[key] {
            return hit
        }

        let parent = try await ensureDirectory(
            relativeComponents: Array(relativeComponents.dropLast()),
            under: root,
            cache: &cache
        )
        let folderName = relativeComponents.last!

        let resolved: RemoteLocation
        switch parent {
        case .local(let parentURL):
            let childURL = parentURL.appendingPathComponent(folderName, isDirectory: true)
            if !FileManager.default.fileExists(atPath: childURL.path) {
                try FileManager.default.createDirectory(at: childURL, withIntermediateDirectories: true)
            }
            resolved = .local(childURL)

        case .mtp(let bus, let dev, let storageID, let parentFolderID, let trail):
            let existing = try await mtpService.listFolder(
                busLocation: bus,
                devNum: dev,
                storageID: storageID,
                folderID: parentFolderID,
                trail: trail,
                showHidden: true,
                sortBy: .name,
                ascending: true
            )
            if let match = existing.first(where: { $0.isDirectory && $0.name == folderName }) {
                resolved = match.location
            } else {
                let newID = try await mtpService.createFolder(
                    busLocation: bus,
                    devNum: dev,
                    storageID: storageID,
                    parentFolderID: parentFolderID,
                    name: folderName
                )
                resolved = .mtp(
                    busLocation: bus,
                    devNum: dev,
                    storageID: storageID,
                    folderID: newID,
                    trail: trail + [MTPPathSegment(folderID: newID, name: folderName)]
                )
            }

        case .adb(let serial, let parentPath):
            let childPath = parentPath == "/" ? "/\(folderName)" : "\(parentPath)/\(folderName)"
            try await adbService.createDirectory(serial: serial, remotePath: childPath)
            resolved = .adb(serial: serial, path: childPath)

        case .ios(let udid, let bundleID, let parentPath):
            let childPath = parentPath == "/" ? "/\(folderName)" : "\(parentPath)/\(folderName)"
            let existing = try await iosService.listDirectory(
                udid: udid,
                appBundleID: bundleID,
                path: parentPath,
                showHidden: true,
                sortBy: .name,
                ascending: true
            )
            if !existing.contains(where: { $0.name == folderName }) {
                try await iosService.createDirectory(udid: udid, appBundleID: bundleID, remotePath: childPath)
            }
            resolved = .ios(udid: udid, appBundleID: bundleID, path: childPath)
        }

        cache[key] = resolved
        return resolved
    }

    private func inspectDestinationEntry(
        named name: String,
        inside directory: RemoteLocation
    ) async throws -> (size: Int64, modifiedDate: Date?, entry: BrowserEntry?)? {
        if let dirURL = directory.localURL {
            let candidate = dirURL.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: candidate.path) else { return nil }
            let attrs = try? FileManager.default.attributesOfItem(atPath: candidate.path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            let mod = attrs?[.modificationDate] as? Date
            return (size, mod, nil)
        }

        let items = try await listEntries(at: directory, showHidden: true, sortBy: .name, ascending: true)
        guard let hit = items.first(where: { $0.name == name }) else { return nil }
        return (hit.size, hit.modifiedDate, hit)
    }

    private func uniqueRemoteName(for preferred: String, inside directory: RemoteLocation) async throws -> String {
        let items = try await listEntries(at: directory, showHidden: true, sortBy: .name, ascending: true)
        let existingNames = Set(items.map(\.name))
        if !existingNames.contains(preferred) {
            return preferred
        }
        let ns = preferred as NSString
        let ext = ns.pathExtension
        let stem = ext.isEmpty ? preferred : ns.deletingPathExtension
        var counter = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem) (\(counter))" : "\(stem) (\(counter)).\(ext)"
            if !existingNames.contains(candidate) {
                return candidate
            }
            counter += 1
        }
    }

    private func transferSingleFile(
        file: PlannedRemoteFile,
        targetName: String,
        destFolder: RemoteLocation,
        stagingRoot: URL,
        control: TransferControl,
        onFileProgress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        // 1. Obtain a local source URL (either direct local file or downloaded into stagingRoot).
        let localSourceURL: URL
        var tempDownloadURL: URL?

        if let directLocal = file.localURL {
            localSourceURL = directLocal
        } else if let destDirURL = destFolder.localURL {
            // Remote -> Local directly into a .part staging file in destination directory!
            let finalURL = destDirURL.appendingPathComponent(targetName)
            let partURL = destDirURL.appendingPathComponent(".unibridge.\(UUID().uuidString).part")
            do {
                try await downloadRemoteFile(file: file, toLocalURL: partURL, control: control, onFileProgress: onFileProgress)
                if FileManager.default.fileExists(atPath: finalURL.path) {
                    try FileManager.default.removeItem(at: finalURL)
                }
                try FileManager.default.moveItem(at: partURL, to: finalURL)
            } catch {
                try? FileManager.default.removeItem(at: partURL)
                throw error
            }
            return
        } else {
            // Remote -> Remote: stage through temporary local file.
            let staged = stagingRoot.appendingPathComponent("\(UUID().uuidString)-\(targetName)")
            tempDownloadURL = staged
            try await downloadRemoteFile(file: file, toLocalURL: staged, control: control) { downloaded in
                onFileProgress(downloaded / 2)
            }
            localSourceURL = staged
        }

        defer {
            if let tempDownloadURL {
                try? FileManager.default.removeItem(at: tempDownloadURL)
            }
        }

        let uploadSize = (try? FileManager.default.attributesOfItem(atPath: localSourceURL.path)[.size] as? NSNumber)?.int64Value ?? file.size
        let isStaged = tempDownloadURL != nil

        // 2. Upload localSourceURL to remote destination.
        switch destFolder {
        case .local:
            // Already handled above
            break
        case .mtp(let bus, let dev, let storageID, let parentFolderID, _):
            _ = try await mtpService.uploadFile(
                busLocation: bus,
                devNum: dev,
                storageID: storageID,
                parentFolderID: parentFolderID,
                fromLocalURL: localSourceURL,
                filename: targetName,
                fileSize: uploadSize,
                control: control
            ) { uploaded, _ in
                onFileProgress(isStaged ? (uploadSize / 2 + uploaded / 2) : uploaded)
            }
        case .adb(let serial, let dirPath):
            let remoteTarget = dirPath == "/" ? "/\(targetName)" : "\(dirPath)/\(targetName)"
            try await adbService.pushFile(
                serial: serial,
                fromLocalURL: localSourceURL,
                remotePath: remoteTarget,
                fileSize: uploadSize,
                control: control
            ) { uploaded in
                onFileProgress(isStaged ? (uploadSize / 2 + uploaded / 2) : uploaded)
            }
        case .ios(let udid, let bundleID, let dirPath):
            let remoteTarget = dirPath == "/" ? "/\(targetName)" : "\(dirPath)/\(targetName)"
            try await iosService.uploadFile(
                udid: udid,
                appBundleID: bundleID,
                fromLocalURL: localSourceURL,
                remotePath: remoteTarget,
                fileSize: uploadSize,
                control: control
            ) { uploaded, _ in
                onFileProgress(isStaged ? (uploadSize / 2 + uploaded / 2) : uploaded)
            }
        }
    }

    private func downloadRemoteFile(
        file: PlannedRemoteFile,
        toLocalURL localURL: URL,
        control: TransferControl,
        onFileProgress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        if let mtp = file.mtpSource {
            try await mtpService.downloadFile(
                busLocation: mtp.bus,
                devNum: mtp.dev,
                objectID: mtp.objectID,
                toLocalURL: localURL,
                control: control
            ) { downloaded, _ in
                onFileProgress(downloaded)
            }
        } else if let adb = file.adbSource {
            try await adbService.pullFile(
                serial: adb.serial,
                remotePath: adb.path,
                toLocalURL: localURL,
                expectedSize: file.size,
                control: control,
                onProgress: onFileProgress
            )
        } else if let ios = file.iosSource {
            try await iosService.downloadFile(
                udid: ios.udid,
                appBundleID: ios.bundleID,
                remotePath: ios.path,
                toLocalURL: localURL,
                expectedSize: file.size,
                control: control
            ) { downloaded, _ in
                onFileProgress(downloaded)
            }
        }
    }

    private func deleteSinglePlannedSource(_ file: PlannedRemoteFile) async throws {
        if let local = file.localURL {
            try FileManager.default.removeItem(at: local)
        } else if let mtp = file.mtpSource {
            try await mtpService.deleteObject(busLocation: mtp.bus, devNum: mtp.dev, objectID: mtp.objectID)
        } else if let adb = file.adbSource {
            try await adbService.delete(serial: adb.serial, remotePath: adb.path)
        } else if let ios = file.iosSource {
            try await iosService.delete(udid: ios.udid, appBundleID: ios.bundleID, remotePath: ios.path)
        }
    }

    private static func eta(remaining: Int64, speed: Double) -> Double? {
        guard remaining > 0, speed > 1024 else { return nil }
        return Double(remaining) / speed
    }
}

private final class UnifiedProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let totalBytes: Int64
    private let totalFiles: Int
    private var bytesCompleted: Int64 = 0
    private var filesCompleted: Int = 0
    private var filesSkipped: Int = 0
    private var emaSpeed: Double = 0
    private var lastSampleTime = Date()
    private var lastSampleBytes: Int64 = 0

    init(totalBytes: Int64, totalFiles: Int) {
        self.totalBytes = totalBytes
        self.totalFiles = totalFiles
    }

    var completedBytes: Int64 {
        lock.withLock { bytesCompleted }
    }

    func recordSkip(bytes: Int64) {
        lock.withLock {
            filesSkipped += 1
            bytesCompleted += bytes
        }
    }

    func recordFileCompleted(bytes: Int64) {
        lock.withLock {
            filesCompleted += 1
            bytesCompleted += bytes
        }
    }

    func updateCurrentFileProgress(
        fileStartOffset: Int64,
        currentFileBytes: Int64,
        currentFileName: String
    ) -> TransferProgressSnapshot? {
        lock.withLock {
            let totalNow = min(totalBytes, fileStartOffset + currentFileBytes)
            let now = Date()
            let dt = now.timeIntervalSince(lastSampleTime)
            guard dt >= 0.15 else { return nil }
            let delta = max(0, totalNow - lastSampleBytes)
            let instant = Double(delta) / dt
            emaSpeed = emaSpeed == 0 ? instant : (0.3 * instant + 0.7 * emaSpeed)
            lastSampleTime = now
            lastSampleBytes = totalNow

            let remaining = max(0, totalBytes - totalNow)
            let eta = (remaining > 0 && emaSpeed > 1024) ? Double(remaining) / emaSpeed : nil
            return TransferProgressSnapshot(
                totalBytes: totalBytes,
                bytesTransferred: totalNow,
                totalFiles: totalFiles,
                filesCompleted: filesCompleted,
                filesSkipped: filesSkipped,
                currentFileName: currentFileName,
                speedBytesPerSecond: emaSpeed,
                estimatedSecondsRemaining: eta
            )
        }
    }

    func snapshot(currentFileName: String) -> TransferProgressSnapshot {
        lock.withLock {
            let remaining = max(0, totalBytes - bytesCompleted)
            let eta = (remaining > 0 && emaSpeed > 1024) ? Double(remaining) / emaSpeed : nil
            return TransferProgressSnapshot(
                totalBytes: totalBytes,
                bytesTransferred: bytesCompleted,
                totalFiles: totalFiles,
                filesCompleted: filesCompleted,
                filesSkipped: filesSkipped,
                currentFileName: currentFileName,
                speedBytesPerSecond: emaSpeed,
                estimatedSecondsRemaining: eta
            )
        }
    }

    func finalCounts() -> (filesCompleted: Int, filesSkipped: Int) {
        lock.withLock { (filesCompleted, filesSkipped) }
    }
}
