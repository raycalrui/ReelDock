import Foundation
import Observation

nonisolated enum ImportDestination: Hashable, Sendable {
    case folder(URL)
    case archive(mediaRoot: URL, deviceFolder: String)

    /// A folder on the volume that will receive the files.
    var volumeProbe: URL {
        switch self {
        case let .folder(url): url
        case let .archive(mediaRoot, _): mediaRoot
        }
    }
}

/// Copies clips in the background: one at a time per card, because parallel reads
/// from one card add seeking without adding throughput.
@Observable
final class ImportQueue {
    enum JobState: Equatable {
        case queued
        case copying
        case verifying
        case done(path: String)
        case failed(reason: String)
        case cancelled

        var isActive: Bool {
            switch self {
            case .queued, .copying, .verifying: true
            case .done, .failed, .cancelled: false
            }
        }
    }

    struct Job: Identifiable {
        let id = UUID()
        let clip: CardClip
        let cardID: String
        let destination: ImportDestination
        var state: JobState = .queued
    }

    private nonisolated enum Outcome: Sendable {
        case done(path: String)
        case failed(reason: String)
        case stopQueue(reason: String)
        case cardRemoved
        case cancelled
    }

    private(set) var jobs: [Job] = []
    private(set) var isPaused = false
    /// Bytes copied of the clip in progress, summed across cards.
    private(set) var activeBytes: Int64 = 0
    private(set) var bytesPerSecond: Double = 0

    @ObservationIgnored private let ledger: ImportLedger
    @ObservationIgnored private let registry: PartFileRegistry
    @ObservationIgnored private let cards: CardMonitor
    @ObservationIgnored private var runners: [String: CopyControl] = [:]
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastTick: (date: Date, bytes: Int64)?
    @ObservationIgnored private var keepAwake: (any NSObjectProtocol)?

    init(ledger: ImportLedger, registry: PartFileRegistry, cards: CardMonitor) {
        self.ledger = ledger
        self.registry = registry
        self.cards = cards
    }

    // MARK: Queries

    var isActive: Bool { jobs.contains { $0.state.isActive } }

    /// Moving a folder that's being copied into would strand the rest of the import.
    func isImporting(into folder: URL) -> Bool {
        jobs.contains { job in
            guard job.state.isActive else { return false }
            let target: URL?
            switch job.destination {
            case let .folder(url): target = url
            case let .archive(mediaRoot, deviceFolder):
                target = ImportRouting.archiveFolder(mediaRoot: mediaRoot, clip: job.clip, deviceFolder: deviceFolder)
            }
            return target?.path.relocated(from: folder.path, to: "") != nil
        }
    }

    func isActive(cardID: String) -> Bool {
        jobs.contains { $0.cardID == cardID && $0.state.isActive }
    }

    func activeJob(clipID: String) -> Job? {
        jobs.last { $0.clip.id == clipID && $0.state.isActive }
    }

    var remainingBytes: Int64 {
        jobs.filter { $0.state.isActive }.reduce(0) { $0 + $1.clip.size }
    }

    var totalBytes: Int64 {
        jobs.filter { job in
            switch job.state {
            case .failed, .cancelled: false
            default: true
            }
        }.reduce(0) { $0 + $1.clip.size }
    }

    var completedBytes: Int64 {
        let finished = jobs.reduce(Int64(0)) { sum, job in
            if case .done = job.state { return sum + job.clip.size }
            return sum
        }
        return finished + activeBytes
    }

    var secondsRemaining: Double? {
        guard bytesPerSecond > 0 else { return nil }
        return Double(max(0, totalBytes - completedBytes)) / bytesPerSecond
    }

    var failedCount: Int {
        jobs.filter { if case .failed = $0.state { true } else { false } }.count
    }

    var doneCount: Int {
        jobs.filter { if case .done = $0.state { true } else { false } }.count
    }

    // MARK: Control

    func enqueue(_ clips: [CardClip], cardID: String, destination: (CardClip) -> ImportDestination) {
        if !isActive { jobs.removeAll() }
        for clip in clips where activeJob(clipID: clip.id) == nil {
            jobs.append(Job(clip: clip, cardID: cardID, destination: destination(clip)))
        }
        startRunner(cardID: cardID)
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        runners.values.forEach { $0.isPaused = paused }
        if paused { bytesPerSecond = 0 }
        lastTick = nil
    }

    func cancelAll() {
        runners.values.forEach { $0.cancel() }
        for index in jobs.indices where jobs[index].state == .queued {
            jobs[index].state = .cancelled
        }
    }

    func retryFailed() {
        var cardIDs = Set<String>()
        for index in jobs.indices {
            if case .failed = jobs[index].state {
                jobs[index].state = .queued
                cardIDs.insert(jobs[index].cardID)
            }
        }
        cardIDs.forEach(startRunner(cardID:))
    }

    func clearFinished() {
        jobs.removeAll { !$0.state.isActive }
    }

    // MARK: Running

    private func startRunner(cardID: String) {
        guard runners[cardID] == nil else { return }
        let control = CopyControl()
        control.isPaused = isPaused
        runners[cardID] = control
        beginBackgroundWork()

        Task {
            while let index = jobs.firstIndex(where: { $0.cardID == cardID && $0.state == .queued }) {
                jobs[index].state = .copying
                let job = jobs[index]
                control.beginClip()
                let ledger = ledger
                let registry = registry
                let outcome = await Task.detached(priority: .userInitiated) {
                    Self.perform(job: job, control: control, ledger: ledger, registry: registry)
                }.value
                control.beginClip()
                apply(outcome, to: job, cardID: cardID)
                if control.isCancelled { break }
            }
            finishRunner(cardID: cardID)
        }
    }

