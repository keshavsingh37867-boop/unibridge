import Foundation

public enum TransferError: LocalizedError, Sendable {
    case emptySelection
    case readOnlyDestination(String)
    case destinationInsideSource(String)
    case fat32FileTooLarge(fileName: String, size: Int64)
    case insufficientSpace(required: Int64, available: Int64)
    case ioError(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .emptySelection:
            return "No files or folders selected."
        case .readOnlyDestination(let volumeName):
            return "\(volumeName) is mounted read-only (e.g. NTFS or locked drive) and cannot receive files."
        case .destinationInsideSource(let name):
            return "Cannot transfer '\(name)' into itself or one of its subfolders."
        case .fat32FileTooLarge(let fileName, let size):
            let formatted = FormattingHelpers.formatByteCount(size)
            return "'\(fileName)' (\(formatted)) exceeds the 4 GB FAT32 file size limit. Format the pendrive as exFAT or APFS for larger files."
        case .insufficientSpace(let required, let available):
            let req = FormattingHelpers.formatByteCount(required)
            let avail = FormattingHelpers.formatByteCount(available)
            return "Not enough free space on destination (\(avail) available, \(req) required)."
        case .ioError(let message):
            return message
        case .cancelled:
            return "Transfer cancelled."
        }
    }
}

/// Thread-safe pause/cancel gate checked between streaming chunks so pause/resume and cancel
/// react within milliseconds without busy-waiting.
public final class TransferControl: @unchecked Sendable {
    private let lock = NSLock()
    private var paused = false
    private var cancelled = false
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public var isPaused: Bool {
        lock.withLock { paused }
    }

    public var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    public func pause() {
        lock.withLock {
            if !cancelled {
                paused = true
            }
        }
    }

    public func resume() {
        let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
            paused = false
            let list = pauseWaiters
            pauseWaiters.removeAll()
            return list
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    public func cancel() {
        let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
            cancelled = true
            paused = false
            let list = pauseWaiters
            pauseWaiters.removeAll()
            return list
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    public func waitIfPaused() async throws {
        if isCancelled {
            throw TransferError.cancelled
        }
        let shouldWait = lock.withLock { paused && !cancelled }
        if shouldWait {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeImmediately = lock.withLock {
                    if paused && !cancelled {
                        pauseWaiters.append(continuation)
                        return false
                    }
                    return true
                }
                if resumeImmediately {
                    continuation.resume()
                }
            }
        }
        if isCancelled {
            throw TransferError.cancelled
        }
    }
}

public struct TransferProgressSnapshot: Sendable {
    public let totalBytes: Int64
    public let bytesTransferred: Int64
    public let totalFiles: Int
    public let filesCompleted: Int
    public let filesSkipped: Int
    public let currentFileName: String
    public let speedBytesPerSecond: Double
    public let estimatedSecondsRemaining: Double?
}

/// Chunked file/folder transfer engine supporting real-time speed/ETA, pause/resume, cancel cleanup,
/// conflict policies, FAT32 4GB guards, free-space validation, and safe cross-volume move semantics.
public final class TransferEngine: Sendable {
    private static let fat32MaxFileBytes: Int64 = 4_294_967_295
    private let chunkSize: Int
    private let allowSameVolumeMoveShortcut: Bool

    public init(chunkSize: Int = 1_048_576, allowSameVolumeMoveShortcut: Bool = true) {
        self.chunkSize = max(65_536, chunkSize)
        self.allowSameVolumeMoveShortcut = allowSameVolumeMoveShortcut
    }

