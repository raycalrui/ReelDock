#if DEBUG
import AppKit

/// Debug-only test driver. Set REELDOCK_DEBUG_DIR, then write commands to `command.txt` there.
/// It runs each line, writes `result.txt`, and deletes the command file.
final class DebugDriver {
    private let directory: URL
    private let app: AppModel
    private var timer: Timer?

    init?(app: AppModel) {
        guard let path = ProcessInfo.processInfo.environment["REELDOCK_DEBUG_DIR"] else { return nil }
        directory = URL(fileURLWithPath: path, isDirectory: true)
        self.app = app
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func poll() {
        let commandFile = directory.appendingPathComponent("command.txt")
        guard let text = try? String(contentsOf: commandFile, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: commandFile)
        var output: [String] = []
        for line in text.split(separator: "\n") where !line.isEmpty {
            output.append("> \(line)")
            output.append(run(String(line)))
        }
        try? output.joined(separator: "\n").write(to: directory.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
    }

    private var current: WorkspaceWindowController? {
        (NSApp.keyWindow?.windowController as? WorkspaceWindowController)
            ?? (NSApp.orderedWindows.first { $0.windowController is WorkspaceWindowController }?.windowController as? WorkspaceWindowController)
    }

    private func run(_ line: String) -> String {
        let parts = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        if parts[0] == "reopen" {
            let didHandle = NSApp.delegate?.applicationShouldHandleReopen?(NSApp, hasVisibleWindows: false)
            return "handled=\(String(describing: didHandle)) \(app.controllers.map { $0.tab.folder?.lastPathComponent ?? "blank" })"
        }
        guard let controller = current else { return "no window" }
        let content = controller.content
        switch parts[0] {
        case "open":
            app.open(URL(fileURLWithPath: parts[1], isDirectory: true), from: controller)
        case "pasteboard":
            // pasteboard|path|path: puts files on the test pasteboard. pasteboard alone reports it.
            guard parts.count > 1 else { return NSPasteboard.files.fileURLs.map(\.path).joined(separator: "\n") }
            NSPasteboard.files.clearContents()
            NSPasteboard.files.writeObjects(parts.dropFirst().map { URL(fileURLWithPath: $0) as NSURL })
        case "transfers":
            let queue = app.transfers
            return "active=\(queue.isActive) paused=\(queue.isPaused) bytes=\(queue.copiedBytes)/\(queue.totalBytes) jobs=\(queue.jobs.map { "\($0.sources.map(\.lastPathComponent))->\($0.destination.lastPathComponent) \($0.state) \($0.items.map(\.result.lastPathComponent))" })"
        case "transferpause":
            app.transfers.setPaused(parts[safe: 1] != "off")
        case "transfercancel":
            app.transfers.cancelAll()
        case "undo":
            let manager = controller.window?.undoManager
            guard manager?.canUndo == true else { return "nothing to undo" }
            manager?.undo()
        case "redo":
            let manager = controller.window?.undoManager
            guard manager?.canRedo == true else { return "nothing to redo" }
            manager?.redo()
        case "headermenu":
            // headermenu|section title: the header's menu items, and with |index, runs one.
            guard let pane = content.debugSectionsHost?.stack.panes.first(where: { $0.section.title == parts[1] }) else { return "not found" }
            guard let menu = pane.header.makeMenu?() else { return "no menu" }
            if let index = Int(parts[safe: 2] ?? "") { menu.performActionForItem(at: index) }
            return menu.items.map(\.title).joined(separator: ",")
        case "columnmenu":
            // columnmenu|section title|column index: the menu for the selected row.
            guard let column = content.debugBrowser(parts[1])?.columns[safe: Int(parts[2]) ?? 0] else { return "not found" }
            return column.contextMenu().items.map(\.title).filter { !$0.isEmpty }.joined(separator: ",")
        case "projectmenu":
            // projectmenu|title|item title: runs an item of the sidebar's menu for a project.
            guard let project = app.projects.first(where: { $0.title == parts[1] }) else { return "not found" }
            let menu = controller.folderContextMenu(for: project.url)
            guard let index = menu.items.firstIndex(where: { $0.title == parts[2] }) else { return "no menu item: \(menu.items.map(\.title))" }
            menu.performActionForItem(at: index)
        case "pressbutton":
            // pressbutton|title: presses a button in the open sheet.
            guard let button = controller.window?.attachedSheet?.contentView?.debugButtons.first(where: { $0.title == parts[1] }) else { return "no button" }
            button.performClick(nil)
        case "focusstate":
            let responder = controller.window?.firstResponder
            let table = responder as? BrowserTableView
            return "responder=\(responder.map { String(describing: type(of: $0)) } ?? "none") column=\(table?.column?.folderURL.lastPathComponent ?? "-") newFolder=\(controller.validateMenuItem(NSMenuItem(title: "", action: #selector(WorkspaceWindowController.newFolder(_:)), keyEquivalent: ""))) paste=\(controller.validateMenuItem(NSMenuItem(title: "", action: #selector(WorkspaceWindowController.paste(_:)), keyEquivalent: ""))) copy=\(controller.validateMenuItem(NSMenuItem(title: "", action: #selector(WorkspaceWindowController.copy(_:)), keyEquivalent: "")))"
        case "tagfilter":
            // tagfilter|name: filters this tab's sidebar. tagfilter alone clears it.
            controller.tab.projectTagFilter = parts[safe: 1]
            return "shown=\(ProjectCatalog.filter(app.projects, query: "", tag: parts[safe: 1]).map(\.folderName)) tags=\(ProjectCatalog.tags(in: app.projects).map(\.name))"
        case "settings":
            // settings|show, clear, or reset.
            switch parts[safe: 1] {
            case "show": app.showSettings()
            case "clear": app.clearMediaRoot()
            case "reset": app.resetSectionLayout()
            default: break
            }
            return "root=\((app.settings.projectRoot as NSString?)?.lastPathComponent ?? "nil") media=\((app.settings.mediaRoot as NSString?)?.lastPathComponent ?? "nil") sections=\(app.settings.sections.count) hidden=\(app.settings.showHidden) window=\(NSApp.windows.first { $0.title == "Settings" }.map { "\($0.isVisible) \($0.frame.size)" } ?? "none")"
        case "setmedia":
            app.debugSetMediaRoot(parts[1])
        case "sectionstate":
            return (content.debugSectionsHost?.stack.panes ?? []).map { "\($0.section.title):\($0.count.map(String.init) ?? "-"):\($0.isExpanded ? "open" : "closed")" }.joined(separator: " ")
        case "blanktab":
            app.addTab(after: controller)
        case "newtab":
            app.open(URL(fileURLWithPath: parts[1], isDirectory: true), from: controller, newTab: true)
        case "mode":
            parts[1] == "single" ? controller.showSingleBrowser(nil) : controller.showSections(nil)
        case "hidden":
            controller.toggleHiddenFiles(nil)
        case "favorite":
            controller.toggleFavorite(nil)
        case "drop":
            // drop|section title|column index|row name or -|all, option, or command|check or perform|paths...
            guard let column = content.debugBrowser(parts[1])?.columns[safe: Int(parts[2]) ?? 0] else { return "not found" }
            let table = column.tableView
            table.layoutSubtreeIfNeeded()
            var point = NSPoint(x: 10, y: table.visibleRect.maxY - 2)
            if parts[3] != "-" {
                guard let row = column.items.firstIndex(where: { $0.name == parts[3] }) else { return "no row" }
                let rect = table.rect(ofRow: row)
                point = NSPoint(x: rect.midX, y: rect.midY)
            }
            let info = DebugDragInfo(files: Array(parts.dropFirst(6)), mask: parts[4], location: table.convert(point, to: nil))
            let operation = column.tableView(table, validateDrop: info, proposedRow: -1, proposedDropOperation: .on)
            let accepted = parts[5] == "perform" && !operation.isEmpty ? column.tableView(table, acceptDrop: info, row: -1, dropOperation: .on) : false
            return "operation=\(operation.debugName) accepted=\(accepted)"
        case "columndrop":
            // columndrop|section title|column index|all, option, or command|check or perform|paths...: on the column, where the "Empty" label is.
            guard let column = content.debugBrowser(parts[1])?.columns[safe: Int(parts[2]) ?? 0] else { return "not found" }
            let info = DebugDragInfo(files: Array(parts.dropFirst(5)), mask: parts[3], location: .zero)
            let operation = column.draggingEntered(info)
            let accepted = parts[4] == "perform" && !operation.isEmpty ? column.performDragOperation(info) : false
            return "operation=\(operation.debugName) accepted=\(accepted)"
        case "headerdrop":
            // headerdrop|section title|all, option, or command|check or perform|paths...
            guard let pane = content.debugPane(parts[1]) else { return "not found" }
            let info = DebugDragInfo(files: Array(parts.dropFirst(4)), mask: parts[2], location: .zero)
            let operation = pane.header.draggingEntered(info)
            let accepted = parts[3] == "perform" && !operation.isEmpty ? pane.header.performDragOperation(info) : false
            return "operation=\(operation.debugName) accepted=\(accepted)"
        case "springhover":
            // springhover|section title|column index|row name|paths...
            guard let column = content.debugBrowser(parts[1])?.columns[safe: Int(parts[2]) ?? 0],
                  let row = column.items.firstIndex(where: { $0.name == parts[3] }) else { return "not found" }
            let table = column.tableView
            table.layoutSubtreeIfNeeded()
            let rect = table.rect(ofRow: row)
            column.updateSpringLoad(DebugDragInfo(files: Array(parts.dropFirst(4)), mask: "all", location: table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)))
        case "imageedit":
            // imageedit|left, right, crop, setcrop|x|y|w|h, apply, cancel, save, copy, revert
            switch parts[1] {
            case "left": controller.rotateImage(clockwise: false)
            case "right": controller.rotateImage(clockwise: true)
            case "crop": controller.beginImageCrop()
            case "setcrop": controller.tab.imageEdit?.crop = CGRect(x: Double(parts[2]) ?? 0, y: Double(parts[3]) ?? 0, width: Double(parts[4]) ?? 1, height: Double(parts[5]) ?? 1)
            case "apply": controller.tab.imageEdit?.applyCrop()
            case "cancel": controller.tab.imageEdit?.crop = nil
            case "save": controller.saveImageEdit(asCopy: false)
            case "copy": controller.saveImageEdit(asCopy: true)
            case "revert": controller.discardImageEdit()
            default: return "unknown"
            }
        case "projectthumbs":
            // projectthumbs: times finding each project's thumbnail source and decoding a first frame, one at a time.
            Task {
                var lines: [String] = []
                for project in app.projects {
                    let start = ContinuousClock.now
                    let source = ProjectThumbnail.source(in: project.url)
                    var detail = "none"
                    switch source {
                    case .cover(let item): detail = "cover \(item.name)"
                    case .firstFrame(let item):
                        let frame = await ThumbnailCache.shared.firstFrame(of: item.url, modified: item.modified, size: 128, scale: 2)
                        detail = "frame \(item.name) \(frame.map { "\(Int($0.size.width))x\(Int($0.size.height))" } ?? "failed")"
                    case nil: break
                    }
                    lines.append("\(ContinuousClock.now - start) \(project.folderName): \(detail)")
                }
                try? lines.joined(separator: "\n").write(to: self.directory.appendingPathComponent("thumbs.txt"), atomically: true, encoding: .utf8)
            }
        case "sidebarsnapshot":
            // sidebarsnapshot|path: draws the sidebar pane alone.
            func table(in view: NSView) -> NSTableView? {
                view as? NSTableView ?? view.subviews.lazy.compactMap(table(in:)).first
            }
            guard let root = controller.debugSidebarItem?.viewController.view, let view = table(in: root),
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.visibleRect) else { return "no view" }
            view.cacheDisplay(in: view.visibleRect, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: parts[1]))
            return "ok \(bitmap.pixelsWide)x\(bitmap.pixelsHigh) rows=\(view.numberOfRows) rowHeight=\(view.numberOfRows > 8 ? view.rect(ofRow: 8).height : 0)"
        case "projectstats":
            return app.projects.map { project in
                let stats = app.projectStats[project.folderName]
                return "\(project.folderName)\t\(stats?.fileCount ?? -1)\t\(stats?.size ?? -1)"
            }.joined(separator: "\n")
        case "copyname":
            // copyname: presses the button beside the title if it's showing, and reports it and the pasteboard.
            let button = controller.debugCopyNameButton
            if !button.isHidden { button.performClick(nil) }
            return "hidden=\(button.isHidden) image=\(button.image?.accessibilityDescription ?? "") pasteboard=\(NSPasteboard.files.string(forType: .string) ?? "nil")"
        case "titlebarframe":
            // Where the title sits in the window, and whether a click there reaches the button.
            let bar = controller.debugTitleBar
            let button = controller.debugCopyNameButton
            let frame = bar.convert(bar.bounds, to: nil)
            let center = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
            let hit = controller.window?.contentView?.superview?.hitTest(center)
            return "frame=\(frame) parent=\(bar.superview.map { "\(type(of: $0))" } ?? "nil") buttonHidden=\(button.isHidden) hit=\(hit === button ? "button" : hit.map { "\(type(of: $0))" } ?? "nil") windowWidth=\(controller.window?.frame.width ?? 0)"
        case "copynamestate":
            let button = controller.debugCopyNameButton
            return "hidden=\(button.isHidden) image=\(button.image?.accessibilityDescription ?? "") frame=\(button.window == nil ? "none" : "\(button.convert(button.bounds, to: nil))") window=\(controller.window?.title ?? "")"
        case "thumbgenerations":
            return "\(app.thumbnailGenerations)"
        case "inspectorsnapshot":
            // inspectorsnapshot|path: draws the inspector alone, which the window snapshot leaves blank.
            guard let view = controller.debugInspectorItem?.viewController.view,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return "no view" }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: parts[1]))
            return "ok \(bitmap.pixelsWide)x\(bitmap.pixelsHigh)"
        case "overviewsnapshot":
            // overviewsnapshot|path: draws what's inside the overview's scroll view, which a snapshot of the panel leaves blank.
            func findScroll(_ view: NSView?) -> NSScrollView? {
                guard let view else { return nil }
                return (view as? NSScrollView) ?? view.subviews.lazy.compactMap(findScroll).first
            }
            guard let scroll = findScroll(controller.debugInspectorItem?.viewController.view) else { return "no scroll view" }
            let target = scroll.contentView
            guard let bitmap = target.bitmapImageRepForCachingDisplay(in: target.bounds) else { return "no bitmap" }
            target.cacheDisplay(in: target.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: parts[1]))
            return "scroll=\(scroll.frame) clip=\(target.bounds) document=\(scroll.documentView?.frame ?? .zero) subviews=\(scroll.documentView?.subviews.count ?? 0)"
        case "previewsnapshot":
            // previewsnapshot|path: draws the full-screen preview's window.
            guard let view = NSApp.windows.first(where: { $0.level == .statusBar })?.contentView,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return "no view" }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: parts[1]))
            return "ok \(bitmap.pixelsWide)x\(bitmap.pixelsHigh)"
        case "previewmove":
            // previewmove|x|y: a mouse move in the full-screen preview, from its bottom left.
            guard let window = NSApp.windows.first(where: { $0.level == .statusBar }),
                  let event = NSEvent.mouseEvent(with: .mouseMoved, location: NSPoint(x: Double(parts[1]) ?? 0, y: Double(parts[2]) ?? 0), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) else { return "no window" }
            window.sendEvent(event)
            return "moved \(window.frame.size)"
        case "waveclick":
            // waveclick|fraction: the same calls as a click on the waveform, which a script can't make.
            let playback = controller.tab.playback
            playback.player.volume = 0
            let duration = playback.player.currentItem?.duration.seconds ?? Double(parts[safe: 2] ?? "") ?? 0
            playback.beginScrub()
            playback.seek(to: duration * (Double(parts[1]) ?? 0))
            playback.endScrub()
            if !playback.isPlaying { playback.togglePlay() }
            return "duration=\(duration)"
        case "clipedit":
            // clipedit|left, right, in, out, clear, save, copy, cancel, key-i, key-o
            switch parts[1] {
            case "left": controller.rotateVideo(clockwise: false)
            case "right": controller.rotateVideo(clockwise: true)
            case "in": controller.markTrimIn()
            case "out": controller.markTrimOut()
            case "clear": controller.clearTrimMarks()
            case "save": controller.saveVideoTrim(asCopy: false)
            case "copy": controller.saveVideoTrim(asCopy: true)
            case "cancel": controller.tab.videoExport?.task?.cancel()
            case "key-i", "key-o", "key-x":
                guard let window = controller.window, let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: parts[1] == "key-i" ? 34 : parts[1] == "key-o" ? 31 : 7) else { return "no event" }
                return "handled=\(controller.handleShortcutKey(event))"
            default: return "unknown"
            }
        case "clipstate":
            let tab = controller.tab
            let item = tab.selection.first
            return "selection=\(tab.selection.map(\.name)) canEdit=\(item.map(WorkspaceWindowController.canEditVideo) ?? false) marks=\(item.flatMap { tab.trimMarks[$0.id] }.map { "\($0.inPoint ?? -1)...\($0.outPoint ?? -1)" } ?? "-") exporting=\(tab.videoExport != nil) progress=\(tab.videoExport?.progress ?? 0) time=\(tab.playback.time) loaded=\(tab.playback.isLoaded) failed=\(tab.playback.failed)"
        case "imagestate":
            let session = controller.tab.imageEdit
            return "session=\(session != nil) size=\(session?.image.map { "\($0.width)x\($0.height)" } ?? "-") edited=\(session?.isEdited ?? false) working=\(session?.isWorking ?? false) crop=\(session?.crop.map { "\($0)" } ?? "-") selection=\(controller.tab.selection.map(\.name)) canEdit=\(controller.tab.selection.first.map(WorkspaceWindowController.canEdit) ?? false)"
        case "cropkey":
            // cropkey|return or esc: goes through the same path as a real key.
            guard let window = controller.window, let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: parts[1] == "return" ? 36 : 53) else { return "no event" }
            return "handled=\(controller.handleShortcutKey(event))"
        case "dragend":
            // dragend|section title|column index: what AppKit calls when a drag ends, dropped or not.
            guard let column = content.debugBrowser(parts[1])?.columns[safe: Int(parts[2]) ?? 0] else { return "not found" }
            column.tableView.draggingEnded(DebugDragInfo(files: [], mask: "all", location: .zero))
            return "survived"
        case "springcancel":
            content.debugBrowser(parts[1])?.columns[safe: Int(parts[2]) ?? 0]?.cancelSpringLoad()
        case "springheader":
            // springheader|section title|enter or exit|paths...
            guard let pane = content.debugPane(parts[1]) else { return "not found" }
            if parts[2] == "exit" {
                pane.header.draggingExited(nil)
            } else {
                _ = pane.header.draggingEntered(DebugDragInfo(files: Array(parts.dropFirst(3)), mask: "all", location: .zero))
            }
        case "columnlist":
            guard let browser = content.debugBrowser(parts[1]) else { return "not found" }
            return browser.columns.map(\.folderURL.lastPathComponent).joined(separator: " > ")
        case "tablefill":
            // tablefill|section title|column index: whether the space past the last row is reachable.
            guard let column = content.debugBrowser(parts[1])?.columns[safe: Int(parts[2]) ?? 0] else { return "not found" }
            let table = column.tableView
            table.layoutSubtreeIfNeeded()
            let clip = table.enclosingScrollView?.contentView
            table.scroll(NSPoint(x: 0, y: max(0, table.frame.height - (clip?.bounds.height ?? 0))))
            let bottom = NSPoint(x: 20, y: table.frame.height - 4)
            let rowsEnd = CGFloat(table.numberOfRows) * table.rowHeight
            let hit = table.window?.contentView?.hitTest(table.window?.contentView?.convert(table.convert(bottom, to: nil), from: nil) ?? .zero)
            return "rows=\(table.numberOfRows) rowsEnd=\(Int(rowsEnd)) table=\(Int(table.frame.height)) clip=\(Int(clip?.bounds.height ?? 0)) rowAtBottom=\(table.row(at: bottom)) hit=\(hit.map { String(describing: type(of: $0)) } ?? "nil") menu=\(column.backgroundMenu()?.items.map(\.title) ?? [])"
        case "headermenu":
            return content.debugPane(parts[1])?.header.makeMenu?()?.items.map(\.title).description ?? "none"
        case "headermenuitem":
            // headermenuitem|section title|item title
            guard let item = content.debugPane(parts[1])?.header.makeMenu?()?.items.first(where: { $0.title == parts[2] }) else { return "no item" }
            NSApp.sendAction(item.action!, to: item.target, from: item)
        case "dragtypes":
            guard let column = content.debugBrowser(parts[1])?.columns[safe: Int(parts[2]) ?? 0] else { return "not found" }
            return "table=\(column.tableView.registeredDraggedTypes.map(\.rawValue)) header=\(content.debugPane(parts[1])?.header.registeredDraggedTypes.map(\.rawValue) ?? [])"
        case "toggleinspector":
            let ok = controller.window?.firstResponder?.tryToPerform(#selector(NSSplitViewController.toggleInspector(_:)), with: nil) ?? false
            return "performed=\(ok)"
        case "splitwidths":
            let window = controller.window
            return "window=\(Int(window?.frame.width ?? 0)) minWindow=\(Int(window?.minSize.width ?? 0)) sidebar=\(Int(controller.debugSidebarView?.frame.width ?? 0)) content=\(Int(content.view.frame.width)) inspector=\(Int(controller.debugInspectorItem?.viewController.view.frame.width ?? 0)) collapsed=\(controller.debugInspectorItem?.isCollapsed ?? false) selection=\(controller.tab.selection.map(\.name))"
        case "sounds":
            return "sounds=\(debugPlayedSounds)"
        case "deselect":
            // deselect|section title|column index
            guard let column = content.debugBrowser(parts[1])?.columns[safe: Int(parts[2]) ?? 0] else { return "not found" }
            column.tableView.deselectAll(nil)
        case "select":
            // select|section title|column index|row name
            guard let column = content.debugBrowser(parts[1])?.columns[safe: Int(parts[2]) ?? 0],
                  let row = column.items.firstIndex(where: { $0.name == parts[3] }) else { return "not found" }
            controller.window?.makeFirstResponder(column.tableView)
            column.tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        case "key":
            // key|section title|column index|key code|optional modifiers
            guard let column = content.debugBrowser(parts[1])?.columns[safe: Int(parts[2]) ?? 0],
                  let code = UInt16(parts[3]) else { return "not found" }
            controller.window?.makeFirstResponder(column.tableView)
            let flags: NSEvent.ModifierFlags = parts.count > 4 && parts[4] == "shift" ? .shift : []
            if let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: controller.window?.windowNumber ?? 0, context: nil,
                characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code
            ) {
                column.tableView.keyDown(with: event)
            }
        case "toggle":
            guard let pane = content.debugPane(parts[1]) else { return "not found" }
            content.debugStack?.toggle(pane)
        case "clickheader":
            // Goes through hit testing, as a real click on the title does.
            guard let pane = content.debugPane(parts[1]), let window = controller.window else { return "not found" }
            let local = NSPoint(x: Double(parts[2]) ?? 60, y: 14)
            let inWindow = pane.header.convert(local, to: nil)
            guard let hit = pane.header.hitTest(pane.header.superview!.convert(local, from: pane.header)),
                  let event = NSEvent.mouseEvent(
                    with: .leftMouseDown, location: inWindow, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
                  ) else { return "no hit" }
            hit.mouseDown(with: event)
            return "hit \(type(of: hit))"
        case "importshow":
            controller.showImportPanel(cardID: parts[safe: 1])
        case "importhide":
            controller.hideImportPanel()
        case "importtoggle":
            controller.showImport(nil)
        case "importitem":
            let item = controller.debugImportItem
            return "open=\(controller.tab.isImportPanelVisible) style=\(item?.style == .prominent ? "prominent" : "plain") tip=\(item?.toolTip ?? "") contentHeight=\(Int(content.view.bounds.height)) panel=\(Int(content.debugImportHost?.frame.width ?? 0))x\(Int(content.debugImportHost?.frame.height ?? 0)) split=\(Int(content.debugSplitView.frame.width)) window=\(Int(controller.window?.frame.width ?? 0)) selection=\(controller.tab.selection.map(\.name))"
        case "activate":
            NSApp.activate(ignoringOtherApps: true)
            controller.window?.makeKeyAndOrderFront(nil)
            return "active=\(NSApp.isActive) key=\(controller.window?.isKeyWindow ?? false)"
        case "snaptoolbar":
            guard let frame = controller.window?.contentView?.superview else { return "no frame" }
            let rect = NSRect(x: 0, y: frame.bounds.height - 60, width: frame.bounds.width, height: 60)
            guard let rep = frame.bitmapImageRepForCachingDisplay(in: rect) else { return "no rep" }
            frame.cacheDisplay(in: rect, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: parts[1]))
        case "toolbarframes":
            func walk(_ view: NSView, _ out: inout [String]) {
                if String(describing: type(of: view)).contains("ToolbarItemViewer") { out.append("\(Int(view.frame.width))x\(Int(view.frame.height))") }
                view.subviews.forEach { walk($0, &out) }
            }
            var frames: [String] = []
            if let frame = controller.window?.contentView?.superview { walk(frame, &frames) }
            return frames.joined(separator: " ")
        case "importhighlight":
            let clips = app.cards.cards.flatMap(\.clips).filter { $0.name == parts[1] }
            content.importModel.highlighted = Set(clips.map(\.id))
            // A click on a row also moves focus to the list.
            func findTable(_ view: NSView?) -> NSTableView? {
                guard let view else { return nil }
                return (view as? NSTableView) ?? view.subviews.lazy.compactMap(findTable).first
            }
            if let table = findTable(content.debugImportHost) { controller.window?.makeFirstResponder(table) }
        case "importcheck":
            // importcheck|none, importcheck|new, or importcheck|name,name
            let model = content.importModel
            let clips = app.cards.cards.flatMap(\.clips)
            model.userEditedSelection = true
            switch parts[1] {
            case "none": model.checked = []
            case "new": model.checked = Set(clips.filter { app.cards.presence[$0.id]?.isNew ?? true }.map(\.id))
            default:
                let names = Set(parts[1].split(separator: ",").map(String.init))
                model.checked = Set(clips.filter { names.contains($0.name) }.map(\.id))
            }
            return "checked \(model.checked.count)"
        case "importrun":
            // importrun|project, importrun|archive, or importrun|folder|path. Uses the panel's selection and card.
            let model = content.importModel
            guard let card = app.cards.cards.first(where: { $0.id == model.cardID }) ?? app.cards.cards.first else { return "no card" }
            let clips = card.clips.filter { model.checked.contains($0.id) }
            let target: ImportTarget
            switch parts[1] {
            case "archive": target = .archive
            case "folder": target = .exactFolder(URL(fileURLWithPath: parts[2], isDirectory: true))
            default:
                guard let folder = controller.tab.folder else { return "no folder" }
                target = .project(folder)
            }
            return "started=\(app.startImport(clips, card: card, target: target, from: controller)) clips=\(clips.count)"
        case "queuectl":
            switch parts[1] {
            case "pause": app.queue.setPaused(true)
            case "resume": app.queue.setPaused(false)
            case "cancel": app.queue.cancelAll()
            case "retry": app.queue.retryFailed()
            case "clear": app.queue.clearFinished()
            default: return "unknown"
            }
        case "queue":
            var lines = ["active=\(app.queue.isActive) paused=\(app.queue.isPaused) done=\(app.queue.doneCount) failed=\(app.queue.failedCount) \(app.queue.completedBytes)/\(app.queue.totalBytes) speed=\(Int(app.queue.bytesPerSecond))"]
            lines += app.queue.jobs.map { "  \($0.clip.name) \($0.state)" }
            return lines.joined(separator: "\n")
        case "cards":
            var lines = ["ready=\(app.cards.isPresenceReady) panel=\(controller.tab.isImportPanelVisible) checked=\(content.importModel.checked.count)"]
            for card in app.cards.cards {
                lines.append("card \(card.volumeName) model=\(card.cameraModel ?? "nil") device=\(card.deviceFolder ?? "nil") new=\(app.cards.newClipCount(in: card))")
                for group in ClipGrouping.groups(card.clips) {
                    lines.append(" group \(group.title) clips=\(group.clips.count)")
                    for clip in group.clips {
                        let status = app.cards.presence[clip.id]?.status(currentFolder: controller.tab.folder, projectRoot: app.projectRootURL, mediaRoot: app.mediaRootURL)
                        lines.append("  \(clip.name) \(ImportFormat.details(clip)) status=\(String(describing: status))")
                    }
                }
            }
            return lines.joined(separator: "\n")
        case "eject":
            guard let card = app.cards.cards.first(where: { $0.volumeName == parts[1] }) else { return "no card" }
            app.eject(card, from: controller)
        case "ejectstate":
            return "ejecting=\(app.ejectingCardIDs.count) cards=\(app.cards.cards.map(\.volumeName)) sounds=\(debugPlayedSounds) duration=\(debugLastEjectDuration.map { "\($0)" } ?? "nil")"
        #if UPDATER_TEST
        case "updatecheck":
            return UpdateController.shared.debugCheckInBackground()
        case "quit":
            NSApp.terminate(nil)
        #endif
        case "closeall":
            // What the red button does to a window of tabs.
            app.controllers.forEach { $0.window?.close() }
            return "controllers=\(app.controllers.count)"
        case "closetab":
            controller.window?.close()
        case "renameprompt":
            // Opens the sheet for a project, as the sidebar's menu item does.
            guard let project = app.projects.first(where: { $0.title == parts[1] }) else { return "not found" }
            let menu = controller.folderContextMenu(for: project.url)
            guard let index = menu.items.firstIndex(where: { $0.title == "Rename…" }) else { return "no menu item" }
            menu.performActionForItem(at: index)
        case "renamesheet":
            // renamesheet|name|date: fills in the open sheet and presses Rename. renamesheet alone reports it.
            guard let sheet = controller.window?.attachedSheet,
                  let fields = sheet.contentView?.debugTextFields.filter(\.isEditable),
                  let date = fields.first(where: { $0.placeholderString == "YYYY-MM-DD" }),
                  let name = fields.first(where: { $0 !== date }),
                  let button = sheet.contentView?.debugButtons.first(where: { $0.title == "Rename" }) else { return "no sheet" }
            guard parts.count > 1 else { return "date=\(date.stringValue) name=\(name.stringValue) nameFirst=\(sheet.initialFirstResponder === name)" }
            name.stringValue = parts[1]
            if parts.count > 2 { date.stringValue = parts[2] }
            button.performClick(nil)
        case "newprojectsheet":
            // newprojectsheet|name|date: fills in the open sheet and presses Create. newprojectsheet alone reports it.
            guard let sheet = controller.window?.attachedSheet,
                  let fields = sheet.contentView?.debugTextFields.filter(\.isEditable),
                  let date = fields.first(where: { $0.placeholderString == "YYYY-MM-DD" }),
                  let name = fields.first(where: { $0 !== date }),
                  let button = sheet.contentView?.debugButtons.first(where: { $0.title == "Create" }) else { return "no sheet" }
            let labels = sheet.contentView?.debugTextFields.filter { !$0.isEditable }.map(\.stringValue) ?? []
            guard parts.count > 1 else { return "date=\(date.stringValue) name=\(name.stringValue) nameFirst=\(sheet.initialFirstResponder === name) labels=\(labels) key=\(button.keyEquivalent == "\r")" }
            name.stringValue = parts[1]
            if parts.count > 2 { date.stringValue = parts[2] }
            button.performClick(nil)
        case "sheetstate":
            // Both levels, because a refused new project reports over its still-open sheet.
            let sheet = controller.window?.attachedSheet
            let nested = sheet?.attachedSheet
            return "sheet=\(sheet?.contentView?.debugTextFields.map(\.stringValue) ?? []) nested=\(nested?.contentView?.debugTextFields.map(\.stringValue) ?? [])"
        case "sheetkey":
            // sheetkey|return or esc: a real key event through the sheet, focused on its name field.
            guard let sheet = controller.window?.attachedSheet,
                  let event = NSEvent.keyEvent(
                      with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: sheet.windowNumber, context: nil,
                      characters: parts[1] == "esc" ? "\u{1b}" : "\r", charactersIgnoringModifiers: parts[1] == "esc" ? "\u{1b}" : "\r",
                      isARepeat: false, keyCode: parts[1] == "esc" ? 53 : 36
                  ) else { return "no sheet" }
            // Through the application, which offers it as a key equivalent first, the way a real key arrives.
            NSApp.activate()
            sheet.makeKey()
            NSApp.sendEvent(event)
            return "keyEquivalent=\(sheet.contentView?.debugButtons.map { "\($0.title):\($0.keyEquivalent.debugDescription)" } ?? []) responder=\(sheet.firstResponder.map { String(describing: type(of: $0)) } ?? "none") default=\(sheet.defaultButtonCell?.title ?? "none")"
        case "dismissnested":
            guard let sheet = controller.window?.attachedSheet, let nested = sheet.attachedSheet else { return "no nested sheet" }
            sheet.endSheet(nested)
        case "renametoday":
            // Presses Today in the open sheet, and reports where the date row's views landed.
            guard let sheet = controller.window?.attachedSheet, let view = sheet.contentView,
                  let button = view.debugButtons.first(where: { $0.title == "Today" }),
                  let date = view.debugTextFields.first(where: { $0.placeholderString == "YYYY-MM-DD" }),
                  let name = view.debugTextFields.first(where: { $0.isEditable && $0.placeholderString == nil }) else { return "no button" }
            view.layoutSubtreeIfNeeded()
            let frames = "date=\(date.convert(date.bounds, to: view)) today=\(button.convert(button.bounds, to: view)) name=\(name.convert(name.bounds, to: view)) sheet=\(view.bounds.size)"
            button.performClick(nil)
            return "value=\(date.stringValue) \(frames)"
        case "snapsheet":
            guard let view = controller.window?.attachedSheet?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return "no sheet" }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: parts[1]))
        case "renamestate":
            let sheet = controller.window?.attachedSheet
            return "sheet=\(sheet?.contentView?.debugTextFields.map(\.stringValue) ?? []) projects=\(app.projects.map(\.folderName)) tabs=\(app.controllers.map { $0.tab.folder?.lastPathComponent ?? "blank" }) favorites=\(app.settings.favorites.map { ($0 as NSString).lastPathComponent }) title=\(controller.window?.title ?? "") panels=\(app.controllers.map(\.tab.isImportPanelVisible))"
        case "dismisssheet":
            guard let sheet = controller.window?.attachedSheet else { return "no sheet" }
            controller.window?.endSheet(sheet)
        case "openstate":
            return (content.debugSectionsHost?.stack.panes ?? []).filter { !$0.browser.openPath.isEmpty }.map { "\($0.section.id.split(separator: "/").suffix(2).joined(separator: "/")) -> \($0.browser.openPath.map { $0.split(separator: "/").suffix(2).joined(separator: "/") })" }.joined(separator: "; ")
        case "stallstart":
            debugStallWatch.start()
        case "stallreport":
            return debugStallWatch.report()
        case "snapimport":
            guard let host = content.debugImportHost, let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return "no panel" }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: parts[1]))
        case "maximize":
            guard let pane = content.debugPane(parts[1]) else { return "not found" }
            content.debugStack?.toggleMaximize(pane)
        case "resize":
            controller.window?.setContentSize(NSSize(width: Double(parts[1]) ?? 1320, height: Double(parts[2]) ?? 860))
        case "snapshot":
            return snapshot(controller, to: parts[1])
        case "state":
            return state()
        case "tree":
            guard let pane = content.debugPane(parts[1]) else { return "not found" }
            return tree(pane, depth: 0, limit: Int(parts[safe: 2] ?? "") ?? 6)
        case "snaptable":
            guard let table = content.debugBrowser(parts[1])?.columns[safe: Int(parts[2]) ?? 0]?.tableView,
                  let rep = table.bitmapImageRepForCachingDisplay(in: table.visibleRect) else { return "not found" }
            table.cacheDisplay(in: table.visibleRect, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: parts[3]))
            return "ok"
        case "snapview":
            guard let pane = content.debugPane(parts[1]),
                  let rep = pane.bitmapImageRepForCachingDisplay(in: pane.bounds) else { return "not found" }
            pane.cacheDisplay(in: pane.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: parts[2]))
            return "ok"
        case "scrollx":
            // scrollx|section title|column index|delta: a real two-finger swipe, sent through hit testing.
            guard let browser = content.debugBrowser(parts[1]), let column = browser.columns[safe: Int(parts[2]) ?? 0],
                  let window = controller.window else { return "not found" }
            let point = column.convert(NSPoint(x: column.bounds.midX, y: column.bounds.midY), to: nil)
            let delta = Int32(parts[3]) ?? 0
            let screen = window.convertPoint(toScreen: point)
            let flipped = CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.height ?? 0) - screen.y)
            // A mouse wheel has no phases. A trackpad swipe begins, changes, then ends.
            let phases: [Int64] = parts[safe: 4] == "wheel" ? [0, 0, 0] : [1, 2, 2, 2, 4]
            // A real swipe starts with a little vertical movement.
            var wobble: Int32 = parts[safe: 4] == "diagonal" ? 2 : 0
            var log: [String] = []
            for phase in phases {
                guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: phase == 4 ? 0 : wobble, wheel2: phase == 1 || phase == 4 ? 0 : delta, wheel3: 0) else { continue }
                cg.location = flipped
                cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
                wobble = 0
                guard let event = NSEvent(cgEvent: cg) else { continue }
                log.append("dx=\(event.scrollingDeltaX) phase=\(event.phase.rawValue) hit=\(window.contentView.flatMap { $0.hitTest(event.locationInWindow) }.map { String(describing: type(of: $0)) } ?? "nil")")
                window.sendEvent(event)
            }
            return browser.debugScrollState + " " + (log.first ?? "")
        case "scrollstate":
            return content.debugBrowser(parts[1])?.debugScrollState ?? "not found"
        case "scrollleft":
            guard let browser = content.debugBrowser(parts[1]) else { return "not found" }
            browser.debugScroll(toX: Double(parts[2]) ?? 0)
            return browser.debugScrollState
        case "playkey":
            // playkey|space, j, k, l|down or up: goes through the same path as a real key.
            let codes: [String: UInt16] = ["space": 49, "j": 38, "k": 40, "l": 37, "f": 3, "p": 35, "esc": 53, "down": 125]
            guard let code = codes[parts[1]], let window = controller.window,
                  let event = NSEvent.keyEvent(
                    with: parts[safe: 2] == "up" ? .keyUp : .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: (NSApp.windows.first { $0.isVisible && $0.level == .statusBar } ?? window).windowNumber, context: nil,
                    characters: parts[1] == "down" ? "\u{F701}" : "", charactersIgnoringModifiers: parts[1] == "down" ? "\u{F701}" : "", isARepeat: false, keyCode: code
                  ) else { return "not found" }
            return "handled=\(controller.handleShortcutKey(event)) responder=\(window.firstResponder.map { NSStringFromClass(type(of: $0)) } ?? "nil")"
        case "playstate":
            let playback = controller.tab.playback
            let item = playback.player.currentItem
            return "url=\(playback.url?.lastPathComponent ?? "nil") loaded=\(playback.isLoaded) rate=\(playback.rate) playerRate=\(playback.player.rate) time=\(String(format: "%.3f", playback.time)) playerTime=\(String(format: "%.3f", playback.player.currentTime().seconds)) failed=\(playback.failed) status=\(item?.status.rawValue ?? -1) reverse=\(item?.canPlayReverse ?? false) fastReverse=\(item?.canPlayFastReverse ?? false) fastForward=\(item?.canPlayFastForward ?? false) stepBack=\(item?.canStepBackward ?? false)"
        case "fullscreen":
            controller.toggleFullScreenPreview()
        case "fsstate":
            let preview = NSApp.windows.first { $0.level == .statusBar }
            return "screens=\(NSScreen.screens.map(\.localizedName)) ids=\(NSScreen.screens.map { $0.stableID ?? "nil" }) open=\(controller.isFullScreenPreviewOpen) visible=\(preview?.isVisible ?? false) frame=\(preview?.frame ?? .zero) screen=\(controller.window?.screen?.frame ?? .zero) key=\(preview?.isKeyWindow ?? false) selection=\(controller.tab.selection.map(\.name))"
        case "forgetcards":
            app.cards.debugForgetCards()
        case "rescancards":
            app.cards.rescanVolumes()
        case "snapfs":
            guard let view = NSApp.windows.first(where: { $0.level == .statusBar })?.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return "no window" }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: parts[1]))
        case "tagitem":
            return "open=\(controller.tab.isImportPanelVisible) enabled=\(controller.debugImportItem?.isEnabled ?? false) tip=\(controller.debugImportItem?.toolTip ?? "") card=\(controller.tab.importCardID ?? "nil")"
        case "tagmenu":
            guard let item = controller.tab.selection.first else { return "no selection" }
            let menu = NSMenu()
            controller.addTagItems(to: menu, for: [item.url])
            return menu.items.map { entry -> String in
                if let palette = entry.submenu, palette.presentationStyle == .palette {
                    return "palette[" + palette.items.map { "\($0.title):\($0.state.rawValue)" }.joined(separator: " ") + "] mode=\(palette.selectionMode.rawValue)"
                }
                return entry.title + "{" + (entry.submenu?.items.map { "\($0.title):\($0.state.rawValue)" }.joined(separator: " ") ?? "") + "}"
            }.joined(separator: " ")
        case "tagcolor":
            // tagcolor|Green|on or off: what clicking a dot does.
            guard let tag = FinderTags.standardTags(labels: NSWorkspace.shared.fileLabels).first(where: { $0.name == parts[1] }) else { return "not found" }
            controller.setColor(of: tag, enabled: parts[2] == "on", on: controller.tab.selection.map(\.url))
        case "tagchoose":
            // Chooses an item from More Tags for the selection, as a click does.
            let menu = NSMenu()
            controller.addTagItems(to: menu, for: controller.tab.selection.map(\.url))
            guard let more = menu.items.first(where: { $0.title == "More Tags" })?.submenu,
                  let index = more.items.firstIndex(where: { $0.title == parts[1] }) else { return "not found" }
            more.performActionForItem(at: index)
        case "tabtags":
            // What the tab bar really draws, so the title can match a tab without tags.
            func fields(in view: NSView) -> [NSTextField] {
                view.subviews.flatMap { ($0 as? NSTextField).map { [$0] } ?? fields(in: $0) }
            }
            let root = controller.window?.contentView?.superview ?? NSView()
            let lines = fields(in: root).map { field in
                let text = field.attributedStringValue
                let runs = (0..<text.length).map { index -> String in
                    let attributes = text.attributes(at: index, effectiveRange: nil)
                    return "\((attributes[.font] as? NSFont).map { "\($0.fontName) \($0.pointSize)" } ?? "nofont") \(attributes[.foregroundColor].map { "\($0)" } ?? "nocolor")"
                }
                return "\(field.stringValue) frame=\(field.frame) textColor=\(field.textColor.map { "\($0)" } ?? "nil") font=\(field.font.map { "\($0.fontName) \($0.pointSize)" } ?? "nil") runs=\(Set(runs))"
            }
            return "attributed=\(controller.window?.tab.attributedTitle?.string ?? "nil") title=\(controller.window?.tab.title ?? "")\n" + lines.joined(separator: "\n")
        case "snaptabs":
            // Draws the title bar, tabs included, to a file.
            guard let frame = controller.window?.contentView?.superview else { return "no frame" }
            let bar = NSRect(x: 0, y: frame.bounds.height - 120, width: frame.bounds.width, height: 120)
            guard let rep = frame.bitmapImageRepForCachingDisplay(in: bar) else { return "no rep" }
            frame.cacheDisplay(in: bar, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: parts[1]))
            return "ok"
        case "sidebarrows":
            // The frames the sidebar's rows really have.
            guard let table = controller.debugSidebarView?.debugFirstTable else { return "no table" }
            return "rows=\(table.numberOfRows) projects=\(app.projects.count)\n" + (0..<min(table.numberOfRows, 9)).map { row -> String in
                let rowView = table.rowView(atRow: row, makeIfNecessary: false)
                let cell = rowView?.subviews.first
                return "row\(row) \(rowView?.frame ?? .zero) cell \(cell?.frame ?? .zero) clips \(cell?.clipsToBounds ?? false)"
            }.joined(separator: "\n")
        case "plus":
            controller.newWindowForTab(nil)
        case "projectclick":
            // Opens a project the way the new-tab page's row does.
            guard let project = app.projects.first(where: { $0.title == parts[1] }) else { return "not found" }
            app.open(project.url, from: controller)
        case "tabcount":
            return "tabs=\(controller.window?.tabbedWindows?.count ?? 1) folder=\(controller.tab.folder?.lastPathComponent ?? "nil") controllers=\(app.controllers.count)"
        case "sidebarhit":
            // Sends a real secondary click to the sidebar row and reports the menu that comes up.
            guard let table = controller.debugSidebarView?.debugFirstTable, let window = controller.window else { return "no table" }
            let row = Int(parts[1]) ?? 0
            let rect = table.rect(ofRow: row)
            let point = table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
            guard let event = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return "no event" }
            debugLastRowMenu = nil
            let timer = Timer(timeInterval: 0.4, repeats: false) { _ in
                MainActor.assumeIsolated { debugLastRowMenu?.cancelTrackingWithoutAnimation() }
            }
            RunLoop.main.add(timer, forMode: .common)
            // Posted, not sent, so it's the app's current event, as a real click is.
            NSApp.postEvent(event, atStart: false)
        case "sidebarmenu":
            return debugLastRowMenu?.items.map { $0.isSeparatorItem ? "-" : ($0.submenu?.presentationStyle == .palette ? "[palette \($0.submenu?.items.count ?? 0)]" : $0.title) }.joined(separator: " , ") ?? "no menu"
        case "sidebarinsets":
            // The right-click area is padded to match the selection, so its frame shows where it lands in each row.
            guard let table = controller.debugSidebarView?.debugFirstTable else { return "no table" }
            if parts[safe: 1] == "dump", let index = Int(parts[safe: 2] ?? ""), index < table.numberOfRows, let row = table.rowView(atRow: index, makeIfNecessary: false) {
                func dump(_ view: NSView, _ depth: Int) -> [String] {
                    ["\(String(repeating: " ", count: depth))\(type(of: view)) \(view.frame) clips=\(view.clipsToBounds)"] + view.subviews.flatMap { dump($0, depth + 1) }
                }
                return dump(row, 0).prefix(30).joined(separator: "\n")
            }
            return (0..<min(table.numberOfRows, 8)).compactMap { row -> String? in
                guard let rowView = table.rowView(atRow: row, makeIfNecessary: false),
                      let catcher = rowView.debugFirstCatcher else { return nil }
                return "row\(row) rowSize=\(rowView.bounds.size) menuArea=\(catcher.convert(catcher.bounds, to: rowView)) selected=\(rowView.isSelected)"
            }.joined(separator: "\n")
        case "contentviews":
            func walk(_ view: NSView, _ depth: Int) -> [String] {
                guard depth < 9 else { return [] }
                let title = (view as? NSButton)?.title ?? ""
                return ["\(String(repeating: " ", count: depth))\(String(describing: type(of: view)).prefix(50)) \(view.convert(view.bounds, to: nil)) \(title)"] + view.subviews.flatMap { walk($0, depth + 1) }
            }
            return walk(content.view, 0).prefix(24).joined(separator: "\n")
        case "snapsidebar":
            guard let view = controller.debugSidebarView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return "no view" }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: parts[1]))
        case "snapcontent":
            let view = content.view
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return "no view" }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: parts[1]))
        case "tagpalette":
            // Clicks a dot, through the palette's own handler.
            let menu = NSMenu()
            controller.addTagItems(to: menu, for: controller.tab.selection.map(\.url))
            guard let palette = menu.items.first?.submenu,
                  let index = palette.items.firstIndex(where: { $0.title == parts[1] }) else { return "not found" }
            palette.performActionForItem(at: index)
            return "state=\(palette.items[index].state.rawValue)"
        case "fschoose":
            NSApp.windows.first { $0.level == .statusBar }.map { _ in controller.debugChooseScreen() }
        case "reversegeom":
            return controller.tab.playback.debugSurfaceGeometry
        case "reversereport":
            let frames = controller.tab.playback.debugReverseFrames
            guard frames.count > 1 else { return "frames=\(frames.count)" }
            let settled = frames.dropFirst(5)
            let gaps = zip(settled, settled.dropFirst()).map { ($1.clock - $0.clock) * 1000 }.sorted()
            let span = (settled.last?.clock ?? 0) - (settled.first?.clock ?? 0)
            let backward = zip(frames, frames.dropFirst()).allSatisfy { $1.time <= $0.time }
            let distinct = zip(frames, frames.dropFirst()).filter { $0.displayed != $1.displayed }.count
            return String(format: "frames=%d fps=%.1f median=%.1fms p95=%.1fms max=%.1fms source=%.3f..%.3f backward=%@ displayedChanges=%d", frames.count, Double(settled.count) / max(span, 0.001), gaps[gaps.count / 2], gaps[Int(Double(gaps.count) * 0.95)], gaps.last ?? 0, frames.first?.time ?? 0, frames.last?.time ?? 0, backward ? "yes" : "no", distinct)
        case "tags":
            let url = URL(fileURLWithPath: parts[1])
            return FinderTags.read(url).map { "\($0.name):\($0.colorIndex)" }.joined(separator: ",")
        case "seek":
            controller.tab.playback.seek(to: Double(parts[1]) ?? 0)
        case "inspector":
            guard let item = controller.debugInspectorItem else { return "no item" }
            if parts[safe: 1] == "collapse" { item.isCollapsed = true }
            return "sheet=\(controller.window?.attachedSheet != nil) collapsed=\(item.isCollapsed) width=\(Int(item.viewController.view.frame.width)) height=\(Int(item.viewController.view.frame.height)) window=\(Int(controller.window?.frame.width ?? 0))"
        case "snapinspector":
            guard let view = controller.debugInspectorItem?.viewController.view,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return "no view" }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: parts[1]))
        case "contextmenu":
            // contextmenu|section title|column index|row name|item title: selects the row and lists its menu, or runs one item.
            guard let column = content.debugBrowser(parts[1])?.columns[safe: Int(parts[2]) ?? 0],
                  let row = column.items.firstIndex(where: { $0.name == parts[3] }) else { return "not found" }
            column.tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            let menu = column.contextMenu()
            guard let title = parts[safe: 4] else { return menu.items.map { $0.isSeparatorItem ? "-" : $0.title }.joined(separator: " | ") }
            guard let item = menu.items.first(where: { $0.title == title }), let action = item.action else { return "no such item" }
            return "performed=\(NSApp.sendAction(action, to: item.target, from: item))"
        case "menu":
            // menu|new, rename, or trash: goes through validation, as the menu does.
            let actions: [String: Selector] = [
                "new": #selector(WorkspaceWindowController.newFolder(_:)),
                "rename": #selector(WorkspaceWindowController.renameSelection(_:)),
                "newproject": #selector(WorkspaceWindowController.newProject(_:)),
                "copy": #selector(WorkspaceWindowController.copy(_:)),
                "paste": #selector(WorkspaceWindowController.paste(_:)),
                "movehere": #selector(WorkspaceWindowController.moveItemsHere(_:)),
                "trash": #selector(WorkspaceWindowController.moveSelectionToTrash(_:)),
            ]
            guard let action = actions[parts[1]] else { return "unknown" }
            let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
            guard controller.validateMenuItem(item) else { return "disabled" }
            // Through the responder chain, as a menu does, without needing the app to be in front.
            guard controller.window?.firstResponder?.tryToPerform(action, with: item) == true else { return "unhandled" }
        case "type":
            // type|new name: commits the rename in progress.
            guard let editor = controller.window?.firstResponder as? NSTextView else { return "not editing" }
            let selected = (editor.string as NSString).substring(with: editor.selectedRange())
            editor.string = parts[1]
            editor.didChangeText()
            controller.window?.makeFirstResponder(nil)
            return "was selected=\(selected)"
        case "cancelrename":
            guard let editor = controller.window?.firstResponder as? NSTextView else { return "not editing" }
            editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        case "undo":
            controller.window?.undoManager?.undo()
            return "canRedo=\(controller.window?.undoManager?.canRedo ?? false)"
        case "redo":
            controller.window?.undoManager?.redo()
        case "responder":
            return String(describing: type(of: controller.window?.firstResponder as Any))
        case "save":
            app.saveNow()
        case "quit":
            NSApp.terminate(nil)
        default:
            return "unknown command"
        }
        return "ok"
    }

    private func snapshot(_ controller: WorkspaceWindowController, to path: String) -> String {
        guard let view = controller.window?.contentView else { return "no view" }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let scale = controller.window?.backingScaleFactor ?? 2
        guard let context = CGContext(
            data: nil, width: Int(view.bounds.width * scale), height: Int(view.bounds.height * scale),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let layer = view.layer else { return "no layer" }
        context.scaleBy(x: scale, y: scale)
        layer.render(in: context)
        guard let image = context.makeImage() else { return "no image" }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return "no png" }
        return (try? data.write(to: URL(fileURLWithPath: path))) == nil ? "write failed" : "ok \(rep.pixelsWide)x\(rep.pixelsHigh) visible=\(controller.window?.isVisible ?? false) occlusion=\(controller.window?.occlusionState.rawValue ?? 0)"
    }

    private func tree(_ view: NSView, depth: Int, limit: Int) -> String {
        var line = String(repeating: "  ", count: depth)
        line += "\(type(of: view)) \(view.frame) hidden=\(view.isHidden) alpha=\(view.alphaValue) layer=\(view.wantsLayer)"
        if let field = view as? NSTextField { line += " text=\(field.stringValue)" }
        guard depth < limit else { return line }
        return ([line] + view.subviews.map { tree($0, depth: depth + 1, limit: limit) }).joined(separator: "\n")
    }

    private func state() -> String {
        var lines = ["projects=\(app.projects.map { "\($0.folderName)\($0.tags.map(\.name))" })", "favorites=\(app.settings.favorites)"]
        for controller in app.controllers {
            let group = controller.window?.tabbedWindows?.count ?? 1
            lines.append("tab folder=\(controller.tab.folder?.lastPathComponent ?? "nil") selectedTags=\(controller.tab.selection.flatMap(\.tags).map(\.name)) mode=\(controller.tab.mode) tabsInGroup=\(group) selection=\(controller.tab.selection.map(\.name)) key=\(controller.window?.isKeyWindow ?? false) title=\(controller.window?.title ?? "")")
            for pane in controller.content.debugStack?.panes ?? [] {
                let columns = pane.browser.columns.map { "\($0.folderURL.lastPathComponent)[\($0.items.count)]w\(Int($0.frame.width))" }
                lines.append("  section \(pane.section.title) count=\(pane.count.map(String.init) ?? "nil") expanded=\(pane.isExpanded) h=\(Int(pane.frame.height)) y=\(Int(pane.frame.minY)) active=\(pane.header.isActive) columns=\(columns)")
            }
            if let browser = controller.content.debugSingle {
                lines.append("  single columns=\(browser.columns.map { "\($0.folderURL.lastPathComponent)[\($0.items.count)]" })")
            }
        }
        return lines.joined(separator: "\n")
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

extension ColumnBrowserView {
    var debugScrollState: String {
        let clip = debugScrollView.contentView
        return "x=\(Int(clip.bounds.minX)) clip=\(Int(clip.bounds.width)) document=\(Int(debugScrollView.documentView?.frame.width ?? 0)) columns=\(columns.count)"
    }

    func debugScroll(toX x: Double) {
        debugScrollView.contentView.scroll(to: NSPoint(x: x, y: 0))
        debugScrollView.reflectScrolledClipView(debugScrollView.contentView)
    }
}

/// Stands in for a real drag, which a script can't start.
private final class DebugDragInfo: NSObject, NSDraggingInfo {
    private static var nextSequence = 1
    let draggingPasteboard = NSPasteboard(name: NSPasteboard.Name("cc.raycal.ReelDock.debugDrag"))
    let draggingSourceOperationMask: NSDragOperation
    let draggingLocation: NSPoint
    let draggingSequenceNumber: Int
    var draggingDestinationWindow: NSWindow? { nil }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    var draggingFormation: NSDraggingFormation = .default
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    init(files: [String], mask: String, location: NSPoint) {
        draggingSourceOperationMask = switch mask {
        case "option": .copy
        case "command": .generic
        default: [.copy, .move, .generic]
        }
        draggingLocation = location
        draggingSequenceNumber = Self.nextSequence
        Self.nextSequence += 1
        draggingPasteboard.clearContents()
        draggingPasteboard.writeObjects(files.map { URL(fileURLWithPath: $0) as NSURL })
    }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?, classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any], using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}

