import CryptoKit
import Foundation
import UniBridgeCore
import Testing

@Suite("UniBridgeCore Tests")
struct UniBridgeTests {
    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("UniBridgeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    @Test("Chunked binary copy preserves exact bytes and reports progress")
    func chunkedCopyIntegrityAndProgress() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let macDir = root.appendingPathComponent("mac", isDirectory: true)
        let driveDir = root.appendingPathComponent("pendrive", isDirectory: true)
        try FileManager.default.createDirectory(at: macDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: driveDir, withIntermediateDirectories: true)

        // ~320 KB deterministic binary payload across multiple 64 KB chunks
        let payload = Data((0..<(320 * 1024)).map { UInt8($0 & 0xFF) })
        let sourceFile = macDir.appendingPathComponent("video_clip.bin")
        try payload.write(to: sourceFile)

        let engine = TransferEngine(chunkSize: 65_536)
        let control = TransferControl()
        actor Recorder {
            var snapshots: [TransferProgressSnapshot] = []
            func append(_ s: TransferProgressSnapshot) { snapshots.append(s) }
            func all() -> [TransferProgressSnapshot] { snapshots }
        }
        let recorder = Recorder()

        let result = try await engine.execute(
            sources: [sourceFile],
            destinationDirectory: driveDir,
            mode: .copy,
            conflictPolicy: .ask,
            control: control,
            onProgress: { snapshot in
                await recorder.append(snapshot)
            },
            onConflict: { _ in (.skip, false) }
        )

        #expect(result.filesCompleted == 1)
        #expect(result.filesSkipped == 0)

        let destFile = driveDir.appendingPathComponent("video_clip.bin")
        #expect(FileManager.default.fileExists(atPath: destFile.path))
        #expect(try sha256(of: sourceFile) == sha256(of: destFile))

        let snapshots = await recorder.all()
        #expect(!snapshots.isEmpty)
        #expect(snapshots.last?.bytesTransferred == Int64(payload.count))
    }

    @Test("Recursive folder move copies nested structure and cleans source after completion")
    func recursiveFolderMove() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let macDir = root.appendingPathComponent("mac", isDirectory: true)
        let driveDir = root.appendingPathComponent("pendrive", isDirectory: true)
        let album = macDir.appendingPathComponent("TripPhotos", isDirectory: true)
        let nested = album.appendingPathComponent("Day1/RAW", isDirectory: true)
        let emptyDir = album.appendingPathComponent("EmptySubfolder", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: driveDir, withIntermediateDirectories: true)

        let fileA = album.appendingPathComponent("notes.txt")
        let fileB = nested.appendingPathComponent("img001.raw")
        try Data("Hello pendrive".utf8).write(to: fileA)
        try Data(repeating: 0xAB, count: 4096).write(to: fileB)

        let engine = TransferEngine(chunkSize: 65_536)
        let result = try await engine.execute(
            sources: [album],
            destinationDirectory: driveDir,
            mode: .move,
            conflictPolicy: .replace,
            control: TransferControl(),
            onProgress: { _ in },
            onConflict: { _ in (.replace, false) }
        )

