import AVFoundation
import SwiftUI

enum InspectorPreview {
    static let posterSize: CGFloat = 720
}

struct InspectorView: View {
    let app: AppModel
    let tab: TabModel
    weak var controller: WorkspaceWindowController?

    var body: some View {
        Group {
            switch tab.selection.count {
            case 0:
                if let folder = tab.folder ?? app.projectRootURL {
                    FolderOverview(url: folder, app: app, tab: tab, controller: controller)
                        .id(folder.path)
                } else {
                    placeholder
                }
            case 1:
                SingleItemInspector(item: tab.selection[0], tab: tab, controller: controller)
                    .id(tab.selection[0].id)
            default:
                MultipleItemsInspector(items: tab.selection, controller: controller)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var placeholder: some View {
        Text("No Selection")
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

enum InspectorFormat {
    static let bytes: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return String(format: "%.1f s", seconds) }
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let rest = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%d:%02d", minutes, rest)
    }

    static func frameRate(_ rate: Double) -> String {
        String(format: "%.2f fps", rate)
    }
}

/// The preview takes the panel's width, and the frame grid fills whatever height is left.
private struct SingleItemInspector: View {
    private static let padding: CGFloat = 10
    /// Keeps the name and details on screen when a tall preview would otherwise push them out.
    private static let reservedHeight: CGFloat = 216

    let item: FolderItem
    let tab: TabModel
    weak var controller: WorkspaceWindowController?

    private var playback: PlaybackController { tab.playback }

    @State private var poster: NSImage?
    @State private var media: MediaInfo?
    @State private var folderCount: Int?
    @State private var waveform: [Float]?
    @State private var gamma: LogGamma?

    var body: some View {
        GeometryReader { proxy in
            let width = max(0, proxy.size.width - Self.padding * 2)
            VStack(alignment: .leading, spacing: 10) {
                previewArea
                    .frame(width: width, height: previewHeight(width: width, available: proxy.size.height))
                if canEditImage {
                    ImageEditBar(session: session, controller: controller)
                }
                if item.isPlayable {
                    TransportBar(
                        playback: playback,
                        duration: media?.duration ?? 0,
                        frameRate: media?.frameRate,
                        isFullScreen: false,
                        canGoFullScreen: item.canPreviewFullScreen,
                        marks: tab.trimMarks[item.id],
                        gamma: gamma,
                        onToggleLUT: { controller?.togglePreviewLUT(nil) }
                    ) { controller?.toggleFullScreenPreview() }
                }
                if canEditVideo {
                    VideoEditBar(item: item, tab: tab, frameRate: media?.frameRate, duration: media?.duration ?? 0, controller: controller)
                }
                header
                details
                if canEditTags {
                    TagRow(controller: controller, items: [item])
                }
                if item.isVideo, let duration = media?.duration, duration > 0 {
                    FrameGrid(url: item.url, modified: item.modified, duration: duration, aspect: aspect, playback: playback, lutGeneration: PreviewLUTs.shared.generation)
                } else {
                    Spacer(minLength: 0)
                }
            }
            .padding(Self.padding)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
        .clipped()
        // The date too, so a saved edit shows up.
        .task(id: "\(item.id)|\(item.modified?.timeIntervalSince1970 ?? 0)") { await loadDetails() }
        .task(id: "\(item.id)|\(item.modified?.timeIntervalSince1970 ?? 0)|\(PreviewLUTs.shared.generation)") { await loadPoster() }
    }

    private var canEditTags: Bool { !FileOperations.isOnCameraCard(item.url) }
    private var canEditImage: Bool { WorkspaceWindowController.canEdit(item) }
    private var canEditVideo: Bool { WorkspaceWindowController.canEditVideo(item) }
    private var session: ImageEditSession? { tab.imageEdit }
    private var editedImage: CGImage? { session?.image }

    /// Follows the file's own shape, so vertical footage and photos can use the panel's height.
    private var aspect: CGFloat {
        if let editedImage {
            return CGFloat(editedImage.width) / CGFloat(editedImage.height)
        }
        if let width = media?.width, let height = media?.height, width > 0, height > 0 {
            return CGFloat(width) / CGFloat(height)
        }
        if let size = poster?.size, size.width > 0, size.height > 0 {
            return size.width / size.height
        }
        return 16.0 / 9.0
    }

    private func previewHeight(width: CGFloat, available: CGFloat) -> CGFloat {
        guard item.hasVisualThumbnail else { return min(120, width * 9 / 16) }
        return min(width / aspect, max(140, available - Self.reservedHeight - (canEditImage || canEditVideo ? 32 : 0)))
    }

    private var previewArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(item.hasVisualThumbnail ? AnyShapeStyle(.black) : AnyShapeStyle(.quaternary))
            if let editedImage {
                Image(decorative: editedImage, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if let poster {
                Image(nsImage: poster)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if !item.hasVisualThumbnail, waveform == nil {
                Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                    .resizable()
                    .frame(width: 64, height: 64)
            }
            if let session, session.crop != nil, let editedImage {
                CropOverlay(session: session, imageSize: CGSize(width: editedImage.width, height: editedImage.height))
            } else if item.isPlayable {
                PlayerLayerRepresentable(playback: playback)
                if let waveform, let duration = media?.duration, duration > 0 {
                    WaveformView(levels: waveform, playback: playback, duration: duration)
                }
                PlayerOverlay(playback: playback, showsPlayIcon: waveform == nil)
            } else if item.canPreviewFullScreen {
                FullScreenButton(isFullScreen: false) { controller?.toggleFullScreenPreview() }
                    .padding(6)
                    .background(.black.opacity(0.45), in: Circle())
                    .foregroundStyle(.white)
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture {
            if item.isPlayable { playback.togglePlay() }
        }
        .help(item.isPlayable ? "Space: play or pause. J K L: shuttle. Hold K and tap J or L: step one frame. F or P: full screen." : "")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(item.name)
                .font(.headline)
                .textSelection(.enabled)
                .lineLimit(2)
            Spacer(minLength: 0)
            if !item.isFolder {
                Button("Open") { NSWorkspace.shared.open(item.url) }
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var details: some View {
        if let media {
            VStack(alignment: .leading, spacing: 3) {
                Text(mediaLine(media))
                Text(fileLine)
                    .foregroundStyle(.secondary)
                whereLine
            }
            .font(.callout)
            .textSelection(.enabled)
        } else {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
                if let kind = item.contentType?.localizedDescription {
                    row("Kind", kind)
                }
                if let size = item.size, !item.isFolder {
                    row("Size", InspectorFormat.bytes.string(fromByteCount: size))
                }
                if let folderCount {
                    row("Items", String(folderCount))
                }
                if let modified = item.modified {
                    row("Modified", modified.formatted(date: .abbreviated, time: .shortened))
                }
                row("Where", item.url.deletingLastPathComponent().path)
            }
            .font(.callout)
        }
    }

    private func mediaLine(_ media: MediaInfo) -> String {
        var parts: [String] = []
        if let width = media.width, let height = media.height { parts.append("\(width) × \(height)") }
        if let rate = media.frameRate { parts.append(InspectorFormat.frameRate(rate)) }
        if let codec = media.codec { parts.append(codec) }
        if let gamma { parts.append(gamma.rawValue) }
        if let channels = media.audioChannels, let rate = media.audioSampleRate {
            parts.append("\(channels) ch, \(Int(rate / 1000)) kHz")
        }
        return parts.joined(separator: " · ")
    }

    private var fileLine: String {
        var parts: [String] = []
        if let size = item.size { parts.append(InspectorFormat.bytes.string(fromByteCount: size)) }
        if let duration = media?.duration, duration > 0 { parts.append(InspectorFormat.duration(duration)) }
        if let modified = item.modified { parts.append(modified.formatted(date: .abbreviated, time: .shortened)) }
        return parts.joined(separator: " · ")
    }

    private var whereLine: some View {
        Text(item.url.deletingLastPathComponent().path)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(item.url.deletingLastPathComponent().path)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// With a LUT in use, the picture before playback starts has it too, so nothing changes color on the first play.
    private func loadPoster() async {
        guard item.hasVisualThumbnail else { return }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        if item.isVideo, let grade = await PreviewLUTs.shared.grade(forClipAt: item.url),
           let graded = await ThumbnailCache.shared.gradedFirstFrame(of: item.url, modified: item.modified, size: InspectorPreview.posterSize, scale: scale, grade: grade) {
            if !Task.isCancelled { poster = graded }
            return
        }
        guard !Task.isCancelled else { return }
        ThumbnailCache.shared.request(item.url, modified: item.modified, size: InspectorPreview.posterSize, scale: scale) { image in
            poster = image
        }
    }

    private func loadDetails() async {
        if item.isVideo {
            let url = item.url
            gamma = await Task.detached(priority: .utility) { await LogFootage.gamma(of: url) }.value
        }
        if item.isFolder {
            let url = item.url
            folderCount = await Task.detached(priority: .utility) {
                try? FolderReader.read(url, showHidden: false).count
            }.value
        } else if item.isPlayable {
            media = await MediaInfoReader.read(item.url)
            if item.isAudio {
                waveform = await WaveformCache.shared.levels(for: item.url, modified: item.modified)
            }
        }
    }
}

/// Reads the playback state on its own, so the 30 Hz clock only redraws this small view.
struct PlayerOverlay: View {
    let playback: PlaybackController
    var showsPlayIcon = true

    var body: some View {
        ZStack {
            if playback.failed {
                Text("Can't play this file")
                    .font(.callout)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.6), in: Capsule())
                    .foregroundStyle(.white)
            } else if !playback.isLoaded, showsPlayIcon {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 36))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.45))
                    .accessibilityLabel("Play")
            }
            if let label = shuttleLabel {
                Text(label)
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.6), in: Capsule())
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(8)
            }
        }
    }

    private var shuttleLabel: String? {
        let rate = playback.rate
        guard rate != 0, rate != 1 else { return nil }
        let speed = abs(rate).rounded() == abs(rate) ? String(Int(abs(rate))) : String(format: "%.1f", abs(rate))
        return (rate < 0 ? "◀ " : "▶ ") + speed + "×"
    }
}

/// Click to play from that point, or drag to listen for the right place first.
private struct WaveformView: View {
    private static let barWidth: CGFloat = 2
    private static let barStep: CGFloat = 3

