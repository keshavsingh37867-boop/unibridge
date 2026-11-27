import Foundation

/// Connection bus / transport classification for detected removable storage.
public enum DriveConnectionKind: String, Codable, Sendable, Hashable {
    case usbOTG = "USB / OTG"
    case usb = "USB"
    case sdCard = "SD Card"
    case thunderbolt = "Thunderbolt"
    case external = "External"
    case customFolder = "Custom Folder"

    public var sfSymbolName: String {
        switch self {
        case .usbOTG, .usb:
            return "externaldrive.fill.badge.plus"
        case .sdCard:
            return "sdcard.fill"
        case .thunderbolt:
            return "externaldrive.connected.to.line.below.fill"
        case .external:
            return "externaldrive.fill"
        case .customFolder:
            return "folder.fill.badge.gearshape"
        }
    }
}

/// Platform category for any pane endpoint.
public enum EndpointPlatform: String, Codable, Sendable, Hashable {
    case macOS = "macOS"
    case pendrive = "Pendrive"
    case androidMTP = "Android (MTP)"
    case androidADB = "Android (ADB)"
    case iosMedia = "iOS Media"
    case iosApp = "iOS App"

    public var sfSymbolName: String {
        switch self {
        case .macOS:
            return "laptopcomputer"
        case .pendrive:
            return "externaldrive.fill"
        case .androidMTP, .androidADB:
            return "smartphone"
        case .iosMedia:
            return "iphone"
        case .iosApp:
            return "app.badge.fill"
        }
    }

    public var isLocal: Bool {
        self == .macOS || self == .pendrive
    }
}

/// Metadata describing a connected USB/OTG pendrive or removable drive.
public struct DriveInfo: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let volumeURL: URL
    public let deviceBSDName: String?
    public let busProtocol: String
    public let connectionKind: DriveConnectionKind
    public let fileSystemName: String
    public let vendorName: String?
    public let modelName: String?
    public let totalBytes: Int64
    public let availableBytes: Int64
    public let isReadOnly: Bool
    public let isRemovable: Bool
    public let isEjectable: Bool
    public let isCustomFolder: Bool

    public init(
        id: String,
        name: String,
        volumeURL: URL,
        deviceBSDName: String? = nil,
        busProtocol: String = "USB",
        connectionKind: DriveConnectionKind = .usbOTG,
        fileSystemName: String = "exFAT",
        vendorName: String? = nil,
        modelName: String? = nil,
        totalBytes: Int64 = 0,
        availableBytes: Int64 = 0,
        isReadOnly: Bool = false,
        isRemovable: Bool = true,
        isEjectable: Bool = true,
        isCustomFolder: Bool = false
    ) {
        self.id = id
        self.name = name
        self.volumeURL = volumeURL
        self.deviceBSDName = deviceBSDName
        self.busProtocol = busProtocol
        self.connectionKind = connectionKind
        self.fileSystemName = fileSystemName
        self.vendorName = vendorName
        self.modelName = modelName
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
        self.isReadOnly = isReadOnly
        self.isRemovable = isRemovable
        self.isEjectable = isEjectable
        self.isCustomFolder = isCustomFolder
    }

    public var usedBytes: Int64 {
        max(0, totalBytes - availableBytes)
    }

    public var usageFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1.0, max(0.0, Double(usedBytes) / Double(totalBytes)))
    }

    public var isFAT32: Bool {
        let lower = fileSystemName.lowercased()
        return lower.contains("fat32") || lower.contains("ms-dos") || lower == "msdos"
    }

    public var isNTFSReadOnly: Bool {
        isReadOnly && fileSystemName.localizedCaseInsensitiveContains("ntfs")
    }

    public var hardwareSubtitle: String {
        let parts = [vendorName, modelName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if parts.isEmpty {
            return connectionKind.rawValue
        }
        return parts.joined(separator: " ")
    }
}

public struct MTPPathSegment: Hashable, Sendable {
    public let folderID: UInt32
    public let name: String

    public init(folderID: UInt32, name: String) {
        self.folderID = folderID
        self.name = name
    }
}

