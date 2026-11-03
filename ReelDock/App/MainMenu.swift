import AppKit

enum MainMenu {
    static func build() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(submenu("ReelDock", appItems()))
        menu.addItem(submenu("File", fileItems()))
        menu.addItem(submenu("Edit", editItems()))
        menu.addItem(submenu("View", viewItems()))
        let window = submenu("Window", windowItems())
        menu.addItem(window)
        NSApp.windowsMenu = window.submenu
        return menu
    }

    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: title)
        items.forEach(submenu.addItem)
        item.submenu = submenu
        return item
    }

    private static func item(
        _ title: String,
        _ action: Selector?,
        _ key: String = "",
        _ modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    private static func appItems() -> [NSMenuItem] {
        [
            item("About ReelDock", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Choose Projects Folder…", #selector(WorkspaceWindowController.chooseProjectRoot(_:))),
            item("Choose Personal Archive Folder…", #selector(WorkspaceWindowController.chooseMediaRoot(_:))),
            .separator(),
            item("Hide ReelDock", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit ReelDock", #selector(NSApplication.terminate(_:)), "q"),
        ]
    }

    private static func fileItems() -> [NSMenuItem] {
        [
            item("New Tab", #selector(NSResponder.newWindowForTab(_:)), "t"),
            item("New Window", #selector(AppDelegate.newWindow(_:)), "n"),
            item("Open Folder…", #selector(WorkspaceWindowController.openFolder(_:)), "o"),
            item("Import from Card…", #selector(WorkspaceWindowController.showImport(_:)), "i"),
            .separator(),
            item("New Folder", #selector(WorkspaceWindowController.newFolder(_:)), "n", [.command, .shift]),
            item("Rename", #selector(WorkspaceWindowController.renameSelection(_:))),
            item("Move to Trash", #selector(WorkspaceWindowController.moveSelectionToTrash(_:)), "\u{8}"),
            .separator(),
            item("Add Folder to Favorites", #selector(WorkspaceWindowController.toggleFavorite(_:)), "d"),
            item("Reveal in Finder", #selector(WorkspaceWindowController.revealInFinder(_:)), "r", [.command, .shift]),
            .separator(),
            item("Close Tab", #selector(NSWindow.performClose(_:)), "w"),
        ]
    }

    private static func editItems() -> [NSMenuItem] {
        [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSResponder.selectAll(_:)), "a"),
        ]
    }

    private static func viewItems() -> [NSMenuItem] {
        [
            item("As Sections", #selector(WorkspaceWindowController.showSections(_:)), "1"),
            item("As Single Browser", #selector(WorkspaceWindowController.showSingleBrowser(_:)), "2"),
            .separator(),
            item("Show Hidden Files", #selector(WorkspaceWindowController.toggleHiddenFiles(_:)), ".", [.command, .shift]),
            .separator(),
            item("Toggle Sidebar", #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control]),
            item("Toggle Inspector", #selector(NSSplitViewController.toggleInspector(_:)), "i", [.command, .option]),
            .separator(),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ]
    }

    private static func windowItems() -> [NSMenuItem] {
        [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            .separator(),
            item("Show Previous Tab", #selector(NSWindow.selectPreviousTab(_:)), "[", [.command, .shift]),
            item("Show Next Tab", #selector(NSWindow.selectNextTab(_:)), "]", [.command, .shift]),
            .separator(),
            item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))),
        ]
    }
}
