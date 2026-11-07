import AppKit
import SwiftUI

/// Shows one tab's folder, either as stacked sections or as a single column browser.
final class TabContentViewController: NSViewController, BrowserHost, NSSplitViewDelegate {
    private unowned let app: AppModel
    private let tab: TabModel
    weak var windowController: WorkspaceWindowController?

    private static let minimumBrowserWidth: CGFloat = 240
    private static let minimumPanelWidth: CGFloat = 360
    private static let minimumWidthWithPanel = minimumBrowserWidth + minimumPanelWidth + 1

    private let splitView = NSSplitView()
    private let contentArea = NSView()
    private var sectionsHost: SectionsHostView?
    private var singleBrowser: ColumnBrowserView?
    private var messageHost: NSView?
    private var importHost: NSView?
    private var panelWidthConstraints: [NSLayoutConstraint] = []
    let importModel = ImportPanelModel()
    private var watcher: FolderWatcher?
    private var activeBrowser: ColumnBrowserView?
    private var loadGeneration = 0
    /// Set when a folder opens, so a later refresh doesn't take focus from what's being typed.
    private var needsFocus = false

    init(app: AppModel, tab: TabModel) {
        self.app = app
        self.tab = tab
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Keeps content below the toolbar, because the window uses a full-size content view.
    override func loadView() {
        view = NSView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.addArrangedSubview(contentArea)
        view.addSubview(splitView)
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: guide.topAnchor),
            splitView.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
            splitView.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
        ])
    }

    var showHidden: Bool { app.settings.showHidden }

    // MARK: Display

    func display(restoring snapshot: TabSnapshot? = nil) {
        loadGeneration += 1
        needsFocus = true
        clearContent()
        watcher = nil
        tab.selection = []
        importModel.highlighted = []
        // The panel stays open, so another project can be opened to import into.
        if importHost != nil { refreshSubfolderOptions() }

        guard let folder = tab.folder else {
            if app.projectRootURL == nil || app.projects.isEmpty {
                showMessage(EmptyTabView(app: app, controller: windowController))
            } else {
                showMessage(ProjectPickerView(app: app, controller: windowController))
            }
            return
        }
        watcher = FolderWatcher(path: folder.canonicalPath) { [weak self] change in
            self?.handle(change)
        }

        switch tab.mode {
        case .sections:
            loadSections(folder: folder, restoring: snapshot)
        case .single:
            let preference = app.settings.sections[SectionBuilder.singleBrowserKey]
            let browser = ColumnBrowserView(
                rootURL: folder,
                identifier: "single",
                filesOnly: false,
                host: self,
                sort: preference?.sort ?? .standard,
                isGrid: preference?.isGrid ?? false
            )
            singleBrowser = browser
            install(browser)
            activeBrowser = browser
            Task {
                await browser.restore(path: snapshot?.openPaths["single"] ?? [])
                browser.focus()
            }
        }
    }

    private func clearContent() {
        sectionsHost?.removeFromSuperview()
        sectionsHost = nil
        singleBrowser?.removeFromSuperview()
        singleBrowser = nil
        messageHost?.removeFromSuperview()
        messageHost = nil
        activeBrowser = nil
    }

    private func install(_ content: NSView) {
        content.translatesAutoresizingMaskIntoConstraints = false
        contentArea.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: contentArea.topAnchor),
            content.bottomAnchor.constraint(equalTo: contentArea.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: contentArea.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: contentArea.trailingAnchor),
        ])
    }

    private func showMessage(_ content: some View) {
        let host = NSHostingView(rootView: content)
        messageHost = host
        install(host)
    }

    private func loadSections(folder: URL, restoring snapshot: TabSnapshot?) {
        let generation = loadGeneration
        let showHidden = showHidden
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try SectionBuilder.build(folder: folder, showHidden: showHidden) }
            }.value
            guard let self, generation == self.loadGeneration else { return }
            switch result {
            case let .success(sections):
                self.apply(sections, restoring: snapshot)
            case let .failure(error):
                self.showMessage(FolderErrorView(folder: folder, message: error.localizedDescription) { [weak self] in
                    self?.display()
                })
            }
        }
    }

    /// Reuses panes for sections that still exist, so refreshes keep open columns.
    private func apply(_ sections: [FolderSection], restoring snapshot: TabSnapshot?) {
        let host: SectionsHostView
        if let existing = sectionsHost {
            host = existing
        } else {
            host = SectionsHostView()
            sectionsHost = host
            install(host)
            host.stack.onWeightChange = { [weak self] section, weight in
                self?.app.updateSectionPreference(section.preferenceKey) { $0.heightWeight = Double(weight) }
            }
            host.stack.onExpansionChange = { [weak self] section, expanded in
                self?.app.updateSectionPreference(section.preferenceKey) { $0.collapsed = !expanded }
            }
        }

        let hasNumbered = sections.contains(where: \.isNumbered)
        let existing = host.stack.panes
        var created: [SectionPaneView] = []
        let panes = sections.map { section -> SectionPaneView in
            if let pane = existing.first(where: { $0.section.id == section.id }) {
                return pane
            }
            let pane = makePane(section, hasNumbered: hasNumbered)
            created.append(pane)
            return pane
        }
        for (pane, section) in zip(panes, sections) {
            pane.header.tags = section.tags
        }
        host.stack.setPanes(panes)
        host.needsLayout = true
        if needsFocus {
            needsFocus = false
            focusContent()
        }

        for pane in created {
            let path = snapshot?.openPaths[pane.section.id] ?? []
            Task { await pane.browser.restore(path: path) }
        }
    }

    private func makePane(_ section: FolderSection, hasNumbered: Bool) -> SectionPaneView {
        let preference = app.settings.sections[section.preferenceKey]
        let pane = SectionPaneView(
            section: section,
            host: self,
            sort: preference?.sort ?? .standard,
            isGrid: preference?.isGrid ?? section.startsAsGrid
        )
        pane.header.isGrid = pane.browser.isGrid
        pane.header.onToggleGrid = { [weak pane] in
            guard let pane else { return }
            pane.browser.setGrid(!pane.browser.isGrid)
        }
        pane.header.makeSortMenu = { [weak pane] in pane?.browser.sortMenu() }
        pane.isExpanded = preference?.collapsed.map { !$0 } ?? section.startsExpanded(amongNumberedSections: hasNumbered)
        pane.weight = preference?.heightWeight.map { CGFloat($0) } ?? pane.defaultWeight

        pane.header.onToggle = { [weak self, weak pane] in
            guard let pane else { return }
            self?.sectionsHost?.stack.toggle(pane)
        }
        pane.header.onMaximize = { [weak self, weak pane] in
            guard let pane else { return }
            self?.sectionsHost?.stack.toggleMaximize(pane)
        }
        pane.header.onReveal = {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: section.url.path)
        }
        // Always in view, so it works when the list is full. It's also the way into a section that's empty, since an empty section doesn't open.
        pane.header.makeMenu = { [weak self, weak pane] in
            guard let self, let pane else { return nil }
            let menu = NSMenu()
            pane.browser.addViewOptionItems(to: menu)
            guard !FileOperations.isOnCameraCard(section.url) else { return menu }
            menu.addItem(.separator())
            if !section.isFilesOnly {
                menu.addItem(.closure("New Folder") { [weak self, weak pane] in
                    guard let pane else { return }
                    // Naming it in place needs a column on screen.
                    if pane.isExpanded, pane.count != 0, let column = pane.browser.columns.first {
                        pane.browser.createFolder(in: column)
                    } else {
                        _ = self?.createFolder(in: section.url)
                    }
                })
            }
            if self.canPasteFiles {
                menu.addItem(.closure("Paste") { [weak self] in self?.transferPastedFiles(.copy, into: section.url) })
                menu.addItem(.closure("Move Here") { [weak self] in self?.transferPastedFiles(.move, into: section.url) })
            }
            return menu
        }
        pane.header.dropOperation = { [weak self] info in
            self?.dropOperation(info, into: section.url) ?? []
        }
        pane.header.acceptDrop = { [weak self] info in
            self?.acceptDrop(info, into: section.url) ?? false
        }
        return pane
    }

    // MARK: Import panel

    func showImportPanel(cardID: String?) {
        guard let cardID = cardID ?? app.cards.cards.first?.id else { return }
        tab.importCardID = cardID
        tab.isImportPanelVisible = true
        importModel.cardID = tab.importCardID
        importModel.highlighted = []
        importModel.userEditedSelection = false
        refreshSubfolderOptions()
        app.cards.refreshPresence()
        windowController?.refreshImportItem()

        guard importHost == nil else { return }
        let host = NSHostingView(rootView: ImportPanelView(app: app, tab: tab, model: importModel, controller: windowController))
        host.sizingOptions = []
        importHost = host
        splitView.addArrangedSubview(host)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 1)
        // Dragging limits alone wouldn't hold when the window narrows.
        panelWidthConstraints = [
            contentArea.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumBrowserWidth),
            host.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumPanelWidth),
        ]
        NSLayoutConstraint.activate(panelWidthConstraints)
        windowController?.setContentMinimumWidth(Self.minimumWidthWithPanel)
        view.window?.layoutIfNeeded()
        let available = splitView.bounds.width - splitView.dividerThickness
        splitView.setPosition(available * (1 - app.importPanelFraction), ofDividerAt: 0)
    }

    func hideImportPanel() {
        guard let importHost else { return }
        let hadFocus = (view.window?.firstResponder as? NSView)?.isDescendant(of: importHost) ?? false
        NSLayoutConstraint.deactivate(panelWidthConstraints)
        panelWidthConstraints = []
        importHost.removeFromSuperview()
        self.importHost = nil
        tab.isImportPanelVisible = false
        tab.importCardID = nil
        importModel.highlighted = []
        syncSelectionFromBrowser()
        windowController?.refreshImportItem()
        windowController?.setContentMinimumWidth(nil)
        if hadFocus { focusContent() }
    }

    /// The panel follows its card: it moves to another card if one is present, and otherwise closes.
    func cardsDidChange() {
        guard importHost != nil else { return }
        let cards = app.cards.cards
        if cards.contains(where: { $0.id == importModel.cardID }) { return }
        if let next = cards.first {
            showImportPanel(cardID: next.id)
        } else {
            hideImportPanel()
        }
    }

    var importPanelHasFocus: Bool {
        guard let importHost, let responder = view.window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: importHost)
    }

    func moveImportHighlight(by delta: Int, extending: Bool) {
        let order = ImportPanelView.listedClips(app: app, model: importModel).map(\.id)
        importModel.moveHighlight(by: delta, extending: extending, order: order)
    }

    func toggleImportChecks() {
        let busy = Set(app.queue.jobs.filter(\.state.isActive).map(\.clip.id))
        importModel.toggleCheckedHighlighted(excluding: busy)
    }

    /// Hands the inspector back to the browser once no clip is highlighted.
    func syncSelectionFromBrowser() {
        tab.selection = activeBrowser?.currentSelection ?? []
    }

    /// Only one side stays selected, so the browser doesn't look selected while a clip is previewed.
    func clearBrowserSelection() {
        activeBrowser?.clearLeafSelection()
    }

    /// The browser the View menu's sort and grid choices apply to.
    var viewOptionsBrowser: ColumnBrowserView? {
        activeBrowser ?? sectionsHost?.stack.panes.first { $0.isExpanded && $0.count != 0 }?.browser
    }

    /// Nil while a card clip is selected, because nothing on a card can be changed.
    var fileOperationBrowser: ColumnBrowserView? {
        importModel.highlighted.isEmpty ? activeBrowser : nil
    }

    // MARK: NSSplitViewDelegate

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        proposedMinimumPosition + Self.minimumBrowserWidth
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        proposedMaximumPosition - Self.minimumPanelWidth
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard let importHost, !view.inLiveResize, NSApp.currentEvent?.type == .leftMouseDragged else { return }
        let available = splitView.bounds.width - splitView.dividerThickness
        guard available > 0 else { return }
        app.setImportPanelFraction(importHost.frame.width / available)
    }

    /// Offers the video folder and the folders directly inside it, like `3 video/FX3`.
    private func refreshSubfolderOptions() {
        importModel.subfolder = nil
        importModel.subfolderOptions = []
        guard let folder = tab.folder, let video = ImportRouting.videoFolder(inProject: folder) else { return }
        let children = (try? FolderReader.read(video, showHidden: false)) ?? []
        importModel.subfolderOptions = [video] + children.filter(\.isFolder).map(\.url)
        importModel.subfolder = video
    }

    // MARK: Live refresh

    private func handle(_ change: FolderWatcher.Change) {
        guard let folder = tab.folder else { return }
        tab.folderChanges &+= 1
        windowController?.refreshTabTags()
        if change.rootChanged, !FileManager.default.fileExists(atPath: folder.path) {
            windowController?.folderDidDisappear()
            return
        }
        if sectionsHost != nil, change.needsFullRescan || change.directories.contains(folder.canonicalPath) {
            loadSections(folder: folder, restoring: nil)
        }
        sectionsHost?.stack.panes.forEach {
            $0.browser.handleChange(directories: change.directories, needsFullRescan: change.needsFullRescan)
        }
        singleBrowser?.handleChange(directories: change.directories, needsFullRescan: change.needsFullRescan)
    }

    func reloadFolderContents() {
        if sectionsHost != nil {
            sectionsHost?.stack.panes.forEach { $0.browser.reloadAll() }
            if let folder = tab.folder { loadSections(folder: folder, restoring: nil) }
        }
        singleBrowser?.reloadAll()
    }

    // MARK: Session state

    func snapshot() -> TabSnapshot? {
        guard let folder = tab.folder else { return nil }
        var paths: [String: [String]] = [:]
        if let singleBrowser {
            paths["single"] = singleBrowser.openPath
        }
        for pane in sectionsHost?.stack.panes ?? [] where !pane.browser.openPath.isEmpty {
            paths[pane.section.id] = pane.browser.openPath
        }
        return TabSnapshot(folderPath: folder.path, mode: tab.mode, openPaths: paths)
    }

    func focusContent() {
        (activeBrowser ?? sectionsHost?.stack.panes.first { $0.isExpanded && $0.count != 0 }?.browser)?.focus()
    }

    #if DEBUG
    var debugSplitView: NSSplitView { splitView }
    var debugSectionsHost: SectionsHostView? { sectionsHost }
    var debugSingle: ColumnBrowserView? { singleBrowser }
    var debugImportHost: NSView? { importHost }
    #endif

    // MARK: BrowserHost

    func browserDidChangeSelection(_ browser: ColumnBrowserView) {
        // A folder refreshing during an import shouldn't take the selection from the panel.
        if let importHost, let responder = view.window?.firstResponder as? NSView, responder.isDescendant(of: importHost) { return }
        importModel.highlighted = []
        if activeBrowser !== browser {
            activeBrowser?.clearLeafSelection()
            activeBrowser = browser
            sectionsHost?.stack.panes.forEach { $0.header.isActive = $0.browser === browser }
        }
        tab.selection = browser.currentSelection
    }

    func browserDidChangePath(_ browser: ColumnBrowserView) {
        app.scheduleSessionSave()
    }

    func browserDidChangeViewOptions(_ browser: ColumnBrowserView) {
        let pane = sectionsHost?.stack.panes.first { $0.browser === browser }
        pane?.header.isGrid = browser.isGrid
        // A grid takes more height than a list.
        sectionsHost?.needsLayout = true
        sectionsHost?.stack.needsLayout = true
        let key = pane?.section.preferenceKey ?? SectionBuilder.singleBrowserKey
        app.updateSectionPreference(key) {
            $0.sort = browser.sort
            $0.isGrid = browser.isGrid
        }
    }

    func browser(_ browser: ColumnBrowserView, didLoadRootWithCount count: Int) {
        guard let stack = sectionsHost?.stack,
              let pane = stack.panes.first(where: { $0.browser === browser }),
              pane.count != count else { return }
        pane.count = count
        stack.refreshHeaders()
        sectionsHost?.needsLayout = true
        stack.needsLayout = true
    }

    func openInNewTab(_ url: URL) {
        app.open(url, from: windowController, newTab: true)
    }

    func isFavorite(_ url: URL) -> Bool {
        app.isFavorite(url)
    }

    func toggleFavorite(_ url: URL) {
        app.toggleFavorite(url)
    }

    func focusAdjacentSection(from browser: ColumnBrowserView?, delta: Int) {
        sectionsHost?.stack.focusAdjacent(from: browser, delta: delta)
    }

    func createFolder(in folder: URL) -> URL? {
        windowController?.createFolder(in: folder)
    }

    func renameItem(at url: URL, to name: String) -> URL? {
        windowController?.renameItem(at: url, to: name)
    }

    var canPasteFiles: Bool {
        !NSPasteboard.files.fileURLs.isEmpty
    }

    func transferPastedFiles(_ kind: FileTransfer.Kind, into folder: URL) {
        windowController?.transferPastedFiles(kind, into: folder)
    }

    func dropOperation(_ info: any NSDraggingInfo, into folder: URL) -> NSDragOperation {
        windowController?.dropOperation(info, into: folder) ?? []
    }

    func acceptDrop(_ info: any NSDraggingInfo, into folder: URL) -> Bool {
        windowController?.acceptDrop(info, into: folder) ?? false
    }

    func moveToTrash(_ urls: [URL]) async {
        await windowController?.moveToTrash(urls)
    }

    func createTraditionalVersions(of urls: [URL]) async -> [URL] {
        await windowController?.createTraditionalVersions(of: urls) ?? []
    }

    func addTagItems(to menu: NSMenu, for urls: [URL]) {
        windowController?.addTagItems(to: menu, for: urls)
    }
}

