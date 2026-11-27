import AppKit
import Combine
import Foundation
import UniBridgeCore

public enum PaneSide: Sendable {
    case left
    case right

    public var other: PaneSide {
        self == .left ? .right : .left
    }
}

public struct ActiveConflictState: Identifiable {
    public let id = UUID()
    public let prompt: ConflictPrompt
    fileprivate let continuation: CheckedContinuation<(ConflictResolution, Bool), Never>
}

public struct NamePromptState: Identifiable {
    public enum Kind {
        case newFolder(pane: PaneSide, location: RemoteLocation)
        case rename(pane: PaneSide, parent: RemoteLocation, entry: BrowserEntry)
    }
    public let id = UUID()
    public let kind: Kind
    public var text: String
}

public struct DeletePromptState: Identifiable {
    public let id = UUID()
    public let pane: PaneSide
    public let parent: RemoteLocation
    public let entries: [BrowserEntry]
    public let isRemoteOrRemovable: Bool
}

public struct PaneModel {
    public var selectedEndpointID: String?
    public var currentLocation: RemoteLocation?
    public var entries: [BrowserEntry] = []
    public var selection: Set<String> = []
    public var searchText: String = ""
    public var sortField: SortField = .name
    public var sortAscending: Bool = true
    public var errorMessage: String?
    public var isLoading: Bool = false
    public var isDropTargeted: Bool = false
    public var history: [RemoteLocation] = []
    public var historyIndex: Int = -1
    public var lastClickedID: String?
}

@MainActor
public final class AppState: ObservableObject {
    public let deviceManager = DeviceManager()
    private let transferService: UnifiedTransferService

    @Published public var leftPane = PaneModel()
    @Published public var rightPane = PaneModel()

    @Published public var showHiddenFiles: Bool = false
    @Published public var conflictPolicy: ConflictPolicy = .ask
    @Published public var jobs: [TransferJob] = []
    @Published public var activeConflict: ActiveConflictState?
    @Published public var conflictApplyToAll: Bool = false
    @Published public var namePrompt: NamePromptState?
    @Published public var namePromptText: String = ""
    @Published public var deletePrompt: DeletePromptState?
    @Published public var alertMessage: String?
    @Published public var isEjecting: Bool = false
    @Published public var showTransferQueue: Bool = true

    public var activeInternalDrag: (pane: PaneSide, entries: [BrowserEntry])?

    private var controls: [UUID: TransferControl] = [:]
    private var cancellables: Set<AnyCancellable> = []

    public init() {
        self.transferService = UnifiedTransferService(
            mtpService: deviceManager.mtpService,
            adbService: deviceManager.adbService,
            iosService: deviceManager.iosService
        )

        // Default Left Pane to Your Mac
        let macEndpoint = StorageEndpoint.macHome()
        leftPane.selectedEndpointID = macEndpoint.id
        leftPane.currentLocation = macEndpoint.rootLocation
        leftPane.history = [macEndpoint.rootLocation]
        leftPane.historyIndex = 0

        deviceManager.$endpoints
            .receive(on: RunLoop.main)
            .sink { [weak self] endpoints in
                self?.handleEndpointsUpdated(endpoints)
            }
            .store(in: &cancellables)

        deviceManager.start()
        refreshPane(.left)
    }

    public var endpoints: [StorageEndpoint] {
        deviceManager.endpoints
    }

