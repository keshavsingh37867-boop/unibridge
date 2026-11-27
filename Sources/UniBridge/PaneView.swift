import AppKit
import UniBridgeCore
import SwiftUI
import UniformTypeIdentifiers

struct DevicePaneView: View {
    @ObservedObject var state: AppState
    let side: PaneSide

    private var model: PaneModel {
        state.pane(side)
    }

    private var selectedEndpoint: StorageEndpoint? {
        state.endpoint(for: side)
    }

    private var entries: [BrowserEntry] {
        state.filteredEntries(for: side)
    }

    private var dropTargetedBinding: Binding<Bool> {
        side == .left ? $state.leftPane.isDropTargeted : $state.rightPane.isDropTargeted
    }

    private var searchTextBinding: Binding<String> {
        side == .left ? $state.leftPane.searchText : $state.rightPane.searchText
    }

    var body: some View {
        VStack(spacing: 0) {
            paneHeader
            Divider()

            if let ep = selectedEndpoint {
                if ep.platform == .macOS {
                    macQuickBar
                    Divider()
                } else {
                    deviceStatusBanner(endpoint: ep)
                    Divider()
                }

                if ep.requiresAttention {
                    attentionStateView(endpoint: ep)
                } else {
                    navigationAndSearchBar
                    Divider()
                    columnHeaderBar
                    Divider()
                    fileListBody
                    Divider()
                    paneFooter(endpoint: ep)
                }
            } else {
                noDeviceEmptyState
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(model.isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.22), lineWidth: model.isDropTargeted ? 2.5 : 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .center) {
            if model.isDropTargeted {
                dropOverlayBadge
            }
        }
        .onDrop(of: [.fileURL, .text], isTargeted: dropTargetedBinding) { providers in
            handleDrop(providers: providers)
        }
    }

    // MARK: - Header & Device Selector

    private var paneHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: selectedEndpoint?.platform.sfSymbolName ?? "externaldrive.badge.plus")
                .font(.title3.weight(.semibold))
                .foregroundStyle(platformColor(selectedEndpoint?.platform))

