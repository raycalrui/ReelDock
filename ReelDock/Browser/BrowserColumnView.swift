import AppKit

extension NSPasteboard {
    /// Where files are copied to and pasted from. Test runs can use their own, so they leave the real clipboard alone.
    static var files: NSPasteboard {
        #if DEBUG
        if let name = ProcessInfo.processInfo.environment["REELDOCK_PASTEBOARD"] {
            return NSPasteboard(name: NSPasteboard.Name(name))
        }
        #endif
        return .general
    }

    var fileURLs: [URL] {
        readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }
}

/// Opens what the pointer rests on during a drag, following the system's spring-loading setting.
final class SpringLoad {
    private var target: AnyHashable?
    private var task: Task<Void, Never>?

    private static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "com.apple.springing.enabled") as? Bool ?? true
    }

    private static var delay: Duration {
        .seconds(UserDefaults.standard.object(forKey: "com.apple.springing.delay") as? Double ?? 0.5)
    }

    func isHovering(over candidate: AnyHashable) -> Bool {
        target == candidate
    }

    func hover(over newTarget: AnyHashable, open: @escaping () -> Void) {
        guard newTarget != target, Self.isEnabled else { return }
        cancel()
        target = newTarget
        task = Task { [weak self] in
            try? await Task.sleep(for: Self.delay)
            guard !Task.isCancelled else { return }
            self?.target = nil
            open()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        target = nil
    }
}

/// A table that reports focus and handles Finder's column-view keys.
final class BrowserTableView: NSTableView {
    /// Blank space past the last row, so a full list still has somewhere to right-click.
    private static let bottomPadding: CGFloat = 44

    weak var column: BrowserColumnView?

    override func setFrameSize(_ newSize: NSSize) {
        let height = CGFloat(numberOfRows) * rowHeight + Self.bottomPadding
        super.setFrameSize(NSSize(width: newSize.width, height: max(newSize.height, height)))
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        column?.updateSpringLoad(sender)
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        column?.updateSpringLoad(sender)
        return super.draggingUpdated(sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        column?.cancelSpringLoad()
        super.draggingExited(sender)
    }

    // No super call: AppKit's views don't implement this, so calling it would crash.
    override func draggingEnded(_ sender: any NSDraggingInfo) {
        column?.cancelSpringLoad()
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { column?.tableDidGainFocus() }
        return accepted
    }

    override func keyDown(with event: NSEvent) {
        let command = event.modifierFlags.contains(.command)
        switch event.keyCode {
        case 124 where !command: // Right arrow
            column?.moveFocusRight()
        case 123 where !command: // Left arrow
            column?.moveFocusLeft()
        case 125 where command: // Command-Down
            column?.openSelection()
        case 49: // Space belongs to the player, and shouldn't feed type-select.
            break
        case 36 where !command, 76 where !command: // Return and Enter
            column?.browser?.renameSelection()
        case 48: // Tab
            column?.moveFocusToAdjacentSection(event.modifierFlags.contains(.shift) ? -1 : 1)
        default:
            super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        window?.makeFirstResponder(self)
        guard row >= 0 else { return column?.backgroundMenu() }
        if !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return column?.contextMenu()
    }
}

/// A column only scrolls vertically, so it hands sideways gestures to the browser around it.
/// The system locks a gesture to this view as soon as it moves slightly vertically, which real swipes almost always do.
final class ColumnScrollView: NSScrollView {
    /// How far a gesture travels before its direction counts, because its first events are tiny and unreliable.
    private static let decisionDistance: CGFloat = 3
    weak var browser: ColumnBrowserView?

    private var isSideways: Bool?
    private var travelX: CGFloat = 0
    private var travelY: CGFloat = 0

    override func scrollWheel(with event: NSEvent) {
        updateDirection(event)
        guard isSideways == true, let browser else {
            super.scrollWheel(with: event)
            return
        }
        browser.scrollColumns(byX: event.hasPreciseScrollingDeltas ? event.scrollingDeltaX : event.scrollingDeltaX * 8)
        // This view saw the start of the gesture, so it needs to see the end too.
        if event.phase == .ended || event.phase == .cancelled {
            super.scrollWheel(with: event)
        }
    }

    private func updateDirection(_ event: NSEvent) {
        // A mouse wheel has no phases, so each of its events decides for itself.
        if event.phase.isEmpty, event.momentumPhase.isEmpty {
            isSideways = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
            return
        }
        if event.phase == .mayBegin || event.phase == .began {
            isSideways = nil
            travelX = 0
            travelY = 0
        }
        // Momentum events have no phase of their own, and keep the gesture's direction.
        guard isSideways == nil, !event.phase.isEmpty else { return }
        travelX += abs(event.scrollingDeltaX)
        travelY += abs(event.scrollingDeltaY)
        if travelX + travelY >= Self.decisionDistance {
            isSideways = travelX > travelY
        }
    }
}

/// Rounded selection that stays compact, since sections can be only a few rows tall.
final class BrowserRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("BrowserRow")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func drawSelection(in dirtyRect: NSRect) {
        let color: NSColor = isEmphasized ? .selectedContentBackgroundColor : .unemphasizedSelectedContentBackgroundColor
        color.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 0.5), xRadius: 5, yRadius: 5).fill()
    }
}

