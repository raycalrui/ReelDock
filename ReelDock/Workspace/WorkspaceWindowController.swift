import AppKit
import AudioToolbox
import SwiftUI

private extension NSToolbarItem.Identifier {
    static let mode = NSToolbarItem.Identifier("mode")
    static let favorite = NSToolbarItem.Identifier("favorite")
    static let reveal = NSToolbarItem.Identifier("reveal")
    static let importCard = NSToolbarItem.Identifier("importCard")
    static let importActivity = NSToolbarItem.Identifier("importActivity")
}

/// One native window tab, holding one folder.
final class WorkspaceWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSMenuItemValidation {
    private unowned let app: AppModel
    let tab = TabModel()
    let content: TabContentViewController

    private let splitController = WorkspaceSplitViewController()
    private let modeControl = NSSegmentedControl()
    private let titleLabel = WindowTitleLabel(labelWithString: "ReelDock")
    private let copyNameButton = NSButton()
    private let titleBar = NSStackView()
    private var copyNameReset: Task<Void, Never>?
    private weak var favoriteItem: NSToolbarItem?
    private weak var importItem: NSToolbarItem?
    private var contentItem: NSSplitViewItem?
    private var inspectorItem: NSSplitViewItem?
    private var inspectorObservation: NSKeyValueObservation?
    private var lastDropCheck: (sequence: Int, folder: URL, mask: NSDragOperation, operation: NSDragOperation)?
    private var keyMonitor: Any?
    private var fullScreenPreview: FullScreenPreview?
    private static let defaultContentMinimumWidth: CGFloat = 420
    private static let defaultInspectorWidth: CGFloat = 440
    private static let titleInset: CGFloat = 20
    private static let sidebarButtonWidth: CGFloat = 60
    #if DEBUG
    var debugInspectorItem: NSSplitViewItem? { inspectorItem }
    var debugSidebarItem: NSSplitViewItem? { splitController.splitViewItems.first }
    var debugImportItem: NSToolbarItem? { importItem }
    var debugCopyNameButton: NSButton { copyNameButton }
    var debugTitleBar: NSView { titleBar }
    var debugSidebarView: NSView? { splitController.splitViewItems.first?.viewController.view }
    func debugChooseScreen() {
        if let screen = NSScreen.screens.last { fullScreenPreview?.choose(screen) }
    }
    #endif

    init(app: AppModel) {
        self.app = app
        content = TabContentViewController(app: app, tab: tab)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1320, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.tabbingMode = .automatic
        window.tabbingIdentifier = "cc.raycal.ReelDock.workspace"
        // Room for all three panes.
        window.minSize = NSSize(width: 920, height: 480)
        window.isRestorable = false
        window.toolbarStyle = .unified
        window.titleVisibility = .hidden
        window.title = "ReelDock"
        super.init(window: window)

        window.delegate = self
        content.windowController = self
        buildSplit()
        buildToolbar()
        window.contentViewController = splitController
        buildTitleBar()
        window.setContentSize(NSSize(width: 1320, height: 860))
        if !window.setFrameUsingName("ReelDockWorkspace") { window.center() }
        window.setFrameAutosaveName("ReelDockWorkspace")
        installKeyMonitor()
        // The split view's saved state could otherwise bring back a hidden inspector.
        inspectorItem?.isCollapsed = false

        content.display()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildSplit() {
        let sidebarHost = NSHostingController(rootView: SidebarView(app: app, tab: tab, controller: self))
        sidebarHost.sizingOptions = []
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarHost)
        // Wide enough for a project's date and size side by side beside its thumbnail.
        sidebarItem.minimumThickness = 220
        sidebarItem.maximumThickness = 340

        let contentItem = NSSplitViewItem(contentListWithViewController: content)
        contentItem.minimumThickness = Self.defaultContentMinimumWidth
        self.contentItem = contentItem

        let inspectorHost = NSHostingController(rootView: InspectorView(app: app, tab: tab, controller: self))
        inspectorHost.sizingOptions = []
        inspectorHost.view.setFrameSize(NSSize(width: Self.defaultInspectorWidth, height: 800))
        let inspectorItem = NSSplitViewItem(inspectorWithViewController: inspectorHost)
        inspectorItem.minimumThickness = 280
        inspectorItem.maximumThickness = 760
        self.inspectorItem = inspectorItem
        // Nobody listens to a hidden player.
        inspectorObservation = inspectorItem.observe(\.isCollapsed) { [weak self] item, _ in
            let collapsed = item.isCollapsed
            Task { @MainActor in
                if collapsed { self?.tab.playback.pause() }
            }
        }

        splitController.splitViewItems = [sidebarItem, contentItem, inspectorItem]
        // Renamed with the wider inspector, so a width saved under the old limits doesn't carry over.
        splitController.splitView.autosaveName = "ReelDockWorkspaceSplit"
    }