/// Location pointer inside any supported local or mobile storage device.
public enum RemoteLocation: Hashable, Sendable {
    case local(URL)
    case mtp(busLocation: UInt32, devNum: UInt8, storageID: UInt32, folderID: UInt32, trail: [MTPPathSegment])
    case adb(serial: String, path: String)
    case ios(udid: String, appBundleID: String?, path: String)

    public var localURL: URL? {
        if case .local(let url) = self { return url }
        return nil
    }

    public var displayPath: String {
        switch self {
        case .local(let url):
            return url.path
        case .mtp(_, _, _, _, let trail):
            if trail.isEmpty { return "/" }
            return "/" + trail.map(\.name).joined(separator: "/")
        case .adb(_, let path):
            return path
        case .ios(_, _, let path):
            return path
        }
    }
}

/// Any target or source device selectable in either pane.
public struct StorageEndpoint: Identifiable, Hashable, Sendable {
    public let id: String
    public let platform: EndpointPlatform
    public let name: String
    public let subtitle: String
    public let detailBadge: String
    public let totalBytes: Int64
    public let availableBytes: Int64
    public let isReadOnly: Bool
    public let requiresAttention: Bool
    public let statusMessage: String?
    public let rootLocation: RemoteLocation
    public let driveInfo: DriveInfo?
    public let mtpBusLocation: UInt32?
    public let mtpDevNum: UInt8?
    public let mtpStorageID: UInt32?
    public let adbSerial: String?
    public let iosUDID: String?
    public let iosAppBundleID: String?

    public init(
        id: String,
        platform: EndpointPlatform,
        name: String,
        subtitle: String,
        detailBadge: String,
        totalBytes: Int64 = 0,
        availableBytes: Int64 = 0,
        isReadOnly: Bool = false,
        requiresAttention: Bool = false,
        statusMessage: String? = nil,
        rootLocation: RemoteLocation,
        driveInfo: DriveInfo? = nil,
        mtpBusLocation: UInt32? = nil,
        mtpDevNum: UInt8? = nil,
        mtpStorageID: UInt32? = nil,
        adbSerial: String? = nil,
        iosUDID: String? = nil,
        iosAppBundleID: String? = nil
    ) {
        self.id = id
        self.platform = platform
        self.name = name
        self.subtitle = subtitle
        self.detailBadge = detailBadge
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
        self.isReadOnly = isReadOnly
        self.requiresAttention = requiresAttention
        self.statusMessage = statusMessage
        self.rootLocation = rootLocation
        self.driveInfo = driveInfo
        self.mtpBusLocation = mtpBusLocation
        self.mtpDevNum = mtpDevNum
        self.mtpStorageID = mtpStorageID
        self.adbSerial = adbSerial
        self.iosUDID = iosUDID
        self.iosAppBundleID = iosAppBundleID
    }

    public var usedBytes: Int64 {
        max(0, totalBytes - availableBytes)
    }

    public var usageFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1.0, max(0.0, Double(usedBytes) / Double(totalBytes)))
    }

    public static func macHome() -> StorageEndpoint {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let space = FileBrowserService.volumeSpaceInfo(for: home)
        return StorageEndpoint(
            id: "mac::local",
            platform: .macOS,
            name: "Your Mac",
            subtitle: Host.current().localizedName ?? "Macintosh HD",
            detailBadge: "macOS",
            totalBytes: space.total,
            availableBytes: space.available,
            isReadOnly: false,
            requiresAttention: false,
            statusMessage: nil,
            rootLocation: .local(home)
        )
    }

    public static func fromDrive(_ drive: DriveInfo) -> StorageEndpoint {
        StorageEndpoint(
            id: "drive::\(drive.id)",
            platform: .pendrive,
            name: drive.name,
            subtitle: "\(drive.connectionKind.rawValue) • \(drive.fileSystemName)",
            detailBadge: drive.isReadOnly ? "\(drive.fileSystemName) (Read-Only)" : drive.fileSystemName,
            totalBytes: drive.totalBytes,
            availableBytes: drive.availableBytes,
            isReadOnly: drive.isReadOnly,
            requiresAttention: false,
            statusMessage: drive.isNTFSReadOnly
                ? "NTFS is read-only on macOS (copy from drive only)"
                : (drive.isFAT32 ? "FAT32: 4 GB max per file" : nil),
            rootLocation: .local(drive.volumeURL),
            driveInfo: drive
        )
    }
}