/// Draws the column edge and lets it be dragged to resize.
final class ColumnResizeHandle: NSView {
    var onDrag: ((CGFloat) -> Void)?
    private var dragStart: CGFloat = 0

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height).fill()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = event.locationInWindow.x
    }

    override func mouseDragged(with event: NSEvent) {
        let current = event.locationInWindow.x
        onDrag?(current - dragStart)
        dragStart = current
    }
}

/// A row or tile whose name is being typed.
protocol NameEditing: AnyObject {
    func endEditingName()
}

final class BrowserColumnView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSCollectionViewDataSource, NSCollectionViewDelegate {
    enum Filter {
        case all
        case filesOnly
    }

    /// A spring-loaded folder can replace the column a drag started in, which has to outlive the drag.
    private static var draggedFrom: BrowserColumnView?

    let folderURL: URL
    let canonicalPath: String
    let filter: Filter
    weak var browser: ColumnBrowserView? {
        didSet { scrollView.browser = browser }
    }
    private static let listWidth: CGFloat = 280
    /// Two tiles, so a grid with a folder open beside it doesn't fold into one long column.
    private static let gridWidth: CGFloat = 322
    var preferredWidth: CGFloat = listWidth

    private(set) var items: [FolderItem] = []
    private var hasLoaded = false
    private var loadGeneration = 0
    private var afterLoad: [() -> Void] = []
    private(set) var isApplyingSelection = false

    let tableView = BrowserTableView()
    /// Set while this column shows a grid. The table then stays out of the window.
    private(set) var grid: BrowserGridView?
    private var gridSelectionPending = false
    private let scrollView = ColumnScrollView()
    private var renamingURL: URL?
    private weak var renamingCell: (any NameEditing)?
    private var needsReloadAfterRename = false
    private let handle = ColumnResizeHandle()
    private let statusLabel = NSTextField(labelWithString: "")
    private let springLoad = SpringLoad()

    init(folderURL: URL, filter: Filter) {
        self.folderURL = folderURL
        self.canonicalPath = folderURL.canonicalPath
        self.filter = filter
        super.init(frame: .zero)

        let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        tableColumn.resizingMask = .autoresizingMask
        tableView.addTableColumn(tableColumn)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.rowHeight = 26
        tableView.rowSizeStyle = .custom
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.backgroundColor = .controlBackgroundColor
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        tableView.column = self
        tableView.target = self
        tableView.doubleAction = #selector(handleDoubleClick)
        // Dragging out of the app can't move files, and Finder would make an alias if a link were allowed.
        // Generic is what the Command key asks for.
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)
        tableView.setDraggingSourceOperationMask(FileOperations.isOnCameraCard(folderURL) ? .copy : [.copy, .move, .generic], forLocal: true)
        tableView.registerForDraggedTypes([.fileURL])
        // The "Empty" label sits above the table, and would otherwise block a drop on it.
        registerForDraggedTypes([.fileURL])

        scrollView.documentView = tableView
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .controlBackgroundColor
        scrollView.horizontalScrollElasticity = .none
        scrollView.borderType = .noBorder
        addSubview(scrollView)

        statusLabel.textColor = .tertiaryLabelColor
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.alignment = .center
        statusLabel.isHidden = true
        addSubview(statusLabel)

        handle.onDrag = { [weak self] delta in
            guard let self else { return }
            self.preferredWidth = max(140, self.preferredWidth + delta)
            self.browser?.needsLayout = true
        }
        addSubview(handle)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// What takes keyboard focus in this column.
    var focusView: NSView { grid ?? tableView }