    private func buildToolbar() {
        let toolbar = NSToolbar(identifier: "ReelDockWorkspaceToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window?.toolbar = toolbar
    }

    /// The system's title takes all the free width and pushes items past it to the far side, and a toolbar item
    /// always gets a glass capsule. So the title and its button are drawn on the title bar itself.
    /// Window tabs still use the window's title.
    private func buildTitleBar() {
        titleLabel.font = .boldSystemFont(ofSize: 15)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        copyNameButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy Name")
        copyNameButton.imageScaling = .scaleProportionallyDown
        copyNameButton.isBordered = false
        copyNameButton.contentTintColor = .secondaryLabelColor
        copyNameButton.toolTip = "Copy name"
        copyNameButton.target = self
        copyNameButton.action = #selector(copyFolderName(_:))
        copyNameButton.isHidden = true
        // The check is narrower than the copy icon, and the title shouldn't shift between them.
        copyNameButton.widthAnchor.constraint(equalToConstant: 18).isActive = true
        copyNameButton.heightAnchor.constraint(equalToConstant: 18).isActive = true
        titleBar.orientation = .horizontal
        titleBar.spacing = 6
        titleBar.addArrangedSubview(titleLabel)
        titleBar.addArrangedSubview(copyNameButton)
        titleBar.translatesAutoresizingMaskIntoConstraints = true
        window?.standardWindowButton(.closeButton)?.superview?.addSubview(titleBar)
        splitController.onResize = { [weak self] in self?.layoutTitleBar() }
    }

    /// Set by hand and not with constraints, because the title bar moves to a window of its own in full screen.
    private func layoutTitleBar() {
        guard let bar = titleBar.superview, let window, let close = window.standardWindowButton(.closeButton),
              let zoom = window.standardWindowButton(.zoomButton), let pane = contentItem?.viewController.view else { return }
        // Clears the traffic lights and the sidebar button when the sidebar is hidden.
        let minX = max(zoom.frame.maxX + Self.sidebarButtonWidth, pane.convert(pane.bounds, to: nil).minX + Self.titleInset)
        // The mode control is the first of the items at the far side, unless the toolbar moved it to its overflow.
        let limit = modeControl.window == nil ? bar.bounds.maxX : bar.convert(modeControl.bounds, from: modeControl).minX
        let fitting = titleBar.fittingSize
        let frame = NSRect(x: minX, y: close.frame.midY - fitting.height / 2, width: max(0, min(fitting.width, limit - Self.titleInset - minX)), height: fitting.height)
        if titleBar.frame != frame { titleBar.frame = frame }
    }

    // MARK: Inspector

    /// It stays open whatever is selected. Only the toolbar button hides it, and asking to play or edit brings it back.
    private func showInspector() {
        guard let inspectorItem, inspectorItem.isCollapsed else { return }
        inspectorItem.animator().isCollapsed = false
    }

    // MARK: Showing folders

    func show(folder: URL, mode: BrowserMode, restoring snapshot: TabSnapshot? = nil) {
        tab.folder = folder
        tab.mode = mode
        window?.title = folder.lastPathComponent
        window?.representedURL = folder
        titleLabel.stringValue = folder.lastPathComponent
        titleLabel.toolTip = folder.lastPathComponent
        copyNameButton.isHidden = false
        layoutTitleBar()
        modeControl.selectedSegment = mode == .sections ? 0 : 1
        refreshFavoriteItem()
        refreshTabTags()
        content.display(restoring: snapshot)
        app.scheduleSessionSave()
    }

    func folderDidDisappear() {
        tab.folder = nil
        window?.title = "ReelDock"
        window?.representedURL = nil
        titleLabel.stringValue = "ReelDock"
        titleLabel.toolTip = nil
        copyNameButton.isHidden = true
        layoutTitleBar()
        refreshFavoriteItem()
        refreshTabTags()
        content.display()
        app.scheduleSessionSave()
    }

    func refreshFavoriteItem() {
        let isFavorite = tab.folder.map(app.isFavorite) ?? false
        favoriteItem?.image = NSImage(
            systemSymbolName: isFavorite ? "star.fill" : "star",
            accessibilityDescription: isFavorite ? "Remove from Favorites" : "Add to Favorites"
        )
        favoriteItem?.isEnabled = tab.folder != nil
    }

    // MARK: Actions

    @IBAction override func newWindowForTab(_ sender: Any?) {
        app.addTab(after: self)
    }

    @objc func openFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Open"
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            for url in panel.urls {
                self?.app.open(url, from: self, newTab: self?.tab.folder != nil)
            }
        }
    }

    @objc func newProject(_ sender: Any?) {
        promptNewProject()
    }

    @objc func showSections(_ sender: Any?) { setMode(.sections) }
    @objc func showSingleBrowser(_ sender: Any?) { setMode(.single) }

    @objc private func modeControlChanged(_ sender: NSSegmentedControl) {
        setMode(sender.selectedSegment == 0 ? .sections : .single)
    }

    private func setMode(_ mode: BrowserMode) {
        guard let folder = tab.folder, tab.mode != mode else {
            modeControl.selectedSegment = tab.mode == .sections ? 0 : 1
            return
        }
        show(folder: folder, mode: mode)
    }

    @objc func toggleFavorite(_ sender: Any?) {
        guard let folder = tab.folder else { return }
        app.toggleFavorite(folder)
        refreshFavoriteItem()
    }

    /// Copies the name shown as the window's title. The button shows a check briefly, since nothing else changes.
    @objc func copyFolderName(_ sender: Any?) {
        guard let name = tab.folder?.lastPathComponent else { return }
        NSPasteboard.files.clearContents()
        NSPasteboard.files.setString(name, forType: .string)
        copyNameButton.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Copied")
        copyNameReset?.cancel()
        copyNameReset = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            self?.copyNameButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy Name")
        }
    }

    @objc func revealInFinder(_ sender: Any?) {
        let selected = tab.selection.map(\.url)
        if !selected.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(selected)
        } else if let folder = tab.folder {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path)
        }
    }

    @objc func toggleHiddenFiles(_ sender: Any?) {
        app.toggleShowHidden()
    }

    @objc func showImport(_ sender: Any?) {
        toggleImportPanel(cardID: nil)
    }

    /// Asking for a different card switches to it instead of closing.
    func toggleImportPanel(cardID: String?) {
        if tab.isImportPanelVisible, cardID == nil || cardID == tab.importCardID {
            hideImportPanel()
        } else {
            showImportPanel(cardID: cardID)
        }
    }

    /// Grows the window if needed, so the browser and the card panel both fit side by side.
    func setContentMinimumWidth(_ width: CGFloat?) {
        contentItem?.minimumThickness = width ?? Self.defaultContentMinimumWidth
    }

    func refreshImportItem() {
        let isOpen = tab.isImportPanelVisible
        importItem?.image = NSImage(
            systemSymbolName: isOpen ? "sdcard.fill" : "sdcard",
            accessibilityDescription: isOpen ? "Close Card Panel" : "Import from Card"
        )
        importItem?.style = isOpen ? .prominent : .plain
        let hasCard = !app.cards.cards.isEmpty
        importItem?.isEnabled = isOpen || hasCard
        importItem?.toolTip = isOpen ? "Close the card panel" : (hasCard ? "Import from a camera card" : "Insert a camera card to import")
    }

    func showImportPanel(cardID: String?) {
        content.showImportPanel(cardID: cardID)
    }

    func cardsDidChange() {
        content.cardsDidChange()
        refreshImportItem()
    }

    func hideImportPanel() {
        content.hideImportPanel()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(rotateLeft(_:)):
            return selectedVideo != nil || (tab.selection.count == 1 && Self.canEdit(tab.selection[0]) && tab.imageEdit?.canEdit != false)
        case #selector(cropImage(_:)):
            return tab.selection.count == 1 && Self.canEdit(tab.selection[0]) && tab.imageEdit?.canEdit != false
        case #selector(saveEdit(_:)), #selector(saveEditCopy(_:)):
            if let selectedVideo {
                return tab.videoExport == nil && tab.trimMarks[selectedVideo.id]?.isEmpty == false
            }
            return tab.imageEdit?.isEdited == true && tab.imageEdit?.canEdit == true
        case #selector(markIn(_:)), #selector(markOut(_:)):
            return selectedVideo != nil
        case #selector(clearMarks(_:)):
            return selectedVideo.map { tab.trimMarks[$0.id]?.isEmpty == false } ?? false
        case #selector(showSections(_:)):
            menuItem.state = tab.mode == .sections ? .on : .off
            return tab.folder != nil
        case #selector(showSingleBrowser(_:)):
            menuItem.state = tab.mode == .single ? .on : .off
            return tab.folder != nil
        case #selector(toggleHiddenFiles(_:)):
            menuItem.state = app.settings.showHidden ? .on : .off
            return true
        case #selector(toggleFavorite(_:)):
            let isFavorite = tab.folder.map(app.isFavorite) ?? false
            menuItem.title = isFavorite ? "Remove Folder from Favorites" : "Add Folder to Favorites"
            return tab.folder != nil
        case #selector(revealInFinder(_:)):
            return tab.folder != nil
        case #selector(newProject(_:)):
            return app.canCreateProject
        case #selector(copy(_:)):
            return content.fileOperationBrowser?.canCopySelection ?? false
        case #selector(paste(_:)), #selector(moveItemsHere(_:)):
            return content.fileOperationBrowser?.pasteFolder != nil && !NSPasteboard.files.fileURLs.isEmpty
        case #selector(newFolder(_:)):
            return content.fileOperationBrowser?.canCreateFolder ?? false
        case #selector(renameSelection(_:)):
            return content.fileOperationBrowser?.canRenameSelection ?? false
        case #selector(moveSelectionToTrash(_:)):
            return content.fileOperationBrowser?.canTrashSelection ?? false
        case #selector(showImport(_:)):
            menuItem.state = tab.isImportPanelVisible ? .on : .off
            return tab.isImportPanelVisible || !app.cards.cards.isEmpty
        default:
            return true
        }
    }

    // MARK: File operations

    @objc func newFolder(_ sender: Any?) {
        content.fileOperationBrowser?.createFolder()
    }

    @objc func renameSelection(_ sender: Any?) {
        content.fileOperationBrowser?.renameSelection()
    }

    @objc func moveSelectionToTrash(_ sender: Any?) {
        content.fileOperationBrowser?.trashSelection()
    }

    @objc func copy(_ sender: Any?) {
        content.fileOperationBrowser?.copySelection()
    }

    @objc func paste(_ sender: Any?) {
        guard let folder = content.fileOperationBrowser?.pasteFolder else { return }
        transferPastedFiles(.copy, into: folder)
    }

    @objc func moveItemsHere(_ sender: Any?) {
        guard let folder = content.fileOperationBrowser?.pasteFolder else { return }
        transferPastedFiles(.move, into: folder)
    }

    func transferPastedFiles(_ kind: FileTransfer.Kind, into folder: URL) {
        let sources = NSPasteboard.files.fileURLs
        guard !sources.isEmpty else { return }
        // Pasting a folder that's still selected makes a copy beside it, not inside it.
        let destination = sources.contains { $0.path == folder.path } ? folder.deletingLastPathComponent() : folder
        transfer(kind, sources: sources, into: destination)
    }

    private func dropKind(_ info: any NSDraggingInfo, into folder: URL) -> FileTransfer.Kind? {
        let mask = info.draggingSourceOperationMask
        return FileTransfer.dropKind(
            sources: info.draggingPasteboard.fileURLs,
            destination: folder,
            canCopy: mask.contains(.copy),
            canMove: mask.contains(.move),
            forcesMove: mask == .generic
        )
    }

    /// Asked continually during a drag, and the checks touch the disk for every dragged file, so the answer is kept until something changes.
    func dropOperation(_ info: any NSDraggingInfo, into folder: URL) -> NSDragOperation {
        let mask = info.draggingSourceOperationMask
        if let last = lastDropCheck, last.sequence == info.draggingSequenceNumber, last.folder == folder, last.mask == mask {
            return last.operation
        }
        let operation: NSDragOperation = switch dropKind(info, into: folder) {
        case .copy: .copy
        case .move: mask.contains(.move) ? .move : .generic
        case nil: []
        }
        lastDropCheck = (info.draggingSequenceNumber, folder, mask, operation)
        return operation
    }

    func acceptDrop(_ info: any NSDraggingInfo, into folder: URL) -> Bool {
        lastDropCheck = nil
        guard let kind = dropKind(info, into: folder) else { return false }
        transfer(kind, sources: info.draggingPasteboard.fileURLs, into: folder)
        return true
    }

    private func transfer(_ kind: FileTransfer.Kind, sources: [URL], into destination: URL) {
        let title = kind == .copy ? "Can't copy" : "Can't move"
        do {
            try FileTransfer.validate(sources: sources, destination: destination, kind: kind)
            let changing = FileTransfer.itemsThatWouldChange(sources, destination: destination, kind: kind)
            guard !changing.isEmpty else { return }
            if kind == .move {
                guard !changing.contains(where: app.isBusy) else { throw FileOperationError.importing }
                changing.forEach(app.releasePlayback)
            }
            app.transfers.enqueue(kind, sources: changing, destination: destination) { [weak self] kind, items, failure in
                self?.finishTransfer(kind, items: items, failure: failure, title: title)
            }
        } catch {
            showFileError(title, error)
        }
    }

    private func finishTransfer(_ kind: FileTransfer.Kind, items: [FileTransfer.Item], failure: String?, title: String) {
        if !items.isEmpty {
            switch kind {
            case .copy:
                let copies = items.map(\.result)
                window?.undoManager?.registerUndo(withTarget: self) { target in
                    target.moveToTrashNow(copies)
                }
                window?.undoManager?.setActionName("Copy")
            case .move:
                registerUndoOfMove(items)
                items.forEach { app.folderDidMove(from: $0.source, to: $0.result) }
            }
            content.reloadFolderContents()
            app.cards.refreshPresence()
        }
        if let failure { showFileError(title, message: failure) }
    }

    private func registerUndoOfMove(_ items: [FileTransfer.Item]) {
        window?.undoManager?.registerUndo(withTarget: self) { target in
            target.undoMove(items)
        }
        window?.undoManager?.setActionName("Move")
    }

    /// A move within a volume can be redone. One across volumes puts the original back and sends the copy to the Trash, which ends it.
    private func undoMove(_ items: [FileTransfer.Item]) {
        var redo: [FileTransfer.Item] = []
        for item in items {
            do {
                guard !app.isBusy(item.result) else { throw FileOperationError.importing }
                app.releasePlayback(under: item.result)
                if let trashed = item.trashedOriginal {
                    try FileOperations.restore(FileOperations.TrashedItem(original: item.source, trashed: trashed))
                    if let error = FileOperations.moveToTrash([item.result]).error { throw error }
                } else {
                    guard !FileManager.default.fileExists(atPath: item.source.path) else {
                        throw FileOperationError.nameTaken(item.source.lastPathComponent)
                    }
                    // moveItem refuses to replace an existing item.
                    try FileManager.default.moveItem(at: item.result, to: item.source)
                    redo.append(FileTransfer.Item(source: item.result, result: item.source))
                }
                app.folderDidMove(from: item.result, to: item.source)
            } catch {
                showFileError("Can't undo the move of “\(item.result.lastPathComponent)”", error)
                break
            }
        }
        if !redo.isEmpty { registerUndoOfMove(redo) }
        content.reloadFolderContents()
    }

    func createFolder(in folder: URL) -> URL? {
        do {
            let url = try FileOperations.createFolder(in: folder)
            window?.undoManager?.registerUndo(withTarget: self) { target in
                target.moveToTrashNow([url])
            }
            window?.undoManager?.setActionName("New Folder")
            return url
        } catch {
            showFileError("Can't create the folder", error)
            return nil
        }
    }

    func renameItem(at url: URL, to name: String) -> URL? {
        do {
            guard !app.isBusy(url) else { throw FileOperationError.importing }
            let renamed = try FileOperations.rename(url, to: name)
            let oldName = url.lastPathComponent
            window?.undoManager?.registerUndo(withTarget: self) { target in
                _ = target.renameItem(at: renamed, to: oldName)
            }
            window?.undoManager?.setActionName("Rename")
            return renamed
        } catch {
            showFileError("Can't rename “\(url.lastPathComponent)”", error)
            return nil
        }
    }

    func promptRenameProject(at url: URL) {
        guard let window else { return }
        let folderName = url.lastPathComponent
        let alert = NSAlert()
        alert.messageText = "Rename Project"
        let form = ProjectForm(date: ProjectCatalog.entry(for: url).displayDate ?? "", name: ProjectCatalog.name(of: folderName))
        alert.accessoryView = form.view
        alert.window.initialFirstResponder = form.name
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let name = form.name.stringValue.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return }
            guard let newName = ProjectCatalog.folderName(date: form.date.stringValue, name: name) else {
                self?.showFileError("Can't rename “\(folderName)”", FileOperationError.invalidDate)
                return
            }
            self?.renameProject(at: url, toFolderName: newName)
        }
    }

    private func renameProject(at url: URL, toFolderName name: String) {
        do {
            let renamed = try app.renameProject(at: url, toFolderName: name)
            guard renamed != url else { return }
            let oldName = url.lastPathComponent
            window?.undoManager?.registerUndo(withTarget: self) { target in
                target.renameProject(at: renamed, toFolderName: oldName)
            }
            window?.undoManager?.setActionName("Rename")
        } catch {
            showFileError("Can't rename “\(url.lastPathComponent)”", error)
        }
    }

    func promptNewProject() {
        guard let window, let root = app.projectRootURL else { return }
        let template = root.appendingPathComponent(ProjectCatalog.templateName, isDirectory: true)
        let alert = NSAlert()
        alert.messageText = "New Project"
        if !FileManager.default.fileExists(atPath: template.path) {
            alert.informativeText = "The projects folder has no “\(ProjectCatalog.templateName)” folder, so this project starts empty."
        }
        let form = ProjectForm(date: ProjectCatalog.dateString(.now), name: "")
        alert.accessoryView = form.view
        alert.window.initialFirstResponder = form.name
        let create = alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        // An alert closes on any button, and this one stays open until the project exists.
        let submit = MenuClosure { [weak self, weak alert, weak create] in
            guard let alert, let create else { return }
            self?.createProject(form: form, root: root, template: template, alert: alert, button: create)
        }
        create.target = submit
        create.action = #selector(MenuClosure.run)
        alert.beginSheetModal(for: window) { _ in
            withExtendedLifetime(submit) {}
        }
    }

    private func createProject(form: ProjectForm, root: URL, template: URL, alert: NSAlert, button: NSButton) {
        let title = "Can't create the project"
        let name = form.name.stringValue.trimmingCharacters(in: .whitespaces)
        guard FileOperations.isValidName(name) else {
            showFileError(title, message: FileOperationError.invalidName.localizedDescription, over: alert.window)
            return
        }
        guard let folderName = ProjectCatalog.folderName(date: form.date.stringValue, name: name) else {
            showFileError(title, message: FileOperationError.invalidDate.localizedDescription, over: alert.window)
            return
        }
        button.isEnabled = false
        Task {
            // Off the main thread, because the template can be large or on a slow drive.
            let result = await Task.detached(priority: .userInitiated) {
                Result { try FileOperations.createProject(named: folderName, in: root, from: template) }
            }.value
            button.isEnabled = true
            switch result {
            case let .success(url):
                window?.endSheet(alert.window, returnCode: .alertFirstButtonReturn)
                app.openNewProject(url, from: self)
            case let .failure(error):
                showFileError(title, message: error.localizedDescription, over: alert.window)
            }
        }
    }

    func promptTrashProject(at url: URL) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Move “\(url.lastPathComponent)” to the Trash?"
        alert.informativeText = "Everything in the project goes with it. You can put it back with Undo or from the Trash."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.trashProject(at: url)
        }
    }

    private func trashProject(at url: URL) {
        guard !app.isBusy(url) else {
            showFileError("Can't move to Trash", FileOperationError.importing)
            return
        }
        let favorites = app.willTrashProject(at: url)
        Task {
            // Off the main thread, because a slow drive can take a while to respond.
            let (moved, failure) = await Task.detached(priority: .userInitiated) {
                let result = FileOperations.moveToTrash([url])
                return (result.moved, result.error.map { $0.localizedDescription })
            }.value
            app.reloadProjects()
            if moved.isEmpty { app.restoreFavorites(favorites) }
            if !moved.isEmpty {
                TrashSound.play()
                window?.undoManager?.registerUndo(withTarget: self) { target in
                    target.restoreFromTrash(moved)
                    target.app.restoreFavorites(favorites)
                    target.app.reloadProjects()
                    // The tab that was showing it went blank, so it picks up where it was.
                    if target.tab.folder == nil, FileManager.default.fileExists(atPath: url.path) {
                        target.app.open(url, from: target)
                    }
                }
                window?.undoManager?.setActionName("Move to Trash")
            }
            if let failure { showFileError("Can't move to Trash", message: failure) }
        }
    }

    /// Follows a project that was renamed, keeping the same folders open.
    func folderDidMove(from old: String, to new: String) {
        guard let snapshot = content.snapshot()?.relocated(from: old, to: new) else { return }
        show(folder: URL(fileURLWithPath: snapshot.folderPath, isDirectory: true), mode: tab.mode, restoring: snapshot)
    }

    /// Runs off the main thread, because a slow drive can take a while to respond.
    func moveToTrash(_ urls: [URL]) async {
        guard !urls.contains(where: app.isBusy) else {
            showFileError("Can't move to Trash", FileOperationError.importing)
            return
        }
        urls.forEach(app.releasePlayback)
        let (moved, failure) = await Task.detached(priority: .userInitiated) {
            let result = FileOperations.moveToTrash(urls)
            return (result.moved, result.error.map { $0.localizedDescription })
        }.value
        finishTrash(moved: moved, failure: failure)
    }

    /// Undo and redo must register their opposite before they return.
    private func moveToTrashNow(_ urls: [URL]) {
        guard !urls.contains(where: app.isBusy) else {
            showFileError("Can't move to Trash", FileOperationError.importing)
            return
        }
        urls.forEach(app.releasePlayback)
        let result = FileOperations.moveToTrash(urls)
        finishTrash(moved: result.moved, failure: result.error?.localizedDescription)
    }

    private func finishTrash(moved: [FileOperations.TrashedItem], failure: String?) {
        if !moved.isEmpty {
            TrashSound.play()
            window?.undoManager?.registerUndo(withTarget: self) { target in
                target.restoreFromTrash(moved)
            }
            window?.undoManager?.setActionName("Move to Trash")
        }
        if let failure {
            showFileError("Can't move to Trash", message: failure)
        }
    }

    private func restoreFromTrash(_ items: [FileOperations.TrashedItem]) {
        var restored: [URL] = []
        for item in items {
            do {
                try FileOperations.restore(item)
                restored.append(item.original)
            } catch {
                showFileError("Can't put back “\(item.original.lastPathComponent)”", error)
                break
            }
        }
        guard !restored.isEmpty else { return }
        window?.undoManager?.registerUndo(withTarget: self) { target in
            target.moveToTrashNow(restored)
        }
        window?.undoManager?.setActionName("Move to Trash")
    }

    private func showFileError(_ title: String, _ error: any Error) {
        showFileError(title, message: error.localizedDescription)
    }

    private func showFileError(_ title: String, message: String, over sheet: NSWindow? = nil) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        if let window = sheet ?? window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    // MARK: Tags

    func tagChoices(for urls: [URL]) -> [TagChoice] {
        app.tagChoices(forCurrentTags: urls.map(FinderTags.read))
    }

    func toggle(_ choice: TagChoice, on urls: [URL]) {
        setTag(choice.tag.name, enabled: choice.state != .all, on: urls)
    }

    func setTag(_ name: String, enabled: Bool, on urls: [URL]) {
        app.rememberTag(name)
        applyTagNames(urls.map { url in
            (url, FinderTags.names(FinderTags.read(url).map(\.name), setting: name, enabled: enabled))
        })
    }

    private func applyTagNames(_ changes: [(URL, [String])]) {
        var previous: [(URL, [String])] = []
        for (url, names) in changes {
            let before = FinderTags.read(url).map(\.name)
            do {
                try FinderTags.write(names, to: url)
                previous.append((url, before))
            } catch {
                showFileError("Can't change the tags of “\(url.lastPathComponent)”", error)
                break
            }
        }
        if !previous.isEmpty {
            window?.undoManager?.registerUndo(withTarget: self) { target in
                target.applyTagNames(previous)
            }
            window?.undoManager?.setActionName("Tags")
        }
        app.tagsDidChange()
    }

    func promptForNewTag(on urls: [URL]) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "New Tag"
        alert.informativeText = "The tag is added to Finder's tags, with no color. Finder can give it one."
        let field = NSTextField(string: "")
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard response == .alertFirstButtonReturn, FinderTags.isValidName(name) else { return }
            self?.setTag(name, enabled: true, on: urls)
        }
    }

    /// Finder's row of color dots, then the tags with their own names.
    func addTagItems(to menu: NSMenu, for urls: [URL]) {
        guard !urls.isEmpty, !urls.contains(where: FileOperations.isOnCameraCard) else { return }
        let palette = NSMenuItem()
        palette.submenu = tagPalette(for: urls)
        menu.addItem(palette)
        let more = NSMenuItem(title: "More Tags", action: nil, keyEquivalent: "")
        more.submenu = moreTagsMenu(for: urls)
        menu.addItem(more)
    }

    private func tagPalette(for urls: [URL]) -> NSMenu {
        let standard = FinderTags.standardTags(labels: NSWorkspace.shared.fileLabels)
        var selected = FinderTags.sharedColors(among: urls.map(FinderTags.read))
        let palette = NSMenu.palette(
            colors: standard.compactMap(\.color),
            titles: standard.map(\.name)
        ) { [weak self] menu in
            let now = Set(menu.selectedItems.map { standard[menu.index(of: $0)].colorIndex })
            for tag in standard where now.contains(tag.colorIndex) != selected.contains(tag.colorIndex) {
                self?.setColor(of: tag, enabled: now.contains(tag.colorIndex), on: urls)
            }
            selected = now
        }
        palette.selectionMode = .selectAny
        palette.selectedItems = zip(palette.items, standard).filter { selected.contains($1.colorIndex) }.map(\.0)
        return palette
    }

    private func moreTagsMenu(for urls: [URL]) -> NSMenu {
        let standard = Set(NSWorkspace.shared.fileLabels)
        let menu = NSMenu()
        for choice in tagChoices(for: urls) where !standard.contains(choice.tag.name) {
            let item = NSMenuItem.closure(choice.tag.name) { [weak self] in self?.toggle(choice, on: urls) }
            item.image = choice.tag.menuImage
            item.state = switch choice.state {
            case .all: .on
            case .some: .mixed
            case .none: .off
            }
            menu.addItem(item)
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        menu.addItem(NSMenuItem.closure("New Tag…") { [weak self] in self?.promptForNewTag(on: urls) })
        return menu
    }

    func setColor(of tag: FinderTag, enabled: Bool, on urls: [URL]) {
        applyTagNames(urls.map { url in
            (url, FinderTags.names(FinderTags.read(url), settingColorOf: tag, enabled: enabled))
        })
    }

    func showTagMenu(for urls: [URL]) {
        let menu = NSMenu()
        addTagItems(to: menu, for: urls)
        guard !menu.items.isEmpty else { return }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    func folderContextMenu(for url: URL) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NSMenuItem.closure("Open in New Tab") { [weak self] in
            self?.app.open(url, from: self, newTab: true)
        })
        menu.addItem(NSMenuItem.closure("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        })
        if app.isProject(url) {
            menu.addItem(NSMenuItem.closure("Rename…") { [weak self] in
                self?.promptRenameProject(at: url)
            })
            menu.addItem(NSMenuItem.closure("Move to Trash…") { [weak self] in
                self?.promptTrashProject(at: url)
            })
        }
        menu.addItem(.separator())
        addTagItems(to: menu, for: [url])
        menu.addItem(.separator())
        menu.addItem(NSMenuItem.closure(app.isFavorite(url) ? "Remove from Favorites" : "Add to Favorites") { [weak self] in
            self?.app.toggleFavorite(url)
            self?.refreshFavoriteItem()
        })
        return menu
    }

    /// A tab's accessory view sits at its far edge, so the dots go in the title to stay next to the name.
    /// They are an image because the tab recolors its title's text.
    func refreshTabTags() {
        guard let window else { return }
        let tags = tab.folder.map(FinderTags.read) ?? []
        guard !tags.isEmpty else {
            window.tab.attributedTitle = nil
            return
        }
        let dots = NSTextAttachment()
        dots.image = TagDotsView.image(of: tags)
        dots.bounds = NSRect(origin: NSPoint(x: 0, y: -1), size: dots.image?.size ?? .zero)
        let title = NSMutableAttributedString(attachment: dots)
        title.append(NSAttributedString(string: " " + window.title))
        window.tab.attributedTitle = title
    }

    // MARK: Playback keys

    /// Catches keys before the focused view, so they work the same from the browser, the card list, and the inspector.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            self?.handleShortcutKey(event) == true ? nil : event
        }
    }

    func handleShortcutKey(_ event: NSEvent) -> Bool {
        let inFullScreen = fullScreenPreview != nil && event.window === fullScreenPreview?.window
        guard inFullScreen || event.window === window, window?.attachedSheet == nil,
              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return false }
        // Typing a name must still type. SwiftUI's list focus is also a text view, but not a field editor.
        if !inFullScreen, let editor = window?.firstResponder as? NSTextView, editor.isFieldEditor { return false }

        if event.type == .keyDown {
            switch event.keyCode {
            case 36, 76: // Return and Enter finish a crop.
                guard !inFullScreen, let session = tab.imageEdit, session.crop != nil else { break }
                if !event.isARepeat { session.applyCrop() }
                return true
            case 53: // Escape
                if !inFullScreen, let session = tab.imageEdit, session.crop != nil {
                    session.crop = nil
                    return true
                }
                // The preview can be on another display, with this window still key.
                if fullScreenPreview != nil {
                    toggleFullScreenPreview()
                    return true
                }
                if tab.isImportPanelVisible {
                    hideImportPanel()
                    return true
                }
                return false
            case 3, 35: // F and P
                guard fullScreenPreview != nil || canPreviewFullScreen else { return false }
                if !event.isARepeat { toggleFullScreenPreview() }
                return true
            case 125, 126 where inFullScreen: // Down and Up move through the list behind the preview.
                window?.firstResponder?.keyDown(with: event)
                return true
            case 123, 124 where inFullScreen: // Left and Right would otherwise change the open columns unseen.
                return true
            default:
                break
            }
        }

        // I, O, and X stay available for type-select when the selection can't be trimmed.
        if event.type == .keyDown, selectedVideo != nil, tab.videoExport?.url.path != selectedVideo?.url.path {
            if event.keyCode == PlaybackController.KeyCode.i {
                markTrimIn()
                return true
            }
            if event.keyCode == PlaybackController.KeyCode.o {
                markTrimOut()
                return true
            }
            if event.keyCode == PlaybackController.KeyCode.x, let selectedVideo, tab.trimMarks[selectedVideo.id] != nil {
                clearTrimMarks()
                return true
            }
        }

        guard event.keyCode == PlaybackController.KeyCode.space else {
            return tab.playback.handleKey(code: event.keyCode, isDown: event.type == .keyDown, isRepeat: event.type == .keyDown && event.isARepeat)
        }
        guard event.type == .keyDown, !tab.selection.isEmpty else { return false }
        if !event.isARepeat {
            if !inFullScreen { showInspector() }
            if tab.playback.canPlay {
                tab.playback.togglePlay()
            }
        }
        return true
    }

    // MARK: Image editing

    static func canEdit(_ item: FolderItem) -> Bool {
        !item.isFolder && ImageEditor.canEdit(item.contentType) && !FileOperations.isOnCameraCard(item.url)
    }

    /// The session for the selected image, started on the first edit.
    private func imageEditSession() -> ImageEditSession? {
        if let session = tab.imageEdit { return session }
        guard tab.selection.count == 1, Self.canEdit(tab.selection[0]) else { return nil }
        showInspector()
        let session = ImageEditSession(url: tab.selection[0].url)
        session.onError = { [weak self] in self?.showFileError("Can't edit this image", $0) }
        tab.imageEdit = session
        return session
    }

    func rotateImage(clockwise: Bool) {
        imageEditSession()?.rotate(clockwise: clockwise)
    }

    func beginImageCrop() {
        imageEditSession()?.beginCrop()
    }

    func discardImageEdit() {
        tab.imageEdit = nil
    }

    func saveImageEdit(asCopy: Bool) {
        guard let session = tab.imageEdit, session.isEdited, session.canEdit, let image = session.image else { return }
        let url = session.url
        let title = "Can't save the image"
        guard !app.isBusy(url) else {
            showFileError(title, FileOperationError.importing)
            return
        }
        session.setWorking(true)
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { () -> (copy: URL?, replaced: FileOperations.TrashedItem?) in
                    if asCopy { return (try ImageEditor.saveCopy(image, of: url), nil) }
                    return (nil, try ImageEditor.replace(url, with: image, trash: Self.trashForEdit))
                }
            }.value
            session.setWorking(false)
            switch result {
            case let .success(saved):
                if tab.imageEdit === session { tab.imageEdit = nil }
                if let copy = saved.copy {
                    window?.undoManager?.registerUndo(withTarget: self) { target in
                        target.moveToTrashNow([copy])
                    }
                    window?.undoManager?.setActionName("Save Copy")
                    content.fileOperationBrowser?.selectNewFile(copy)
                }
                if let replaced = saved.replaced {
                    registerFileVersionUndo(at: url, other: replaced)
                }
                content.reloadFolderContents()
            case let .failure(error):
                showFileError(title, error)
            }
        }
    }

    private nonisolated static func trashForEdit(_ url: URL) throws -> FileOperations.TrashedItem {
        let result = FileOperations.moveToTrash([url])
        guard let item = result.moved.first else { throw result.error ?? ImageEditorError.cantWrite }
        return item
    }

    private func registerFileVersionUndo(at url: URL, other: FileOperations.TrashedItem) {
        window?.undoManager?.registerUndo(withTarget: self) { target in
            target.swapFileVersion(at: url, with: other)
        }
        window?.undoManager?.setActionName("Save")
    }

    /// Undo and redo trade the version on disk for the one in the Trash, so neither is lost.
    private func swapFileVersion(at url: URL, with other: FileOperations.TrashedItem) {
        let title = "Can't change the file back"
        guard !app.isBusy(url) else {
            showFileError(title, FileOperationError.importing)
            return
        }
        do {
            app.releasePlayback(under: url)
            let current = try Self.trashForEdit(url)
            do {
                try FileOperations.restore(other)
            } catch {
                try? FileOperations.restore(current)
                throw error
            }
            tab.imageEdit = nil
            tab.trimMarks[url.path] = nil
            registerFileVersionUndo(at: url, other: current)
            content.reloadFolderContents()
        } catch {
            showFileError(title, error)
        }
    }

    // MARK: Video editing

    static func canEditVideo(_ item: FolderItem) -> Bool {
        !item.isFolder && item.isVideo && VideoEditor.canEdit(item.contentType) && !FileOperations.isOnCameraCard(item.url)
    }

    private var selectedVideo: FolderItem? {
        tab.selection.count == 1 && Self.canEditVideo(tab.selection[0]) ? tab.selection[0] : nil
    }

    func rotateVideo(clockwise: Bool) {
        guard let selectedVideo else { return }
        rotateVideo(at: selectedVideo.url, clockwise: clockwise)
    }

    /// Changes the file's header directly, so undo is simply a turn the other way.
    private func rotateVideo(at url: URL, clockwise: Bool) {
        let title = "Can't rotate this video"
        guard !app.isBusy(url) else {
            showFileError(title, FileOperationError.importing)
            return
        }
        do {
            try VideoEditor.rotate(url, clockwise: clockwise)
        } catch {
            showFileError(title, error)
            return
        }
        window?.undoManager?.registerUndo(withTarget: self) { target in
            target.rotateVideo(at: url, clockwise: !clockwise)
        }
        window?.undoManager?.setActionName("Rotate")
        app.controllers.filter { $0.tab.playback.url?.path == url.path }.forEach { $0.tab.playback.reloadFile() }
        content.reloadFolderContents()
    }

    /// The first frame is shown right away, so a mark can be set before anything has played.
    func markTrimIn() {
        guard let selectedVideo else { return }
        tab.playback.prepare()
        tab.trimMarks[selectedVideo.id, default: TrimMarks()].markIn(tab.playback.time)
    }

    func markTrimOut() {
        guard let selectedVideo else { return }
        tab.playback.prepare()
        tab.trimMarks[selectedVideo.id, default: TrimMarks()].markOut(tab.playback.time)
    }

    func clearTrimMarks() {
        guard let selectedVideo else { return }
        tab.trimMarks[selectedVideo.id] = nil
    }

    func saveVideoTrim(asCopy: Bool) {
        guard tab.videoExport == nil, let item = selectedVideo, let marks = tab.trimMarks[item.id], !marks.isEmpty else { return }
        let url = item.url
        let title = "Can't save the trimmed video"
        guard !app.isBusy(url) else {
            showFileError(title, FileOperationError.importing)
            return
        }
        let export = VideoTrimExport(url: url)
        tab.videoExport = export
        app.trimSources.insert(url.path)
        export.task = Task {
            defer {
                tab.videoExport = nil
                app.trimSources.remove(url.path)
            }
            var partFolder: URL?
            defer {
                if let partFolder {
                    try? FileManager.default.removeItem(at: partFolder)
                    app.partFiles.remove(partFolder)
                }
            }
            do {
                let folder = try VideoEditor.makePartFolder(beside: url)
                partFolder = folder
                app.partFiles.add(folder)
                let built = try await VideoEditor.exportTrim(of: url, marks: marks, into: folder) { [weak export] fraction in
                    Task { @MainActor in export?.progress = fraction }
                }
                try Task.checkCancellation()
                // Publishing is what releases the source, so nothing can be busy with it past this point.
                app.trimSources.remove(url.path)
                try finishTrim(built, of: url, asCopy: asCopy)
            } catch {
                if !Task.isCancelled { showFileError(title, error) }
            }
        }
    }

    private func finishTrim(_ built: URL, of url: URL, asCopy: Bool) throws {
        if asCopy {
            let copy = try VideoEditor.publishCopy(built, of: url)
            window?.undoManager?.registerUndo(withTarget: self) { target in
                target.moveToTrashNow([copy])
            }
            window?.undoManager?.setActionName("Save Copy")
        } else {
            let wasOpen = tab.playback.isLoaded
            app.releasePlayback(under: url)
            let replaced = try VideoEditor.publishReplacing(url, with: built, trash: Self.trashForEdit)
            tab.trimMarks[url.path] = nil
            registerFileVersionUndo(at: url, other: replaced)
            if wasOpen, tab.playback.url?.path == url.path { tab.playback.prepare() }
        }
        content.reloadFolderContents()
    }

    // MARK: Editing commands

    @objc func rotateLeft(_ sender: Any?) {
        if selectedVideo != nil {
            rotateVideo(clockwise: false)
        } else {
            rotateImage(clockwise: false)
        }
    }

    @objc func cropImage(_ sender: Any?) { beginImageCrop() }
    @objc func saveEdit(_ sender: Any?) { saveEdit(asCopy: false) }
    @objc func saveEditCopy(_ sender: Any?) { saveEdit(asCopy: true) }
    @objc func markIn(_ sender: Any?) { markTrimIn() }
    @objc func markOut(_ sender: Any?) { markTrimOut() }
    @objc func clearMarks(_ sender: Any?) { clearTrimMarks() }

    private func saveEdit(asCopy: Bool) {
        if selectedVideo != nil {
            saveVideoTrim(asCopy: asCopy)
        } else {
            saveImageEdit(asCopy: asCopy)
        }
    }

    // MARK: Full-screen preview

    private var canPreviewFullScreen: Bool {
        tab.selection.count == 1 && tab.selection[0].canPreviewFullScreen
    }

    var isFullScreenPreviewOpen: Bool { fullScreenPreview != nil }

    func toggleFullScreenPreview() {
        if let fullScreenPreview {
            fullScreenPreview.close()
            self.fullScreenPreview = nil
            tab.playback.staysLoaded = false
            window?.makeKeyAndOrderFront(nil)
        } else if canPreviewFullScreen, let screen = previewScreen {
            tab.playback.staysLoaded = true
            tab.playback.prepare()
            let preview = FullScreenPreview(
                tab: tab,
                screen: screen,
                onChooseScreen: { [weak self] in self?.app.setPreviewDisplay($0.stableID) },
                onClose: { [weak self] in self?.toggleFullScreenPreview() }
            )
            fullScreenPreview = preview
            preview.present()
        }
    }

    /// The display chosen last time if it's connected, otherwise the one this window is on.
    private var previewScreen: NSScreen? {
        NSScreen.screens.first { $0.stableID == app.settings.previewDisplay } ?? window?.screen ?? NSScreen.main
    }

    // MARK: Window

    func windowWillClose(_ notification: Notification) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        fullScreenPreview?.close()
        fullScreenPreview = nil
        tab.playback.staysLoaded = false
        tab.playback.unload()
        app.controllerDidClose(self)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        refreshFavoriteItem()
        titleLabel.textColor = .labelColor
    }

    func windowDidResignKey(_ notification: Notification) {
        tab.playback.releaseHeldKeys()
        titleLabel.textColor = .secondaryLabelColor
    }

    /// Items at the far side move without the window resizing, when the import button appears for one.
    func windowDidUpdate(_ notification: Notification) {
        layoutTitleBar()
    }

    func windowDidResize(_ notification: Notification) {
        // The toolbar places its items in the layout pass that follows.
        window?.contentView?.superview?.layoutSubtreeIfNeeded()
        layoutTitleBar()
    }

    /// A tab in the background shouldn't keep playing out of sight.
    func windowDidChangeOcclusionState(_ notification: Notification) {
        // The full-screen preview covers this window, and is what's playing.
        if fullScreenPreview == nil, window?.occlusionState.contains(.visible) == false {
            tab.playback.pause()
        }
    }

    // MARK: Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, .mode, .importActivity, .importCard, .favorite, .reveal, .inspectorTrackingSeparator, .toggleInspector]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch identifier {
        case .mode:
            modeControl.segmentCount = 2
            modeControl.trackingMode = .selectOne
            modeControl.setImage(NSImage(systemSymbolName: "rectangle.split.1x2", accessibilityDescription: "Sections"), forSegment: 0)
            modeControl.setImage(NSImage(systemSymbolName: "rectangle.split.3x1", accessibilityDescription: "Single Browser"), forSegment: 1)
            modeControl.setToolTip("Sections", forSegment: 0)
            modeControl.setToolTip("Single Browser", forSegment: 1)
            modeControl.selectedSegment = tab.mode == .sections ? 0 : 1
            modeControl.target = self
            modeControl.action = #selector(modeControlChanged(_:))
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.view = modeControl
            item.label = "View"
            return item
        case .importCard:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = "Import"
            item.toolTip = "Import from a camera card"
            item.target = self
            item.action = #selector(showImport(_:))
            item.autovalidates = false
            importItem = item
            refreshImportItem()
            return item
        case .importActivity:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = "Import Activity"
            item.view = NSHostingView(rootView: ImportActivityButton(app: app))
            return item
        case .favorite:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = "Favorite"
            item.toolTip = "Add or remove this folder from Favorites"
            item.target = self
            item.action = #selector(toggleFavorite(_:))
            item.autovalidates = false
            favoriteItem = item
            refreshFavoriteItem()
            return item
        case .reveal:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = "Reveal in Finder"
            item.toolTip = "Reveal in Finder (⌘F)"
            item.image = NSImage(systemSymbolName: "arrow.up.forward.square", accessibilityDescription: "Reveal in Finder")
            item.target = self
            item.action = #selector(revealInFinder(_:))
            return item
        default:
            return nil
        }
    }
}

