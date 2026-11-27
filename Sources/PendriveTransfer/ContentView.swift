import PendriveTransferCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 10) {
            topToolbar

            HStack(spacing: 10) {
                DevicePaneView(state: state, side: .left)
                centerTransferStrip
                DevicePaneView(state: state, side: .right)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            TransferDrawerView(state: state)
        }
        .padding(12)
        .frame(minWidth: 1080, minHeight: 700)
        .background(Color(nsColor: .underPageBackgroundColor))
        .sheet(item: $state.activeConflict) { conflict in
            ConflictResolutionSheet(
                conflict: conflict,
                applyToAll: $state.conflictApplyToAll
            ) { resolution, applyToAll in
                state.resolveConflict(resolution: resolution, applyToAll: applyToAll)
            }
        }
        .sheet(item: $state.namePrompt) { prompt in
            NameInputSheet(
                prompt: prompt,
                text: $state.namePromptText
            ) { updatedPrompt in
                state.submitNamePrompt(updatedPrompt)
            } onCancel: {
                state.namePrompt = nil
            }
        }
        .alert(item: $state.deletePrompt) { prompt in
            Alert(
                title: Text("Delete \(prompt.entries.count) item(s)?"),
                message: Text(
                    prompt.isRemoteOrRemovable
                        ? "Files on USB pendrives, Android, or iOS devices are deleted directly if Trash is unavailable."
                        : "Selected items will be moved to the Mac Trash."
                ),
                primaryButton: .destructive(Text("Delete")) {
                    state.confirmDelete(prompt)
                },
                secondaryButton: .cancel {
                    state.deletePrompt = nil
                }
            )
        }
        .alert("Notice", isPresented: Binding(
            get: { state.alertMessage != nil },
            set: { if !$0 { state.alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) {
                state.alertMessage = nil
            }
        } message: {
            Text(state.alertMessage ?? "")
        }
    }

    private var topToolbar: some View {
        let externalCount = state.endpoints.filter { $0.platform != .macOS }.count

        return HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "externaldrive.fill.badge.checkmark")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Pendrive Transfer")
                        .font(.headline)
                    Text("Mac • USB/OTG • Android • iOS")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()
                .frame(height: 28)

            HStack(spacing: 6) {
                Circle()
                    .fill(externalCount > 0 ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(externalCount == 0
                     ? "No external devices detected"
                     : "\(externalCount) connected endpoint\(externalCount == 1 ? "" : "s")")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 7))

            Spacer()

            Button {
                state.swapPanes()
            } label: {
                Label("Swap Panes", systemImage: "arrow.left.arrow.right")
            }
            .buttonStyle(.bordered)
            .help("Swap left and right device panes")

            Menu {
                Picker("If File Exists", selection: $state.conflictPolicy) {
                    ForEach(ConflictPolicy.allCases, id: \.self) { policy in
                        Text(policy.rawValue).tag(policy)
                    }
                }
            } label: {
                Label("Conflicts: \(state.conflictPolicy.rawValue)", systemImage: "doc.on.doc")
            }
            .menuStyle(.borderedButton)
            .fixedSize()

            Toggle(isOn: Binding(
                get: { state.showHiddenFiles },
                set: { _ in state.toggleShowHidden() }
            )) {
                Label("Hidden", systemImage: state.showHiddenFiles ? "eye.fill" : "eye.slash")
            }
            .toggleStyle(.button)
            .help("Show or hide hidden files")

            Button {
                state.rescanDevices()
            } label: {
                if state.deviceManager.isScanning {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.22), lineWidth: 1)
        )
    }

    private var centerTransferStrip: some View {
        let leftSelected = state.leftPane.selection.count
        let rightSelected = state.rightPane.selection.count
        let leftReadOnly = state.endpoint(for: .left)?.isReadOnly ?? false
        let rightReadOnly = state.endpoint(for: .right)?.isReadOnly ?? false

        return VStack(spacing: 12) {
            Spacer()

            VStack(spacing: 8) {
                Text("Left -> Right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)

                Button {
                    state.transferSelected(from: .left, to: .right, mode: .copy)
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: "arrow.right.circle.fill")
                            .font(.title3)
                        Text("Copy")
                            .font(.caption.weight(.semibold))
                        if leftSelected > 0 {
                            Text("\(leftSelected)")
                                .font(.caption2)
                                .opacity(0.85)
                        }
                    }
                    .frame(width: 74, height: 58)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .disabled(!state.canTransferLeftToRight)

                Button {
                    state.transferSelected(from: .left, to: .right, mode: .move)
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "arrow.right.square")
                            .font(.callout)
                        Text("Move")
                            .font(.caption.weight(.medium))
                    }
                    .frame(width: 74, height: 42)
                }
                .buttonStyle(.bordered)
                .tint(.orange)
                .disabled(!state.canTransferLeftToRight || leftReadOnly)
            }

            Divider()
                .frame(width: 56)

            VStack(spacing: 8) {
                Text("Right -> Left")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)

                Button {
                    state.transferSelected(from: .right, to: .left, mode: .copy)
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: "arrow.left.circle.fill")
                            .font(.title3)
                        Text("Copy")
                            .font(.caption.weight(.semibold))
                        if rightSelected > 0 {
                            Text("\(rightSelected)")
                                .font(.caption2)
                                .opacity(0.85)
                        }
                    }
                    .frame(width: 74, height: 58)
                }
                .buttonStyle(.borderedProminent)
                .tint(.teal)
                .disabled(!state.canTransferRightToLeft)

                Button {
                    state.transferSelected(from: .right, to: .left, mode: .move)
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "arrow.left.square")
                            .font(.callout)
                        Text("Move")
                            .font(.caption.weight(.medium))
                    }
                    .frame(width: 74, height: 42)
                }
                .buttonStyle(.bordered)
                .tint(.orange)
                .disabled(!state.canTransferRightToLeft || rightReadOnly)
            }

            Spacer()
        }
        .padding(.vertical, 8)
    }
}

