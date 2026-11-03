import AppKit
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

    private let splitController = NSSplitViewController()
    private let modeControl = NSSegmentedControl()
    private weak var favoriteItem: NSToolbarItem?
    private weak var importItem: NSToolbarItem?
    private var contentItem: NSSplitViewItem?
    private var inspectorItem: NSSplitViewItem?
    private var inspectorObservation: NSKeyValueObservation?
    private var keyMonitor: Any?
    private var fullScreenPreview: FullScreenPreview?
    private static let defaultContentMinimumWidth: CGFloat = 420
    private static let defaultInspectorWidth: CGFloat = 440
    #if DEBUG
    var debugInspectorItem: NSSplitViewItem? { inspectorItem }
    var debugImportItem: NSToolbarItem? { importItem }
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
        window.minSize = NSSize(width: 820, height: 480)
        window.isRestorable = false
        window.toolbarStyle = .unified
        window.title = "ReelDock"
        super.init(window: window)

        window.delegate = self
        content.windowController = self
        buildSplit()
        buildToolbar()
        window.contentViewController = splitController
        window.setContentSize(NSSize(width: 1320, height: 860))
        if !window.setFrameUsingName("ReelDockWorkspace") { window.center() }
        window.setFrameAutosaveName("ReelDockWorkspace")
        installKeyMonitor()

        content.display()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildSplit() {
        let sidebarHost = NSHostingController(rootView: SidebarView(app: app, tab: tab, controller: self))
        sidebarHost.sizingOptions = []
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarHost)
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 340

        let contentItem = NSSplitViewItem(contentListWithViewController: content)
        contentItem.minimumThickness = Self.defaultContentMinimumWidth
        self.contentItem = contentItem

        let inspectorHost = NSHostingController(rootView: InspectorView(tab: tab, controller: self))
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

    // MARK: Showing folders

    func show(folder: URL, mode: BrowserMode, restoring snapshot: TabSnapshot? = nil) {
        tab.folder = folder
        tab.mode = mode
        window?.title = folder.lastPathComponent
        window?.representedURL = folder
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

    @objc func chooseProjectRoot(_ sender: Any?) {
        app.chooseProjectRoot(from: self)
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

    @objc func chooseMediaRoot(_ sender: Any?) {
        app.chooseMediaRoot(from: self)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
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

    /// Runs off the main thread, because a slow drive can take a while to respond.
    func moveToTrash(_ urls: [URL]) async {
        let (moved, failure) = await Task.detached(priority: .userInitiated) {
            let result = FileOperations.moveToTrash(urls)
            return (result.moved, result.error.map { $0.localizedDescription })
        }.value
        finishTrash(moved: moved, failure: failure)
    }

    /// Undo and redo must register their opposite before they return.
    private func moveToTrashNow(_ urls: [URL]) {
        let result = FileOperations.moveToTrash(urls)
        finishTrash(moved: result.moved, failure: result.error?.localizedDescription)
    }

    private func finishTrash(moved: [FileOperations.TrashedItem], failure: String?) {
        if !moved.isEmpty {
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

    private func showFileError(_ title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        if let window {
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
            case 53: // Escape
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

        guard event.keyCode == PlaybackController.KeyCode.space else {
            return tab.playback.handleKey(code: event.keyCode, isDown: event.type == .keyDown, isRepeat: event.type == .keyDown && event.isARepeat)
        }
        guard event.type == .keyDown, !tab.selection.isEmpty else { return false }
        if !event.isARepeat {
            if !inFullScreen, inspectorItem?.isCollapsed == true {
                inspectorItem?.animator().isCollapsed = false
            }
            if tab.playback.canPlay {
                tab.playback.togglePlay()
            }
        }
        return true
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
    }

    func windowDidResignKey(_ notification: Notification) {
        tab.playback.releaseHeldKeys()
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
        [.toggleSidebar, .sidebarTrackingSeparator, .mode, .flexibleSpace, .importActivity, .importCard, .favorite, .reveal, .inspectorTrackingSeparator, .toggleInspector]
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
            item.toolTip = "Reveal in Finder"
            item.image = NSImage(systemSymbolName: "arrow.up.forward.square", accessibilityDescription: "Reveal in Finder")
            item.target = self
            item.action = #selector(revealInFinder(_:))
            return item
        default:
            return nil
        }
    }
}
