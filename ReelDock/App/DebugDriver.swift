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
        guard let controller = current else { return "no window" }
        let content = controller.content
        switch parts[0] {
        case "open":
            app.open(URL(fileURLWithPath: parts[1], isDirectory: true), from: controller)
        case "newtab":
            app.open(URL(fileURLWithPath: parts[1], isDirectory: true), from: controller, newTab: true)
        case "mode":
            parts[1] == "single" ? controller.showSingleBrowser(nil) : controller.showSections(nil)
        case "hidden":
            controller.toggleHiddenFiles(nil)
        case "favorite":
            controller.toggleFavorite(nil)
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
            return "open=\(controller.isFullScreenPreviewOpen) visible=\(preview?.isVisible ?? false) frame=\(preview?.frame ?? .zero) screen=\(controller.window?.screen?.frame ?? .zero) key=\(preview?.isKeyWindow ?? false) selection=\(controller.tab.selection.map(\.name))"
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
            guard let menu = controller.tagMenu(for: [item.url]) else { return "no menu" }
            return menu.items.map { "\($0.title):\($0.state.rawValue)" }.joined(separator: " ")
        case "tagchoose":
            // Chooses an item from the tag menu of the selection, as a click does.
            guard let item = controller.tab.selection.first,
                  let menu = controller.tagMenu(for: controller.tab.selection.map(\.url)),
                  let index = menu.items.firstIndex(where: { $0.title == parts[1] }) ?? (item.name.isEmpty ? 0 : nil) else { return "not found" }
            menu.performActionForItem(at: index)
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
        case "menu":
            // menu|new, rename, or trash: goes through validation, as the menu does.
            let actions: [String: Selector] = [
                "new": #selector(WorkspaceWindowController.newFolder(_:)),
                "rename": #selector(WorkspaceWindowController.renameSelection(_:)),
                "trash": #selector(WorkspaceWindowController.moveSelectionToTrash(_:)),
            ]
            guard let action = actions[parts[1]] else { return "unknown" }
            let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
            guard controller.validateMenuItem(item) else { return "disabled" }
            NSApp.sendAction(action, to: controller, from: item)
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

extension TabContentViewController {
    var debugStack: SectionStackView? { debugSectionsHost?.stack }

    func debugPane(_ title: String) -> SectionPaneView? {
        debugStack?.panes.first { $0.section.title == title }
    }

    func debugBrowser(_ title: String) -> ColumnBrowserView? {
        title == "single" ? debugSingle : debugPane(title)?.browser
    }
}
#endif
