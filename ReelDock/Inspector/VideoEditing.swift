import Observation
import SwiftUI

/// A trim being written in the background, so browsing carries on while a long clip saves.
@Observable
final class VideoTrimExport {
    let url: URL
    var progress: Double = 0
    @ObservationIgnored var task: Task<Void, Never>?

    init(url: URL) {
        self.url = url
    }
}

/// Rotate, and mark in and out points to save a part of the clip, under the player.
struct VideoEditBar: View {
    let item: FolderItem
    let tab: TabModel
    let frameRate: Double?
    let duration: Double
    weak var controller: WorkspaceWindowController?

    private var marks: TrimMarks { tab.trimMarks[item.id] ?? TrimMarks() }
    private var export: VideoTrimExport? { tab.videoExport }
    private var isExportingThis: Bool { export?.url.path == item.url.path }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Button { controller?.rotateVideo(clockwise: false) } label: { Image(systemName: "rotate.left") }
                    .buttonStyle(.borderless)
                    .help("Rotate Left (⌘L). Takes effect at once, without re-encoding.")
                Spacer().frame(width: 6)
                Button("I") { controller?.markTrimIn() }
                    .help("Mark In at the current frame (I)")
                Button("O") { controller?.markTrimOut() }
                    .help("Mark Out at the current frame (O)")
                Spacer(minLength: 4)
                if !marks.isEmpty {
                    Text("\(Timecode.format(marks.inPoint ?? 0, frameRate: frameRate)) – \(Timecode.format(marks.outPoint ?? duration, frameRate: frameRate))")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(isExportingThis)
            if let export, isExportingThis {
                HStack(spacing: 6) {
                    ProgressView(value: export.progress)
                    Button("Cancel") { export.task?.cancel() }
                }
            } else if !marks.isEmpty {
                HStack(spacing: 4) {
                    if let range = marks.range(duration: duration) {
                        Text(Timecode.format(range.upperBound - range.lowerBound, frameRate: frameRate))
                            .font(.system(size: 11).monospacedDigit())
                    }
                    Spacer(minLength: 4)
                    Button("Clear") { controller?.clearTrimMarks() }
                        .help("Clear the marks (X)")
                    Button("Save Copy") { controller?.saveVideoTrim(asCopy: true) }
                        .help("Save the marked part as a new file, and leave this one as it is (⇧⌘S)")
                        .disabled(export != nil || marks.range(duration: duration) == nil)
                    Button("Save") { controller?.saveVideoTrim(asCopy: false) }
                        .help("Replace this file with the marked part. The original goes to the Trash, and Undo brings it back (⌘S)")
                        .buttonStyle(.borderedProminent)
                        .disabled(export != nil || marks.range(duration: duration) == nil)
                }
            }
        }
        .controlSize(.small)
    }
}
