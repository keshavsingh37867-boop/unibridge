import UniBridgeCore
import SwiftUI

struct TransferDrawerView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        state.showTransferQueue.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: state.showTransferQueue ? "chevron.down" : "chevron.up")
                            .font(.caption.weight(.bold))
                        Image(systemName: "arrow.left.arrow.right.circle.fill")
                            .foregroundStyle(state.activeJobCount > 0 ? Color.accentColor : Color.secondary)
                        Text("Transfers")
                            .font(.subheadline.weight(.semibold))
                        if state.activeJobCount > 0 {
                            Text("\(state.activeJobCount) active")
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.16))
                                .foregroundStyle(Color.accentColor)
                                .clipShape(Capsule())
                        }
                    }
                }
                .buttonStyle(.plain)

                Spacer()

                if state.jobs.contains(where: { $0.status.isTerminal }) {
                    Button("Clear Completed") {
                        state.clearCompletedJobs()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(nsColor: .windowBackgroundColor))

            if state.showTransferQueue {
                Divider()
                if state.jobs.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "tray")
                            .foregroundStyle(.tertiary)
                        Text("No transfers yet — pick devices in both panes, select files, and click Copy/Move or drag & drop.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(state.jobs) { job in
                                TransferJobRow(
                                    job: job,
                                    onTogglePause: { state.togglePause(jobID: job.id) },
                                    onCancel: { state.cancelJob(jobID: job.id) },
                                    onRevealDestination: {
                                        if let dest = job.destinationDirectory {
                                            NSWorkspace.shared.activateFileViewerSelecting([dest])
                                        }
                                    }
                                )
                            }
                        }
                        .padding(10)
                    }
                    .frame(maxHeight: 165)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.22), lineWidth: 1)
        )
    }
}

private struct TransferJobRow: View {
    let job: TransferJob
    let onTogglePause: () -> Void
    let onCancel: () -> Void
    let onRevealDestination: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.right.circle.fill")
                    .foregroundStyle(Color.accentColor)

                Text(job.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)

                Text(job.mode.rawValue.uppercased())
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(job.mode == .move ? Color.orange.opacity(0.18) : Color.blue.opacity(0.14))
                    .foregroundStyle(job.mode == .move ? Color.orange : Color.blue)
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                Text(job.direction.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer()

                statusText

                if job.status.isActive {
                    Button {
                        onTogglePause()
                    } label: {
                        Image(systemName: job.status == .paused ? "play.fill" : "pause.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(job.status == .paused ? "Resume Transfer" : "Pause Transfer")

                    Button(role: .destructive) {
                        onCancel()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Cancel Transfer")
                } else if job.destinationDirectory != nil {
                    Button {
                        onRevealDestination()
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Show Destination in Finder")
                }
            }

            if job.status.isActive {
                ProgressView(value: job.progress)
                    .tint(job.status == .paused ? .orange : .accentColor)

                HStack(spacing: 12) {
                    Text(job.currentFileName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()

                    Text("\(job.filesCompleted)/\(max(job.totalFiles, 1)) files")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)

                    Text("\(FormattingHelpers.formatByteCount(job.bytesTransferred)) / \(FormattingHelpers.formatByteCount(job.totalBytes))")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)

                    Text(job.status == .paused ? "Paused" : FormattingHelpers.formatSpeed(job.speedBytesPerSecond))
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(job.status == .paused ? Color.orange : Color.primary)

                    if job.status != .paused, let eta = job.estimatedSecondsRemaining {
                        Text("\(FormattingHelpers.formatDuration(eta)) left")
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var statusText: some View {
        switch job.status {
        case .completed:
            Label("Done (\(job.filesCompleted) files)", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .completedWithSkips(let skipped):
            Label("Done (\(skipped) skipped)", systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.orange)
        case .cancelled:
            Label("Cancelled", systemImage: "slash.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(1)
        default:
            Text("\(Int((job.progress * 100).rounded()))%")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}
