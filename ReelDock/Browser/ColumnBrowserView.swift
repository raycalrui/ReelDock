import AppKit

protocol BrowserHost: AnyObject {
    var showHidden: Bool { get }
    func browserDidChangeSelection(_ browser: ColumnBrowserView)
    func browserDidChangePath(_ browser: ColumnBrowserView)
    func browser(_ browser: ColumnBrowserView, didLoadRootWithCount count: Int)
    func openInNewTab(_ url: URL)
    func isFavorite(_ url: URL) -> Bool
    func toggleFavorite(_ url: URL)
    func focusAdjacentSection(from browser: ColumnBrowserView?, delta: Int)
    func createFolder(in folder: URL) -> URL?
    func renameItem(at url: URL, to name: String) -> URL?
    func moveToTrash(_ urls: [URL]) async
    func tagMenu(for urls: [URL]) -> NSMenu?
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Finder-style column browsing rooted at one folder.
final class ColumnBrowserView: NSView {
    weak var host: BrowserHost?
    let rootURL: URL
    let identifier_: String
    private let rootFilter: BrowserColumnView.Filter

    private let scrollView = NSScrollView()
    private let container = FlippedView()
    private(set) var columns: [BrowserColumnView] = []
    private weak var focusedColumn: BrowserColumnView?

    var showHidden: Bool { host?.showHidden ?? false }

    #if DEBUG
    var debugScrollView: NSScrollView { scrollView }
    #endif

    init(rootURL: URL, identifier: String, filesOnly: Bool, host: BrowserHost) {
        self.rootURL = rootURL
        self.identifier_ = identifier
        self.rootFilter = filesOnly ? .filesOnly : .all
        self.host = host
        super.init(frame: .zero)

        scrollView.documentView = container
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .none
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .controlBackgroundColor
        addSubview(scrollView)

        appendColumn(rootURL, filter: rootFilter)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        layoutColumns()
    }

    /// The last column fills leftover width so short sections don't leave a void.
    private func layoutColumns() {
        let clipSize = scrollView.contentSize
        var x: CGFloat = 0
        for (index, column) in columns.enumerated() {
            let isLast = index == columns.count - 1
            let width = isLast ? max(column.preferredWidth, clipSize.width - x) : column.preferredWidth
            column.showsResizeHandle = !isLast
            column.frame = NSRect(x: x, y: 0, width: width, height: clipSize.height)
            x += width
        }
        container.frame = NSRect(x: 0, y: 0, width: max(x, clipSize.width), height: clipSize.height)
    }

    /// Positive moves toward the left columns, matching the sign of a scroll event's delta.
    func scrollColumns(byX delta: CGFloat) {
        let clip = scrollView.contentView
        let limit = max(0, container.frame.width - clip.bounds.width)
        clip.scroll(to: NSPoint(x: min(limit, max(0, clip.bounds.minX - delta)), y: clip.bounds.minY))
        scrollView.reflectScrolledClipView(clip)
        scrollView.flashScrollers()
    }

    @discardableResult
    private func appendColumn(_ url: URL, filter: BrowserColumnView.Filter = .all) -> BrowserColumnView {
        let column = BrowserColumnView(folderURL: url, filter: filter)
        column.browser = self
        columns.append(column)
        container.addSubview(column)
        needsLayout = true
        return column
    }

    private func truncate(after column: BrowserColumnView) {
        guard let index = columns.firstIndex(where: { $0 === column }) else { return }
        for removed in columns[(index + 1)...] {
            removed.removeFromSuperview()
        }
        columns.removeSubrange((index + 1)...)
        if let focusedColumn, !columns.contains(where: { $0 === focusedColumn }) {
            self.focusedColumn = column
        }
        needsLayout = true
    }

    private func nextColumn(after column: BrowserColumnView) -> BrowserColumnView? {
        guard let index = columns.firstIndex(where: { $0 === column }), index + 1 < columns.count else { return nil }
        return columns[index + 1]
    }

    private func previousColumn(before column: BrowserColumnView) -> BrowserColumnView? {
        guard let index = columns.firstIndex(where: { $0 === column }), index > 0 else { return nil }
        return columns[index - 1]
    }

    // MARK: Column callbacks

    func columnDidGainFocus(_ column: BrowserColumnView) {
        focusedColumn = column
        host?.browserDidChangeSelection(self)
    }

    func columnSelectionDidChange(_ column: BrowserColumnView) {
        focusedColumn = column
        syncChild(of: column)
        host?.browserDidChangeSelection(self)
    }

    func columnDidReload(_ column: BrowserColumnView, selectionChanged: Bool) {
        if column === columns.first {
            host?.browser(self, didLoadRootWithCount: column.items.count)
        }
        if selectionChanged {
            syncChild(of: column)
            host?.browserDidChangeSelection(self)
        }
    }

