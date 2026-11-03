import AppKit
import SwiftUI

struct SidebarView: View {
    let app: AppModel
    let tab: TabModel
    weak var controller: WorkspaceWindowController?

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
        HStack(spacing: 6) {
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
            TagDots(tags: project.tags)
        }
        .tag("project:\(project.url.path)")
        .help(project.folderName)
        .contextMenu { contextMenu(url: project.url) }
    }

    private func folderRow(path: String, tag: String, systemImage: String) -> some View {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        // Favorites can be anywhere, so nothing else is watching them for tag changes.
        _ = app.tagsGeneration
        return HStack(spacing: 6) {
            Label(url.lastPathComponent, systemImage: systemImage)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            TagDots(tags: FinderTags.read(url))
        }
            .tag(tag)
            .help(path)
            .contextMenu { contextMenu(url: url) }
    }

    @ViewBuilder
    private func contextMenu(url: URL) -> some View {
        Button("Open in New Tab") { app.open(url, from: controller, newTab: true) }
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        Menu("Tags") {
            TagMenuItems(controller: controller, urls: [url])
        }
        Divider()
        Button(app.isFavorite(url) ? "Remove from Favorites" : "Add to Favorites") {
            app.toggleFavorite(url)
            controller?.refreshFavoriteItem()
        }
    }
}
