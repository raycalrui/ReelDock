import AppKit
import SwiftUI

/// A project's 16:9 picture in the project lists. Projects with nothing to show keep the same space, so titles line up.
struct ProjectThumbnailView: View {
    /// One size for every list, so they share the same cached images.
    private static let loadSize: CGFloat = 128
    /// What each project last showed, so a row scrolled back into view doesn't flash empty.
    private static let shown = NSCache<NSString, NSImage>()

    let project: ProjectEntry
    /// Changes when the project's cover or video folder does.
    let generation: Int
    let width: CGFloat

    @Environment(\.displayScale) private var displayScale
    @State private var image: NSImage?
    @State private var loadingID: String?

    init(project: ProjectEntry, generation: Int, width: CGFloat) {
        self.project = project
        self.generation = generation
        self.width = width
        _image = State(initialValue: Self.shown.object(forKey: project.id as NSString))
    }

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "film")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: width, height: (width * 9 / 16).rounded())
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .task(id: "\(project.id)|\(generation)") { await load() }
    }

    private func load() async {
        let url = project.url
        let source = await Task.detached(priority: .utility) { ProjectThumbnail.source(in: url) }.value
        guard !Task.isCancelled else { return }
        switch source {
        case .cover(let cover):
            loadingID = cover.id
            if let cached = ThumbnailCache.shared.cached(cover.url, modified: cover.modified, size: Self.loadSize) {
                show(cached)
                return
            }
            ThumbnailCache.shared.request(cover.url, modified: cover.modified, size: Self.loadSize, scale: displayScale) { picture in
                if loadingID == cover.id { show(picture) }
            }
        case .firstFrame(let video):
            loadingID = video.id
            let frame = await ThumbnailCache.shared.firstFrame(of: video.url, modified: video.modified, size: Self.loadSize, scale: displayScale)
            if loadingID == video.id, !Task.isCancelled { show(frame) }
        case nil:
            loadingID = nil
            show(nil)
        }
    }

    private func show(_ picture: NSImage?) {
        image = picture
        if let picture {
            Self.shown.setObject(picture, forKey: project.id as NSString)
        } else {
            Self.shown.removeObject(forKey: project.id as NSString)
        }
    }
}
