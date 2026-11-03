import AVFoundation
import AppKit
import Observation
import SwiftUI

private final class FullScreenPreviewWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

extension NSScreen {
    /// Survives reconnecting the display, unlike the display number.
    var stableID: String? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
}

/// Covers one screen without leaving the current Space, which a native full-screen window would.
/// It opens and closes with no animation, because the point is speed.
@Observable
final class FullScreenPreview {
    @ObservationIgnored let window: NSWindow
    private(set) var screens = NSScreen.screens
    private(set) var screen: NSScreen

    @ObservationIgnored private let onChooseScreen: (NSScreen) -> Void
    @ObservationIgnored private var screenObserver: (any NSObjectProtocol)?

    init(tab: TabModel, screen: NSScreen, onChooseScreen: @escaping (NSScreen) -> Void, onClose: @escaping () -> Void) {
        self.screen = screen
        self.onChooseScreen = onChooseScreen
        window = FullScreenPreviewWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.backgroundColor = .black
        window.isOpaque = true
        // Above the menu bar and the Dock. Hiding on deactivate keeps it from covering other apps.
        window.level = .statusBar
        window.hidesOnDeactivate = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        let host = NSHostingView(rootView: FullScreenPreviewView(tab: tab, preview: self, onClose: onClose))
        host.sizingOptions = []
        window.contentView = host
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensDidChange() }
        }
    }

    func present() {
        window.setFrame(screen.frame, display: false)
        window.contentView?.layoutSubtreeIfNeeded()
        window.makeKeyAndOrderFront(nil)
    }

    func choose(_ screen: NSScreen) {
        self.screen = screen
        window.setFrame(screen.frame, display: true)
        onChooseScreen(screen)
    }

    func close() {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        window.orderOut(nil)
        window.contentView = nil
    }

    /// A display was unplugged or changed resolution. Falls back to a remaining one, and doesn't remember that as a choice.
    private func screensDidChange() {
        screens = NSScreen.screens
        let id = screen.stableID
        screen = screens.first { $0.stableID == id } ?? NSScreen.main ?? screens.first ?? screen
        window.setFrame(screen.frame, display: true)
    }
}

private struct FullScreenPreviewView: View {
    private static let controlsTimeout: Duration = .milliseconds(2500)

    let tab: TabModel
    let preview: FullScreenPreview
    let onClose: () -> Void

    @State private var picture: NSImage?
    @State private var media: MediaInfo?
    @State private var controlsVisible = true
    @State private var activity = 0

    init(tab: TabModel, preview: FullScreenPreview, onClose: @escaping () -> Void) {
        self.tab = tab
        self.preview = preview
        self.onClose = onClose
        // The inspector's image shows at once, so full screen never opens on black.
        if tab.selection.count == 1 {
            let item = tab.selection[0]
            _picture = State(initialValue: ThumbnailCache.shared.cached(item.url, modified: item.modified, size: InspectorPreview.posterSize))
        }
    }

    private var item: FolderItem? {
        tab.selection.count == 1 ? tab.selection[0] : nil
    }

    var body: some View {
        ZStack {
            Color.black
            if let picture {
                Image(nsImage: picture)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
            if item?.isPlayable == true {
                PlayerLayerRepresentable(playback: tab.playback)
                PlayerOverlay(playback: tab.playback)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if item?.isPlayable == true { tab.playback.togglePlay() }
        }
        .overlay(alignment: .bottom) {
            if controlsVisible, let item {
                controls(item)
            }
        }
        .environment(\.colorScheme, .dark)
        .onContinuousHover { phase in
            if case .active = phase { showControls() }
        }
        .task(id: activity) { await hideControlsLater() }
        .task(id: item?.id) { await loadDetails() }
        .onChange(of: item?.id) {
            if item?.canPreviewFullScreen != true { onClose() }
        }
    }

    private func controls(_ item: FolderItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(item.name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if preview.screens.count > 1 {
                    displayMenu
                }
                if !item.isPlayable {
                    FullScreenButton(isFullScreen: true, action: onClose)
                }
            }
            if item.isPlayable {
                TransportBar(
                    playback: tab.playback,
                    duration: media?.duration ?? 0,
                    frameRate: media?.frameRate,
                    isFullScreen: true,
                    onFullScreen: onClose
                )
            }
        }
        .padding(12)
        .frame(maxWidth: 720)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 24)
        .padding(.bottom, 32)
    }

    private var displayMenu: some View {
        Menu {
            ForEach(preview.screens, id: \.self) { screen in
                Toggle(screen.localizedName, isOn: Binding(
                    get: { screen == preview.screen },
                    set: { _ in preview.choose(screen) }
                ))
            }
        } label: {
            Image(systemName: "display")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Show on another display")
    }

    private func showControls() {
        controlsVisible = true
        activity &+= 1
    }

    private func hideControlsLater() async {
        try? await Task.sleep(for: Self.controlsTimeout)
        guard !Task.isCancelled else { return }
        controlsVisible = false
        NSCursor.setHiddenUntilMouseMoves(true)
    }

    private func loadDetails() async {
        guard let item else { return }
        picture = ThumbnailCache.shared.cached(item.url, modified: item.modified, size: InspectorPreview.posterSize)
        media = nil
        if item.isPlayable {
            media = await MediaInfoReader.read(item.url)
        } else {
            let side = max(preview.screen.frame.width, preview.screen.frame.height)
            ThumbnailCache.shared.request(item.url, modified: item.modified, size: side, scale: preview.screen.backingScaleFactor) { image in
                if self.item?.id == item.id { picture = image }
            }
        }
    }
}
