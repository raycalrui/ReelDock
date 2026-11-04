import SwiftUI

/// What the inspector shows with nothing selected: the open folder, or the projects folder on the new-tab page.
struct FolderOverview: View {
    private static let padding: CGFloat = 10
    /// Recounting waits for this much quiet, so a long copy doesn't scan over and over.
    private static let settleDelay: Duration = .seconds(1)

    let url: URL
    let app: AppModel
    let tab: TabModel
    weak var controller: WorkspaceWindowController?

    @State private var summary: FolderSummary?
    @State private var isCounting: Bool

    init(url: URL, app: AppModel, tab: TabModel, controller: WorkspaceWindowController?) {
        self.url = url
        self.app = app
        self.tab = tab
        self.controller = controller
        let last = tab.lastSummary?.path == url.path ? tab.lastSummary?.summary : nil
        _summary = State(initialValue: last)
        _isCounting = State(initialValue: last == nil)
    }

    private var isProjectsFolder: Bool { tab.folder == nil }
    private var entry: ProjectEntry { ProjectCatalog.entry(for: url) }
    private var changes: Int { isProjectsFolder ? app.rootChanges : tab.folderChanges }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !isProjectsFolder, app.isProject(url) {
                        ProjectThumbnailView(
                            project: entry,
                            generation: app.thumbnailGenerations[entry.folderName] ?? 0,
                            width: max(0, proxy.size.width - Self.padding * 2),
                            loadSize: InspectorPreview.posterSize
                        )
                    }
                    header
                    if let summary {
                        totals(summary)
                    } else {
                        Text(isCounting ? "Counting…" : "Can't read this folder")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    if !isProjectsFolder, !FileOperations.isOnCameraCard(url) {
                        TagRow(controller: controller, items: [folderItem])
                    }
                    if let summary, !isProjectsFolder, !summary.sections.isEmpty {
                        contents(summary)
                    }
                    details
                }
                .padding(Self.padding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task(id: changes) { await load() }
    }

    private var folderItem: FolderItem {
        _ = app.tagsGeneration
        return FolderItem(url: url, name: url.lastPathComponent, isFolder: true, size: nil, modified: nil, contentType: nil, tags: FinderTags.read(url))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(isProjectsFolder ? "All Projects" : entry.title)
                .font(.headline)
                .lineLimit(3)
                .textSelection(.enabled)
            if isProjectsFolder {
                Text(app.projects.count == 1 ? "1 project" : "\(app.projects.count) projects")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if let date = entry.displayDate {
                Text(date)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func totals(_ summary: FolderSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 24) {
                total(InspectorFormat.bytes.string(fromByteCount: summary.total.size), "Size")
                total(summary.total.fileCount.formatted(), "Files")
            }
            let kinds = kindsLine(summary)
            if !kinds.isEmpty {
                Text(kinds)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func total(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .textSelection(.enabled)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func kindsLine(_ summary: FolderSummary) -> String {
        var parts: [String] = []
        if summary.videos > 0 { parts.append(summary.videos == 1 ? "1 video" : "\(summary.videos.formatted()) videos") }
        if summary.pictures > 0 { parts.append(summary.pictures == 1 ? "1 picture" : "\(summary.pictures.formatted()) pictures") }
        if summary.audio > 0 { parts.append(summary.audio == 1 ? "1 audio file" : "\(summary.audio.formatted()) audio files") }
        return parts.joined(separator: " · ")
    }

    private func contents(_ summary: FolderSummary) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
            ForEach(summary.sections) { section in
                contentRow(section.name, section.stats)
            }
            let outside = summary.outsideSections
            if outside.fileCount > 0 {
                contentRow("Other files", outside)
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity)
    }

    private func contentRow(_ name: String, _ stats: ProjectStats) -> some View {
        GridRow {
            Text(name)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(name)
            Text(stats.fileCount == 0 ? "Empty" : stats.fileLabel)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(stats.fileCount == 0 ? "" : InspectorFormat.bytes.string(fromByteCount: stats.size))
                .monospacedDigit()
                .gridColumnAlignment(.trailing)
        }
    }

    private var details: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
            if let created = summary?.created {
                detail("Created", created.formatted(date: .abbreviated, time: .shortened))
            }
            if let modified = summary?.modified {
                detail("Modified", modified.formatted(date: .abbreviated, time: .shortened))
            }
            detail("Where", (isProjectsFolder ? url : url.deletingLastPathComponent()).path)
        }
        .font(.callout)
    }

    private func detail(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(value)
        }
    }

    private func load() async {
        if summary != nil {
            try? await Task.sleep(for: Self.settleDelay)
            guard !Task.isCancelled else { return }
        }
        let folder = url
        let scan = Task.detached(priority: .utility) { FolderSummary.read(folder) }
        let result = await withTaskCancellationHandler { await scan.value } onCancel: { scan.cancel() }
        guard !Task.isCancelled else { return }
        summary = result
        isCounting = false
        tab.lastSummary = result.map { (folder.path, $0) }
    }
}