/// Represents a file or folder shown inside either pane (local or remote).
public struct FileItem: Identifiable, Hashable, Sendable {
    public var id: URL { url }
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public let isPackage: Bool
    public let isSymlink: Bool
    public let size: Int64
    public let modifiedDate: Date
    public let contentTypeIdentifier: String?
    public let isHidden: Bool

    public init(
        url: URL,
        name: String,
        isDirectory: Bool,
        isPackage: Bool = false,
        isSymlink: Bool = false,
        size: Int64,
        modifiedDate: Date,
        contentTypeIdentifier: String? = nil,
        isHidden: Bool = false
    ) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.isSymlink = isSymlink
        self.size = size
        self.modifiedDate = modifiedDate
        self.contentTypeIdentifier = contentTypeIdentifier
        self.isHidden = isHidden
    }

    public var fileExtension: String {
        url.pathExtension.lowercased()
    }

    public var kindDescription: String {
        if isDirectory && !isPackage {
            return "Folder"
        }
        if !fileExtension.isEmpty {
            return "\(fileExtension.uppercased()) File"
        }
        return "Document"
    }
}

/// Unified browser item supporting Mac, Pendrives, Android MTP, Android ADB, and iOS.
public struct BrowserEntry: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let isDirectory: Bool
    public let isPackage: Bool
    public let size: Int64
    public let modifiedDate: Date
    public let isHidden: Bool
    public let location: RemoteLocation
    public let mtpObjectID: UInt32?
    public let remotePath: String?

    public init(
        id: String,
        name: String,
        isDirectory: Bool,
        isPackage: Bool = false,
        size: Int64,
        modifiedDate: Date,
        isHidden: Bool = false,
        location: RemoteLocation,
        mtpObjectID: UInt32? = nil,
        remotePath: String? = nil
    ) {
        self.id = id
        self.name = name
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.size = size
        self.modifiedDate = modifiedDate
        self.isHidden = isHidden
        self.location = location
        self.mtpObjectID = mtpObjectID
        self.remotePath = remotePath
    }

    public init(fileItem: FileItem) {
        self.id = fileItem.url.path
        self.name = fileItem.name
        self.isDirectory = fileItem.isDirectory
        self.isPackage = fileItem.isPackage
        self.size = fileItem.size
        self.modifiedDate = fileItem.modifiedDate
        self.isHidden = fileItem.isHidden
        self.location = .local(fileItem.url)
        self.mtpObjectID = nil
        self.remotePath = nil
    }

    public var localURL: URL? {
        location.localURL
    }

    public var fileExtension: String {
        (name as NSString).pathExtension.lowercased()
    }

    public var kindDescription: String {
        if isDirectory && !isPackage {
            return "Folder"
        }
        if !fileExtension.isEmpty {
            return "\(fileExtension.uppercased()) File"
        }
        return "Document"
    }
}

public enum SortField: String, CaseIterable, Sendable {
    case name = "Name"
    case size = "Size"
    case dateModified = "Modified"
    case kind = "Kind"
}

public enum TransferDirection: Equatable, Sendable {
    case macToPendrive
    case pendriveToMac
    case bridge(from: String, to: String)

    public var label: String {
        switch self {
        case .macToPendrive: return "Mac -> Pendrive"
        case .pendriveToMac: return "Pendrive -> Mac"
        case .bridge(let from, let to): return "\(from) -> \(to)"
        }
    }
}

public enum TransferMode: String, Sendable {
    case copy = "Copy"
    case move = "Move"
}

public enum ConflictPolicy: String, CaseIterable, Sendable {
    case ask = "Ask Each Time"
    case replace = "Replace Existing"
    case skip = "Skip Existing"
    case keepBoth = "Keep Both"
}

public enum ConflictResolution: Sendable {
    case replace
    case skip
    case keepBoth
    case cancelAll
}

public struct ConflictPrompt: Identifiable, Sendable {
    public let id: UUID
    public let sourceURL: URL
    public let destinationURL: URL
    public let sourceName: String
    public let destinationPathDisplay: String
    public let sourceSize: Int64
    public let destinationSize: Int64
    public let sourceDate: Date?
    public let destinationDate: Date?