/// Dragging the title still moves the window, as the system's own title does.
private final class WindowTitleLabel: NSTextField {
    override var mouseDownCanMoveWindow: Bool { true }
}

/// Keeps the title on the title bar lined up with the panes.
private final class WorkspaceSplitViewController: NSSplitViewController {
    var onResize: (() -> Void)?

    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        onResize?()
    }
}

/// Finder's sound for moving to the Trash. A system sound honors the setting for user interface sound effects.
private enum TrashSound {
    private static let sound: SystemSoundID? = {
        let file = URL(fileURLWithPath: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/finder/move to trash.aif")
        var sound: SystemSoundID = 0
        return AudioServicesCreateSystemSoundID(file as CFURL, &sound) == noErr ? sound : nil
    }()

    static func play() {
        if let sound { AudioServicesPlaySystemSound(sound) }
        #if DEBUG
        debugPlayedSounds.append("trash=\(sound != nil)")
        #endif
    }
}

/// The date and name fields that make up a project's folder name.
private struct ProjectForm {
    let view: NSView
    let date: NSTextField
    let name: NSTextField

    init(date dateText: String, name nameText: String) {
        date = NSTextField(string: dateText)
        date.placeholderString = "YYYY-MM-DD"
        name = NSTextField(string: nameText)
        let todayButton = TodayButton(field: date)
        let dateRow = NSStackView(views: [date, todayButton])
        dateRow.spacing = 6
        date.widthAnchor.constraint(equalToConstant: 144).isActive = true
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Date"), dateRow],
            [NSTextField(labelWithString: "Name"), name],
        ])
        grid.rowSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 210
        grid.rowAlignment = .firstBaseline
        grid.frame = NSRect(x: 0, y: 0, width: 260, height: 52)
        view = grid
        date.nextKeyView = todayButton
        todayButton.nextKeyView = name
        name.nextKeyView = date
    }
}

/// Fills a date field with today. A view of its own, because a button doesn't keep its target alive.
private final class TodayButton: NSButton {
    private weak var field: NSTextField?

    convenience init(field: NSTextField) {
        self.init(title: "Today", target: nil, action: nil)
        self.field = field
        target = self
        action = #selector(fillToday)
        setContentHuggingPriority(.required, for: .horizontal)
    }

    @objc private func fillToday() {
        field?.stringValue = ProjectCatalog.dateString(.now)
    }
}
