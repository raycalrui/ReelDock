import AVFoundation
import AppKit
import SwiftUI

private final class FullScreenPreviewWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Covers one screen without leaving the current Space, which a native full-screen window would.
/// It zooms out of the inspector's preview and back into it.
final class FullScreenPreview {
    private static let duration: TimeInterval = 0.26

    let window: NSWindow
    private(set) var isClosing = false

    init(tab: TabModel, onClose: @escaping () -> Void) {
        window = FullScreenPreviewWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.backgroundColor = .black
        window.isOpaque = true
        // Above the menu bar and the Dock. Hiding on deactivate keeps it from covering other apps.
        window.level = .statusBar
        window.hidesOnDeactivate = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        let host = NSHostingView(rootView: FullScreenPreviewView(tab: tab, onClose: onClose))
        host.sizingOptions = []
        window.contentView = host
    }

    func present(from source: NSRect, on screen: NSScreen) {
        window.setFrame(source, display: false)
        window.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(screen.frame, display: true)
        }
    }

    func dismiss(to target: NSRect, completion: @escaping @MainActor () -> Void) {
        isClosing = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(target, display: true)
        } completionHandler: { [window] in
            MainActor.assumeIsolated {
                window.orderOut(nil)
                completion()
            }
        }
    }

    func closeImmediately() {
        isClosing = true
        window.orderOut(nil)
    }
}

private struct FullScreenPreviewView: View {
    private static let controlsTimeout: Duration = .milliseconds(2500)

    let tab: TabModel
    let onClose: () -> Void

    @State private var picture: NSImage?
    @State private var media: MediaInfo?
    @State private var controlsVisible = false
    @State private var activity = 0

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
                PlayerLayerRepresentable(player: tab.playback.player)
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
                    .transition(.opacity)
            }
        }
        .environment(\.colorScheme, .dark)
        .onContinuousHover { phase in
            if case .active = phase { showControls() }
        }
        .onAppear(perform: showControls)
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

    private func showControls() {
        withAnimation(.easeOut(duration: 0.15)) { controlsVisible = true }
        activity &+= 1
    }

    private func hideControlsLater() async {
        try? await Task.sleep(for: Self.controlsTimeout)
        guard !Task.isCancelled else { return }
        withAnimation(.easeIn(duration: 0.3)) { controlsVisible = false }
        NSCursor.setHiddenUntilMouseMoves(true)
    }

    private func loadDetails() async {
        guard let item else { return }
        // The inspector's image shows at once, so the zoom never starts on black.
        picture = ThumbnailCache.shared.cached(item.url, modified: item.modified, size: InspectorPreview.posterSize)
        media = nil
        if item.isPlayable {
            media = await MediaInfoReader.read(item.url)
        } else {
            let side = NSScreen.main.map { max($0.frame.width, $0.frame.height) } ?? 1800
            ThumbnailCache.shared.request(item.url, modified: item.modified, size: side, scale: NSScreen.main?.backingScaleFactor ?? 2) { image in
                if self.item?.id == item.id { picture = image }
            }
        }
    }
}
