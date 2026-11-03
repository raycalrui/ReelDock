import AppKit
import Observation

/// Tracks mounted camera cards and where their clips already exist.
@Observable
final class CardMonitor {
    private(set) var cards: [CameraCard] = []
    private(set) var presence: [String: ClipPresence] = [:]
    /// False until the first scan for already-imported clips finishes.
    private(set) var isPresenceReady = false
    /// Changes whenever `presence` is rebuilt.
    private(set) var presenceGeneration = 0

    @ObservationIgnored var onCardsChanged: (([CameraCard]) -> Void)?
    @ObservationIgnored private let ledger: ImportLedger
    @ObservationIgnored private let roots: () -> (project: URL?, media: URL?)
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private var scanGeneration = 0
    @ObservationIgnored private var presenceScan = 0

    init(ledger: ImportLedger, roots: @escaping () -> (project: URL?, media: URL?)) {
        self.ledger = ledger
        self.roots = roots
    }

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.rescanVolumes() }
            })
        }
        rescanVolumes()
    }

    func rescanVolumes() {
        scanGeneration += 1
        let generation = scanGeneration
        Task {
            let found = await Task.detached(priority: .userInitiated) { Self.readCards() }.value
            guard generation == scanGeneration else { return }
            cards = found
            onCardsChanged?(found)
            refreshPresence()
        }
    }

    #if DEBUG
    /// Acts as if every card were gone, without ejecting a real one. `rescanVolumes` brings them back.
    func debugForgetCards() {
        cards = []
        onCardsChanged?([])
    }
    #endif

    /// The system volume is excluded, since a card is never the startup disk.
    nonisolated private static func readCards() -> [CameraCard] {
        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeNameKey],
            options: [.skipHiddenVolumes]
        ) ?? []
        return volumes.filter { $0.path != "/" }.compactMap { volume in
            guard let adapter = CardAdapters.adapter(for: volume) else { return nil }
            return try? adapter.read(volume: volume)
        }
    }

    func refreshPresence() {
        presenceScan += 1
        let scan = presenceScan
        let clips = cards.flatMap(\.clips)
        let (project, media) = roots()
        let ledger = ledger
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> [String: ClipPresence] in
                let index = ClipIndex.scan(projectRoot: project, mediaRoot: media)
                var result: [String: ClipPresence] = [:]
                for clip in clips {
                    result[clip.id] = ClipPresence.resolve(clip, ledger: ledger, index: index)
                }
                return result
            }.value
            guard scan == presenceScan else { return }
            presence = result
            isPresenceReady = true
            presenceGeneration += 1
        }
    }

    func noteImported(clipID: String, path: String) {
        var entry = presence[clipID] ?? ClipPresence(existingPaths: [], isInLedger: true)
        entry.existingPaths.append(path)
        entry.isInLedger = true
        presence[clipID] = entry
        presenceGeneration += 1
    }

    func newClipCount(in card: CameraCard) -> Int {
        guard isPresenceReady else { return card.clips.count }
        return card.clips.filter { presence[$0.id]?.isNew ?? true }.count
    }
}