private struct EmptyTabView: View {
    let app: AppModel
    weak var controller: WorkspaceWindowController?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "film.stack")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
            if app.projectRootURL == nil {
                Text("Choose your projects folder to get started.")
                    .foregroundStyle(.secondary)
                Button("Choose Projects Folder…") { app.chooseProjectRoot(from: controller) }
                    .controlSize(.large)
            } else {
                HStack(spacing: 12) {
                    Button("New Project…") { controller?.promptNewProject() }
                        .disabled(!app.canCreateProject)
                    Button("Open Folder…") { controller?.openFolder(nil) }
                }
                .controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The new-tab page: every project, one click away.
private struct ProjectPickerView: View {
    let app: AppModel
    weak var controller: WorkspaceWindowController?

    var body: some View {
        VStack(spacing: 12) {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(app.projects) { project in
                        ProjectPickerRow(
                            project: project,
                            thumbnailGeneration: app.thumbnailGenerations[project.folderName, default: 0],
                            stats: app.projectStats[project.folderName]
                        ) {
                            app.open(project.url, from: controller)
                        }
                        .task { app.loadStats(for: project) }
                    }
                }
                .frame(maxWidth: 560)
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .frame(maxWidth: .infinity)
            }
            .ignoresSafeArea(.container, edges: .top)
            HStack(spacing: 12) {
                Button("New Project…") { controller?.promptNewProject() }
                Button("Open Folder…") { controller?.openFolder(nil) }
            }
            .controlSize(.large)
            .padding(.bottom, 16)
        }
    }
}

private struct ProjectPickerRow: View {
    let project: ProjectEntry
    let thumbnailGeneration: Int
    let stats: ProjectStats?
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                ProjectThumbnailView(project: project, generation: thumbnailGeneration, width: 80)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(project.title)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        TagDots(tags: project.tags)
                    }
                    if let date = project.displayDate {
                        Text(date)
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if let stats {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(ImportFormat.bytes(stats.size))
                        Text(stats.fileLabel)
                    }
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isHovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(project.folderName)
    }
}

private struct FolderErrorView: View {
    let folder: URL
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.secondary)
            Text("Can't open \(folder.lastPathComponent)")
                .font(.headline)
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Try Again", action: retry)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