    /// Swaps the list and the grid, keeping the selection.
    func setGrid(_ isGrid: Bool) {
        guard isGrid != (grid != nil) else { return }
        let rows = selectedRows
        let hadFocus = window?.firstResponder === focusView
        if isGrid {
            let view = BrowserGridView()
            view.column = self
            view.dataSource = self
            view.delegate = self
            view.setDraggingSourceOperationMask(.copy, forLocal: false)
            view.setDraggingSourceOperationMask(FileOperations.isOnCameraCard(folderURL) ? .copy : [.copy, .move, .generic], forLocal: true)
            view.autoresizingMask = [.width]
            grid = view
            scrollView.documentView = view
            if preferredWidth == Self.listWidth { preferredWidth = Self.gridWidth }
        } else {
            grid = nil
            scrollView.documentView = tableView
            if preferredWidth == Self.gridWidth { preferredWidth = Self.listWidth }
        }
        browser?.needsLayout = true
        reloadRows()
        selectRows(rows, quietly: true)
        if hadFocus { window?.makeFirstResponder(focusView) }
    }

    /// A reload can shrink the table's selection, and whoever calls this reports any change itself.
    private func reloadRows() {
        if let grid {
            grid.reloadData()
        } else {
            let wasApplying = isApplyingSelection
            isApplyingSelection = true
            tableView.reloadData()
            isApplyingSelection = wasApplying
        }
    }

    var showsResizeHandle = true {
        didSet { handle.isHidden = !showsResizeHandle }
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        handle.frame = NSRect(x: bounds.maxX - 5, y: 0, width: 5, height: bounds.height)
        handle.needsDisplay = true
        statusLabel.sizeToFit()
        statusLabel.frame = NSRect(
            x: 8,
            y: (bounds.height - statusLabel.frame.height) / 2,
            width: bounds.width - 16,
            height: statusLabel.frame.height
        )
    }

    // MARK: Loading

    /// Reloads off the main thread. Unchanged listings leave the table untouched.
    /// A newer load can replace this one, so `completion` runs once the latest listing is showing.
    func load(completion: (() -> Void)? = nil) async {
        if let completion { afterLoad.append(completion) }
        loadGeneration += 1
        let generation = loadGeneration
        let url = folderURL
        let showHidden = browser?.showHidden ?? false
        let filesOnly = filter == .filesOnly
        let sort = browser?.sort ?? .standard
        let result = await Task.detached(priority: .userInitiated) { () async -> Result<[FolderItem], any Error> in
            do {
                let read = try FolderReader.read(url, showHidden: showHidden)
                let items = filesOnly ? read.filter { !$0.isFolder } : read
                let dates = sort.key == .date ? await ShootingDate.dates(for: items) : [:]
                return .success(sort.sorted(items, dates: dates))
            } catch {
                return .failure(error)
            }
        }.value
        guard generation == loadGeneration else { return }

        switch result {
        case let .success(newItems):
            statusLabel.stringValue = "Empty"
            statusLabel.isHidden = !newItems.isEmpty
            apply(newItems)
        case .failure:
            statusLabel.stringValue = "Can't read this folder"
            statusLabel.isHidden = false
            apply([])
        }
        let actions = afterLoad
        afterLoad = []
        actions.forEach { $0() }
    }

    private func apply(_ newItems: [FolderItem]) {
        // Reloading the table would end the rename in progress.
        if renamingURL != nil {
            needsReloadAfterRename = true
            return
        }
        guard !hasLoaded || newItems != items else { return }
        hasLoaded = true
        let selectedIDs = Set(selectedItems.map(\.id))
        let selectionWasEmpty = selectedIDs.isEmpty
        items = newItems
        reloadRows()
        selectRows(IndexSet(items.indices.filter { selectedIDs.contains(items[$0].id) }), quietly: true)
        browser?.columnDidReload(self, selectionChanged: !selectionWasEmpty)
    }

    // MARK: Selection

    var selectedRows: IndexSet {
        grid.map { IndexSet($0.selectionIndexPaths.map(\.item)) } ?? tableView.selectedRowIndexes
    }

    var selectedItems: [FolderItem] {
        selectedRows.compactMap { $0 < items.count ? items[$0] : nil }
    }

