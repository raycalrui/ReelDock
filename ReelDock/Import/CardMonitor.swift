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
    @ObservationIgnored private let roots: () -> (project: URL?, media: URL?, archive: URL?)
    @ObservationIgnored private var downloadsWatcher: FolderWatcher?
    @ObservationIgnored private var downloadsScan = 0
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private var scanGeneration = 0
    @ObservationIgnored private var presenceScan = 0

    init(ledger: ImportLedger, roots: @escaping () -> (project: URL?, media: URL?, archive: URL?)) {
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
        let downloads = DownloadedClips.folder.canonicalPath
        downloadsWatcher = FolderWatcher(path: downloads) { [weak self] change in
            if change.needsFullRescan || change.rootChanged || change.directories.contains(downloads) {
                self?.rescanDownloads()
            }
        }
        rescanVolumes()
    }

    /// Downloads changes often, so this reads only that folder and does nothing more unless its clips changed.
    func rescanDownloads() {
        downloadsScan += 1
        let scan = downloadsScan
        let folder = DownloadedClips.folder
        Task {
            let found = await Task.detached(priority: .utility) { await DownloadedClips.read(folder) }.value
            guard scan == downloadsScan else { return }
            let next = cards.filter { !$0.isFolderSource } + (found.map { [$0] } ?? [])
            guard next != cards else { return }
            cards = next
            onCardsChanged?(next)
            refreshPresence()
        }
    }

    func rescanVolumes() {
        scanGeneration += 1
        let generation = scanGeneration
        let downloads = downloadsScan
        Task {
            let found = await Task.detached(priority: .userInitiated) { await Self.readCards() }.value
            guard generation == scanGeneration else { return }
            cards = found
            onCardsChanged?(found)
            refreshPresence()
            // Downloads changed during this slower scan, so what it read there may already be old.
            if downloads != downloadsScan { rescanDownloads() }
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
    nonisolated private static func readCards() async -> [CameraCard] {
        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeNameKey],
            options: [.skipHiddenVolumes]
        ) ?? []
        let cards = volumes.filter { $0.path != "/" }.compactMap { volume -> CameraCard? in
            guard let adapter = CardAdapters.adapter(for: volume) else { return nil }
            return try? adapter.read(volume: volume)
        }
        return cards + (await DownloadedClips.read(DownloadedClips.folder).map { [$0] } ?? [])
    }

    func refreshPresence() {
        presenceScan += 1
        let scan = presenceScan
        let clips = cards.flatMap(\.clips)
        let (project, media, archive) = roots()
        let ledger = ledger
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> [String: ClipPresence] in
                let index = ClipIndex.scan(projectRoot: project, mediaRoot: media, archiveRoot: archive)
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

/// System sounds, so nothing extra ships with the app.
enum CardSound: String {
    case inserted = "Submarine"
    case ejected = "Glass"
    case imported = "Hero"
    case importFailed = "Basso"

    func play() {
        let sound = NSSound(named: rawValue)
        // A named sound is shared, and can't start again while it's still playing.
        sound?.stop()
        sound?.play()
        #if DEBUG
        debugPlayedSounds.append("\(rawValue)=\(sound?.isPlaying ?? false)")
        #endif
    }
}

#if DEBUG
var debugPlayedSounds: [String] = []
var debugLastEjectDuration: Duration?
#endif
