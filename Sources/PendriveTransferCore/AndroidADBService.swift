import Foundation

public enum AndroidADBError: LocalizedError, Sendable {
    case adbNotInstalled
    case commandFailed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .adbNotInstalled:
            return "ADB binary was not found."
        case .commandFailed(let message):
            return message
        case .cancelled:
            return "Transfer cancelled."
        }
    }
}

/// Manages Android devices connected via ADB (USB Debugging) for fast bidirectional transfers.
public final class AndroidADBService: Sendable {
    public init() {}

    public static func locateADBBinary() -> String? {
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/adb").path,
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            "/usr/bin/adb"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    public func discoverEndpoints() async -> [StorageEndpoint] {
        guard let adbPath = Self.locateADBBinary() else { return [] }
        guard let output = try? await runADB(adbPath: adbPath, args: ["devices", "-l"], timeoutSeconds: 4) else {
            return []
        }

        let lines = output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("List of devices") && !$0.hasPrefix("*") }

        var endpoints: [StorageEndpoint] = []
        for line in lines {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard parts.count >= 2 else { continue }
            let serial = parts[0]
            let state = parts[1]

            var modelName = serial
            for token in parts.dropFirst(2) {
                if token.hasPrefix("model:") {
                    modelName = String(token.dropFirst("model:".count)).replacingOccurrences(of: "_", with: " ")
                }
            }

            if state == "device" {
                let space = await fetchStorageInfo(adbPath: adbPath, serial: serial)
                endpoints.append(
                    StorageEndpoint(
                        id: "adb::\(serial)",
                        platform: .androidADB,
                        name: "\(modelName) (ADB)",
                        subtitle: "Android USB Debugging • /sdcard",
                        detailBadge: "ADB Fast",
                        totalBytes: space.total,
                        availableBytes: space.available,
                        isReadOnly: false,
                        requiresAttention: false,
                        statusMessage: nil,
                        rootLocation: .adb(serial: serial, path: "/sdcard"),
                        adbSerial: serial
                    )
                )
            } else if state == "unauthorized" {
                endpoints.append(
                    StorageEndpoint(
                        id: "adb::\(serial)::unauth",
                        platform: .androidADB,
                        name: "\(modelName) (ADB)",
                        subtitle: "Android USB Debugging",
                        detailBadge: "Authorize on Phone",
                        isReadOnly: true,
                        requiresAttention: true,
                        statusMessage: "Tap 'Allow USB debugging' on your Android phone, then tap Rescan.",
                        rootLocation: .adb(serial: serial, path: "/sdcard"),
                        adbSerial: serial
                    )
                )
            }
        }

        return endpoints
    }

    public func listDirectory(
        serial: String,
        path: String,
        showHidden: Bool,
        sortBy: SortField,
        ascending: Bool
    ) async throws -> [BrowserEntry] {
        guard let adbPath = Self.locateADBBinary() else {
            throw AndroidADBError.adbNotInstalled
        }

        let quotedDir = Self.shellQuote(path)
        let script = """
        DIR=\(quotedDir)
        if [ ! -d "$DIR" ]; then echo "__ERR__Folder not found"; exit 1; fi
        for f in "$DIR"/* "$DIR"/.*; do
          [ -e "$f" ] || [ -L "$f" ] || continue
          b=$(basename "$f")
          [ "$b" = "." ] || [ "$b" = ".." ] && continue
          if [ -d "$f" ]; then t="D"; else t="F"; fi
          s=$(stat -c "%s|%Y" "$f" 2>/dev/null || echo "0|0")
          printf "%s|%s|%s\\n" "$t" "$s" "$b"
        done
        """

        let out = try await runADB(adbPath: adbPath, args: ["-s", serial, "shell", script], timeoutSeconds: 15)
        var entries: [BrowserEntry] = []

        for rawLine in out.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if line.isEmpty { continue }
            if line.hasPrefix("__ERR__") {
                throw AndroidADBError.commandFailed(String(line.dropFirst("__ERR__".count)))
            }

            let fields = line.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false)
            guard fields.count == 4 else { continue }
            let isDir = fields[0] == "D"
            let size = Int64(fields[1]) ?? 0
            let mtime = Int64(fields[2]) ?? 0
            let name = String(fields[3])
            let hidden = name.hasPrefix(".")
            if !showHidden && hidden {
                continue
            }