    /// `quietly` keeps the browser and the inspector from hearing about it.
    func selectRows(_ rows: IndexSet, quietly: Bool = false) {
        if let grid {
            grid.selectionIndexPaths = Set(rows.map { IndexPath(item: $0, section: 0) })
            if !quietly { browser?.columnSelectionDidChange(self) }
        } else {
            let wasApplying = isApplyingSelection
            isApplyingSelection = quietly || wasApplying
            tableView.selectRowIndexes(rows, byExtendingSelection: false)
            isApplyingSelection = wasApplying
        }
    }

    private func scrollToRow(_ row: Int) {
        if let grid {
            grid.scrollToItems(at: [IndexPath(item: row, section: 0)], scrollPosition: .nearestHorizontalEdge)
        } else {
            tableView.scrollRowToVisible(row)
        }
    }

    func selectSilently(path: String) -> FolderItem? {
        guard let row = items.firstIndex(where: { $0.url.path == path }) else { return nil }
        selectRows(IndexSet(integer: row), quietly: true)
        scrollToRow(row)
        return items[row]
    }

    func clearSelectionSilently() {
        selectRows(IndexSet(), quietly: true)
    }

    func select(url: URL) {
        guard let row = items.firstIndex(where: { $0.url.path == url.path }) else { return }
        selectRows(IndexSet(integer: row))
        scrollToRow(row)
    }

    /// Keeps culling moving after a delete. A folder isn't selected, since that would open it.
    func selectFileAfterRemoval(near row: Int) {
        guard !items.isEmpty, selectedRows.isEmpty else { return }
        let next = min(row, items.count - 1)
        window?.makeFirstResponder(focusView)
        guard !items[next].isFolder else { return }
        selectRows(IndexSet(integer: next))
        scrollToRow(next)
    }

    // MARK: Rename