    public var macQuickLocations: [(label: String, icon: String, url: URL)] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var list: [(String, String, URL)] = [("Home", "house.fill", home)]
        let candidates: [(String, String, FileManager.SearchPathDirectory)] = [
            ("Desktop", "menubar.dock.rectangle", .desktopDirectory),
            ("Downloads", "arrow.down.circle.fill", .downloadsDirectory),
            ("Documents", "doc.text.fill", .documentDirectory),
            ("Pictures", "photo.fill", .picturesDirectory),
            ("Movies", "film.fill", .moviesDirectory)
        ]
        for (title, icon, dir) in candidates {
            if let url = fm.urls(for: dir, in: .userDomainMask).first {
                list.append((title, icon, url))
            }
        }
        return list
    }

    public func pane(_ side: PaneSide) -> PaneModel {
        side == .left ? leftPane : rightPane
    }

    private func updatePane(_ side: PaneSide, _ mutate: (inout PaneModel) -> Void) {
        if side == .left {
            mutate(&leftPane)
        } else {
            mutate(&rightPane)
        }
    }

    public func endpoint(for side: PaneSide) -> StorageEndpoint? {
        guard let id = pane(side).selectedEndpointID else { return nil }
        return endpoints.first { $0.id == id }
    }

    public func filteredEntries(for side: PaneSide) -> [BrowserEntry] {
        let model = pane(side)
        let q = model.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return model.entries }
        return model.entries.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    public func canGoBack(_ side: PaneSide) -> Bool {
        pane(side).historyIndex > 0
    }

    public func canGoForward(_ side: PaneSide) -> Bool {
        let m = pane(side)
        return m.historyIndex >= 0 && m.historyIndex < m.history.count - 1
    }

    public func canGoUp(_ side: PaneSide) -> Bool {
        guard let loc = pane(side).currentLocation, let ep = endpoint(for: side) else { return false }
        switch (loc, ep.rootLocation) {
        case (.local(let cur), .local(let root)):
            if ep.platform == .macOS {
                return cur.standardizedFileURL.path != "/"
            }
            return cur.standardizedFileURL.path != root.standardizedFileURL.path
        case (.mtp(_, _, _, _, let trail), _):
            return !trail.isEmpty
        case (.adb(_, let path), .adb(_, let rootPath)):
            return path != rootPath && path != "/"
        case (.ios(_, _, let path), .ios(_, _, let rootPath)):
            return path != rootPath && path != "/"
        default:
            return false
        }
    }

    public var activeJobCount: Int {
        jobs.filter { $0.status.isActive }.count
    }

    public var canTransferLeftToRight: Bool {
        let leftSel = leftPane.selection
        guard !leftSel.isEmpty,
              let leftEp = endpoint(for: .left),
              let rightEp = endpoint(for: .right),
              rightPane.currentLocation != nil,
              !rightEp.requiresAttention,
              !rightEp.isReadOnly
        else { return false }
        _ = leftEp
        return true
    }

    public var canTransferRightToLeft: Bool {
        let rightSel = rightPane.selection
        guard !rightSel.isEmpty,
              let rightEp = endpoint(for: .right),
              let leftEp = endpoint(for: .left),
              leftPane.currentLocation != nil,
              !leftEp.requiresAttention,
              !leftEp.isReadOnly
        else { return false }
        _ = rightEp
        return true
    }

    // MARK: - Device Discovery & Switching

    private func handleEndpointsUpdated(_ newEndpoints: [StorageEndpoint]) {
        // Keep Left Pane valid (default to Mac if disconnected)
        if let leftID = leftPane.selectedEndpointID,
           let match = newEndpoints.first(where: { $0.id == leftID })
        {
            if case .local(let url) = leftPane.currentLocation,
               !FileManager.default.fileExists(atPath: url.path)
            {
                navigate(side: .left, to: match.rootLocation, recordHistory: true)
            }
        } else if let mac = newEndpoints.first {
            selectEndpoint(mac, in: .left)
        }

        // Keep Right Pane valid or auto-select first connected external/mobile device!
        if let rightID = rightPane.selectedEndpointID,
           let match = newEndpoints.first(where: { $0.id == rightID })
        {
            if match.requiresAttention {
                updatePane(.right) {
                    $0.entries = []
                    $0.errorMessage = nil
                }
            } else if case .local(let url) = rightPane.currentLocation,
                      !FileManager.default.fileExists(atPath: url.path)
            {
                navigate(side: .right, to: match.rootLocation, recordHistory: true)
            }
        } else if let prevID = rightPane.selectedEndpointID,
                  prevID.hasPrefix("mtp::"),
                  let readyMTP = newEndpoints.first(where: { $0.platform == .androidMTP && !$0.requiresAttention })
        {
            selectEndpoint(readyMTP, in: .right)
        } else if let prevID = rightPane.selectedEndpointID,
                  prevID.hasPrefix("ios::"),
                  let readyIOS = newEndpoints.first(where: { ($0.platform == .iosMedia || $0.platform == .iosApp) && !$0.requiresAttention })
        {
            selectEndpoint(readyIOS, in: .right)
        } else if let autoExternal = newEndpoints.first(where: { $0.platform != .macOS }) {
            selectEndpoint(autoExternal, in: .right)
        } else {
            // No external device connected; clear right pane if previous device disappeared.
            if rightPane.selectedEndpointID != StorageEndpoint.macHome().id {
                updatePane(.right) {
                    $0.selectedEndpointID = nil
                    $0.currentLocation = nil
                    $0.entries = []
                    $0.selection = []
                    $0.history = []
                    $0.historyIndex = -1
                    $0.errorMessage = nil
                }
            }
        }
    }

    public func selectEndpoint(_ endpoint: StorageEndpoint, in side: PaneSide) {
        updatePane(side) {
            $0.selectedEndpointID = endpoint.id
            $0.currentLocation = endpoint.rootLocation
            $0.selection = []
            $0.searchText = ""
            $0.history = [endpoint.rootLocation]
            $0.historyIndex = 0
            $0.lastClickedID = nil
            $0.errorMessage = nil
        }
        refreshPane(side)
    }

    public func swapPanes() {
        let oldLeft = leftPane
        leftPane = rightPane
        rightPane = oldLeft
        refreshAll()
    }

    public func rescanDevices() {
        Task {
            await deviceManager.refreshNow()
            refreshPane(.left)
            refreshPane(.right)
        }
    }

    public func ejectPendrive(in side: PaneSide) {
        guard let ep = endpoint(for: side), let drive = ep.driveInfo else { return }
        if activeJobCount > 0 {
            alertMessage = "A transfer is currently running. Finish or cancel it before ejecting '\(drive.name)'."
            return
        }
        isEjecting = true
        Task {
            defer { isEjecting = false }
            do {
                try await deviceManager.ejectDrive(drive)
            } catch {
                alertMessage = error.localizedDescription
            }
        }
    }

    public func chooseMacFolder(in side: PaneSide) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if case .local(let url) = pane(side).currentLocation {
            panel.directoryURL = url
        }
        panel.prompt = "Open Folder"
        if panel.runModal() == .OK, let url = panel.url {
            if endpoint(for: side)?.platform != .macOS {
                if let macEp = endpoints.first(where: { $0.platform == .macOS }) {
                    selectEndpoint(macEp, in: side)
                }
            }
            navigate(side: side, to: .local(url))
        }
    }

    public func chooseCustomFolderEndpoint(in side: PaneSide) {
        let panel = NSOpenPanel()
        panel.title = "Select Any Folder or Mounted Volume"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Target"
        if panel.runModal() == .OK, let url = panel.url {
            deviceManager.addCustomFolderTarget(url)
            if let match = deviceManager.endpoints.first(where: { $0.rootLocation == .local(url) }) {
                selectEndpoint(match, in: side)
            }
        }
    }

    // MARK: - Navigation & Listing

    public func navigate(side: PaneSide, to location: RemoteLocation, recordHistory: Bool = true) {
        updatePane(side) {
            $0.currentLocation = location
            $0.selection = []
            $0.lastClickedID = nil
            if recordHistory {
                if $0.historyIndex < $0.history.count - 1 {
                    $0.history.removeSubrange(($0.historyIndex + 1)...)
                }
                if $0.history.last != location {
                    $0.history.append(location)
                    $0.historyIndex = $0.history.count - 1
                }
            }
        }
        refreshPane(side)
    }

    public func goBack(_ side: PaneSide) {
        let model = pane(side)
        guard model.historyIndex > 0 else { return }
        let targetIndex = model.historyIndex - 1
        updatePane(side) { $0.historyIndex = targetIndex }
        navigate(side: side, to: model.history[targetIndex], recordHistory: false)
    }

    public func goForward(_ side: PaneSide) {
        let model = pane(side)
        guard model.historyIndex >= 0 && model.historyIndex < model.history.count - 1 else { return }
        let targetIndex = model.historyIndex + 1
        updatePane(side) { $0.historyIndex = targetIndex }
        navigate(side: side, to: model.history[targetIndex], recordHistory: false)
    }

    public func goUp(_ side: PaneSide) {
        guard canGoUp(side), let loc = pane(side).currentLocation else { return }
        switch loc {
        case .local(let url):
            navigate(side: side, to: .local(url.deletingLastPathComponent()))
        case .mtp(let bus, let dev, let storageID, _, let trail):
            let newTrail = Array(trail.dropLast())
            let parentID = newTrail.last?.folderID ?? 0
            navigate(
                side: side,
                to: .mtp(busLocation: bus, devNum: dev, storageID: storageID, folderID: parentID, trail: newTrail)
            )
        case .adb(let serial, let path):
            let parent = (path as NSString).deletingLastPathComponent
            navigate(side: side, to: .adb(serial: serial, path: parent.isEmpty ? "/" : parent))
        case .ios(let udid, let bundleID, let path):
            let parent = (path as NSString).deletingLastPathComponent
            navigate(side: side, to: .ios(udid: udid, appBundleID: bundleID, path: parent.isEmpty ? "/" : parent))
        }
    }

    public func refreshPane(_ side: PaneSide) {
        guard let loc = pane(side).currentLocation,
              let ep = endpoint(for: side)
        else {
            updatePane(side) {
                $0.entries = []
                $0.errorMessage = nil
                $0.isLoading = false
            }
            return
        }

        if ep.requiresAttention {
            updatePane(side) {
                $0.entries = []
                $0.errorMessage = nil
                $0.isLoading = false
            }
            return
        }

        let showHidden = showHiddenFiles
        let sortField = pane(side).sortField
        let ascending = pane(side).sortAscending

        updatePane(side) { $0.isLoading = true }

        Task { [weak self] in
            guard let self else { return }
            do {
                let list = try await self.transferService.listEntries(
                    at: loc,
                    showHidden: showHidden,
                    sortBy: sortField,
                    ascending: ascending
                )
                await MainActor.run {
                    guard self.pane(side).currentLocation == loc else { return }
                    let validIDs = Set(list.map(\.id))
                    self.updatePane(side) {
                        $0.entries = list
                        $0.errorMessage = nil
                        $0.isLoading = false
                        $0.selection = $0.selection.intersection(validIDs)
                    }
                }
            } catch {
                await MainActor.run {
                    guard self.pane(side).currentLocation == loc else { return }
                    self.updatePane(side) {
                        $0.entries = []
                        $0.errorMessage = error.localizedDescription
                        $0.isLoading = false
                    }
                }
            }
        }
    }

    public func refreshAll() {
        rescanDevices()
    }

    public func toggleSort(side: PaneSide, field: SortField) {
        updatePane(side) {
            if $0.sortField == field {
                $0.sortAscending.toggle()
            } else {
                $0.sortField = field
                $0.sortAscending = true
            }
        }
        refreshPane(side)
    }

    public func toggleShowHidden() {
        showHiddenFiles.toggle()
        refreshPane(.left)
        refreshPane(.right)
    }

    // MARK: - Selection & Row Click

    public func handleRowClick(entry: BrowserEntry, side: PaneSide, modifiers: NSEvent.ModifierFlags) {
        let visible = filteredEntries(for: side)
        var sel = pane(side).selection
        let anchor = pane(side).lastClickedID

        if modifiers.contains(.shift), let anchor,
           let anchorIdx = visible.firstIndex(where: { $0.id == anchor }),
           let targetIdx = visible.firstIndex(where: { $0.id == entry.id })
        {
            let lower = min(anchorIdx, targetIdx)
            let upper = max(anchorIdx, targetIdx)
            for i in lower...upper {
                sel.insert(visible[i].id)
            }
        } else if modifiers.contains(.command) {
            if sel.contains(entry.id) {
                sel.remove(entry.id)
            } else {
                sel.insert(entry.id)
            }
        } else {
            sel = [entry.id]
        }

        updatePane(side) {
            $0.selection = sel
            $0.lastClickedID = entry.id
        }
    }

    public func clearSelection(_ side: PaneSide) {
        updatePane(side) { $0.selection = [] }
    }

    public func openEntry(_ entry: BrowserEntry, in side: PaneSide) {
        if entry.isDirectory && !entry.isPackage {
            navigate(side: side, to: entry.location)
        } else if let localURL = entry.localURL {
            NSWorkspace.shared.open(localURL)
        } else {
            // For remote files on Android/iOS, double-click copies to the opposite pane if writable.
            transfer(entries: [entry], from: side, to: side.other, mode: .copy)
        }
    }

    public func revealInFinder(_ entries: [BrowserEntry]) {
        let urls = entries.compactMap(\.localURL)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    // MARK: - Folder / Rename / Delete

    public func promptNewFolder(in side: PaneSide) {
        guard let loc = pane(side).currentLocation,
              let ep = endpoint(for: side)
        else { return }

        if ep.isReadOnly || ep.requiresAttention {
            alertMessage = "'\(ep.name)' is currently read-only or requires attention."
            return
        }
        namePromptText = "New Folder"
        namePrompt = NamePromptState(kind: .newFolder(pane: side, location: loc), text: "New Folder")
    }

    public func promptRename(entry: BrowserEntry, in side: PaneSide) {
        guard let loc = pane(side).currentLocation,
              let ep = endpoint(for: side)
        else { return }

        if ep.isReadOnly || ep.requiresAttention {
            alertMessage = "'\(ep.name)' is read-only and cannot rename items."
            return
        }
        namePromptText = entry.name
        namePrompt = NamePromptState(kind: .rename(pane: side, parent: loc, entry: entry), text: entry.name)
    }

    public func submitNamePrompt(_ prompt: NamePromptState) {
        let enteredName = namePromptText
        namePrompt = nil

        Task { [weak self] in
            guard let self else { return }
            do {
                switch prompt.kind {
                case .newFolder(let side, let location):
                    try await self.transferService.createFolder(named: enteredName, in: location)
                    await MainActor.run { self.refreshPane(side) }
                case .rename(let side, let parent, let entry):
                    try await self.transferService.rename(entry: entry, in: parent, to: enteredName)
                    await MainActor.run { self.refreshPane(side) }
                }
            } catch {
                await MainActor.run { self.alertMessage = error.localizedDescription }
            }
        }
    }

    public func requestDelete(entries: [BrowserEntry], in side: PaneSide) {
        guard !entries.isEmpty,
              let loc = pane(side).currentLocation,
              let ep = endpoint(for: side)
        else { return }

        if ep.isReadOnly || ep.requiresAttention {
            alertMessage = "'\(ep.name)' is read-only and cannot delete items."
            return
        }
        deletePrompt = DeletePromptState(
            pane: side,
            parent: loc,
            entries: entries,
            isRemoteOrRemovable: ep.platform != .macOS
        )
    }

    public func confirmDelete(_ prompt: DeletePromptState) {
        deletePrompt = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.transferService.delete(
                    entries: prompt.entries,
                    from: prompt.parent,
                    permanentlyIfTrashUnavailable: prompt.isRemoteOrRemovable
                )
                await MainActor.run { self.refreshPane(prompt.pane) }
            } catch {
                await MainActor.run { self.alertMessage = error.localizedDescription }
            }
        }
    }

    // MARK: - Transfers (Mac <-> Pendrive <-> Android <-> iOS)

    public func transferSelected(from sourceSide: PaneSide, to destSide: PaneSide, mode: TransferMode) {
        let selected = orderedSelection(in: sourceSide)
        transfer(entries: selected, from: sourceSide, to: destSide, mode: mode)
    }

    public func transfer(entries: [BrowserEntry], from sourceSide: PaneSide, to destSide: PaneSide, mode: TransferMode) {
        guard !entries.isEmpty,
              let sourceEp = endpoint(for: sourceSide),
              let sourceLoc = pane(sourceSide).currentLocation,
              let destEp = endpoint(for: destSide),
              let destLoc = pane(destSide).currentLocation
        else {
            alertMessage = "Select a valid source and destination device."
            return
        }

        if destEp.requiresAttention {
            alertMessage = destEp.statusMessage ?? "Destination device '\(destEp.name)' is not ready."
            return
        }
        if destEp.isReadOnly {
            alertMessage = "'\(destEp.name)' is read-only and cannot receive files."
            return
        }
        if mode == .move && sourceEp.isReadOnly {
            alertMessage = "'\(sourceEp.name)' is read-only, so files cannot be moved (removed from source). Use Copy instead."
            return
        }

        enqueueTransfer(
            entries: entries,
            sourceEp: sourceEp,
            sourceParent: sourceLoc,
            destEp: destEp,
            destDir: destLoc,
            mode: mode
        )
    }

    public func handleFinderDrop(urls: [URL], onto targetSide: PaneSide) {
        guard !urls.isEmpty,
              let destEp = endpoint(for: targetSide),
              let destLoc = pane(targetSide).currentLocation
        else { return }

        if destEp.requiresAttention {
            alertMessage = destEp.statusMessage ?? "'\(destEp.name)' is not ready."
            return
        }
        if destEp.isReadOnly {
            alertMessage = "'\(destEp.name)' is read-only and cannot receive files."
            return
        }

        let entries: [BrowserEntry] = urls.map { url in
            let rv = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey])
            let isDir = rv?.isDirectory ?? false
            let isPkg = rv?.isPackage ?? false
            let size = Int64(rv?.fileSize ?? 0)
            let mod = rv?.contentModificationDate ?? Date()
            return BrowserEntry(
                id: url.path,
                name: url.lastPathComponent,
                isDirectory: isDir,
                isPackage: isPkg,
                size: isDir && !isPkg ? 0 : size,
                modifiedDate: mod,
                isHidden: url.lastPathComponent.hasPrefix("."),
                location: .local(url)
            )
        }

        let finderEp = StorageEndpoint.macHome()
        let parentURL = urls[0].deletingLastPathComponent()
        enqueueTransfer(
            entries: entries,
            sourceEp: finderEp,
            sourceParent: .local(parentURL),
            destEp: destEp,
            destDir: destLoc,
            mode: .copy
        )
    }

    private func enqueueTransfer(
        entries: [BrowserEntry],
        sourceEp: StorageEndpoint,
        sourceParent: RemoteLocation,
        destEp: StorageEndpoint,
        destDir: RemoteLocation,
        mode: TransferMode
    ) {
        let title = entries.count == 1
            ? entries[0].name
            : "\(entries[0].name) + \(entries.count - 1) more"

        let direction: TransferDirection = .bridge(from: sourceEp.name, to: destEp.name)
        let job = TransferJob(
            title: title,
            direction: direction,
            mode: mode,
            sourceURLs: entries.compactMap(\.localURL),
            destinationDirectory: destDir.localURL,
            driveName: destEp.name,
            status: .preparing,
            totalFiles: entries.count,
            currentFileName: entries.first?.name ?? ""
        )

        let control = TransferControl()
        controls[job.id] = control
        jobs.insert(job, at: 0)
        showTransferQueue = true

        let service = transferService
        let policy = conflictPolicy

        Task { [weak self] in
            guard let self else { return }
            do {
                let outcome = try await service.execute(
                    entries: entries,
                    from: sourceEp,
                    sourceParent: sourceParent,
                    to: destEp,
                    destinationDirectory: destDir,
                    mode: mode,
                    conflictPolicy: policy,
                    control: control,
                    onProgress: { [weak self] snapshot in
                        await MainActor.run {
                            self?.applyProgress(snapshot, to: job.id)
                        }
                    },
                    onConflict: { [weak self] prompt in
                        guard let self else { return (.cancelAll, false) }
                        return await self.askUserConflict(prompt: prompt)
                    }
                )

                await MainActor.run {
                    self.markJobCompleted(jobID: job.id, filesCompleted: outcome.filesCompleted, filesSkipped: outcome.filesSkipped)
                }
            } catch TransferError.cancelled, AndroidMTPError.cancelled, AndroidADBError.cancelled, IOSDeviceError.cancelled {
                await MainActor.run {
                    self.markJobCancelled(jobID: job.id)
                }
            } catch {
                await MainActor.run {
                    self.markJobFailed(jobID: job.id, message: error.localizedDescription)
                }
            }
        }
    }

    public func togglePause(jobID: UUID) {
        guard let idx = jobs.firstIndex(where: { $0.id == jobID }),
              let control = controls[jobID]
        else { return }

        if control.isPaused {
            control.resume()
            jobs[idx].status = .transferring
        } else if jobs[idx].status == .transferring || jobs[idx].status == .preparing {
            control.pause()
            jobs[idx].status = .paused
        }
    }

    public func cancelJob(jobID: UUID) {
        controls[jobID]?.cancel()
        if let idx = jobs.firstIndex(where: { $0.id == jobID }), jobs[idx].status.isActive {
            jobs[idx].status = .cancelled
            jobs[idx].finishedAt = Date()
        }
    }

    public func clearCompletedJobs() {
        jobs.removeAll { $0.status.isTerminal }
    }

    public func resolveConflict(resolution: ConflictResolution, applyToAll: Bool) {
        guard let pending = activeConflict else { return }
        activeConflict = nil
        conflictApplyToAll = false
        pending.continuation.resume(returning: (resolution, applyToAll))
    }

    // MARK: - Private Helpers

    private func applyProgress(_ snapshot: TransferProgressSnapshot, to jobID: UUID) {
        guard let idx = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        if jobs[idx].status == .preparing {
            jobs[idx].status = (controls[jobID]?.isPaused == true) ? .paused : .transferring
        }
        jobs[idx].totalBytes = snapshot.totalBytes
        jobs[idx].bytesTransferred = snapshot.bytesTransferred
        jobs[idx].totalFiles = snapshot.totalFiles
        jobs[idx].filesCompleted = snapshot.filesCompleted
        jobs[idx].filesSkipped = snapshot.filesSkipped
        jobs[idx].currentFileName = snapshot.currentFileName
        jobs[idx].speedBytesPerSecond = snapshot.speedBytesPerSecond
        jobs[idx].estimatedSecondsRemaining = snapshot.estimatedSecondsRemaining
    }

    private func markJobCompleted(jobID: UUID, filesCompleted: Int, filesSkipped: Int) {
        if let idx = jobs.firstIndex(where: { $0.id == jobID }) {
            jobs[idx].filesCompleted = filesCompleted
            jobs[idx].filesSkipped = filesSkipped
            jobs[idx].bytesTransferred = jobs[idx].totalBytes
            jobs[idx].speedBytesPerSecond = 0
            jobs[idx].estimatedSecondsRemaining = 0
            jobs[idx].finishedAt = Date()
            jobs[idx].status = filesSkipped > 0 ? .completedWithSkips(filesSkipped) : .completed
        }
        controls.removeValue(forKey: jobID)
        refreshPane(.left)
        refreshPane(.right)
    }

    private func markJobCancelled(jobID: UUID) {
        if let idx = jobs.firstIndex(where: { $0.id == jobID }) {
            jobs[idx].status = .cancelled
            jobs[idx].speedBytesPerSecond = 0
            jobs[idx].estimatedSecondsRemaining = nil
            jobs[idx].finishedAt = Date()
        }
        controls.removeValue(forKey: jobID)
        refreshPane(.left)
        refreshPane(.right)
    }

    private func markJobFailed(jobID: UUID, message: String) {
        if let idx = jobs.firstIndex(where: { $0.id == jobID }) {
            jobs[idx].status = .failed(message)
            jobs[idx].speedBytesPerSecond = 0
            jobs[idx].estimatedSecondsRemaining = nil
            jobs[idx].finishedAt = Date()
        }
        controls.removeValue(forKey: jobID)
        refreshPane(.left)
        refreshPane(.right)
    }

    private func askUserConflict(prompt: ConflictPrompt) async -> (ConflictResolution, Bool) {
        await withCheckedContinuation { continuation in
            self.conflictApplyToAll = false
            self.activeConflict = ActiveConflictState(prompt: prompt, continuation: continuation)
        }
    }

    private func orderedSelection(in side: PaneSide) -> [BrowserEntry] {
        let model = pane(side)
        return model.entries.filter { model.selection.contains($0.id) }
    }
}