    let levels: [Float]
    let playback: PlaybackController
    let duration: Double
    @State private var isDragging = false

    var body: some View {
        GeometryReader { proxy in
            let fraction = min(1, max(0, playback.time / duration))
            let bars = WaveformReader.bars(levels, count: Int(proxy.size.width / Self.barStep))
            Canvas { context, size in
                let middle = size.height / 2
                let reach = size.height / 2 - 6
                let playedEnd = size.width * fraction
                var played = Path()
                var unplayed = Path()
                for (index, value) in bars.enumerated() {
                    let x = CGFloat(index) * Self.barStep
                    let height = max(1, CGFloat(value) * reach)
                    let bar = CGRect(x: x, y: middle - height, width: Self.barWidth, height: height * 2)
                    if x < playedEnd { played.addRect(bar) } else { unplayed.addRect(bar) }
                }
                context.fill(unplayed, with: .color(.gray))
                context.fill(played, with: .color(.accentColor))
                context.fill(Path(CGRect(x: playedEnd - 0.75, y: 0, width: 1.5, height: size.height)), with: .color(.white))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard proxy.size.width > 0 else { return }
                        if !isDragging {
                            isDragging = true
                            playback.beginScrub()
                        }
                        playback.seek(to: duration * min(1, max(0, value.location.x / proxy.size.width)))
                    }
                    .onEnded { _ in
                        isDragging = false
                        playback.endScrub()
                        if !playback.isPlaying { playback.togglePlay() }
                    }
            )
        }
        .help("Click to play from there")
        .accessibilityLabel("Waveform")
    }
}

