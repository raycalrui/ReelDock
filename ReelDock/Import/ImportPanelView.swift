import AppKit
import SwiftUI

/// One tab's import panel state.
@Observable
final class ImportPanelModel {
    var cardID: String?
    var checked: Set<String> = []
    var highlighted: Set<String> = []
    var hideImported = false
    var subfolder: URL?
    var subfolderOptions: [URL] = []
    /// While false, the selection follows "every new clip" as the status scan completes.
    var userEditedSelection = false
}

struct ImportPanelView: View {
    let app: AppModel
    let tab: TabModel
    let model: ImportPanelModel
    weak var controller: WorkspaceWindowController?

    @State private var freeBytes: Int64?

    private var card: CameraCard? {
        app.cards.cards.first { $0.id == model.cardID } ?? app.cards.cards.first
    }

    var body: some View {
        VStack(spacing: 0) {
            if let card {
                header(card)
                Divider()
                clipList(card)
                Divider()
                footer(card)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: syncSelection)
        .onChange(of: app.cards.presenceGeneration) { syncSelection() }
        .onChange(of: card?.id) { syncSelection() }
        .onChange(of: model.highlighted) { publishHighlight() }
        .task(id: "\(tab.folder?.path ?? "")|\(app.queue.jobs.count)|\(app.queue.doneCount)") { await refreshFreeSpace() }
    }

    // MARK: Header

    private func header(_ card: CameraCard) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "sdcard")
                .foregroundStyle(.secondary)
            if app.cards.cards.count > 1 {
                Picker("Card", selection: cardBinding) {
                    ForEach(app.cards.cards) { Text($0.volumeName).tag(Optional($0.id)) }
                }
                .labelsHidden()
                .fixedSize()
            } else {
                Text(card.volumeName)
                    .font(.headline)
            }
            Text(cardSummary(card))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button {
                app.eject(card, from: controller)
            } label: {
                if app.ejectingCardIDs.contains(card.id) {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Ejecting…")
                    }
                } else {
                    Label("Eject", systemImage: "eject.fill")
                }
            }
            .disabled(app.queue.isActive(cardID: card.id) || app.ejectingCardIDs.contains(card.id))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var cardBinding: Binding<String?> {
        Binding(
            get: { card?.id },
            set: {
                model.cardID = $0
                model.userEditedSelection = false
                syncSelection()
            }
        )
    }

    private func cardSummary(_ card: CameraCard) -> String {
        var parts = [card.deviceFolder ?? card.cameraModel ?? card.adapterName]
        parts.append("\(card.clips.count) clips")
        parts.append(ImportFormat.bytes(card.clips.reduce(0) { $0 + $1.size }))
        return parts.joined(separator: " · ")
    }

    // MARK: Clips

    @ViewBuilder
    private func clipList(_ card: CameraCard) -> some View {
        let groups = ClipGrouping.groups(visibleClips(card))
        if card.clips.isEmpty {
            placeholder("This card has no clips.")
        } else if groups.isEmpty {
            placeholder("Every clip on this card has been imported.")
        } else {
            List(selection: Bindable(model).highlighted) {
                ForEach(groups) { group in
                    Section {
                        ForEach(group.clips) { clip in
                            row(clip)
                                .tag(clip.id)
                                .listRowSeparator(.hidden)
                        }
                    } header: {
                        groupHeader(group)
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func visibleClips(_ card: CameraCard) -> [CardClip] {
        guard model.hideImported else { return card.clips }
        return card.clips.filter { isNew($0) || app.queue.activeJob(clipID: $0.id) != nil }
    }

    private func groupHeader(_ group: ClipGroup) -> some View {
        let selectable = group.clips.filter(isNew)
        let checkedCount = selectable.filter { model.checked.contains($0.id) }.count
        return HStack(spacing: 8) {
            Toggle(sources: [Binding(
                get: { !selectable.isEmpty && checkedCount == selectable.count },
                set: { value in
                    model.userEditedSelection = true
                    if value {
                        model.checked.formUnion(selectable.map(\.id))
                    } else {
                        model.checked.subtract(group.clips.map(\.id))
                    }
                }
            )], isOn: \.self) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(selectable.isEmpty)
            Text(group.title)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
            Text("\(group.clips.count) clips · \(ImportFormat.bytes(group.totalSize))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 2)
    }

    private func row(_ clip: CardClip) -> some View {
        let isBusy = app.queue.activeJob(clipID: clip.id) != nil
        return HStack(spacing: 10) {
            Toggle("Import \(clip.name)", isOn: Binding(
                get: { model.checked.contains(clip.id) && !isBusy },
                set: { value in
                    model.userEditedSelection = true
                    if value { model.checked.insert(clip.id) } else { model.checked.remove(clip.id) }
                }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(isBusy)

            ClipThumbnail(url: clip.thumbnailURL)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(clip.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    Text(ImportFormat.bytes(clip.size))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                Text(ImportFormat.details(clip))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                statusLabel(clip)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func statusLabel(_ clip: CardClip) -> some View {
        if let job = app.queue.activeJob(clipID: clip.id) {
            switch job.state {
            case .queued:
                Text("Queued").foregroundStyle(.secondary).font(.callout)
            case .verifying:
                Text("Verifying…").foregroundStyle(.secondary).font(.callout)
            default:
                ProgressView(value: min(1, Double(app.queue.activeBytes) / Double(max(1, clip.size))))
                    .frame(width: 120)
            }
        } else {
            switch status(of: clip) {
            case .new:
                Text(app.cards.isPresenceReady ? "New" : "Checking…")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            case let .inCurrentFolder(path):
                revealButton("In this folder", path: path, tint: .green)
            case let .elsewhere(path, place):
                revealButton("In \(place)", path: path, tint: .green)
            case .importedMissing:
                Label("Imported, now missing", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
                    .help("This clip was imported before, but the file is no longer where it was saved.")
            }
        }
    }

    private func revealButton(_ title: String, path: String, tint: Color) -> some View {
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        } label: {
            Label(title, systemImage: "checkmark.circle.fill")
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(tint)
                .font(.callout)
        }
        .buttonStyle(.plain)
        .help("Reveal \(path) in Finder")
    }

    // MARK: Footer

    private func footer(_ card: CameraCard) -> some View {
        let selected = checkedClips(card)
        let size = selected.reduce(0) { $0 + $1.size }
        return VStack(spacing: 8) {
            HStack(spacing: 10) {
                Button("Select New") { selectAllNew(card) }
                    .fixedSize()
                Button("Deselect All") {
                    model.userEditedSelection = true
                    model.checked.removeAll()
                }
                .fixedSize()
                Spacer(minLength: 0)
                Toggle("Hide Imported", isOn: Bindable(model).hideImported)
                    .toggleStyle(.checkbox)
                    .fixedSize()
            }
            Text(selectionSummary(count: selected.count, size: size))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if model.subfolderOptions.count > 1 {
                HStack {
                    Picker("Into", selection: Bindable(model).subfolder) {
                        ForEach(model.subfolderOptions, id: \.self) { url in
                            Text(subfolderTitle(url)).tag(Optional(url))
                        }
                    }
                    .fixedSize()
                    Spacer(minLength: 0)
                }
            }
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button("Import to Archive") {
                    start(selected, card: card, target: .archive)
                }
                .fixedSize()
                .disabled(selected.isEmpty || app.ejectingCardIDs.contains(card.id))
                targetButton(selected: selected, card: card)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// A separate button and menu, because a combined menu button can't be drawn as the prominent action.
    private func targetButton(selected: [CardClip], card: CameraCard) -> some View {
        HStack(spacing: 4) {
            Button {
                if let folder = tab.folder {
                    start(selected, card: card, target: model.subfolder.map(ImportTarget.exactFolder) ?? .project(folder))
                } else {
                    app.chooseImportFolder(from: controller) { start(selected, card: card, target: .exactFolder($0)) }
                }
            } label: {
                Text(tab.folder.map { "Import to \($0.lastPathComponent)" } ?? "Import to…")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .buttonStyle(.borderedProminent)

            Menu {
                let others = app.controllers.compactMap(\.tab.folder).filter { $0 != tab.folder }
                ForEach(others, id: \.self) { folder in
                    Button(folder.lastPathComponent) { start(selected, card: card, target: .project(folder)) }
                }
                if !others.isEmpty { Divider() }
                ForEach(app.settings.favorites, id: \.self) { path in
                    Button((path as NSString).lastPathComponent) {
                        start(selected, card: card, target: .project(URL(fileURLWithPath: path, isDirectory: true)))
                    }
                }
                if !app.settings.favorites.isEmpty { Divider() }
                Button("Choose Folder…") {
                    app.chooseImportFolder(from: controller) { start(selected, card: card, target: .exactFolder($0)) }
                }
            } label: {
                EmptyView()
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Import somewhere else")
        }
        .disabled(selected.isEmpty || app.ejectingCardIDs.contains(card.id))
    }

    private func subfolderTitle(_ url: URL) -> String {
        guard let base = model.subfolderOptions.first, url != base else { return url.lastPathComponent }
        return "\(base.lastPathComponent)/\(url.lastPathComponent)"
    }

    private func selectionSummary(count: Int, size: Int64) -> String {
        var parts = ["\(count) selected"]
        if count > 0 { parts.append(ImportFormat.bytes(size)) }
        if let freeBytes { parts.append("\(ImportFormat.bytes(freeBytes)) free") }
        return parts.joined(separator: " · ")
    }

    // MARK: Actions

    private func status(of clip: CardClip) -> ClipStatus {
        app.cards.presence[clip.id]?.status(
            currentFolder: tab.folder,
            projectRoot: app.projectRootURL,
            mediaRoot: app.mediaRootURL
        ) ?? .new
    }

    private func isNew(_ clip: CardClip) -> Bool {
        (app.cards.presence[clip.id]?.isNew ?? true) && app.queue.activeJob(clipID: clip.id) == nil
    }

    private func checkedClips(_ card: CameraCard) -> [CardClip] {
        card.clips.filter { model.checked.contains($0.id) && app.queue.activeJob(clipID: $0.id) == nil }
    }

    private func selectAllNew(_ card: CameraCard) {
        model.userEditedSelection = true
        model.checked = Set(card.clips.filter(isNew).map(\.id))
    }

    /// Selects every new clip for one-click import, until the user changes the selection.
    private func syncSelection() {
        guard !model.userEditedSelection, let card else { return }
        model.checked = app.cards.isPresenceReady ? Set(card.clips.filter(isNew).map(\.id)) : []
    }

    private func start(_ clips: [CardClip], card: CameraCard, target: ImportTarget) {
        guard app.startImport(clips, card: card, target: target, from: controller) else { return }
        // Leave what's left selected, so it can go somewhere else with one more click.
        model.userEditedSelection = false
        syncSelection()
    }

    /// Selected rows drive the inspector and its player, like files in a browser.
    private func publishHighlight() {
        guard let card, !model.highlighted.isEmpty else {
            controller?.content.syncSelectionFromBrowser()
            return
        }
        controller?.content.clearBrowserSelection()
        tab.selection = card.clips.filter { model.highlighted.contains($0.id) }.map { clip in
            FolderItem(url: clip.url, name: clip.name, isFolder: false, size: clip.size, modified: nil, contentType: .mpeg4Movie)
        }
    }

    private func refreshFreeSpace() async {
        let folder = tab.folder ?? app.projectRootURL ?? URL(fileURLWithPath: NSHomeDirectory())
        freeBytes = await Task.detached(priority: .utility) {
            (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage
        }.value
    }
}

enum ImportFormat {
    private static let formatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    static func bytes(_ count: Int64) -> String {
        formatter.string(fromByteCount: count)
    }

    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return String(format: "%.1f s", seconds) }
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }

    static func details(_ clip: CardClip) -> String {
        var parts: [String] = []
        if let time = clip.time?.time { parts.append(time) }
        if let duration = clip.duration { parts.append(Self.duration(duration)) }
        if let width = clip.width, let height = clip.height { parts.append("\(width)×\(height)") }
        if let rate = clip.frameRateLabel { parts.append(rate) }
        if let gamma = clip.gamma { parts.append(gamma) }
        if let lens = clip.lens { parts.append(lens) }
        return parts.joined(separator: " · ")
    }
}

/// Uses the thumbnail the camera already wrote to the card, so listing never decodes video.
fileprivate struct ClipThumbnail: View {
    let url: URL?

    private static let cache = NSCache<NSString, NSImage>()

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .frame(width: 80, height: 45)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .task(id: url) {
            guard let url else { return }
            let key = url.path as NSString
            if let cached = Self.cache.object(forKey: key) {
                image = cached
                return
            }
            let data = await Task.detached(priority: .utility) { try? Data(contentsOf: url) }.value
            guard let data, let loaded = NSImage(data: data) else { return }
            Self.cache.setObject(loaded, forKey: key)
            image = loaded
        }
    }
}

/// Toolbar control for background imports, available from any tab.
struct ImportActivityButton: View {
    let app: AppModel
    @State private var showsDetails = false

    var body: some View {
        Button {
            showsDetails.toggle()
        } label: {
            ZStack {
                if app.queue.isActive || app.transfers.isActive {
                    ProgressView(value: fraction)
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                } else if app.queue.failedCount > 0 || app.transfers.failedCount > 0 {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                } else {
                    Image(systemName: "arrow.down.circle")
                        .foregroundStyle(isEmpty ? .tertiary : .primary)
                }
            }
            // The toolbar's glass capsule takes its width from this frame, so it must match its height.
            .frame(width: 36, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isEmpty)
        .help("Copy activity")
        .accessibilityLabel("Copy activity")
        .popover(isPresented: $showsDetails, arrowEdge: .bottom) {
            VStack(spacing: 0) {
                if !app.transfers.jobs.isEmpty {
                    TransferActivityView(queue: app.transfers)
                }
                if !app.transfers.jobs.isEmpty, !app.queue.jobs.isEmpty {
                    Divider()
                }
                if !app.queue.jobs.isEmpty {
                    ImportActivityView(app: app)
                }
            }
        }
    }

    private var isEmpty: Bool {
        app.queue.jobs.isEmpty && app.transfers.jobs.isEmpty
    }

    private var fraction: Double {
        guard app.queue.isActive else { return app.transfers.fraction }
        return min(1, Double(app.queue.completedBytes) / Double(max(1, app.queue.totalBytes)))
    }
}

struct ImportActivityView: View {
    let app: AppModel

    private var queue: ImportQueue { app.queue }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            summary
            if queue.isActive {
                ProgressView(value: min(1, Double(queue.completedBytes) / Double(max(1, queue.totalBytes))))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(queue.jobs) { job in
                        HStack(spacing: 8) {
                            stateIcon(job.state)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(job.clip.name)
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
                }
            }
            .frame(maxHeight: 260)
            controls
        }
        .padding(14)
        .frame(width: 360)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 2) {
            if queue.isActive {
                Text(queue.isPaused ? "Paused" : "Importing \(queue.doneCount + 1) of \(queue.jobs.filter { !isStopped($0.state) }.count)")
                    .font(.headline)
                Text(progressLine)
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else {
                Text(queue.failedCount > 0
                    ? "\(queue.doneCount) imported, \(queue.failedCount) failed"
                    : "\(queue.doneCount) clips imported and verified")
                    .font(.headline)
            }
        }
    }

    private var progressLine: String {
        var parts = ["\(ImportFormat.bytes(queue.completedBytes)) of \(ImportFormat.bytes(queue.totalBytes))"]
        if queue.bytesPerSecond > 0 { parts.append("\(ImportFormat.bytes(Int64(queue.bytesPerSecond)))/s") }
        if let remaining = queue.secondsRemaining, queue.bytesPerSecond > 0 {
            parts.append("\(ImportFormat.duration(remaining)) left")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var controls: some View {
        HStack {
            if queue.isActive {
                Button(queue.isPaused ? "Resume" : "Pause") { queue.setPaused(!queue.isPaused) }
                Button("Cancel", role: .cancel) { queue.cancelAll() }
            } else {
                if queue.failedCount > 0 {
                    Button("Retry Failed") { queue.retryFailed() }
                }
                Button("Clear") { queue.clearFinished() }
            }
            Spacer()
            ForEach(ejectableCards) { card in
                Button(app.ejectingCardIDs.contains(card.id) ? "Ejecting \(card.volumeName)…" : "Eject \(card.volumeName)") {
                    app.eject(card, from: nil)
                }
                .disabled(app.ejectingCardIDs.contains(card.id))
            }
        }
    }

    /// Cards this queue read from, offered once nothing is copying from them.
    private var ejectableCards: [CameraCard] {
        let used = Set(queue.jobs.map(\.cardID))
        return app.cards.cards.filter { used.contains($0.id) && !queue.isActive(cardID: $0.id) }
    }

    private func isStopped(_ state: ImportQueue.JobState) -> Bool {
        switch state {
        case .failed, .cancelled: true
        default: false
        }
    }

    private func detail(_ job: ImportQueue.Job) -> String? {
        switch job.state {
        case let .failed(reason): reason
        case let .done(path): ClipPresence.placeName(path: path, projectRoot: app.projectRootURL, mediaRoot: app.mediaRootURL)
        case .verifying: "Verifying"
        case .cancelled: "Cancelled"
        case .queued, .copying: nil
        }
    }

    @ViewBuilder
    private func stateIcon(_ state: ImportQueue.JobState) -> some View {
        switch state {
        case .queued:
            Image(systemName: "clock").foregroundStyle(.secondary)
        case .copying, .verifying:
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