        #expect(result.filesCompleted == 2)
        #expect(FileManager.default.fileExists(atPath: driveDir.appendingPathComponent("TripPhotos/notes.txt").path))
        #expect(FileManager.default.fileExists(atPath: driveDir.appendingPathComponent("TripPhotos/Day1/RAW/img001.raw").path))
        #expect(FileManager.default.fileExists(atPath: driveDir.appendingPathComponent("TripPhotos/EmptySubfolder").path))
        // Source files and empty moved directories should be cleaned up.
        #expect(!FileManager.default.fileExists(atPath: fileA.path))
        #expect(!FileManager.default.fileExists(atPath: fileB.path))
        #expect(!FileManager.default.fileExists(atPath: album.path))
    }

    @Test("Conflict policies: skip, replace, keepBoth, and apply-to-all")
    func conflictPolicies() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let srcDir = root.appendingPathComponent("src", isDirectory: true)
        let dstDir = root.appendingPathComponent("dst", isDirectory: true)
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dstDir, withIntermediateDirectories: true)

        let srcFile = srcDir.appendingPathComponent("report.txt")
        let existingDst = dstDir.appendingPathComponent("report.txt")
        try Data("NEW_CONTENT".utf8).write(to: srcFile)
        try Data("OLD_CONTENT".utf8).write(to: existingDst)

        let engine = TransferEngine()

        // 1. Skip preserves existing file
        let skipRes = try await engine.execute(
            sources: [srcFile],
            destinationDirectory: dstDir,
            mode: .copy,
            conflictPolicy: .skip,
            control: TransferControl(),
            onProgress: { _ in },
            onConflict: { _ in Issue.record("Should not prompt when policy is .skip"); return (.cancelAll, false) }
        )
        #expect(skipRes.filesSkipped == 1)
        #expect(try String(contentsOf: existingDst, encoding: .utf8) == "OLD_CONTENT")

        // 2. Keep Both creates `report (2).txt`
        let keepRes = try await engine.execute(
            sources: [srcFile],
            destinationDirectory: dstDir,
            mode: .copy,
            conflictPolicy: .keepBoth,
            control: TransferControl(),
            onProgress: { _ in },
            onConflict: { _ in (.skip, false) }
        )
        #expect(keepRes.filesCompleted == 1)
        let renamedCopy = dstDir.appendingPathComponent("report (2).txt")
        #expect(FileManager.default.fileExists(atPath: renamedCopy.path))
        #expect(try String(contentsOf: renamedCopy, encoding: .utf8) == "NEW_CONTENT")
        #expect(try String(contentsOf: existingDst, encoding: .utf8) == "OLD_CONTENT")

        // 3. Replace overwrites existing file
        let replaceRes = try await engine.execute(
            sources: [srcFile],
            destinationDirectory: dstDir,
            mode: .copy,
            conflictPolicy: .replace,
            control: TransferControl(),
            onProgress: { _ in },
            onConflict: { _ in (.skip, false) }
        )
        #expect(replaceRes.filesCompleted == 1)
        #expect(try String(contentsOf: existingDst, encoding: .utf8) == "NEW_CONTENT")
    }

    @Test("Move does not delete source file when destination skips conflict")
    func moveWithSkipPreservesSource() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let srcDir = root.appendingPathComponent("src", isDirectory: true)
        let dstDir = root.appendingPathComponent("dst", isDirectory: true)
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dstDir, withIntermediateDirectories: true)

        let srcFile = srcDir.appendingPathComponent("important.pdf")
        let dstFile = dstDir.appendingPathComponent("important.pdf")
        try Data("SRC".utf8).write(to: srcFile)
        try Data("EXISTING".utf8).write(to: dstFile)

        let engine = TransferEngine()
        let outcome = try await engine.execute(
            sources: [srcFile],
            destinationDirectory: dstDir,
            mode: .move,
            conflictPolicy: .skip,
            control: TransferControl(),
            onProgress: { _ in },
            onConflict: { _ in (.skip, false) }
        )

        #expect(outcome.filesSkipped == 1)
        #expect(FileManager.default.fileExists(atPath: srcFile.path))
        #expect(try String(contentsOf: dstFile, encoding: .utf8) == "EXISTING")
    }

    @Test("Cancel stops transfer, leaves no temp files, and preserves source on move")
    func cancelCleansUpAndPreservesSource() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let srcDir = root.appendingPathComponent("src", isDirectory: true)
        let dstDir = root.appendingPathComponent("dst", isDirectory: true)
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dstDir, withIntermediateDirectories: true)

        let payload = Data(repeating: 0x5A, count: 512 * 1024)
        let srcFile = srcDir.appendingPathComponent("large.dat")
        try payload.write(to: srcFile)

        let control = TransferControl()
        let engine = TransferEngine(chunkSize: 65_536, allowSameVolumeMoveShortcut: false)

        await #expect(throws: TransferError.self) {
            _ = try await engine.execute(
                sources: [srcFile],
                destinationDirectory: dstDir,
                mode: .move,
                conflictPolicy: .replace,
                control: control,
                onProgress: { snapshot in
                    if snapshot.bytesTransferred > 0 {
                        control.cancel()
                    }
                },
                onConflict: { _ in (.replace, false) }
            )
        }

        // No destination file or leftover .part files
        let dstContents = try FileManager.default.contentsOfDirectory(atPath: dstDir.path)
        #expect(dstContents.isEmpty)
        // Source remains intact
        #expect(FileManager.default.fileExists(atPath: srcFile.path))
    }

    @Test("Pause and resume gate completes transfer cleanly")
    func pauseAndResume() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let srcDir = root.appendingPathComponent("src", isDirectory: true)
        let dstDir = root.appendingPathComponent("dst", isDirectory: true)
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dstDir, withIntermediateDirectories: true)

        let srcFile = srcDir.appendingPathComponent("stream.bin")
        try Data(repeating: 0x7E, count: 256 * 1024).write(to: srcFile)

        let control = TransferControl()
        control.pause()

        let engine = TransferEngine(chunkSize: 65_536)
        let task = Task {
            try await engine.execute(
                sources: [srcFile],
                destinationDirectory: dstDir,
                mode: .copy,
                conflictPolicy: .replace,
                control: control,
                onProgress: { _ in },
                onConflict: { _ in (.replace, false) }
            )
        }

        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(!FileManager.default.fileExists(atPath: dstDir.appendingPathComponent("stream.bin").path))

        control.resume()
        let outcome = try await task.value
        #expect(outcome.filesCompleted == 1)
        #expect(FileManager.default.fileExists(atPath: dstDir.appendingPathComponent("stream.bin").path))
    }

    @Test("Self-nesting folder guard prevents recursive infinite copy")
    func preventsCopyingFolderIntoItself() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let folder = root.appendingPathComponent("Folder", isDirectory: true)
        let nested = folder.appendingPathComponent("Subfolder", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        let engine = TransferEngine()
        await #expect(throws: TransferError.self) {
            _ = try await engine.execute(
                sources: [folder],
                destinationDirectory: nested,
                mode: .copy,
                conflictPolicy: .ask,
                control: TransferControl(),
                onProgress: { _ in },
                onConflict: { _ in (.skip, false) }
            )
        }
    }

    @Test("FileBrowserService lists, sorts, hides dotfiles, creates folders, and renames")
    func fileBrowserOperations() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("a".utf8).write(to: root.appendingPathComponent("zeta.txt"))
        try Data("abcd".utf8).write(to: root.appendingPathComponent("alpha.txt"))
        try Data("hidden".utf8).write(to: root.appendingPathComponent(".DS_Store"))
        _ = try FileBrowserService.createFolder(named: "Photos", in: root)

        let visibleOnly = try FileBrowserService.listContents(of: root, showHidden: false, sortBy: .name, ascending: true)
        #expect(visibleOnly.map(\.name) == ["Photos", "alpha.txt", "zeta.txt"])

        let withHidden = try FileBrowserService.listContents(of: root, showHidden: true, sortBy: .name, ascending: true)
        #expect(withHidden.contains { $0.name == ".DS_Store" })

        let renamed = try FileBrowserService.renameItem(
            at: root.appendingPathComponent("zeta.txt"),
            to: "beta.txt"
        )
        #expect(renamed.lastPathComponent == "beta.txt")
        #expect(FileManager.default.fileExists(atPath: renamed.path))
    }

    @Test("DriveInfo flags FAT32, NTFS read-only, and capacity usage accurately")
    func driveInfoClassificationAndCapacity() {
        let fat32Drive = DriveInfo(
            id: "disk4s1",
            name: "SANDISK OTG",
            volumeURL: URL(fileURLWithPath: "/Volumes/SANDISK OTG"),
            busProtocol: "USB",
            connectionKind: .usbOTG,
            fileSystemName: "MS-DOS (FAT32)",
            totalBytes: 32_000_000_000,
            availableBytes: 8_000_000_000,
            isReadOnly: false
        )
        #expect(fat32Drive.isFAT32)
        #expect(!fat32Drive.isNTFSReadOnly)
        #expect(fat32Drive.usedBytes == 24_000_000_000)
        #expect(abs(fat32Drive.usageFraction - 0.75) < 0.001)

        let ntfsDrive = DriveInfo(
            id: "disk5s1",
            name: "WIN_DRIVE",
            volumeURL: URL(fileURLWithPath: "/Volumes/WIN_DRIVE"),
            busProtocol: "USB",
            connectionKind: .usbOTG,
            fileSystemName: "NTFS",
            totalBytes: 64_000_000_000,
            availableBytes: 16_000_000_000,
            isReadOnly: true
        )
        #expect(ntfsDrive.isNTFSReadOnly)
        #expect(!ntfsDrive.isFAT32)
    }

    @Test("DriveMonitor refreshes and manages custom folder targets without crashing")
    @MainActor
    func driveMonitorCustomTargetLifecycle() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let monitor = DriveMonitor()
        monitor.refreshDrives()
        let initialCount = monitor.drives.count

        monitor.addCustomFolderTarget(root)
        #expect(monitor.drives.count == initialCount + 1)
        let custom = try #require(monitor.drives.first { $0.isCustomFolder && $0.volumeURL == root })
        #expect(custom.connectionKind == .customFolder)

        monitor.removeCustomFolderTarget(custom)
        #expect(monitor.drives.count == initialCount)
    }

    @Test("FAT32 4 GB limit blocks oversized file before starting transfer")
    func fat32FourGigabyteGuard() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let srcDir = root.appendingPathComponent("src", isDirectory: true)
        let dstDir = root.appendingPathComponent("dst", isDirectory: true)
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dstDir, withIntermediateDirectories: true)

        // Create a sparse 4 GiB + 1 byte file so the test takes milliseconds and uses almost zero disk blocks.
        let oversized = srcDir.appendingPathComponent("huge_backup.iso")
        FileManager.default.createFile(atPath: oversized.path, contents: nil)
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: 4_294_967_296)
        try handle.close()

        let engine = TransferEngine()
        await #expect(throws: TransferError.self) {
            _ = try await engine.execute(
                sources: [oversized],
                destinationDirectory: dstDir,
                mode: .copy,
                conflictPolicy: .replace,
                destinationFileSystemHint: "MS-DOS (FAT32)",
                control: TransferControl(),
                onProgress: { _ in },
                onConflict: { _ in (.replace, false) }
            )
        }
    }

    @Test("AndroidADBService shell quoting safely escapes spaces, quotes, and dollar signs")
    func adbShellQuoting() {
        let path = "/sdcard/My Documents/photo's $100 (1).jpg"
        let quoted = AndroidADBService.shellQuote(path)
        #expect(quoted == "'/sdcard/My Documents/photo'\"'\"'s $100 (1).jpg'")
    }

    @Test("UnifiedTransferService executes local-to-local transfers and browser operations")
    func unifiedServiceLocalWorkflow() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let leftDir = root.appendingPathComponent("mac", isDirectory: true)
        let rightDir = root.appendingPathComponent("pendrive", isDirectory: true)
        try FileManager.default.createDirectory(at: leftDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rightDir, withIntermediateDirectories: true)

        let sourceURL = leftDir.appendingPathComponent("note.txt")
        try Data("Unified transfer payload".utf8).write(to: sourceURL)

        let mtp = AndroidMTPService()
        let adb = AndroidADBService()
        let ios = IOSDeviceService()
        let unified = UnifiedTransferService(mtpService: mtp, adbService: adb, iosService: ios)

        try await unified.createFolder(named: "Exports", in: .local(rightDir))
        let rightItems = try await unified.listEntries(
            at: .local(rightDir),
            showHidden: false,
            sortBy: .name,
            ascending: true
        )
        #expect(rightItems.map(\.name) == ["Exports"])

        let leftItems = try await unified.listEntries(
            at: .local(leftDir),
            showHidden: false,
            sortBy: .name,
            ascending: true
        )
        #expect(leftItems.count == 1)

        let leftEp = StorageEndpoint.macHome()
        let rightEp = StorageEndpoint(
            id: "test::drive",
            platform: .pendrive,
            name: "Test Drive",
            subtitle: "USB",
            detailBadge: "exFAT",
            totalBytes: 1_000_000_000,
            availableBytes: 500_000_000,
            rootLocation: .local(rightDir)
        )

        let outcome = try await unified.execute(
            entries: leftItems,
            from: leftEp,
            sourceParent: .local(leftDir),
            to: rightEp,
            destinationDirectory: .local(rightDir.appendingPathComponent("Exports")),
            mode: .copy,
            conflictPolicy: .replace,
            control: TransferControl(),
            onProgress: { _ in },
            onConflict: { _ in (.replace, false) }
        )

        #expect(outcome.filesCompleted == 1)
        let copied = rightDir.appendingPathComponent("Exports/note.txt")
        #expect(try String(contentsOf: copied, encoding: .utf8) == "Unified transfer payload")
    }

    @Test("CDeviceBridge Android MTP and iOS discovery services run cleanly")
    func nativeBridgesSmokeCheck() async {
        let mtp = AndroidMTPService()
        let ios = IOSDeviceService()
        let adb = AndroidADBService()

        _ = await mtp.discoverEndpoints()
        _ = await ios.discoverEndpoints()
        _ = await adb.discoverEndpoints()
    }
}