    /// Edits the row's name in place. The extension stays out of the initial selection, as in Finder.
    func beginRename(of url: URL) {
        guard renamingURL == nil, let row = items.firstIndex(where: { $0.url.path == url.path }) else { return }
        _ = selectSilently(path: url.path)
        if let grid {
            grid.layoutSubtreeIfNeeded()
            guard let item = grid.item(at: IndexPath(item: row, section: 0)) as? GridTileItem, let tile = item.view as? GridTileView else { return }
            renamingURL = url
            renamingCell = tile
            item.beginEditingName(delegate: self, isFolder: items[row].isFolder)
            return
        }
        tableView.layoutSubtreeIfNeeded()
        guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? FileRowView else { return }
        renamingURL = url
        renamingCell = cell
        cell.beginEditingName(delegate: self, isFolder: items[row].isFolder)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let url = renamingURL, let field = notification.object as? NSTextField else { return }
        finishRename(url: url, field: field, newName: field.stringValue)
        let movement = notification.userInfo?["NSTextMovement"] as? Int
        if movement == NSTextMovement.return.rawValue {
            window?.makeFirstResponder(focusView)
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)), let url = renamingURL, let field = control as? NSTextField else { return false }
        field.abortEditing()
        finishRename(url: url, field: field, newName: nil)
        window?.makeFirstResponder(focusView)
        return true
    }

    private func finishRename(url: URL, field: NSTextField, newName: String?) {
        renamingURL = nil
        renamingCell?.endEditingName()
        renamingCell = nil
        var result = url
        if let newName, newName != url.lastPathComponent {
            result = browser?.host?.renameItem(at: url, to: newName) ?? url
        }
        if needsReloadAfterRename || result != url {
            needsReloadAfterRename = false
            browser?.renameDidFinish(in: self, newURL: result)
        } else if let row = items.firstIndex(where: { $0.url.path == url.path }) {
            // Selecting for real opens a new folder's column, which editing its name held back.
            selectRows(IndexSet(), quietly: true)
            selectRows(IndexSet(integer: row))
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingSelection else { return }
        browser?.columnSelectionDidChange(self)
    }

    func tableDidGainFocus() {
        browser?.columnDidGainFocus(self)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: FileRowView.identifier, owner: nil) as? FileRowView ?? FileRowView()
        cell.configure(with: items[row])
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        tableView.makeView(withIdentifier: BrowserRowView.identifier, owner: nil) as? BrowserRowView ?? BrowserRowView()
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        items[row].name
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        items[row].url as NSURL
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        Self.draggedFrom = self
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        // Later, since releasing a replaced column here could free the table while it's still ending the drag.
        Task { Self.draggedFrom = nil }
    }

    // MARK: Grid

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: GridTileItem.identifier, for: indexPath)
        (item as? GridTileItem)?.configure(with: items[indexPath.item])
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        gridSelectionDidChange()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        gridSelectionDidChange()
    }

    /// A click on another tile deselects and then selects, and only the result should reach the browser.
    private func gridSelectionDidChange() {
        guard !gridSelectionPending else { return }
        gridSelectionPending = true
        Task { [weak self] in
            guard let self else { return }
            self.gridSelectionPending = false
            self.browser?.columnSelectionDidChange(self)
        }
    }

    func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool {
        true
    }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> (any NSPasteboardWriting)? {
        items[indexPath.item].url as NSURL
    }

    func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forItemsAt indexPaths: Set<IndexPath>) {
        Self.draggedFrom = self
    }

    func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, dragOperation operation: NSDragOperation) {
        Task { Self.draggedFrom = nil }
    }

    func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: any NSDraggingInfo, proposedIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>, dropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        let target = dropTarget(draggingInfo)
        let operation = browser?.host?.dropOperation(draggingInfo, into: target.folder) ?? []
        if !operation.isEmpty, target.row >= 0 {
            proposedIndexPath.pointee = IndexPath(item: target.row, section: 0) as NSIndexPath
            dropOperation.pointee = .on
        }
        return operation
    }

    func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: any NSDraggingInfo, indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
        browser?.host?.acceptDrop(draggingInfo, into: dropTarget(draggingInfo).folder) ?? false
    }

    // MARK: Drop

    /// The row under a drag, in either form of the column.
    private func row(under info: any NSDraggingInfo) -> Int {
        if let grid {
            return grid.indexPathForItem(at: grid.convert(info.draggingLocation, from: nil))?.item ?? -1
        }
        return tableView.row(at: tableView.convert(info.draggingLocation, from: nil))
    }

    /// Resting on a folder selects it, which opens it in the next column, so a drop can reach any depth.
    /// A folder the drag can't go into won't open, but the one its items are already in does, for its subfolders.
    func updateSpringLoad(_ info: any NSDraggingInfo) {
        let row = row(under: info)
        guard row >= 0, row < items.count, items[row].isFolder, selectedRows != IndexSet(integer: row) else {
            springLoad.cancel()
            return
        }
        let url = items[row].url
        guard !springLoad.isHovering(over: url) else { return }
        guard (try? FileTransfer.validate(sources: info.draggingPasteboard.fileURLs, destination: url, kind: .copy)) != nil else {
            springLoad.cancel()
            return
        }
        springLoad.hover(over: url) { [weak self] in self?.select(url: url) }
    }

    func cancelSpringLoad() {
        springLoad.cancel()
    }

    /// A folder row takes the drop. Anywhere else in the column means this column's folder.
    private func dropTarget(_ info: any NSDraggingInfo) -> (row: Int, folder: URL) {
        let row = row(under: info)
        if row >= 0, row < items.count, items[row].isFolder {
            return (row, items[row].url)
        }
        return (-1, folderURL)
    }

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        let target = dropTarget(info)
        let operation = browser?.host?.dropOperation(info, into: target.folder) ?? []
        if !operation.isEmpty {
            tableView.setDropRow(target.row, dropOperation: .on)
        }
        return operation
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        browser?.host?.acceptDrop(info, into: dropTarget(info).folder) ?? false
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        browser?.host?.dropOperation(sender, into: folderURL) ?? []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        browser?.host?.dropOperation(sender, into: folderURL) ?? []
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        browser?.host?.acceptDrop(sender, into: folderURL) ?? false
    }

    // MARK: Actions

    @objc private func handleDoubleClick() {
        openItem(at: tableView.clickedRow)
    }

    func openItem(at row: Int) {
        guard row >= 0, row < items.count, !items[row].isFolder else { return }
        NSWorkspace.shared.open(items[row].url)
    }

    func moveFocusRight() { browser?.moveFocusRight(from: self) }
    func moveFocusLeft() { browser?.moveFocusLeft(from: self) }
    func moveFocusToAdjacentSection(_ delta: Int) { browser?.host?.focusAdjacentSection(from: browser, delta: delta) }

    func openSelection() {
        for item in selectedItems where !item.isFolder {
            NSWorkspace.shared.open(item.url)
        }
        if let folder = selectedItems.first(where: \.isFolder) {
            browser?.host?.openInNewTab(folder.url)
        }
    }

    func copySelectionToPasteboard() {
        let urls = selectedItems.map { $0.url as NSURL }
        guard !urls.isEmpty else { return }
        NSPasteboard.files.clearContents()
        NSPasteboard.files.writeObjects(urls)
    }

    /// For a click on the column's empty space.
    func backgroundMenu() -> NSMenu? {
        let menu = NSMenu()
        if !FileOperations.isOnCameraCard(folderURL) {
            if filter == .all {
                let item = NSMenuItem(title: "New Folder", action: #selector(contextNewFolder), keyEquivalent: "")
                item.target = self
                menu.addItem(item)
            }
            addPasteItems(to: menu, into: folderURL)
            if !menu.items.isEmpty { menu.addItem(.separator()) }
        }
        browser?.addViewOptionItems(to: menu)
        return menu
    }

    private func addPasteItems(to menu: NSMenu, into folder: URL) {
        guard let host = browser?.host, host.canPasteFiles else { return }
        menu.addItem(.closure("Paste") { [weak host] in host?.transferPastedFiles(.copy, into: folder) })
        menu.addItem(.closure("Move Here") { [weak host] in host?.transferPastedFiles(.move, into: folder) })
    }

    func contextMenu() -> NSMenu {
        let menu = NSMenu()
        let selection = selectedItems
        let folders = selection.filter(\.isFolder)

        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }

        if selection.contains(where: { !$0.isFolder }) {
            add("Open", #selector(contextOpen))
        }
        if !folders.isEmpty {
            add("Open in New Tab", #selector(contextOpenInNewTab))
        }
        menu.addItem(.separator())
        add("Reveal in Finder", #selector(contextReveal))
        add("Copy", #selector(contextCopy))
        add("Copy Path", #selector(contextCopyPath))
        if !FileOperations.isOnCameraCard(folderURL) {
            menu.addItem(.separator())
            if filter == .all {
                add("New Folder", #selector(contextNewFolder))
            }
            if selection.count == 1 {
                add("Rename", #selector(contextRename))
            }
            if selection.contains(where: SubtitleConverter.canConvert) {
                add("Create Traditional Chinese Version", #selector(contextCreateTraditional))
            }
            add("Move to Trash", #selector(contextTrash))
            if let target = browser?.pasteFolder {
                addPasteItems(to: menu, into: target)
            }
            if !selection.isEmpty {
                menu.addItem(.separator())
                browser?.host?.addTagItems(to: menu, for: selection.map(\.url))
            }
        }
        if folders.count == 1, let host = browser?.host {
            menu.addItem(.separator())
            add(host.isFavorite(folders[0].url) ? "Remove from Favorites" : "Add to Favorites", #selector(contextToggleFavorite))
        }
        return menu
    }

    @objc private func contextOpen() {
        for item in selectedItems where !item.isFolder {
            NSWorkspace.shared.open(item.url)
        }
    }

    @objc private func contextOpenInNewTab() {
        for folder in selectedItems where folder.isFolder {
            browser?.host?.openInNewTab(folder.url)
        }
    }

    @objc private func contextNewFolder() {
        browser?.createFolder(in: self)
    }

    @objc private func contextRename() {
        browser?.renameSelection()
    }

    @objc private func contextCreateTraditional() {
        guard let host = browser?.host else { return }
        let subtitles = selectedItems.filter(SubtitleConverter.canConvert).map(\.url)
        Task {
            let created = await host.createTraditionalVersions(of: subtitles)
            await load { if created.count == 1 { self.select(url: created[0]) } }
        }
    }

    @objc private func contextTrash() {
        browser?.trashSelection()
    }

    @objc private func contextReveal() {
        NSWorkspace.shared.activateFileViewerSelecting(selectedItems.map(\.url))
    }

    @objc private func contextCopy() {
        copySelectionToPasteboard()
    }

    @objc private func contextCopyPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selectedItems.map(\.url.path).joined(separator: "\n"), forType: .string)
    }

    @objc private func contextToggleFavorite() {
        guard let folder = selectedItems.first(where: \.isFolder) else { return }
        browser?.host?.toggleFavorite(folder.url)
    }
}