            VStack(alignment: .leading, spacing: 2) {
                Menu {
                    endpointPickerMenuItems
                } label: {
                    HStack(spacing: 5) {
                        Text(selectedEndpoint?.name ?? "Choose Device...")
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize(horizontal: false, vertical: true)

                if let ep = selectedEndpoint {
                    Text(ep.platform == .macOS ? (model.currentLocation?.displayPath ?? ep.subtitle) : ep.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("No external device selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if let ep = selectedEndpoint {
                if ep.platform == .macOS {
                    Button {
                        state.chooseMacFolder(in: side)
                    } label: {
                        Label("Folder...", systemImage: "folder.badge.gearshape")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else if ep.platform == .pendrive, ep.driveInfo != nil {
                    Button {
                        state.ejectPendrive(in: side)
                    } label: {
                        if state.isEjecting {
                            ProgressView().controlSize(.small)
                        } else {
                            Label(ep.driveInfo?.isCustomFolder == true ? "Disconnect" : "Safe Eject", systemImage: "eject.fill")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(state.isEjecting)
                } else {
                    Text(ep.detailBadge)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(platformColor(ep.platform).opacity(0.15))
                        .foregroundStyle(platformColor(ep.platform))
                        .clipShape(Capsule())
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var endpointPickerMenuItems: some View {
        let macs = state.endpoints.filter { $0.platform == .macOS }
        let pendrives = state.endpoints.filter { $0.platform == .pendrive }
        let androids = state.endpoints.filter { $0.platform == .androidMTP || $0.platform == .androidADB }
        let iosDevices = state.endpoints.filter { $0.platform == .iosMedia || $0.platform == .iosApp }

        if !macs.isEmpty {
            Section("macOS") {
                ForEach(macs) { ep in
                    endpointButton(ep)
                }
            }
        }
        if !pendrives.isEmpty {
            Section("USB / OTG Pendrives") {
                ForEach(pendrives) { ep in
                    endpointButton(ep)
                }
            }
        }
        if !androids.isEmpty {
            Section("Android Devices") {
                ForEach(androids) { ep in
                    endpointButton(ep)
                }
            }
        }
        if !iosDevices.isEmpty {
            Section("iPhone & iPad (iOS)") {
                ForEach(iosDevices) { ep in
                    endpointButton(ep)
                }
            }
        }

        Divider()
        Button {
            state.chooseCustomFolderEndpoint(in: side)
        } label: {
            Label("Open Custom Folder as Target...", systemImage: "folder.badge.plus")
        }
        Button {
            state.rescanDevices()
        } label: {
            Label("Rescan All Connected Devices", systemImage: "arrow.clockwise")
        }
    }

    private func endpointButton(_ ep: StorageEndpoint) -> some View {
        Button {
            state.selectEndpoint(ep, in: side)
        } label: {
            HStack {
                Label("\(ep.name) (\(ep.detailBadge))", systemImage: ep.platform.sfSymbolName)
                if ep.id == selectedEndpoint?.id {
                    Image(systemName: "checkmark")
                }
            }
        }
    }

    private var macQuickBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(state.macQuickLocations, id: \.url) { loc in
                    let isActive = model.currentLocation == .local(loc.url)
                    Button {
                        state.navigate(side: side, to: .local(loc.url))
                    } label: {
                        Label(loc.label, systemImage: loc.icon)
                            .font(.caption.weight(isActive ? .semibold : .regular))
                    }
                    .buttonStyle(.bordered)
                    .tint(isActive ? .accentColor : .secondary)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.5))
    }

    private func deviceStatusBanner(endpoint: StorageEndpoint) -> some View {
        HStack(spacing: 8) {
            if endpoint.totalBytes > 0 {
                ProgressView(value: endpoint.usageFraction)
                    .tint(endpoint.usageFraction > 0.9 ? .red : platformColor(endpoint.platform))
                    .frame(maxWidth: 140)
                Text("\(FormattingHelpers.formatByteCount(endpoint.availableBytes)) free of \(FormattingHelpers.formatByteCount(endpoint.totalBytes))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(endpoint.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let note = endpoint.statusMessage {
                Label(note, systemImage: endpoint.isReadOnly ? "exclamationmark.triangle.fill" : "info.circle.fill")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(endpoint.isReadOnly ? Color.orange : Color.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.5))
    }

    private var navigationAndSearchBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 3) {
                Button {
                    state.goBack(side)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(!state.canGoBack(side))
                .help("Back")

                Button {
                    state.goForward(side)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(!state.canGoForward(side))
                .help("Forward")

                Button {
                    state.goUp(side)
                } label: {
                    Image(systemName: "arrow.up")
                }
                .disabled(!state.canGoUp(side))
                .help("Parent Folder")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            breadcrumbBar

            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Filter...", text: searchTextBinding)
                    .textFieldStyle(.plain)
                    .font(.caption)
                if !searchTextBinding.wrappedValue.isEmpty {
                    Button {
                        searchTextBinding.wrappedValue = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
            )
            .frame(width: 135)

            Button {
                state.promptNewFolder(in: side)
            } label: {
                Image(systemName: "folder.badge.plus")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(selectedEndpoint?.isReadOnly == true)
            .help("New Folder")

            Button {
                state.refreshPane(side)
            } label: {
                if model.isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Refresh Folder")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private var breadcrumbBar: some View {
        let crumbs = buildBreadcrumbs()
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(crumbs.indices, id: \.self) { idx in
                    let crumb = crumbs[idx]
                    let isLast = idx == crumbs.count - 1
                    Button {
                        state.navigate(side: side, to: crumb.location)
                    } label: {
                        Text(crumb.label)
                            .font(.caption.weight(isLast ? .semibold : .regular))
                            .foregroundStyle(isLast ? Color.primary : Color.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(isLast ? Color.secondary.opacity(0.14) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)

                    if !isLast {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var columnHeaderBar: some View {
        HStack(spacing: 8) {
            sortHeader("Name", field: .name)
                .frame(maxWidth: .infinity, alignment: .leading)
            sortHeader("Size", field: .size)
                .frame(width: 78, alignment: .trailing)
            sortHeader("Modified", field: .dateModified)
                .frame(width: 122, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.65))
    }

    private func sortHeader(_ title: String, field: SortField) -> some View {
        Button {
            state.toggleSort(side: side, field: field)
        } label: {
            HStack(spacing: 3) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if model.sortField == field {
                    Image(systemName: model.sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - List & Empty States

    private var fileListBody: some View {
        Group {
            if let errorMessage = model.errorMessage {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.orange)
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Retry") {
                        state.refreshPane(side)
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else if entries.isEmpty && !model.isLoading {
                VStack(spacing: 8) {
                    Image(systemName: model.searchText.isEmpty ? "folder" : "magnifyingglass")
                        .font(.system(size: 30))
                        .foregroundStyle(.tertiary)
                    Text(model.searchText.isEmpty ? "This folder is empty" : "No matching items")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("Drop files from Finder or drag from the other pane")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { state.clearSelection(side) }
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(entries) { entry in
                            BrowserRowView(
                                entry: entry,
                                isSelected: model.selection.contains(entry.id),
                                onClick: { modifiers in
                                    state.handleRowClick(entry: entry, side: side, modifiers: modifiers)
                                },
                                onDoubleClick: {
                                    state.openEntry(entry, in: side)
                                }
                            )
                            .onDrag {
                                let dragged: [BrowserEntry]
                                if model.selection.contains(entry.id) {
                                    dragged = entries.filter { model.selection.contains($0.id) }
                                } else {
                                    dragged = [entry]
                                }
                                state.activeInternalDrag = (side, dragged)
                                if let localURL = entry.localURL {
                                    return NSItemProvider(object: localURL as NSURL)
                                }
                                return NSItemProvider(object: entry.id as NSString)
                            }
                            .contextMenu {
                                entryContextMenu(for: entry)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 6)
                }
                .background(
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { state.clearSelection(side) }
                )
            }
        }
    }

    private func paneFooter(endpoint: StorageEndpoint) -> some View {
        let selectedItems = entries.filter { model.selection.contains($0.id) }
        let selectedBytes = selectedItems.reduce(Int64(0)) { $0 + ($1.isDirectory ? 0 : $1.size) }

        return HStack(spacing: 8) {
            Text("\(entries.count) items")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !selectedItems.isEmpty {
                Text("•")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text("\(selectedItems.count) selected (\(FormattingHelpers.formatByteCount(selectedBytes)))")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.accentColor)
            }

            Spacer()

            if endpoint.availableBytes > 0 {
                Text("\(FormattingHelpers.formatByteCount(endpoint.availableBytes)) available")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))
    }

    private func attentionStateView(endpoint: StorageEndpoint) -> some View {
        VStack(spacing: 12) {
            Image(systemName: endpoint.platform == .iosMedia || endpoint.platform == .iosApp ? "iphone.and.arrow.forward" : "lock.shield.fill")
                .font(.system(size: 42))
                .foregroundStyle(.orange)

            Text(endpoint.name)
                .font(.title3.weight(.semibold))

            Text(endpoint.statusMessage ?? "Unlock your device and approve the USB connection prompt.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            Button {
                state.rescanDevices()
            } label: {
                Label("Retry / Rescan Devices", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var noDeviceEmptyState: some View {
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                Image(systemName: "externaldrive.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.orange)
                Image(systemName: "smartphone")
                    .font(.system(size: 28))
                    .foregroundStyle(.green)
                Image(systemName: "iphone")
                    .font(.system(size: 28))
                    .foregroundStyle(.indigo)
            }

            Text("Connect a Pendrive, Android, or iPhone/iPad")
                .font(.title3.weight(.semibold))

            VStack(alignment: .leading, spacing: 6) {
                Label("USB / OTG Pendrives & SD Cards mount automatically", systemImage: "checkmark.circle.fill")
                Label("Android: plug via USB and pick 'File Transfer (MTP)' or enable USB Debugging (ADB)", systemImage: "checkmark.circle.fill")
                Label("iOS: plug via USB, unlock, and tap 'Trust This Computer' for Media & App Documents", systemImage: "checkmark.circle.fill")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button {
                    state.rescanDevices()
                } label: {
                    Label("Rescan Devices", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    state.chooseCustomFolderEndpoint(in: side)
                } label: {
                    Label("Pick Mac Folder...", systemImage: "folder")
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var dropOverlayBadge: some View {
        let name = selectedEndpoint?.name ?? "Destination"
        return VStack(spacing: 6) {
            Image(systemName: "arrow.down.doc.fill")
                .font(.system(size: 28, weight: .semibold))
            Text("Drop to Copy to \(name)")
                .font(.headline)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.ultraThickMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 10)
    }

    @ViewBuilder
    private func entryContextMenu(for entry: BrowserEntry) -> some View {
        let targets: [BrowserEntry] = model.selection.contains(entry.id)
            ? entries.filter { model.selection.contains($0.id) }
            : [entry]
        let otherName = state.endpoint(for: side.other)?.name ?? "Other Pane"
        let otherReady = state.endpoint(for: side.other) != nil
            && state.endpoint(for: side.other)?.isReadOnly == false
            && state.endpoint(for: side.other)?.requiresAttention == false

        Button {
            state.transfer(entries: targets, from: side, to: side.other, mode: .copy)
        } label: {
            Label("Copy to \(otherName)", systemImage: side == .left ? "arrow.right.circle" : "arrow.left.circle")
        }
        .disabled(!otherReady)

        Button {
            state.transfer(entries: targets, from: side, to: side.other, mode: .move)
        } label: {
            Label("Move to \(otherName)", systemImage: side == .left ? "arrow.right.square" : "arrow.left.square")
        }
        .disabled(!otherReady || selectedEndpoint?.isReadOnly == true)

        Divider()

        if entry.isDirectory && !entry.isPackage {
            Button {
                state.openEntry(entry, in: side)
            } label: {
                Label("Open Folder", systemImage: "folder")
            }
        } else if entry.localURL != nil {
            Button {
                state.openEntry(entry, in: side)
            } label: {
                Label("Open", systemImage: "arrow.up.forward.app")
            }
        }

        if targets.contains(where: { $0.localURL != nil }) {
            Button {
                state.revealInFinder(targets)
            } label: {
                Label("Reveal in Finder", systemImage: "finder")
            }
        }

        if targets.count == 1 {
            Button {
                state.promptRename(entry: entry, in: side)
            } label: {
                Label("Rename...", systemImage: "pencil")
            }
            .disabled(selectedEndpoint?.isReadOnly == true)
        }

        Divider()

        Button(role: .destructive) {
            state.requestDelete(entries: targets, in: side)
        } label: {
            Label("Delete...", systemImage: "trash")
        }
        .disabled(selectedEndpoint?.isReadOnly == true)
    }

    // MARK: - Helpers

    private func platformColor(_ platform: EndpointPlatform?) -> Color {
        switch platform {
        case .macOS: return .blue
        case .pendrive: return .orange
        case .androidMTP, .androidADB: return .green
        case .iosMedia, .iosApp: return .indigo
        case nil: return .secondary
        }
    }

    private func buildBreadcrumbs() -> [(label: String, location: RemoteLocation)] {
        guard let loc = model.currentLocation, let ep = selectedEndpoint else { return [] }

        switch loc {
        case .local(let url):
            if case .local(let root) = ep.rootLocation, ep.platform != .macOS {
                let rootPath = root.standardizedFileURL.path
                let curPath = url.standardizedFileURL.path
                guard curPath.hasPrefix(rootPath) else {
                    return [(url.lastPathComponent, loc)]
                }
                var out: [(String, RemoteLocation)] = [(ep.name, .local(root))]
                let comps = String(curPath.dropFirst(rootPath.count)).split(separator: "/").map(String.init)
                var rolling = root
                for c in comps {
                    rolling = rolling.appendingPathComponent(c)
                    out.append((c, .local(rolling)))
                }
                return out
            }
            var out: [(String, RemoteLocation)] = []
            var cursor = url.standardizedFileURL
            while cursor.path != "/" {
                out.append((cursor.lastPathComponent, .local(cursor)))
                cursor = cursor.deletingLastPathComponent()
            }
            out.append(("Macintosh HD", .local(URL(fileURLWithPath: "/"))))
            return Array(out.reversed().suffix(5))

        case .mtp(let bus, let dev, let storageID, _, let trail):
            var out: [(String, RemoteLocation)] = [
                (ep.name, .mtp(busLocation: bus, devNum: dev, storageID: storageID, folderID: 0, trail: []))
            ]
            for i in trail.indices {
                let prefix = Array(trail.prefix(i + 1))
                out.append((
                    trail[i].name,
                    .mtp(busLocation: bus, devNum: dev, storageID: storageID, folderID: trail[i].folderID, trail: prefix)
                ))
            }
            return out

        case .adb(let serial, let path):
            let rootPath = ep.rootLocation.displayPath
            var out: [(String, RemoteLocation)] = [(ep.name, .adb(serial: serial, path: rootPath))]
            if path.hasPrefix(rootPath), path != rootPath {
                let comps = String(path.dropFirst(rootPath.count)).split(separator: "/").map(String.init)
                var rolling = rootPath
                for c in comps {
                    rolling = rolling == "/" ? "/\(c)" : "\(rolling)/\(c)"
                    out.append((c, .adb(serial: serial, path: rolling)))
                }
            }
            return out

        case .ios(let udid, let bundleID, let path):
            let rootPath = ep.rootLocation.displayPath
            var out: [(String, RemoteLocation)] = [(ep.name, .ios(udid: udid, appBundleID: bundleID, path: rootPath))]
            if path.hasPrefix(rootPath), path != rootPath {
                let comps = String(path.dropFirst(rootPath.count)).split(separator: "/").map(String.init)
                var rolling = rootPath
                for c in comps {
                    rolling = rolling == "/" ? "/\(c)" : "\(rolling)/\(c)"
                    out.append((c, .ios(udid: udid, appBundleID: bundleID, path: rolling)))
                }
            }
            return out
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        let capturedDrag = state.activeInternalDrag
        state.activeInternalDrag = nil
        let isCommandMove = NSEvent.modifierFlags.contains(.command) && !NSEvent.modifierFlags.contains(.option)

        // Check if dropping internal pane items across panes.
        if let internalDrag = capturedDrag, internalDrag.pane != side {
            let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
            if !fileProviders.isEmpty {
                loadFileURLs(from: fileProviders) { urls in
                    let matchesInternal = urls.contains { dropped in
                        internalDrag.entries.contains { $0.localURL?.standardizedFileURL == dropped.standardizedFileURL }
                    }
                    if matchesInternal {
                        state.transfer(
                            entries: internalDrag.entries,
                            from: internalDrag.pane,
                            to: side,
                            mode: isCommandMove ? .move : .copy
                        )
                    } else {
                        state.handleFinderDrop(urls: urls, onto: side)
                    }
                }
                return true
            }

            // Remote-to-local or remote-to-remote drag (NSString id payload)
            state.transfer(
                entries: internalDrag.entries,
                from: internalDrag.pane,
                to: side,
                mode: isCommandMove ? .move : .copy
            )
            return true
        }

        // External Finder drop
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }
        loadFileURLs(from: fileProviders) { urls in
            if !urls.isEmpty {
                state.handleFinderDrop(urls: urls, onto: side)
            }
        }
        return true
    }

    private func loadFileURLs(from providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void) {
        let collector = DropURLCollector()
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil)
                {
                    collector.add(url)
                } else if let url = item as? URL {
                    collector.add(url)
                }
            }
        }
        group.notify(queue: .main) {
            Task { @MainActor in
                completion(collector.urls)
            }
        }
    }
}

private final class DropURLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []

    func add(_ url: URL) {
        lock.withLock { storage.append(url) }
    }

    var urls: [URL] {
        lock.withLock { storage }
    }
}

private struct BrowserRowView: View {
    let entry: BrowserEntry
    let isSelected: Bool
    let onClick: (NSEvent.ModifierFlags) -> Void
    let onDoubleClick: () -> Void

    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .short
        df.timeStyle = .short
        return df
    }()

    private func iconForEntry() -> NSImage {
        if let local = entry.localURL {
            return NSWorkspace.shared.icon(forFile: local.path)
        }
        if entry.isDirectory && !entry.isPackage {
            return NSWorkspace.shared.icon(for: .folder)
        }
        let ext = entry.fileExtension
        if !ext.isEmpty, let utType = UTType(filenameExtension: ext) {
            return NSWorkspace.shared.icon(for: utType)
        }
        return NSWorkspace.shared.icon(for: .data)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: iconForEntry())
                .resizable()
                .frame(width: 18, height: 18)

            Text(entry.name)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.middle)
                .opacity(entry.isHidden ? 0.65 : 1.0)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(entry.isDirectory && !entry.isPackage ? "--" : FormattingHelpers.formatByteCount(entry.size))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(isSelected ? Color.white.opacity(0.9) : Color.secondary)
                .frame(width: 78, alignment: .trailing)

            Text(entry.modifiedDate == .distantPast ? "--" : Self.dateFormatter.string(from: entry.modifiedDate))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(isSelected ? Color.white.opacity(0.9) : Color.secondary)
                .frame(width: 122, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            onDoubleClick()
        }
        .simultaneousGesture(
            TapGesture(count: 1).onEnded {
                let flags = NSApp.currentEvent?.modifierFlags ?? []
                onClick(flags)
            }
        )
    }
}
