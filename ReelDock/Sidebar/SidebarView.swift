import AppKit
import SwiftUI

struct SidebarView: View {
    let app: AppModel
    let tab: TabModel
    weak var controller: WorkspaceWindowController?

    /// How far the list's selection reaches past a row's content, so a right-click anywhere on it opens the menu.
    private static let rowInsetX: CGFloat = 6
    private static let rowInsetY: CGFloat = 4

    @State private var filter = ""
    @AppStorage("sidebar.favoritesExpanded") private var favoritesExpanded = true
    @AppStorage("sidebar.projectsExpanded") private var projectsExpanded = true

    private var filteredProjects: [ProjectEntry] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return app.projects }
        return app.projects.filter { $0.folderName.localizedCaseInsensitiveContains(query) }
    }

    /// Paths open in Projects are highlighted there, not again under Favorites.
    private var selection: Binding<String?> {
        Binding(
            get: {
                guard let path = tab.folder?.path else { return nil }
                if app.projects.contains(where: { $0.url.path == path }) { return "project:\(path)" }
                if app.settings.favorites.contains(path) { return "favorite:\(path)" }
                return nil
            },
            set: { value in
                guard let value, let separator = value.firstIndex(of: ":") else { return }
                let path = String(value[value.index(after: separator)...])
                let newTab = NSEvent.modifierFlags.contains(.command)
                app.open(URL(fileURLWithPath: path, isDirectory: true), from: controller, newTab: newTab)
            }
        )
    }

    var body: some View {
        List(selection: selection) {
            if !app.cards.cards.isEmpty {
                Section("Cards") {
                    ForEach(app.cards.cards) { card in
                        cardRow(card)
                    }
                }
            }

            Section(isExpanded: $favoritesExpanded) {
                ForEach(app.settings.favorites, id: \.self) { path in
                    folderRow(path: path, tag: "favorite:\(path)", systemImage: "star")
                }
                .onMove { app.moveFavorites(from: $0, to: $1) }
                .dropDestination(for: URL.self) { urls, _ in
                    app.addFavorites(urls)
                }
                if app.settings.favorites.isEmpty {
                    Text("Drag folders here")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .dropDestination(for: URL.self) { urls, _ in
                            app.addFavorites(urls)
                            return true
                        }
                }
            } header: {
                Text("Favorites")
            }

            Section(isExpanded: $projectsExpanded) {
                if app.projectRootURL == nil {
                    Button("Choose Projects Folder…") { app.chooseProjectRoot(from: controller) }
                } else if app.projectRootIsMissing {
                    Text("Projects folder can't be read")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Choose Projects Folder…") { app.chooseProjectRoot(from: controller) }
                } else {
                    ForEach(filteredProjects) { project in
                        projectRow(project)
                    }
                }
            } header: {
                Text("Projects")
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            TextField("Filter Projects", text: $filter)
                .textFieldStyle(.roundedBorder)
                .controlSize(.regular)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
        }
    }

    private func cardRow(_ card: CameraCard) -> some View {
        let newClips = app.cards.newClipCount(in: card)
        let isOpen = tab.isImportPanelVisible && tab.importCardID == card.id
        // A button, not a selectable row: the open project keeps the sidebar's selection.
        return Button {
            controller?.toggleImportPanel(cardID: card.id)
        } label: {
            HStack {
                Label {
                    Text(card.volumeName).lineLimit(1)
                } icon: {
                    Image(systemName: isOpen ? "sdcard.fill" : "sdcard")
                        .foregroundStyle(isOpen ? Color.accentColor : Color.secondary)
                }
                Spacer()
                if app.queue.isActive(cardID: card.id) {
                    ProgressView().controlSize(.mini)
                } else if newClips > 0 {
                    Text("\(newClips) new")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Import…") { controller?.showImportPanel(cardID: card.id) }
            Button("Eject") { app.eject(card, from: controller) }
                .disabled(app.queue.isActive(cardID: card.id))
        }
    }

    private func projectRow(_ project: ProjectEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            LeadingTagDots(tags: project.tags)
            VStack(alignment: .leading, spacing: 1) {
                Text(project.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let date = project.displayDate {
                    Text(date)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .overlay {
            RowContextMenu { [weak controller] in controller?.folderContextMenu(for: project.url) }
                .padding(.horizontal, -Self.rowInsetX)
                .padding(.vertical, -Self.rowInsetY)
        }
        .tag("project:\(project.url.path)")
        .help(project.folderName)
    }

    private func folderRow(path: String, tag: String, systemImage: String) -> some View {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        // Favorites can be anywhere, so nothing else is watching them for tag changes.
        _ = app.tagsGeneration
        let tags = FinderTags.read(url)
        return Label {
            HStack(spacing: 6) {
                TagDots(tags: tags)
                Text(url.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } icon: {
            Image(systemName: systemImage)
        }
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay {
                RowContextMenu { [weak controller] in controller?.folderContextMenu(for: url) }
                    .padding(.horizontal, -Self.rowInsetX)
                    .padding(.vertical, -Self.rowInsetY)
            }
            .tag(tag)
            .help(path)
    }
}

#if DEBUG
var debugLastRowMenu: NSMenu?
#endif

/// Lets a SwiftUI row show an `NSMenu`, because SwiftUI context menus can't hold Finder's row of color dots.
/// Only secondary clicks land here, so ordinary clicks still reach the list.
private struct RowContextMenu: NSViewRepresentable {
    let makeMenu: () -> NSMenu?

    final class CatcherView: NSView {
        var makeMenu: (() -> NSMenu?)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent,
                  event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control)) else { return nil }
            return super.hitTest(point)
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            let menu = makeMenu?()
            #if DEBUG
            debugLastRowMenu = menu
            #endif
            return menu
        }
    }

    func makeNSView(context: Context) -> CatcherView { CatcherView() }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.makeMenu = makeMenu
    }
}
