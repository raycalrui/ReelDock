import AppKit

/// A table that reports focus and handles Finder's column-view keys.
final class BrowserTableView: NSTableView {
    weak var column: BrowserColumnView?

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

    @objc func copy(_ sender: Any?) {
        column?.copySelectionToPasteboard()
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

final class BrowserColumnView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    enum Filter {
        case all
        case filesOnly
    }

    let folderURL: URL
    let canonicalPath: String
    let filter: Filter
    weak var browser: ColumnBrowserView? {
        didSet { scrollView.browser = browser }
    }
    var preferredWidth: CGFloat = 280

    private(set) var items: [FolderItem] = []
    private var hasLoaded = false
    private var loadGeneration = 0
    private var afterLoad: [() -> Void] = []
    private(set) var isApplyingSelection = false

    let tableView = BrowserTableView()
    private let scrollView = ColumnScrollView()
    private var renamingURL: URL?
    private var needsReloadAfterRename = false
    private let handle = ColumnResizeHandle()
    private let statusLabel = NSTextField(labelWithString: "")

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
        // Dragging out is limited to copy and link until file operations exist.
        tableView.setDraggingSourceOperationMask([.copy, .link], forLocal: false)
        tableView.setDraggingSourceOperationMask([.copy, .link], forLocal: true)

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
        let result = await Task.detached(priority: .userInitiated) { () -> Result<[FolderItem], any Error> in
            Result {
                let items = try FolderReader.read(url, showHidden: showHidden)
                return filesOnly ? items.filter { !$0.isFolder } : items
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
        isApplyingSelection = true
        tableView.reloadData()
        let rows = IndexSet(items.indices.filter { selectedIDs.contains(items[$0].id) })
        tableView.selectRowIndexes(rows, byExtendingSelection: false)
        isApplyingSelection = false
        browser?.columnDidReload(self, selectionChanged: !selectionWasEmpty)
    }

    // MARK: Selection

    var selectedItems: [FolderItem] {
        tableView.selectedRowIndexes.compactMap { $0 < items.count ? items[$0] : nil }
    }

    func selectSilently(path: String) -> FolderItem? {
        guard let row = items.firstIndex(where: { $0.url.path == path }) else { return nil }
        isApplyingSelection = true
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
        isApplyingSelection = false
        return items[row]
    }

    func clearSelectionSilently() {
        isApplyingSelection = true
        tableView.deselectAll(nil)
        isApplyingSelection = false
    }

    func select(url: URL) {
        guard let row = items.firstIndex(where: { $0.url.path == url.path }) else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    /// Keeps culling moving after a delete. A folder isn't selected, since that would open it.
    func selectFileAfterRemoval(near row: Int) {
        guard !items.isEmpty, tableView.selectedRowIndexes.isEmpty else { return }
        let next = min(row, items.count - 1)
        window?.makeFirstResponder(tableView)
        guard !items[next].isFolder else { return }
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    // MARK: Rename

    /// Edits the row's name in place. The extension stays out of the initial selection, as in Finder.
    func beginRename(of url: URL) {
        guard renamingURL == nil, let row = items.firstIndex(where: { $0.url.path == url.path }) else { return }
        _ = selectSilently(path: url.path)
        tableView.scrollRowToVisible(row)
        tableView.layoutSubtreeIfNeeded()
        guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? FileRowView else { return }
        renamingURL = url
        cell.beginEditingName(delegate: self, isFolder: items[row].isFolder)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let url = renamingURL, let field = notification.object as? NSTextField else { return }
        finishRename(url: url, field: field, newName: field.stringValue)
        let movement = notification.userInfo?["NSTextMovement"] as? Int
        if movement == NSTextMovement.return.rawValue {
            window?.makeFirstResponder(tableView)
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)), let url = renamingURL, let field = control as? NSTextField else { return false }
        field.abortEditing()
        finishRename(url: url, field: field, newName: nil)
        window?.makeFirstResponder(tableView)
        return true
    }

    private func finishRename(url: URL, field: NSTextField, newName: String?) {
        renamingURL = nil
        (field.superview?.superview as? FileRowView)?.endEditingName()
        var result = url
        if let newName, newName != url.lastPathComponent {
            result = browser?.host?.renameItem(at: url, to: newName) ?? url
        }
        if needsReloadAfterRename || result != url {
            needsReloadAfterRename = false
            browser?.renameDidFinish(in: self, newURL: result)
        } else if let row = items.firstIndex(where: { $0.url.path == url.path }) {
            // Selecting for real opens a new folder's column, which editing its name held back.
            isApplyingSelection = false
            tableView.selectRowIndexes(IndexSet(), byExtendingSelection: false)
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
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

    // MARK: Actions

    @objc private func handleDoubleClick() {
        let row = tableView.clickedRow
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
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(urls)
    }

    /// For a click on the column's empty space.
    func backgroundMenu() -> NSMenu? {
        guard filter == .all, !FileOperations.isOnCameraCard(folderURL) else { return nil }
        let menu = NSMenu()
        let item = NSMenuItem(title: "New Folder", action: #selector(contextNewFolder), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
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
        add("Copy Path", #selector(contextCopyPath))
        if !FileOperations.isOnCameraCard(folderURL) {
            menu.addItem(.separator())
            if filter == .all {
                add("New Folder", #selector(contextNewFolder))
            }
            if selection.count == 1 {
                add("Rename", #selector(contextRename))
            }
            add("Move to Trash", #selector(contextTrash))
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

    @objc private func contextTrash() {
        browser?.trashSelection()
    }

    @objc private func contextReveal() {
        NSWorkspace.shared.activateFileViewerSelecting(selectedItems.map(\.url))
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