struct FullScreenButton: View {
    let isFullScreen: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isFullScreen ? "Exit Full Screen" : "Full Screen")
        .help(isFullScreen ? "Exit full screen (F or Esc)" : "Full screen (F or P)")
    }
}

/// Lit when this clip is showing through a LUT.
private struct LUTButton: View {
    let gamma: LogGamma
    let action: () -> Void

    private var isShowing: Bool {
        PreviewLUTs.shared.isEnabled && PreviewLUTs.shared.paths[gamma] != nil
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: "camera.filters")
                .foregroundStyle(isShowing ? Color.accentColor : Color.primary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Preview with LUT")
        .help(isShowing ? "\(gamma.rawValue) with its LUT. G shows it as shot." : "\(gamma.rawValue) as shot. G shows it with a LUT.")
    }
}

struct TransportBar: View {
    let playback: PlaybackController
    let duration: Double
    let frameRate: Double?
    let isFullScreen: Bool
    var canGoFullScreen = true
    var marks: TrimMarks?
    /// Set for log footage, which is what a preview LUT is for.
    var gamma: LogGamma?
    var onToggleLUT: (() -> Void)?
    let onFullScreen: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button {
                playback.togglePlay()
            } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .foregroundStyle(Color.primary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")
            Text(Timecode.format(playback.time, frameRate: frameRate))
                .font(.system(size: 11).monospacedDigit())
            Scrubber(playback: playback, duration: duration, marks: marks)
            Text(Timecode.format(duration, frameRate: frameRate))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
            if let gamma, let onToggleLUT {
                LUTButton(gamma: gamma, action: onToggleLUT)
            }
            if canGoFullScreen {
                FullScreenButton(isFullScreen: isFullScreen, action: onFullScreen)
                    .foregroundStyle(Color.primary)
            }
        }
    }
}