    public func execute(
        sources: [URL],
        destinationDirectory: URL,
        mode: TransferMode,
        conflictPolicy: ConflictPolicy,
        destinationFileSystemHint: String? = nil,
        control: TransferControl,
        onProgress: @escaping @Sendable (TransferProgressSnapshot) async -> Void,
        onConflict: @escaping @Sendable (ConflictPrompt) async -> (ConflictResolution, applyToAll: Bool)
    ) async throws -> (filesCompleted: Int, filesSkipped: Int) {
        guard !sources.isEmpty else {
            throw TransferError.emptySelection
        }

        let fm = FileManager.default
        let destStandard = destinationDirectory.standardizedFileURL

        let spaceInfo = FileBrowserService.volumeSpaceInfo(for: destinationDirectory)
        if spaceInfo.readOnly {
            throw TransferError.readOnlyDestination(destinationDirectory.lastPathComponent)
        }

        // Prevent transferring a directory into itself or any nested subfolder.
        for source in sources {
            let srcStandard = source.standardizedFileURL
            if destStandard == srcStandard || destStandard.path.hasPrefix(srcStandard.path + "/") {
                throw TransferError.destinationInsideSource(source.lastPathComponent)
            }
        }

        let isDestFAT32 = {
            let fs = (destinationFileSystemHint ?? spaceInfo.fileSystem).lowercased()
            return fs.contains("fat32") || fs.contains("ms-dos") || fs == "msdos"
        }()

        // Expand directory trees on a background thread.
        let plan = try await Task.detached(priority: .userInitiated) {
            try Self.buildPlan(
                sources: sources,
                destinationDirectory: destinationDirectory,
                isDestFAT32: isDestFAT32
            )
        }.value

        // Check destination free space when copying or moving across volumes.
        let sameVolume = Self.areOnSameVolume(sources.first!, destinationDirectory)
        if !(mode == .move && sameVolume), spaceInfo.total > 0, plan.totalBytes > spaceInfo.available {
            throw TransferError.insufficientSpace(required: plan.totalBytes, available: spaceInfo.available)
        }

        var policy = conflictPolicy
        let tracker = TransferProgressTracker(totalBytes: plan.totalBytes, totalFiles: plan.files.count)
        var transferredSourceFilesForMove: [URL] = []
        var skippedAnyInSourceRoot: Set<URL> = []

        await onProgress(tracker.snapshot(currentFileName: plan.files.first?.source.lastPathComponent ?? ""))

        // Create directories first (so empty folders are also preserved cleanly).
        for dirEntry in plan.directories {
            try await control.waitIfPaused()
            if !fm.fileExists(atPath: dirEntry.destination.path) {
                try fm.createDirectory(at: dirEntry.destination, withIntermediateDirectories: true)
            }
        }

        for fileEntry in plan.files {
            try await control.waitIfPaused()

            var resolvedDest = fileEntry.destination
            let sourcePath = fileEntry.source.standardizedFileURL.path
            let destPath = resolvedDest.standardizedFileURL.path

            // No-op if source and destination resolve to the exact same path.
            if sourcePath == destPath {
                tracker.recordSkip(bytes: 0)
                skippedAnyInSourceRoot.insert(fileEntry.rootSource)
                continue
            }

            if fm.fileExists(atPath: resolvedDest.path) {
                let resolution: ConflictResolution
                switch policy {
                case .ask:
                    let prompt = Self.makeConflictPrompt(source: fileEntry.source, destination: resolvedDest)
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
                case .replace:
                    resolution = .replace
                case .skip:
                    resolution = .skip
                case .keepBoth:
                    resolution = .keepBoth
                }

                switch resolution {
                case .cancelAll:
                    control.cancel()
                    throw TransferError.cancelled
                case .skip:
                    tracker.recordSkip(bytes: fileEntry.size)
                    skippedAnyInSourceRoot.insert(fileEntry.rootSource)
                    await onProgress(tracker.snapshot(currentFileName: fileEntry.source.lastPathComponent))
                    continue
                case .keepBoth:
                    resolvedDest = FileBrowserService.uniqueDestinationURL(for: resolvedDest)
                case .replace:
                    break
                }
            }

            let parentDir = resolvedDest.deletingLastPathComponent()
            if !fm.fileExists(atPath: parentDir.path) {
                try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
            }

            // Instant same-volume move when there's no cross-device copy needed.
            if mode == .move && allowSameVolumeMoveShortcut && Self.areOnSameVolume(fileEntry.source, resolvedDest) {
                if fm.fileExists(atPath: resolvedDest.path) {
                    try fm.removeItem(at: resolvedDest)
                }
                try fm.moveItem(at: fileEntry.source, to: resolvedDest)
                tracker.recordChunk(bytes: fileEntry.size, elapsedSeconds: 0)
                tracker.recordFileCompleted()
                await onProgress(tracker.snapshot(currentFileName: fileEntry.source.lastPathComponent))
                continue
            }

            // Stream copy into a staging temp file, then move into final path only on 100% completion.
            let tempURL = parentDir.appendingPathComponent(".unibridge.\(UUID().uuidString).part")
            let currentName = fileEntry.source.lastPathComponent
            do {
                try await copyFileChunked(
                    from: fileEntry.source,
                    to: tempURL,
                    control: control
                ) { chunkBytes, chunkSeconds in
                    if let snapshot = tracker.recordChunkAndMaybeSnapshot(
                        bytes: Int64(chunkBytes),
                        elapsedSeconds: chunkSeconds,
                        currentFileName: currentName
                    ) {
                        await onProgress(snapshot)
                    }
                }

                // Preserve modification date if supported by target filesystem.
                if let attrs = try? fm.attributesOfItem(atPath: fileEntry.source.path),
                   let modDate = attrs[.modificationDate] as? Date
                {
                    try? fm.setAttributes([.modificationDate: modDate], ofItemAtPath: tempURL.path)
                }

                if fm.fileExists(atPath: resolvedDest.path) {
                    try fm.removeItem(at: resolvedDest)
                }
                try fm.moveItem(at: tempURL, to: resolvedDest)
            } catch {
                try? fm.removeItem(at: tempURL)
                throw error
            }

            tracker.recordFileCompleted()
            if mode == .move {
                transferredSourceFilesForMove.append(fileEntry.source)
            }

            await onProgress(tracker.snapshot(currentFileName: currentName))
        }

        // Remove source files only after successful copy, and remove empty source directories whose contents were fully moved.
        if mode == .move {
            for srcFile in transferredSourceFilesForMove {
                try? fm.removeItem(at: srcFile)
            }
            for rootSource in sources where !skippedAnyInSourceRoot.contains(rootSource) {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: rootSource.path, isDirectory: &isDir), isDir.boolValue {
                    Self.removeEmptySubdirectories(at: rootSource)
                }
            }
        }