private extension NSDragOperation {
    var debugName: String {
        if isEmpty { return "none" }
        if contains(.copy) { return "copy" }
        if contains(.move) { return "move" }
        if contains(.generic) { return "generic" }
        return "other"
    }
}

extension TabContentViewController {
    var debugStack: SectionStackView? { debugSectionsHost?.stack }

    func debugPane(_ title: String) -> SectionPaneView? {
        debugStack?.panes.first { $0.section.title == title }
    }

    func debugBrowser(_ title: String) -> ColumnBrowserView? {
        title == "single" ? debugSingle : debugPane(title)?.browser
    }
}

private extension NSView {
    var debugFirstCatcher: NSView? {
        if String(describing: type(of: self)).contains("CatcherView") { return self }
        for view in subviews {
            if let catcher = view.debugFirstCatcher { return catcher }
        }
        return nil
    }

    var debugFirstTable: NSTableView? {
        if let table = self as? NSTableView, table.numberOfRows > 0 { return table }
        for view in subviews {
            if let table = view.debugFirstTable { return table }
        }
        return nil
    }
}

/// Measures the longest time the main thread went without running a timer.
let debugStallWatch = DebugStallWatch()

final class DebugStallWatch {
    private var timer: Timer?
    private var last = ContinuousClock.now
    private var longest = Duration.zero

    func start() {
        timer?.invalidate()
        last = .now
        longest = .zero
        let timer = Timer(timeInterval: 0.005, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let now = ContinuousClock.now
        longest = max(longest, now - last)
        last = now
    }

    func report() -> String {
        timer?.invalidate()
        timer = nil
        return "longestMainThreadGap=\(longest)"
    }
}

private extension NSView {
    func debugAll<T: NSView>(_ type: T.Type) -> [T] {
        subviews.flatMap { ($0 as? T).map { [$0] } ?? $0.debugAll(type) }
    }

    var debugTextFields: [NSTextField] { debugAll(NSTextField.self) }
    var debugButtons: [NSButton] { debugAll(NSButton.self) }
}
#endif
