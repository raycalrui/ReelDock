import SwiftUI

/// Pastes and moves, in the same popover as imports.
struct TransferActivityView: View {
    let queue: FileTransferQueue

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(queue.isActive ? (queue.isPaused ? "Paused" : "Copying") : "Copies and moves")
                .font(.headline)
            if queue.isActive {
                ProgressView(value: queue.fraction)
                Text("\(ImportFormat.bytes(queue.copiedBytes)) of \(ImportFormat.bytes(queue.totalBytes))")
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(queue.jobs) { job in
                        row(job)
                    }
                }
            }
            .frame(maxHeight: 180)
            HStack {
                if queue.isActive {
                    Button(queue.isPaused ? "Resume" : "Pause") { queue.setPaused(!queue.isPaused) }
                    Button("Cancel", role: .cancel) { queue.cancelAll() }
                } else {
                    Button("Clear") { queue.clearFinished() }
                }
                Spacer()
            }
        }
        .padding(14)
        .frame(width: 360)
    }

    private func row(_ job: FileTransferQueue.Job) -> some View {
        HStack(spacing: 8) {
            icon(job.state)
            VStack(alignment: .leading, spacing: 1) {
                Text(title(job))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail = detail(job) {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func title(_ job: FileTransferQueue.Job) -> String {
        let what = job.sources.count == 1 ? job.sources[0].lastPathComponent : "\(job.sources.count) items"
        return "\(what) → \(job.destination.lastPathComponent)"
    }

    private func detail(_ job: FileTransferQueue.Job) -> String? {
        switch job.state {
        case let .failed(reason): return reason
        case .cancelled: return "Cancelled"
        case .running: return job.kind == .copy && queue.isVerifying ? "Verifying" : nil
        case .queued: return nil
        case .done:
            // A taken name means the item landed under another one.
            let renamed = job.items.first { $0.result.lastPathComponent != $0.source.lastPathComponent }
            return renamed.map { "Saved as \($0.result.lastPathComponent)" }
        }
    }

    @ViewBuilder
    private func icon(_ state: FileTransferQueue.State) -> some View {
        switch state {
        case .queued:
            Image(systemName: "clock").foregroundStyle(.secondary)
        case .running:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .cancelled:
            Image(systemName: "minus.circle").foregroundStyle(.secondary)
        }
    }
}
