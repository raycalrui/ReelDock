import AppKit
import Observation

@Observable
final class TabModel {
    var folder: URL?
    var mode: BrowserMode = .sections
    var selection: [FolderItem] = [] {
        didSet { playback.follow(selection) }
    }
    let playback = PlaybackController()
    /// Where the inspector's preview sits, so full screen can zoom out of it.
    @ObservationIgnored weak var previewAnchor: NSView?
    var isImportPanelVisible = false
    var importCardID: String?
}

enum ImportTarget {
    /// The folder's video section, or the folder itself if it isn't a project.
    case project(URL)
    case exactFolder(URL)
    case archive
}

@Observable
final class AppModel {
    private(set) var settings: AppSettings
    private(set) var projects: [ProjectEntry] = []
    private(set) var projectRootIsMissing = false
    /// Changes when tags are written, for views that read tags directly.
    private(set) var tagsGeneration = 0

    let cards: CardMonitor
    let queue: ImportQueue

    @ObservationIgnored private let store: SettingsStore
    @ObservationIgnored private var rootWatcher: FolderWatcher?
    @ObservationIgnored private var saveWork: DispatchWorkItem?
    @ObservationIgnored private var knownCardIDs: Set<String> = []
    @ObservationIgnored private(set) var controllers: [WorkspaceWindowController] = []

    init(store: SettingsStore = SettingsStore(directory: SettingsStore.standardDirectory)) {
        self.store = store
        let loaded = store.load()
        settings = loaded

        let ledger = ImportLedger(fileURL: store.directory.appendingPathComponent("import-ledger.jsonl"))
        let registry = PartFileRegistry(fileURL: store.directory.appendingPathComponent("in-progress.json"))
        registry.removeLeftovers()

        var currentRoots: (() -> (project: URL?, media: URL?))?
        let monitor = CardMonitor(ledger: ledger) { currentRoots?() ?? (nil, nil) }
        cards = monitor
        queue = ImportQueue(ledger: ledger, registry: registry, cards: monitor)
        currentRoots = { [weak self] in (self?.projectRootURL, self?.mediaRootURL) }

        monitor.onCardsChanged = { [weak self] in self?.cardsDidChange($0) }
        watchProjectRoot()
        monitor.start()
    }

