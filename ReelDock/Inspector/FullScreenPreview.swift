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

    init(tab: TabModel, screen: NSScreen, onChooseScreen: @escaping (NSScreen) -> Void, onToggleLUT: @escaping () -> Void, onClose: @escaping () -> Void) {
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
        let host = NSHostingView(rootView: FullScreenPreviewView(tab: tab, preview: self, onToggleLUT: onToggleLUT, onClose: onClose))
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
    let onToggleLUT: () -> Void
    let onClose: () -> Void

    @State private var gamma: LogGamma?
    @State private var picture: NSImage?
    @State private var media: MediaInfo?
    @State private var controlsVisible = true
    @State private var activity = 0
    @State private var isOverControls = false

    init(tab: TabModel, preview: FullScreenPreview, onToggleLUT: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.tab = tab
        self.preview = preview
        self.onToggleLUT = onToggleLUT
        self.onClose = onClose
        // The inspector's image shows at once, so full screen never opens on black.
        // With a LUT in use it stays black for a moment instead, so the picture doesn't change color.
        if tab.selection.count == 1, !(tab.selection[0].isVideo && PreviewLUTs.shared.isEnabled) {
            let item = tab.selection[0]
            _picture = State(initialValue: ThumbnailCache.shared.cached(item.url, modified: item.modified, size: InspectorPreview.posterSize))
        }
    }

    private var item: FolderItem? {
        tab.selection.count == 1 ? tab.selection[0] : nil
    }

    private var hasMarks: Bool {
        item.flatMap { tab.trimMarks[$0.id] }?.isEmpty == false
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
                    .onHover { isOverControls = $0 }
                    .onDisappear { isOverControls = false }
            }
        }
        .environment(\.colorScheme, .dark)
        .onContinuousHover { phase in
            if case .active = phase { showControls() }
        }
        .task(id: activity) { await hideControlsLater() }
        // Starts the wait over when the pointer leaves or the marks clear, and shows the marks as they're set.
        .onChange(of: isOverControls) { showControls() }
        .onChange(of: hasMarks) { showControls() }
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
                    marks: tab.trimMarks[item.id],
                    gamma: gamma,
                    onToggleLUT: onToggleLUT,
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
        guard !Task.isCancelled, !isOverControls, !hasMarks else { return }
        controlsVisible = false
        NSCursor.setHiddenUntilMouseMoves(true)
    }

    private func loadDetails() async {
        guard let item else { return }
        picture = item.isVideo && PreviewLUTs.shared.isEnabled ? nil : ThumbnailCache.shared.cached(item.url, modified: item.modified, size: InspectorPreview.posterSize)
        media = nil
        gamma = nil
        if item.isPlayable {
            let url = item.url
            if item.isVideo {
                gamma = await Task.detached(priority: .utility) { await LogFootage.gamma(of: url) }.value
            }
            media = await MediaInfoReader.read(item.url)
        } else {
            let side = max(preview.screen.frame.width, preview.screen.frame.height)
            ThumbnailCache.shared.request(item.url, modified: item.modified, size: side, scale: preview.screen.backingScaleFactor) { image in
                if self.item?.id == item.id { picture = image }
            }
        }
    }
}