    private func finishRunner(cardID: String) {
        runners[cardID] = nil
        // Clips queued just as a cancel finished still need a runner.
        if jobs.contains(where: { $0.cardID == cardID && $0.state == .queued }) {
            startRunner(cardID: cardID)
        }
        if runners.isEmpty { endBackgroundWork() }
        tick()
        cards.refreshPresence()
    }

    private func apply(_ outcome: Outcome, to job: Job, cardID: String) {
        func set(_ state: JobState, id: UUID) {
            if let index = jobs.firstIndex(where: { $0.id == id }) { jobs[index].state = state }
        }
        func failRemaining(reason: String, where matches: (Job) -> Bool) {
            for index in jobs.indices where jobs[index].state == .queued && matches(jobs[index]) {
                jobs[index].state = .failed(reason: reason)
            }
        }

        switch outcome {
        case let .done(path):
            set(.done(path: path), id: job.id)
            cards.noteImported(clipID: job.clip.id, path: path)
        case let .failed(reason):
            set(.failed(reason: reason), id: job.id)
        case let .stopQueue(reason):
            set(.failed(reason: reason), id: job.id)
            failRemaining(reason: "Not started: \(reason)") { _ in true }
        case .cardRemoved:
            let reason = "The card was removed"
            set(.failed(reason: reason), id: job.id)
            failRemaining(reason: reason) { $0.cardID == cardID }
        case .cancelled:
            set(.cancelled, id: job.id)
        }
    }

    /// Runs off the main thread. A mismatch is retried once, in case the fault was transient.
    nonisolated private static func perform(job: Job, control: CopyControl, ledger: ImportLedger, registry: PartFileRegistry) -> Outcome {
        let folder: URL
        do {
            switch job.destination {
            case let .folder(url):
                folder = url
            case let .archive(mediaRoot, deviceFolder):
                guard let target = ImportRouting.archiveFolder(mediaRoot: mediaRoot, clip: job.clip, deviceFolder: deviceFolder) else {
                    return .failed(reason: "The clip has no shooting date")
                }
                try ImportRouting.prepareArchiveFolder(target, mediaRoot: mediaRoot)
                folder = target
            }
        } catch {
            return .stopQueue(reason: "Can't create the destination folder: \(error.localizedDescription)")
        }

        let hooks = ClipCopier.Hooks(partCreated: registry.add, partFinished: registry.remove)
        for attempt in 1...2 {
            do {
                control.beginClip()
                // What a phone clip's camera recorded stays with it. A card's clips have none of these.
                let output = try ClipCopier.copy(source: job.clip.url, toFolder: folder, control: control, hooks: hooks) {
                    $0.hasPrefix(BlackmagicClipInfo.attributePrefix)
                }
                // The clip is already safe at this point, so a ledger failure doesn't fail the import.
                // The folder scan still recognizes it next time.
                try? ledger.append(LedgerEntry(
                    umid: job.clip.umid,
                    name: job.clip.name,
                    size: job.clip.size,
                    sha256: output.sha256,
                    destination: output.url.path,
                    importedAt: Date()
                ))
                return .done(path: output.url.path)
            } catch ClipCopier.Failure.verificationMismatch where attempt == 1 {
                continue
            } catch let failure as ClipCopier.Failure {
                switch failure {
                case .cancelled:
                    return .cancelled
                case .verificationMismatch:
                    return .failed(reason: "Verification failed twice. This clip wasn't saved.")
                case .sourceSizeChanged:
                    return .failed(reason: "The clip changed size while copying")
                case let .sourceRead(code):
                    if !FileManager.default.fileExists(atPath: job.clip.url.path) {
                        // A card takes the rest of its clips with it, and one file gone from a folder doesn't.
                        return FileManager.default.fileExists(atPath: job.cardID) ? .failed(reason: "The clip is no longer there") : .cardRemoved
                    }
                    return .failed(reason: "Can't read the clip: \(String(cString: strerror(code)))")
                case let .destinationWrite(code):
                    return .stopQueue(reason: "Can't write to the destination: \(String(cString: strerror(code)))")
                }
            } catch {
                return .failed(reason: error.localizedDescription)
            }
        }
        return .failed(reason: "Verification failed twice. This clip wasn't saved.")
    }

    // MARK: Progress and power

    private func beginBackgroundWork() {
        guard timer == nil else { return }
        lastTick = nil
        keepAwake = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Importing clips from a camera card"
        )
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func endBackgroundWork() {
        timer?.invalidate()
        timer = nil
        if let keepAwake { ProcessInfo.processInfo.endActivity(keepAwake) }
        keepAwake = nil
        bytesPerSecond = 0
    }

    private func tick() {
        activeBytes = runners.values.reduce(0) { $0 + $1.bytesCopied }
        for index in jobs.indices {
            guard let control = runners[jobs[index].cardID] else { continue }
            if jobs[index].state == .copying, control.isVerifying { jobs[index].state = .verifying }
        }
        let now = Date()
        let total = completedBytes
        if let lastTick, !isPaused {
            let elapsed = now.timeIntervalSince(lastTick.date)
            let delta = total - lastTick.bytes
            if elapsed > 0, delta >= 0 {
                let current = Double(delta) / elapsed
                bytesPerSecond = bytesPerSecond == 0 ? current : bytesPerSecond * 0.7 + current * 0.3
            }
        }
        lastTick = (now, total)
    }
}