        return tracker.finalCounts()
    }

    private func copyFileChunked(
        from source: URL,
        to tempDestination: URL,
        control: TransferControl,
        onChunk: @escaping @Sendable (Int, TimeInterval) async -> Void
    ) async throws {
        let size = chunkSize
        try await Task.detached(priority: .userInitiated) {
            let srcHandle = try FileHandle(forReadingFrom: source)
            defer { try? srcHandle.close() }

            FileManager.default.createFile(atPath: tempDestination.path, contents: nil)
            let dstHandle = try FileHandle(forWritingTo: tempDestination)
            defer { try? dstHandle.close() }

            while true {
                try await control.waitIfPaused()

                let start = Date()
                let data = try srcHandle.read(upToCount: size)
                guard let data, !data.isEmpty else {
                    break
                }
                try dstHandle.write(contentsOf: data)

                let elapsed = Date().timeIntervalSince(start)
                await onChunk(data.count, elapsed)
            }

            try dstHandle.synchronize()
        }.value
    }

    private struct PlannedDirectory {
        let destination: URL
    }

    private struct PlannedFile {
        let rootSource: URL
        let source: URL
        let destination: URL
        let size: Int64
    }

    private struct TransferPlan {
        let directories: [PlannedDirectory]
        let files: [PlannedFile]
        let totalBytes: Int64
    }

    private static func buildPlan(
        sources: [URL],
        destinationDirectory: URL,
        isDestFAT32: Bool
    ) throws -> TransferPlan {
        let fm = FileManager.default
        var directories: [PlannedDirectory] = []
        var files: [PlannedFile] = []
        var totalBytes: Int64 = 0

        for rootSource in sources {
            let values = try rootSource.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .totalFileSizeKey])
            let isDir = values.isDirectory ?? false
            let targetRoot = destinationDirectory.appendingPathComponent(rootSource.lastPathComponent)

            if !isDir {
                let size = Int64(values.fileSize ?? values.totalFileSize ?? 0)
                if isDestFAT32 && size > fat32MaxFileBytes {
                    throw TransferError.fat32FileTooLarge(fileName: rootSource.lastPathComponent, size: size)
                }
                files.append(PlannedFile(rootSource: rootSource, source: rootSource, destination: targetRoot, size: size))
                totalBytes += size
                continue
            }

            directories.append(PlannedDirectory(destination: targetRoot))

