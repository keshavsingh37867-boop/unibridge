import Foundation

public enum FileBrowserError: LocalizedError, Sendable {
    case invalidName
    case directoryUnreadable(String)
    case deleteNotSupported(String)

    public var errorDescription: String? {
        switch self {
        case .invalidName:
            return "Name cannot be empty or contain '/' or ':'."
        case .directoryUnreadable(let message):
            return "Could not open folder: \(message)"
        case .deleteNotSupported(let message):
            return message
        }
    }
}

public enum FileBrowserService {
    private static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey,
        .isPackageKey,
        .isSymbolicLinkKey,
        .fileSizeKey,
        .totalFileSizeKey,
        .contentModificationDateKey,
        .isHiddenKey
    ]

    public static func listContents(
        of directory: URL,
        showHidden: Bool,
        sortBy: SortField,
        ascending: Bool
    ) throws -> [FileItem] {
        let options: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: resourceKeys,
                options: options
            )
        } catch {
            throw FileBrowserError.directoryUnreadable(error.localizedDescription)
        }

        let items = urls.map { url -> FileItem in
            let values = try? url.resourceValues(forKeys: Set(resourceKeys))
            let attrs = values == nil ? (try? FileManager.default.attributesOfItem(atPath: url.path)) : nil
            let isDir = values?.isDirectory ?? ((attrs?[.type] as? FileAttributeType) == .typeDirectory)
            let isPackage = values?.isPackage ?? false
            let isSymlink = values?.isSymbolicLink ?? ((attrs?[.type] as? FileAttributeType) == .typeSymbolicLink)
            let size = Int64(values?.fileSize ?? values?.totalFileSize ?? ((attrs?[.size] as? NSNumber)?.intValue ?? 0))
            let modified = values?.contentModificationDate ?? (attrs?[.modificationDate] as? Date) ?? Date.distantPast
            let hidden = values?.isHidden ?? url.lastPathComponent.hasPrefix(".")

            return FileItem(
                url: url,
                name: url.lastPathComponent,
                isDirectory: isDir,
                isPackage: isPackage,
                isSymlink: isSymlink,
                size: isDir && !isPackage ? 0 : size,
                modifiedDate: modified,
                contentTypeIdentifier: nil,
                isHidden: hidden
            )
        }

        return sort(items: items, by: sortBy, ascending: ascending)
    }

    public static func sort(items: [FileItem], by field: SortField, ascending: Bool) -> [FileItem] {
        items.sorted { lhs, rhs in
            // Keep folders above files when sorting by name or kind for familiar Commander ergonomics.
            if (field == .name || field == .kind) && (lhs.isDirectory != rhs.isDirectory) {
                return lhs.isDirectory && !rhs.isDirectory
            }

            let ordered: ComparisonResult
            switch field {
            case .name:
                ordered = lhs.name.localizedStandardCompare(rhs.name)
            case .size:
                if lhs.size == rhs.size {
                    ordered = lhs.name.localizedStandardCompare(rhs.name)
                } else {
                    ordered = lhs.size < rhs.size ? .orderedAscending : .orderedDescending
                }
            case .dateModified:
                if lhs.modifiedDate == rhs.modifiedDate {
                    ordered = lhs.name.localizedStandardCompare(rhs.name)
                } else {
                    ordered = lhs.modifiedDate < rhs.modifiedDate ? .orderedAscending : .orderedDescending
                }
            case .kind:
                let kindCmp = lhs.kindDescription.localizedStandardCompare(rhs.kindDescription)
                ordered = kindCmp == .orderedSame ? lhs.name.localizedStandardCompare(rhs.name) : kindCmp
            }

            return ascending ? (ordered == .orderedAscending) : (ordered == .orderedDescending)
        }
    }

    public static func createFolder(named rawName: String, in directory: URL) throws -> URL {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidFileName(name) else {
            throw FileBrowserError.invalidName
        }
        let target = uniqueDestinationURL(for: directory.appendingPathComponent(name, isDirectory: true))
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        return target
    }

    public static func renameItem(at url: URL, to rawNewName: String) throws -> URL {
        let newName = rawNewName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidFileName(newName) else {
            throw FileBrowserError.invalidName
        }
        let destination = url.deletingLastPathComponent().appendingPathComponent(newName)
        if destination.standardizedFileURL == url.standardizedFileURL {
            return url
        }
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }

    /// Moves an item to Trash when supported by the volume, optionally falling back to permanent deletion
    /// on removable volumes (e.g., FAT32/exFAT pendrives without a Trash folder).
    public static func removeItem(at url: URL, permanentlyIfTrashUnavailable: Bool = false) throws {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            if permanentlyIfTrashUnavailable {
                try FileManager.default.removeItem(at: url)
            } else {
                throw FileBrowserError.deleteNotSupported(
                    "Trash is unavailable on this volume (\(error.localizedDescription))."
                )
            }
        }
    }

    public static func isValidFileName(_ name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != ".." else { return false }
        return !name.contains("/") && !name.contains(":")
    }

    /// Returns a collision-free URL such as `photo (2).jpg` or `Backup (2)`.
    public static func uniqueDestinationURL(for preferredURL: URL) -> URL {
        let fm = FileManager.default
        if !fm.fileExists(atPath: preferredURL.path) {
            return preferredURL
        }

        let directory = preferredURL.deletingLastPathComponent()
        let isDir = (try? preferredURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? preferredURL.hasDirectoryPath
        let ext = isDir ? "" : preferredURL.pathExtension
        let stem = isDir || ext.isEmpty
            ? preferredURL.lastPathComponent
            : preferredURL.deletingPathExtension().lastPathComponent

        var counter = 2
        while true {
            let candidateName = ext.isEmpty ? "\(stem) (\(counter))" : "\(stem) (\(counter)).\(ext)"
            let candidateURL = directory.appendingPathComponent(candidateName)
            if !fm.fileExists(atPath: candidateURL.path) {
                return candidateURL
            }
            counter += 1
        }
    }

    public static func volumeSpaceInfo(for url: URL) -> (total: Int64, available: Int64, readOnly: Bool, fileSystem: String) {
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
            .volumeIsReadOnlyKey,
            .volumeLocalizedFormatDescriptionKey
        ]
        let values = try? url.resourceValues(forKeys: keys)
        let fsAttrs = try? FileManager.default.attributesOfFileSystem(forPath: url.path)
        let total = Int64(values?.volumeTotalCapacity ?? 0) > 0
            ? Int64(values?.volumeTotalCapacity ?? 0)
            : ((fsAttrs?[.systemSize] as? NSNumber)?.int64Value ?? 0)

        let availableImportant = values?.volumeAvailableCapacityForImportantUsage ?? 0
        let availableStandard = values?.volumeAvailableCapacity.map(Int64.init) ?? 0
        let fsFree = (fsAttrs?[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        let available = availableImportant > 0
            ? availableImportant
            : (availableStandard > 0 ? availableStandard : fsFree)

        let readOnly = values?.volumeIsReadOnly ?? false
        let fs = values?.volumeLocalizedFormatDescription ?? "Unknown"
        return (total, available, readOnly, fs)
    }
}
