import Foundation
import Observation

/// Runs pastes and moves in the background, one at a time, so a large copy doesn't hold up browsing.
@Observable
final class FileTransferQueue {
    enum State: Equatable {
        case queued
        case running
        case done
        case failed(String)
        case cancelled

        var isActive: Bool { self == .queued || self == .running }
    }

    struct Job: Identifiable {
        let id = UUID()
        let kind: FileTransfer.Kind
        let sources: [URL]
        let destination: URL
        var state: State = .queued
        var items: [FileTransfer.Item] = []
    }

    typealias Completion = (FileTransfer.Kind, [FileTransfer.Item], String?) -> Void

    private(set) var jobs: [Job] = []
    private(set) var isPaused = false
    /// Across the current job, the only one being written.
    private(set) var copiedBytes: Int64 = 0
    private(set) var totalBytes: Int64 = 0
    private(set) var isVerifying = false

    @ObservationIgnored private let registry: PartFileRegistry
    @ObservationIgnored private var completions: [UUID: Completion] = [:]
    @ObservationIgnored private var control: CopyControl?
    @ObservationIgnored private var isRunning = false
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var keepAwake: (any NSObjectProtocol)?

    init(registry: PartFileRegistry) {
        self.registry = registry
    }

    var isActive: Bool { jobs.contains { $0.state.isActive } }
    var failedCount: Int { jobs.filter { if case .failed = $0.state { true } else { false } }.count }
    var fraction: Double { min(1, Double(copiedBytes) / Double(max(1, totalBytes))) }

    /// A folder can't move while something is being written into it, read out of it, or moved from inside it.
    func isBusy(with url: URL) -> Bool {
        jobs.contains { job in
            guard job.state.isActive else { return false }
            if job.destination.path.relocated(from: url.path, to: "") != nil { return true }
            return job.sources.contains {
                $0.path.relocated(from: url.path, to: "") != nil || url.path.relocated(from: $0.path, to: "") != nil
            }
        }
    }

    func enqueue(_ kind: FileTransfer.Kind, sources: [URL], destination: URL, completion: @escaping Completion) {
        if !isActive { jobs.removeAll() }
        let job = Job(kind: kind, sources: sources, destination: destination)
        jobs.append(job)
        completions[job.id] = completion
        startRunner()
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        control?.isPaused = paused
    }

    func cancelAll() {
        control?.cancel()
        for index in jobs.indices where jobs[index].state == .queued {
            jobs[index].state = .cancelled
            completions[jobs[index].id] = nil
        }
    }

    func clearFinished() {
        jobs.removeAll { !$0.state.isActive }
    }

    private func startRunner() {
        guard !isRunning else { return }
        isRunning = true
        keepAwake = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Copying files"
        )
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        Task {
            while let index = jobs.firstIndex(where: { $0.state == .queued }) {
                jobs[index].state = .running
                await run(jobs[index])
            }
            isRunning = false
            timer?.invalidate()
            timer = nil
            if let keepAwake { ProcessInfo.processInfo.endActivity(keepAwake) }
            keepAwake = nil
        }
    }

    private func run(_ job: Job) async {
        let control = CopyControl()
        control.isPaused = isPaused
        self.control = control
        copiedBytes = 0
        isVerifying = false
        let registry = registry
        totalBytes = await Task.detached(priority: .userInitiated) {
            FileTransfer.bytesToWrite(sources: job.sources, destination: job.destination, kind: job.kind)
        }.value
        let needed = totalBytes
        let outcome = await Task.detached(priority: .userInitiated) {
            Self.perform(job, needed: needed, control: control, registry: registry)
        }.value
        self.control = nil
        tick(control)
        if let index = jobs.firstIndex(where: { $0.id == job.id }) {
            jobs[index].items = outcome.items
            jobs[index].state = outcome.state
        }
        var failure: String?
        if case let .failed(reason) = outcome.state { failure = reason }
        completions.removeValue(forKey: job.id)?(job.kind, outcome.items, failure)
    }

    /// Stops at the first failure, keeping what already finished so it can still be undone.
    nonisolated private static func perform(_ job: Job, needed: Int64, control: CopyControl, registry: PartFileRegistry) -> (items: [FileTransfer.Item], state: State) {
        guard needed == 0 || ImportRouting.hasEnoughSpace(needed, at: job.destination) else {
            return ([], .failed("There isn't enough free space at the destination."))
        }
        let hooks = ClipCopier.Hooks(partCreated: registry.add, partFinished: registry.remove)
        var items: [FileTransfer.Item] = []
        for source in job.sources {
            do {
                items.append(try FileTransfer.perform(source, kind: job.kind, destination: job.destination, control: control, hooks: hooks))
            } catch ClipCopier.Failure.cancelled {
                return (items, .cancelled)
            } catch {
                return (items, .failed(FileTransfer.describe(error)))
            }
        }
        return (items, .done)
    }

    private func tick() {
        if let control { tick(control) }
    }

    private func tick(_ control: CopyControl) {
        copiedBytes = control.bytesCopied
        isVerifying = control.isVerifying
    }
}