            guard let enumerator = fm.enumerator(
                at: rootSource,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .totalFileSizeKey],
                options: []
            ) else {
                throw TransferError.ioError("Unable to enumerate folder '\(rootSource.lastPathComponent)'.")
            }

            let basePath = rootSource.standardizedFileURL.path
            while let itemURL = enumerator.nextObject() as? URL {
                let itemPath = itemURL.standardizedFileURL.path
                let relative = String(itemPath.dropFirst(basePath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let destURL = targetRoot.appendingPathComponent(relative)
                let itemValues = try itemURL.resourceValues(forKeys: Set<URLResourceKey>([.isDirectoryKey, .fileSizeKey, .totalFileSizeKey]))

                if itemValues.isDirectory == true {
                    directories.append(PlannedDirectory(destination: destURL))
                } else {
                    let size = Int64(itemValues.fileSize ?? itemValues.totalFileSize ?? 0)
                    if isDestFAT32 && size > fat32MaxFileBytes {
                        throw TransferError.fat32FileTooLarge(fileName: itemURL.lastPathComponent, size: size)
                    }
                    files.append(PlannedFile(rootSource: rootSource, source: itemURL, destination: destURL, size: size))
                    totalBytes += size
                }
            }
        }

        return TransferPlan(directories: directories, files: files, totalBytes: totalBytes)
    }

    private static func makeConflictPrompt(source: URL, destination: URL) -> ConflictPrompt {
        let srcValues = try? source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let dstValues = try? destination.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return ConflictPrompt(
            sourceURL: source,
            destinationURL: destination,
            sourceSize: Int64(srcValues?.fileSize ?? 0),
            destinationSize: Int64(dstValues?.fileSize ?? 0),
            sourceDate: srcValues?.contentModificationDate,
            destinationDate: dstValues?.contentModificationDate
        )
    }

    private static func areOnSameVolume(_ a: URL, _ b: URL) -> Bool {
        let fm = FileManager.default
        let devA = (try? fm.attributesOfItem(atPath: a.path)[.systemNumber] as? NSNumber)?.int64Value
        let targetB = fm.fileExists(atPath: b.path) ? b.path : b.deletingLastPathComponent().path
        let devB = (try? fm.attributesOfItem(atPath: targetB)[.systemNumber] as? NSNumber)?.int64Value
        return devA != nil && devA == devB
    }

    private static func estimateETA(remainingBytes: Int64, speed: Double) -> Double? {
        guard remainingBytes > 0, speed > 1024 else { return nil }
        return Double(remainingBytes) / speed
    }

    private static func removeEmptySubdirectories(at root: URL) {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return
        }
        for child in children {
            let isDir = (try? child.resourceValues(forKeys: Set<URLResourceKey>([.isDirectoryKey])).isDirectory) ?? false
            if isDir {
                removeEmptySubdirectories(at: child)
            }
        }
        if let remaining = try? fm.contentsOfDirectory(atPath: root.path), remaining.isEmpty {
            try? fm.removeItem(at: root)
        }
    }
}

private final class TransferProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let totalBytes: Int64
    private let totalFiles: Int
    private var bytesTransferred: Int64 = 0
    private var filesCompleted: Int = 0
    private var filesSkipped: Int = 0
    private var emaSpeed: Double = 0
    private var lastEmitTime: Date = .distantPast

    init(totalBytes: Int64, totalFiles: Int) {
        self.totalBytes = totalBytes
        self.totalFiles = totalFiles
    }

    func recordSkip(bytes: Int64) {
        lock.withLock {
            filesSkipped += 1
            bytesTransferred += bytes
        }
    }

    func recordFileCompleted() {
        lock.withLock {
            filesCompleted += 1
        }
    }

    func recordChunk(bytes: Int64, elapsedSeconds: TimeInterval) {
        lock.withLock {
            bytesTransferred += bytes
            if elapsedSeconds > 0 {
                let instantSpeed = Double(bytes) / elapsedSeconds
                emaSpeed = emaSpeed == 0 ? instantSpeed : (0.25 * instantSpeed + 0.75 * emaSpeed)
            }
        }
    }

    func recordChunkAndMaybeSnapshot(
        bytes: Int64,
        elapsedSeconds: TimeInterval,
        currentFileName: String
    ) -> TransferProgressSnapshot? {
        lock.withLock {
            bytesTransferred += bytes
            if elapsedSeconds > 0 {
                let instantSpeed = Double(bytes) / elapsedSeconds
                emaSpeed = emaSpeed == 0 ? instantSpeed : (0.25 * instantSpeed + 0.75 * emaSpeed)
            }
            let now = Date()
            guard now.timeIntervalSince(lastEmitTime) >= 0.08 else {
                return nil
            }
            lastEmitTime = now
            return buildSnapshotLocked(currentFileName: currentFileName)
        }
    }

    func snapshot(currentFileName: String) -> TransferProgressSnapshot {
        lock.withLock {
            buildSnapshotLocked(currentFileName: currentFileName)
        }
    }

    func finalCounts() -> (filesCompleted: Int, filesSkipped: Int) {
        lock.withLock {
            (filesCompleted, filesSkipped)
        }
    }

    private func buildSnapshotLocked(currentFileName: String) -> TransferProgressSnapshot {
        let remaining = max(0, totalBytes - bytesTransferred)
        let eta: Double? = (remaining > 0 && emaSpeed > 1024) ? Double(remaining) / emaSpeed : nil
        return TransferProgressSnapshot(
            totalBytes: totalBytes,
            bytesTransferred: bytesTransferred,
            totalFiles: totalFiles,
            filesCompleted: filesCompleted,
            filesSkipped: filesSkipped,
            currentFileName: currentFileName,
            speedBytesPerSecond: emaSpeed,
            estimatedSecondsRemaining: eta
        )
    }
}