    var projectRootURL: URL? {
        settings.projectRoot.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    var mediaRootURL: URL? {
        settings.mediaRoot.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    // MARK: Project root

    func chooseProjectRoot(from controller: WorkspaceWindowController?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose"
        panel.message = "Choose the folder that contains your video projects."
        panel.directoryURL = projectRootURL
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.setProjectRoot(url)
        }
        if let window = controller?.window {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(panel.runModal())
        }
    }

    func setProjectRoot(_ url: URL) {
        settings.projectRoot = url.path
        saveNow()
        watchProjectRoot()
        for controller in controllers where controller.tab.folder == nil {
            controller.content.display()
        }
    }

    private func watchProjectRoot() {
        rootWatcher = nil
        guard let root = projectRootURL else {
            projects = []
            projectRootIsMissing = false
            return
        }
        let path = root.canonicalPath
        rootWatcher = FolderWatcher(path: path) { [weak self] change in
            if change.needsFullRescan || change.rootChanged || change.directories.contains(path) {
                self?.reloadProjects()
            }
        }
        reloadProjects()
    }

    func reloadProjects() {
        guard let root = projectRootURL else { return }
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                try? ProjectCatalog.list(root: root)
            }.value
            projects = result ?? []
            projectRootIsMissing = result == nil
        }
    }

    // MARK: Tags

    func tagChoices(forCurrentTags current: [[FinderTag]]) -> [TagChoice] {
        FinderTags.choices(
            standard: FinderTags.standardTags(labels: NSWorkspace.shared.fileLabels),
            seen: projects.flatMap(\.tags),
            current: current
        )
    }

    func tagsDidChange() {
        tagsGeneration += 1
        reloadProjects()
        controllers.forEach { $0.content.reloadFolderContents() }
    }

    // MARK: Cards

    /// Every window updates. Only a newly inserted card opens a panel, and only in the front window.
    private func cardsDidChange(_ cards: [CameraCard]) {
        let inserted = cards.first { !knownCardIDs.contains($0.id) }
        knownCardIDs = Set(cards.map(\.id))
        controllers.forEach { $0.cardsDidChange() }
        guard let inserted else { return }
        let target = frontController ?? addWindow()
        if !target.tab.isImportPanelVisible {
            target.showImportPanel(cardID: inserted.id)
        }
    }

    private var frontController: WorkspaceWindowController? {
        NSApp.orderedWindows.lazy.compactMap { $0.windowController as? WorkspaceWindowController }.first
    }

    // MARK: Import

    func chooseMediaRoot(from controller: WorkspaceWindowController?, completion: ((URL) -> Void)? = nil) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose"
        panel.message = "Choose your personal archive folder. Clips go into YYYYMM/video/<camera> inside it."
        panel.directoryURL = mediaRootURL ?? projectRootURL?.deletingLastPathComponent()
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.settings.mediaRoot = url.path
            self?.saveNow()
            self?.cards.refreshPresence()
            completion?(url)
        }
        if let window = controller?.window {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(panel.runModal())
        }
    }

    func chooseImportFolder(from controller: WorkspaceWindowController?, completion: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Import Here"
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            if response == .OK, let url = panel.url { completion(url) }
        }
        if let window = controller?.window {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(panel.runModal())
        }
    }

    /// Resolves the destination, checks free space, and queues the clips. Returns false if nothing was queued.
    @discardableResult
    func startImport(_ clips: [CardClip], card: CameraCard, target: ImportTarget, from controller: WorkspaceWindowController?) -> Bool {
        guard !clips.isEmpty else { return false }
        let destination: ImportDestination

        switch target {
        case let .exactFolder(folder):
            destination = .folder(folder)
        case let .project(folder):
            if let video = ImportRouting.videoFolder(inProject: folder) {
                destination = .folder(video)
            } else if folder.deletingLastPathComponent().canonicalPath == projectRootURL?.canonicalPath {
                // A project without a video folder: ask rather than guess.
                chooseImportFolder(from: controller) { [weak self] chosen in
                    self?.startImport(clips, card: card, target: .exactFolder(chosen), from: controller)
                }
                return false
            } else {
                destination = .folder(folder)
            }
        case .archive:
            guard let mediaRoot = mediaRootURL else {
                chooseMediaRoot(from: controller) { [weak self] _ in
                    self?.startImport(clips, card: card, target: .archive, from: controller)
                }
                return false
            }
            guard let device = card.deviceFolder ?? askForDeviceFolder(card: card) else { return false }
            destination = .archive(mediaRoot: mediaRoot, deviceFolder: device)
        }

        let needed = clips.reduce(0) { $0 + $1.size } + queue.remainingBytes
        guard ImportRouting.hasEnoughSpace(needed, at: destination.volumeProbe) else {
            showAlert(
                "Not enough space",
                "These clips need \(ImportFormat.bytes(needed)), which is more than the destination has free. Nothing was copied.",
                controller
            )
            return false
        }
        queue.enqueue(clips, cardID: card.id) { _ in destination }
        return true
    }

    /// A camera with no known folder name asks once per import. Only a single folder name is accepted.
    private func askForDeviceFolder(card: CameraCard) -> String? {
        let alert = NSAlert()
        alert.messageText = "Which camera folder should these clips go in?"
        alert.informativeText = "\(card.cameraModel ?? "This camera") isn't a known camera. Clips go into YYYYMM/video/<this folder> in your personal archive."
        let field = NSTextField(string: card.cameraModel ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Import")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.contains("/"), !name.hasPrefix(".") else { return nil }
        return name
    }

    func eject(_ card: CameraCard, from controller: WorkspaceWindowController?) {
        guard !queue.isActive(cardID: card.id) else { return }
        // An open clip would keep the volume busy.
        controllers.forEach { $0.tab.playback.release(under: card.volumeURL) }
        attemptEject(card, from: controller, retriesLeft: 5)
    }

    /// The player closes its file a moment after being released, so the first attempt can find the card still busy.
    private func attemptEject(_ card: CameraCard, from controller: WorkspaceWindowController?, retriesLeft: Int) {
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: card.volumeURL)
        } catch {
            guard retriesLeft > 0 else {
                showAlert("Can't eject \(card.volumeName)", error.localizedDescription, controller)
                return
            }
            Task { [weak self, weak controller] in
                try? await Task.sleep(for: .milliseconds(400))
                self?.attemptEject(card, from: controller, retriesLeft: retriesLeft - 1)
            }
        }
    }

    private func showAlert(_ title: String, _ message: String, _ controller: WorkspaceWindowController?) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        if let window = controller?.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    // MARK: Opening

    func controller(showing url: URL) -> WorkspaceWindowController? {
        let path = url.canonicalPath
        return controllers.first { $0.tab.folder?.canonicalPath == path }
    }

    /// Opening something already open switches to its tab. Otherwise it replaces the current tab unless a new one is requested.
    func open(_ url: URL, from controller: WorkspaceWindowController?, newTab: Bool = false) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            let alert = NSAlert()
            alert.messageText = "\(url.lastPathComponent) can't be found"
            alert.informativeText = "It may have been moved or renamed."
            if let window = controller?.window {
                alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
            return
        }
        if let existing = self.controller(showing: url) {
            existing.window?.tabGroup?.selectedWindow = existing.window
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let target: WorkspaceWindowController
        if !newTab, let controller {
            target = controller
        } else if let controller, controller.tab.folder == nil {
            target = controller
        } else {
            target = addTab(after: controller)
        }
        target.show(folder: url, mode: SectionBuilder.defaultMode(for: url, projectRoot: projectRootURL))
        target.window?.makeKeyAndOrderFront(nil)
    }

    @discardableResult
    func addWindow() -> WorkspaceWindowController {
        let controller = WorkspaceWindowController(app: self)
        controllers.append(controller)
        controller.showWindow(nil)
        return controller
    }

    @discardableResult
    func addTab(after controller: WorkspaceWindowController?) -> WorkspaceWindowController {
        guard let host = controller?.window ?? NSApp.keyWindow, host.windowController is WorkspaceWindowController else {
            return addWindow()
        }
        let new = WorkspaceWindowController(app: self)
        controllers.append(new)
        if let window = new.window {
            host.addTabbedWindow(window, ordered: .above)
            window.makeKeyAndOrderFront(nil)
        }
        return new
    }

    func controllerDidClose(_ controller: WorkspaceWindowController) {
        controllers.removeAll { $0 === controller }
        scheduleSessionSave()
    }

    // MARK: Favorites

    func isFavorite(_ url: URL) -> Bool {
        settings.favorites.contains(url.path)
    }

    func toggleFavorite(_ url: URL) {
        if isFavorite(url) {
            settings.favorites.removeAll { $0 == url.path }
        } else {
            settings.favorites.append(url.path)
        }
        saveNow()
    }

    func addFavorites(_ urls: [URL]) {
        var isDirectory: ObjCBool = false
        for url in urls where !isFavorite(url) {
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                settings.favorites.append(url.path)
            }
        }
        saveNow()
    }

    func moveFavorites(from source: IndexSet, to destination: Int) {
        settings.favorites.move(fromOffsets: source, toOffset: destination)
        saveNow()
    }

    // MARK: Preferences

    /// The card panel's share of the content height.
    var importPanelFraction: CGFloat {
        settings.importPanelFraction.map { CGFloat($0) } ?? 0.5
    }

    func setImportPanelFraction(_ fraction: CGFloat) {
        settings.importPanelFraction = Double(fraction)
        scheduleSessionSave()
    }

    func updateSectionPreference(_ key: String, change: (inout SectionPreference) -> Void) {
        var preference = settings.sections[key] ?? SectionPreference()
        change(&preference)
        settings.sections[key] = preference
        scheduleSessionSave()
    }

    func toggleShowHidden() {
        settings.showHidden.toggle()
        saveNow()
        controllers.forEach { $0.content.reloadFolderContents() }
    }

    // MARK: Session

    func scheduleSessionSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.saveNow() }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    func saveNow() {
        saveWork?.cancel()
        settings.windows = currentWindowSnapshots()
        try? store.save(settings)
    }

    private func currentWindowSnapshots() -> [WindowSnapshot] {
        var seen = Set<ObjectIdentifier>()
        var result: [WindowSnapshot] = []
        for controller in controllers {
            guard let window = controller.window, !seen.contains(ObjectIdentifier(window)) else { continue }
            let group = window.tabbedWindows ?? [window]
            group.forEach { seen.insert(ObjectIdentifier($0)) }

            var tabs: [TabSnapshot] = []
            var selected = 0
            for member in group {
                guard let tabController = member.windowController as? WorkspaceWindowController,
                      let snapshot = tabController.content.snapshot() else { continue }
                if member == window.tabGroup?.selectedWindow { selected = tabs.count }
                tabs.append(snapshot)
            }
            if !tabs.isEmpty {
                result.append(WindowSnapshot(tabs: tabs, selectedTab: selected))
            }
        }
        return result
    }

    /// Reopens the saved windows and tabs, skipping folders that no longer exist.
    func restoreSession() {
        for saved in settings.windows {
            let tabs = saved.tabs.filter { FileManager.default.fileExists(atPath: $0.folderPath) }
            var created: [WorkspaceWindowController] = []
            for (index, snapshot) in tabs.enumerated() {
                let controller = index == 0 ? addWindow() : addTab(after: created[0])
                controller.show(
                    folder: URL(fileURLWithPath: snapshot.folderPath, isDirectory: true),
                    mode: snapshot.mode,
                    restoring: snapshot
                )
                created.append(controller)
            }
            if created.indices.contains(saved.selectedTab) {
                created[saved.selectedTab].window?.makeKeyAndOrderFront(nil)
            }
        }
        if controllers.isEmpty {
            addWindow()
        }
    }
}