private struct Scrubber: View {
    let playback: PlaybackController
    let duration: Double
    let marks: TrimMarks?
    @State private var isDragging = false

    var body: some View {
        GeometryReader { proxy in
            let fraction = duration > 0 ? min(1, max(0, playback.time / duration)) : 0
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.3))
                    .frame(height: 4)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: proxy.size.width * fraction, height: 4)
                if let marks, !marks.isEmpty, duration > 0 {
                    // What the marks keep, with a tick at each mark that's set.
                    let start = min(1, max(0, (marks.inPoint ?? 0) / duration))
                    let end = min(1, max(start, (marks.outPoint ?? duration) / duration))
                    Rectangle()
                        .fill(Color.yellow.opacity(0.45))
                        .frame(width: proxy.size.width * (end - start), height: 12)
                        .offset(x: proxy.size.width * start)
                    if marks.inPoint != nil {
                        Rectangle().fill(Color.yellow).frame(width: 2, height: 14)
                            .offset(x: proxy.size.width * start - 1)
                    }
                    if marks.outPoint != nil {
                        Rectangle().fill(Color.yellow).frame(width: 2, height: 14)
                            .offset(x: proxy.size.width * end - 1)
                    }
                }
                Circle()
                    .fill(.white)
                    .shadow(radius: 1)
                    .frame(width: 10, height: 10)
                    .offset(x: max(0, proxy.size.width * fraction - 5))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard duration > 0, proxy.size.width > 0 else { return }
                        if !isDragging {
                            isDragging = true
                            playback.beginScrub()
                        }
                        playback.seek(to: duration * min(1, max(0, value.location.x / proxy.size.width)))
                    }
                    .onEnded { _ in
                        isDragging = false
                        playback.endScrub()
                    }
            )
        }
        .frame(height: 18)
    }
}