    /// Makes the column to the right match the column's selection.
    private func syncChild(of column: BrowserColumnView) {
        let selection = column.selectedItems
        let selectedFolder = selection.count == 1 && selection[0].isFolder ? selection[0] : nil

        if let child = nextColumn(after: column), let selectedFolder, child.folderURL.path == selectedFolder.url.path {
            return
        }
        let hadChild = nextColumn(after: column) != nil
        truncate(after: column)

        if let selectedFolder {
            let child = appendColumn(selectedFolder.url)
            layoutSubtreeIfNeeded()
            container.scrollToVisible(child.frame)
            Task { await child.load() }
            host?.browserDidChangePath(self)
        } else if hadChild {
            host?.browserDidChangePath(self)
        }
    }

    // MARK: Keyboard focus

    func moveFocusRight(from column: BrowserColumnView) {
        guard let child = nextColumn(after: column), !child.items.isEmpty else { return }
        window?.makeFirstResponder(child.tableView)
        if child.selectedItems.isEmpty {
            child.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        container.scrollToVisible(child.frame)
    }

    func moveFocusLeft(from column: BrowserColumnView) {
        guard let parent = previousColumn(before: column) else { return }
        column.clearSelectionSilently()
        truncate(after: column)
        window?.makeFirstResponder(parent.tableView)
        container.scrollToVisible(parent.frame)
    }

    /// Moves keyboard focus here. Selecting the first row is optional, because selecting a folder opens it.
    func focus(selectingFirstRow: Bool = false) {
        guard let column = focusedColumn ?? columns.first else { return }
        window?.makeFirstResponder(column.tableView)
        if selectingFirstRow, column.selectedItems.isEmpty, !column.items.isEmpty {
            column.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    // MARK: Selection and state

    /// The focused column's selection, falling back to the nearest selection to its left.
    var currentSelection: [FolderItem] {
        guard let start = focusedColumn, let index = columns.firstIndex(where: { $0 === start }) else { return [] }
        for column in columns[...index].reversed() {
            let selection = column.selectedItems
            if !selection.isEmpty { return selection }
        }
        return []
    }

    // MARK: File operations

    /// A selected folder is already open to the right, so a new folder goes inside it, as in Finder.
    private var newFolderColumn: BrowserColumnView? {
        guard let column = focusedColumn ?? columns.first else { return nil }
        let selection = column.selectedItems
        if selection.count == 1, selection[0].isFolder, let child = nextColumn(after: column) {
            return child
        }
        return column.filter == .all ? column : nil
    }

    /// The column holding what the inspector shows.
    private var selectionColumn: BrowserColumnView? {
        guard let start = focusedColumn, let index = columns.firstIndex(where: { $0 === start }) else { return nil }
        return columns[...index].last { !$0.selectedItems.isEmpty }
    }

    private var isReadOnly: Bool { FileOperations.isOnCameraCard(rootURL) }

    var canCreateFolder: Bool { newFolderColumn != nil && !isReadOnly }
    var canRenameSelection: Bool { selectionColumn?.selectedItems.count == 1 && !isReadOnly }
    var canTrashSelection: Bool { selectionColumn != nil && !isReadOnly }

    func createFolder() {
        guard let column = newFolderColumn else { return }
        createFolder(in: column)
    }

    func createFolder(in column: BrowserColumnView) {
        guard !isReadOnly, let url = host?.createFolder(in: column.folderURL) else { return }
        Task {
            await column.load { column.beginRename(of: url) }
        }
    }

    func renameSelection() {
        guard canRenameSelection, let column = selectionColumn, let item = column.selectedItems.first else { return }
        column.beginRename(of: item.url)
    }

    func trashSelection() {
        guard canTrashSelection, let column = selectionColumn, let host else { return }
        let rows = column.tableView.selectedRowIndexes
        let urls = column.selectedItems.map(\.url)
        Task {
            await host.moveToTrash(urls)
            await column.load { column.selectFileAfterRemoval(near: rows.first ?? 0) }
        }
    }

    func renameDidFinish(in column: BrowserColumnView, newURL: URL) {
        Task {
            await column.load { column.select(url: newURL) }
        }
    }

    /// Clears what another section's activation replaces, while keeping open folder chains visible.
    func clearLeafSelection() {
        guard let last = columns.last(where: { !$0.selectedItems.isEmpty }) else { return }
        if nextColumn(after: last) == nil {
            last.clearSelectionSilently()
            if let parent = previousColumn(before: last) {
                focusedColumn = parent
            }
        }
    }

    /// Folder paths of open columns, excluding the root.
    var openPath: [String] {
        columns.dropFirst().map(\.folderURL.path)
    }

    func loadRoot() async {
        await columns[0].load()
    }

    /// Reopens a saved folder chain. Stops quietly at the first path that no longer exists.
    func restore(path: [String]) async {
        var column = columns[0]
        await column.load()
        for folderPath in path {
            guard let item = column.selectSilently(path: folderPath), item.isFolder else { break }
            let child = appendColumn(item.url)
            await child.load()
            column = child
        }
        layoutSubtreeIfNeeded()
    }

    func handleChange(directories: Set<String>, needsFullRescan: Bool) {
        for column in columns where needsFullRescan || directories.contains(column.canonicalPath) {
            Task { await column.load() }
        }
    }

    func reloadAll() {
        for column in columns {
            Task { await column.load() }
        }
    }
}