    public init(
        id: UUID = UUID(),
        sourceURL: URL,
        destinationURL: URL,
        sourceName: String? = nil,
        destinationPathDisplay: String? = nil,
        sourceSize: Int64,
        destinationSize: Int64,
        sourceDate: Date?,
        destinationDate: Date?
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.destinationURL = destinationURL
        self.sourceName = sourceName ?? destinationURL.lastPathComponent
        self.destinationPathDisplay = destinationPathDisplay ?? destinationURL.path
        self.sourceSize = sourceSize
        self.destinationSize = destinationSize
        self.sourceDate = sourceDate
        self.destinationDate = destinationDate
    }
}

public enum TransferStatus: Equatable, Sendable {
    case queued
    case preparing
    case transferring
    case paused
    case completed
    case completedWithSkips(Int)
    case cancelled
    case failed(String)

    public var isActive: Bool {
        switch self {
        case .queued, .preparing, .transferring, .paused:
            return true
        case .completed, .completedWithSkips, .cancelled, .failed:
            return false
        }
    }

    public var isTerminal: Bool {
        !isActive
    }

    public var label: String {
        switch self {
        case .queued:
            return "Queued"
        case .preparing:
            return "Preparing..."
        case .transferring:
            return "Transferring"
        case .paused:
            return "Paused"
        case .completed:
            return "Completed"
        case .completedWithSkips(let skipped):
            return "Completed (\(skipped) skipped)"
        case .cancelled:
            return "Cancelled"
        case .failed(let reason):
            return "Failed: \(reason)"
        }
    }
}

public struct TransferJob: Identifiable, Sendable {
    public let id: UUID
    public var title: String
    public let direction: TransferDirection
    public let mode: TransferMode
    public let sourceURLs: [URL]
    public let destinationDirectory: URL?
    public let driveName: String
    public var status: TransferStatus
    public var totalBytes: Int64
    public var bytesTransferred: Int64
    public var totalFiles: Int
    public var filesCompleted: Int
    public var filesSkipped: Int
    public var currentFileName: String
    public var speedBytesPerSecond: Double
    public var estimatedSecondsRemaining: Double?
    public let startedAt: Date
    public var finishedAt: Date?

    public init(
        id: UUID = UUID(),
        title: String,
        direction: TransferDirection,
        mode: TransferMode,
        sourceURLs: [URL] = [],
        destinationDirectory: URL? = nil,
        driveName: String,
        status: TransferStatus = .queued,
        totalBytes: Int64 = 0,
        bytesTransferred: Int64 = 0,
        totalFiles: Int = 0,
        filesCompleted: Int = 0,
        filesSkipped: Int = 0,
        currentFileName: String = "",
        speedBytesPerSecond: Double = 0,
        estimatedSecondsRemaining: Double? = nil,
        startedAt: Date = Date(),
        finishedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.direction = direction
        self.mode = mode
        self.sourceURLs = sourceURLs
        self.destinationDirectory = destinationDirectory
        self.driveName = driveName
        self.status = status
        self.totalBytes = totalBytes
        self.bytesTransferred = bytesTransferred
        self.totalFiles = totalFiles
        self.filesCompleted = filesCompleted
        self.filesSkipped = filesSkipped
        self.currentFileName = currentFileName
        self.speedBytesPerSecond = speedBytesPerSecond
        self.estimatedSecondsRemaining = estimatedSecondsRemaining
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    public var progress: Double {
        if totalBytes > 0 {
            return min(1.0, max(0.0, Double(bytesTransferred) / Double(totalBytes)))
        }
        switch status {
        case .completed, .completedWithSkips:
            return 1.0
        default:
            if totalFiles > 0 {
                return min(1.0, Double(filesCompleted) / Double(totalFiles))
            }
            return 0.0
        }
    }
}

public enum FormattingHelpers {
    public static func formatByteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    public static func formatSpeed(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond > 0 else { return "--" }
        let formatted = ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file)
        return "\(formatted)/s"
    }

    public static func formatDuration(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "--" }
        let totalSeconds = Int(seconds.rounded())
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    public static func sortBrowserEntries(_ entries: [BrowserEntry], by field: SortField, ascending: Bool) -> [BrowserEntry] {
        entries.sorted { lhs, rhs in
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
}