nonisolated struct FrameGridLayout: Equatable {
    static let spacing: CGFloat = 4

    let columns: Int
    let rows: Int
    let tileSize: CGSize

    var count: Int { columns * rows }

    /// Only whole rows are shown, so a frame is never cut off at the panel's bottom edge.
    init(size: CGSize, aspect: CGFloat) {
        let safeAspect = aspect > 0 ? aspect : 16.0 / 9.0
        columns = safeAspect < 1 ? 5 : (size.width >= 480 ? 4 : 3)
        let width = max(0, (size.width - Self.spacing * CGFloat(columns - 1)) / CGFloat(columns))
        let height = width / safeAspect
        tileSize = CGSize(width: width, height: height)
        rows = height > 0 ? max(0, Int((size.height + Self.spacing) / (height + Self.spacing))) : 0
    }
}

/// Evenly spaced frames from the clip. Clicking one jumps there.
private struct FrameGrid: View {
    let url: URL
    /// A rotated clip's frames need drawing again.
    let modified: Date?
    let duration: Double
    let aspect: CGFloat
    let playback: PlaybackController
    let lutGeneration: Int

    @State private var images: [Int: NSImage] = [:]

    var body: some View {
        GeometryReader { proxy in
            let layout = FrameGridLayout(size: proxy.size, aspect: aspect)
            VStack(alignment: .leading, spacing: FrameGridLayout.spacing) {
                ForEach(0..<layout.rows, id: \.self) { row in
                    HStack(spacing: FrameGridLayout.spacing) {
                        ForEach(0..<layout.columns, id: \.self) { column in
                            tile(row * layout.columns + column, layout: layout)
                        }
                    }
                }
            }
            .overlay(alignment: .topLeading) {
                if layout.count > 0 {
                    PlayheadOutline(playback: playback, duration: duration, layout: layout)
                }
            }
            .task(id: "\(url.path)|\(layout.count)|\(modified?.timeIntervalSince1970 ?? 0)|\(lutGeneration)") { await load(count: layout.count) }
        }
    }

    private func tile(_ index: Int, layout: FrameGridLayout) -> some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image = images[index] {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
        .frame(width: layout.tileSize.width, height: layout.tileSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .contentShape(Rectangle())
        .onTapGesture {
            playback.seek(to: Self.time(of: index, count: layout.count, duration: duration))
        }
    }

    private static func time(of index: Int, count: Int, duration: Double) -> Double {
        (Double(index) + 0.5) * duration / Double(count)
    }

    /// Waits first, so arrowing through a folder doesn't read every clip it passes.
    private func load(count: Int) async {
        images = [:]
        guard count > 0 else { return }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }

        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        if let grade = await PreviewLUTs.shared.grade(forClipAt: url) {
            generator.videoComposition = await grade.composition(for: asset)
        }
        guard !Task.isCancelled else { return }
        generator.maximumSize = CGSize(width: 480, height: 480)
        // Any frame near the target will do, and allowing that avoids decoding from the last keyframe.
        let tolerance = CMTime(seconds: duration / Double(count) / 2, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        let times = (0..<count).map {
            CMTime(seconds: Self.time(of: $0, count: count, duration: duration), preferredTimescale: 600)
        }
        for await result in generator.images(for: times) {
            guard !Task.isCancelled else {
                generator.cancelAllCGImageGeneration()
                return
            }
            guard let cgImage = try? result.image,
                  let index = times.firstIndex(where: { CMTimeCompare($0, result.requestedTime) == 0 }) else { continue }
            images[index] = NSImage(cgImage: cgImage, size: .zero)
        }
    }
}

/// Separate from the grid, so the 30 Hz clock doesn't redraw every frame tile.
private struct PlayheadOutline: View {
    let playback: PlaybackController
    let duration: Double
    let layout: FrameGridLayout