private struct ConflictResolutionSheet: View {
    let conflict: ActiveConflictState
    @Binding var applyToAll: Bool
    let onDecide: (ConflictResolution, Bool) -> Void

    private static let df: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "doc.on.doc.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("File Already Exists")
                        .font(.headline)
                    Text("'\(conflict.prompt.sourceName)' already exists at \(conflict.prompt.destinationPathDisplay).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            HStack(spacing: 12) {
                fileCard(
                    title: "Incoming File",
                    size: conflict.prompt.sourceSize,
                    date: conflict.prompt.sourceDate
                )
                fileCard(
                    title: "Existing File",
                    size: conflict.prompt.destinationSize,
                    date: conflict.prompt.destinationDate
                )
            }

            Toggle("Apply this choice to all remaining conflicts in this transfer", isOn: $applyToAll)
                .font(.callout)

            HStack {
                Button("Cancel Transfer", role: .cancel) {
                    onDecide(.cancelAll, false)
                }
                Spacer()
                Button("Skip") {
                    onDecide(.skip, applyToAll)
                }
                Button("Keep Both") {
                    onDecide(.keepBoth, applyToAll)
                }
                Button("Replace") {
                    onDecide(.replace, applyToAll)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 490)
    }

    private func fileCard(title: String, size: Int64, date: Date?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(FormattingHelpers.formatByteCount(size))
                .font(.callout.weight(.medium))
            Text(date.map { Self.df.string(from: $0) } ?? "Unknown date")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct NameInputSheet: View {
    let prompt: NamePromptState
    @Binding var text: String
    let onSubmit: (NamePromptState) -> Void
    let onCancel: () -> Void

    private var titleText: String {
        switch prompt.kind {
        case .newFolder: return "Create New Folder"
        case .rename: return "Rename Item"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(titleText)
                .font(.headline)

            TextField("Name", text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        onSubmit(prompt)
                    }
                }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Confirm") {
                    onSubmit(prompt)
                }
                .buttonStyle(.borderedProminent)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