            let childPath = path == "/" ? "/\(name)" : "\(path)/\(name)"
            entries.append(
                BrowserEntry(
                    id: "adb::\(serial)::\(childPath)",
                    name: name,
                    isDirectory: isDir,
                    isPackage: false,
                    size: isDir ? 0 : size,
                    modifiedDate: mtime > 0 ? Date(timeIntervalSince1970: TimeInterval(mtime)) : Date.distantPast,
                    isHidden: hidden,
                    location: .adb(serial: serial, path: childPath),
                    remotePath: childPath
                )
            )
        }

        return FormattingHelpers.sortBrowserEntries(entries, by: sortBy, ascending: ascending)
    }

    public func fileExists(serial: String, remotePath: String) async throws -> (exists: Bool, isDirectory: Bool, size: Int64, mtime: Date?) {
        guard let adbPath = Self.locateADBBinary() else {
            throw AndroidADBError.adbNotInstalled
        }
        let q = Self.shellQuote(remotePath)
        let script = "if [ -d \(q) ]; then echo \"D|0|0\"; elif [ -e \(q) ]; then s=$(stat -c \"%s|%Y\" \(q) 2>/dev/null || echo \"0|0\"); echo \"F|$s\"; else echo \"N|0|0\"; fi"
        let out = try await runADB(adbPath: adbPath, args: ["-s", serial, "shell", script], timeoutSeconds: 8)
        let parts = out.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "|")
        guard parts.count >= 3 else { return (false, false, 0, nil) }
        if parts[0] == "N" { return (false, false, 0, nil) }
        let isDir = parts[0] == "D"
        let size = Int64(parts[1]) ?? 0
        let ts = Int64(parts[2]) ?? 0
        return (true, isDir, size, ts > 0 ? Date(timeIntervalSince1970: TimeInterval(ts)) : nil)
    }

    public func createDirectory(serial: String, remotePath: String) async throws {
        guard let adbPath = Self.locateADBBinary() else { throw AndroidADBError.adbNotInstalled }
        _ = try await runADB(adbPath: adbPath, args: ["-s", serial, "shell", "mkdir -p \(Self.shellQuote(remotePath))"], timeoutSeconds: 10)
    }

    public func rename(serial: String, fromPath: String, toPath: String) async throws {
        guard let adbPath = Self.locateADBBinary() else { throw AndroidADBError.adbNotInstalled }
        _ = try await runADB(adbPath: adbPath, args: ["-s", serial, "shell", "mv \(Self.shellQuote(fromPath)) \(Self.shellQuote(toPath))"], timeoutSeconds: 10)
    }

    public func delete(serial: String, remotePath: String) async throws {
        guard let adbPath = Self.locateADBBinary() else { throw AndroidADBError.adbNotInstalled }
        _ = try await runADB(adbPath: adbPath, args: ["-s", serial, "shell", "rm -rf \(Self.shellQuote(remotePath))"], timeoutSeconds: 15)
    }

    public func pullFile(
        serial: String,
        remotePath: String,
        toLocalURL localURL: URL,
        expectedSize: Int64,
        control: TransferControl,
        onProgress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        guard let adbPath = Self.locateADBBinary() else { throw AndroidADBError.adbNotInstalled }
        try await runADBTransfer(
            adbPath: adbPath,
            args: ["-s", serial, "pull", remotePath, localURL.path],
            control: control,
            pollProgress: {
                let size = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? NSNumber)?.int64Value ?? 0
                onProgress(min(expectedSize > 0 ? expectedSize : size, size))
            }
        )
        onProgress(expectedSize)
    }

    public func pushFile(
        serial: String,
        fromLocalURL localURL: URL,
        remotePath: String,
        fileSize: Int64,
        control: TransferControl,
        onProgress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        guard let adbPath = Self.locateADBBinary() else { throw AndroidADBError.adbNotInstalled }
        try await runADBTransfer(
            adbPath: adbPath,
            args: ["-s", serial, "push", localURL.path, remotePath],
            control: control,
            pollProgress: {
                // Report remote file size growth during push
                if let info = try? await self.fileExists(serial: serial, remotePath: remotePath), info.exists {
                    onProgress(min(fileSize, info.size))
                }
            }
        )
        onProgress(fileSize)
    }

    private func fetchStorageInfo(adbPath: String, serial: String) async -> (total: Int64, available: Int64) {
        guard let out = try? await runADB(adbPath: adbPath, args: ["-s", serial, "shell", "df -k /sdcard"], timeoutSeconds: 4) else {
            return (0, 0)
        }
        let lines = out.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let last = lines.last else { return (0, 0) }
        let cols = last.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        // Typical df -k columns: Filesystem 1K-blocks Used Available Use% Mounted
        guard cols.count >= 4, let totalKB = Int64(cols[1]), let availKB = Int64(cols[3]) else {
            return (0, 0)
        }
        return (totalKB * 1024, availKB * 1024)
    }

    private func runADB(adbPath: String, args: [String], timeoutSeconds: TimeInterval) async throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: adbPath)
        proc.arguments = args

        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr

        try proc.run()

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while proc.isRunning && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        if proc.isRunning {
            proc.terminate()
            throw AndroidADBError.commandFailed("ADB command timed out.")
        }

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        let outStr = String(data: outData, encoding: .utf8) ?? ""
        let errStr = String(data: errData, encoding: .utf8) ?? ""

        if proc.terminationStatus != 0 {
            let msg = errStr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw AndroidADBError.commandFailed(msg.isEmpty ? "ADB exited with status \(proc.terminationStatus)." : msg)
        }
        return outStr
    }

    private func runADBTransfer(
        adbPath: String,
        args: [String],
        control: TransferControl,
        pollProgress: @escaping @Sendable () async -> Void
    ) async throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: adbPath)
        proc.arguments = args

        let stderr = Pipe()
        let stdout = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr

        try proc.run()

        while proc.isRunning {
            if control.isCancelled {
                proc.terminate()
                throw AndroidADBError.cancelled
            }
            await pollProgress()
            try await Task.sleep(nanoseconds: 150_000_000)
        }

        if control.isCancelled {
            throw AndroidADBError.cancelled
        }

        if proc.terminationStatus != 0 {
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            let outData = stdout.fileHandleForReading.readDataToEndOfFile()
            let errText = (String(data: errData, encoding: .utf8) ?? "") + "\n" + (String(data: outData, encoding: .utf8) ?? "")
            let cleaned = errText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw AndroidADBError.commandFailed(cleaned.isEmpty ? "ADB transfer failed." : cleaned)
        }
    }
}