    var body: some View {
        let index = min(layout.count - 1, max(0, Int(playback.time / duration * Double(layout.count))))
        RoundedRectangle(cornerRadius: 3)
            .strokeBorder(.tint, lineWidth: 2)
            .frame(width: layout.tileSize.width, height: layout.tileSize.height)
            .offset(
                x: CGFloat(index % layout.columns) * (layout.tileSize.width + FrameGridLayout.spacing),
                y: CGFloat(index / layout.columns) * (layout.tileSize.height + FrameGridLayout.spacing)
            )
            .opacity(playback.isLoaded ? 1 : 0)
            .allowsHitTesting(false)
    }
}

private struct MultipleItemsInspector: View {
    let items: [FolderItem]
    weak var controller: WorkspaceWindowController?

    private var canEditTags: Bool { !items.contains { FileOperations.isOnCameraCard($0.url) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(items.count) items selected")
                .font(.headline)
            let total = items.compactMap(\.size).reduce(0, +)
            if items.contains(where: { !$0.isFolder }) {
                Text(InspectorFormat.bytes.string(fromByteCount: total))
                    .foregroundStyle(.secondary)
            }
            if canEditTags {
                TagRow(controller: controller, items: items)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A bare video layer. Taking no mouse or key focus keeps Space and J K L with the file list.
final class PlayerSurfaceView: NSView {
    let playerLayer = AVPlayerLayer()
    /// Above the player, for frames the player can't show smoothly itself.
    private let reverseLayer = AVSampleBufferDisplayLayer()

    var reverseRotation: CGFloat = 0 {
        didSet {
            guard reverseRotation != oldValue else { return }
            needsLayout = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
        reverseLayer.videoGravity = .resizeAspect
        reverseLayer.isHidden = true
        layer?.addSublayer(reverseLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        // Decoded frames arrive unrotated. Layers here have y going up, so a clockwise turn is negative.
        let sideways = abs(sin(reverseRotation)) > 0.5
        reverseLayer.setAffineTransform(.identity)
        reverseLayer.bounds = CGRect(
            x: 0,
            y: 0,
            width: sideways ? bounds.height : bounds.width,
            height: sideways ? bounds.width : bounds.height
        )
        reverseLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        reverseLayer.setAffineTransform(CGAffineTransform(rotationAngle: -reverseRotation))
        CATransaction.commit()
    }

    func enqueueReverseFrame(_ sample: CMSampleBuffer) {
        let renderer = reverseLayer.sampleBufferRenderer
        if renderer.requiresFlushToResumeDecoding { renderer.flush() }
        renderer.enqueue(sample)
        guard reverseLayer.isHidden else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        reverseLayer.isHidden = false
        CATransaction.commit()
    }

    func hideReverseFrames() {
        guard !reverseLayer.isHidden else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        reverseLayer.isHidden = true
        CATransaction.commit()
        reverseLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
    }

    #if DEBUG
    var debugDisplayedBuffer: CVPixelBuffer? { reverseLayer.sampleBufferRenderer.displayedPixelBuffer() }
    /// Where the right edge of an unrotated frame lands in this view, which has y going up.
    var debugGeometry: String {
        guard let root = layer else { return "no layer" }
        let edge = reverseLayer.convert(CGPoint(x: reverseLayer.bounds.maxX, y: reverseLayer.bounds.midY), to: root)
        return "rotation=\(reverseRotation) rootFlipped=\(root.isGeometryFlipped) reverseFlipped=\(reverseLayer.contentsAreFlipped()) viewFlipped=\(isFlipped) view=\(bounds.size) layerBounds=\(reverseLayer.bounds.size) rightEdge=\(edge) hidden=\(reverseLayer.isHidden)"
    }
    #endif

    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct PlayerLayerRepresentable: NSViewRepresentable {
    let playback: PlaybackController

    func makeNSView(context: Context) -> PlayerSurfaceView {
        let view = PlayerSurfaceView()
        view.playerLayer.player = playback.player
        playback.attach(view)
        return view
    }

    func updateNSView(_ view: PlayerSurfaceView, context: Context) {}

    static func dismantleNSView(_ view: PlayerSurfaceView, coordinator: ()) {
        view.playerLayer.player = nil
    }
}
