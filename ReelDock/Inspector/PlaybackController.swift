import AVFoundation
import Observation

nonisolated enum Timecode {
    /// Elapsed time as `MM:SS:FF`, or `H:MM:SS:FF` past an hour.
    static func format(_ seconds: Double, frameRate: Double?) -> String {
        let base = max(1, Int((frameRate ?? 30).rounded()))
        let total = Int((max(0, seconds) * Double(base)).rounded(.down))
        let frames = total % base
        let elapsed = total / base
        let hours = elapsed / 3600
        let minutes = (elapsed % 3600) / 60
        let rest = elapsed % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d:%02d", hours, minutes, rest, frames)
            : String(format: "%02d:%02d:%02d", minutes, rest, frames)
    }
}

/// What J and L do to the current rate, as in editing apps: each press doubles, up to a limit.
nonisolated enum Shuttle {
    static let maximumRate: Float = 8

    static func rate(after current: Float, forward: Bool) -> Float {
        let sameDirection = forward ? current > 0 : current < 0
        let magnitude = sameDirection ? min(abs(current) * 2, maximumRate) : 1
        return forward ? magnitude : -magnitude
    }
}

/// One tab's preview player. Files open only on the first play, so browsing never reads whole clips.
@Observable
final class PlaybackController {
    private(set) var url: URL?
    private(set) var isLoaded = false
    private(set) var rate: Float = 0
    private(set) var time: Double = 0
    private(set) var failed = false

    @ObservationIgnored let player = AVPlayer()
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var rateObservation: NSKeyValueObservation?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var pendingRate: Float?
    @ObservationIgnored private var pendingSeek: Double?
    @ObservationIgnored private var pendingSteps = 0
    @ObservationIgnored private var seekTarget: Double?
    @ObservationIgnored private var isSeeking = false
    @ObservationIgnored private var rateBeforeScrub: Float = 0
    @ObservationIgnored private var isHoldingK = false

    /// While true, each new selection loads at once, because a full-screen view has no other image of it.
    @ObservationIgnored var staysLoaded = false

    var isPlaying: Bool { rate != 0 }
    var canPlay: Bool { url != nil }

    init() {
        player.actionAtItemEnd = .pause
    }

    /// A folder refresh that keeps the same file selected doesn't interrupt playback.
    func follow(_ selection: [FolderItem]) {
        let next = selection.count == 1 && selection[0].isPlayable ? selection[0].url : nil
        guard next != url else { return }
        let keepPlaying = isPlaying
        unload()
        url = next
        if keepPlaying, next != nil {
            start(rate: 1)
        } else if staysLoaded {
            prepare()
        }
    }

    /// Opens the file, so its current frame shows without starting playback.
    func prepare() {
        _ = loadIfNeeded()
    }

    /// Closes the file, so a card can be ejected. The selection stays and can load again.
    func release(under folder: URL) {
        guard let url, url.path.hasPrefix(folder.path + "/") else { return }
        unload()
    }

    func unload() {
        statusObservation = nil
        rateObservation = nil
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        pendingRate = nil
        pendingSeek = nil
        pendingSteps = 0
        seekTarget = nil
        isSeeking = false
        isLoaded = false
        failed = false
        rate = 0
        time = 0
    }

    // MARK: Commands

    func togglePlay() {
        isPlaying ? pause() : start(rate: 1)
    }

    func pause() {
        pendingRate = nil
        player.pause()
    }

    func shuttle(forward: Bool) {
        start(rate: Shuttle.rate(after: rate, forward: forward))
    }

    func step(_ frames: Int) {
        guard loadIfNeeded() else { return }
        pause()
        guard let item = player.currentItem, item.status == .readyToPlay else {
            pendingSteps += frames
            return
        }
        guard frames > 0 ? item.canStepForward : item.canStepBackward else { return }
        item.step(byCount: frames)
        syncTimeSoon()
    }

    func seek(to seconds: Double) {
        guard loadIfNeeded() else { return }
        time = seconds
        guard player.currentItem?.status == .readyToPlay else {
            pendingSeek = seconds
            return
        }
        seekTarget = seconds
        if !isSeeking { runSeek() }
    }

    func beginScrub() {
        rateBeforeScrub = rate
        pause()
    }

    func endScrub() {
        if rateBeforeScrub != 0 { start(rate: rateBeforeScrub) }
        rateBeforeScrub = 0
    }

    // MARK: Keys

    /// Returns whether the key was used. Holding K and tapping J or L steps one frame.
    func handleKey(code: UInt16, isDown: Bool, isRepeat: Bool) -> Bool {
        guard canPlay else {
            if code == KeyCode.k, !isDown { isHoldingK = false }
            return false
        }
        switch code {
        case KeyCode.k:
            isHoldingK = isDown
            if isDown, !isRepeat { pause() }
            return true
        case KeyCode.j, KeyCode.l:
            guard isDown else { return false }
            let forward = code == KeyCode.l
            if isHoldingK {
                step(forward ? 1 : -1)
            } else if !isRepeat {
                shuttle(forward: forward)
            }
            return true
        default:
            return false
        }
    }

    func releaseHeldKeys() {
        isHoldingK = false
    }

    enum KeyCode {
        static let j: UInt16 = 38
        static let k: UInt16 = 40
        static let l: UInt16 = 37
        static let space: UInt16 = 49
    }

    // MARK: Internals

    private func start(rate newRate: Float) {
        guard loadIfNeeded() else { return }
        guard let item = player.currentItem, item.status == .readyToPlay else {
            pendingRate = newRate
            return
        }
        apply(rate: newRate, to: item)
    }

    /// Falls back to the fastest speed the file supports, and restarts a clip that already ended.
    private func apply(rate newRate: Float, to item: AVPlayerItem) {
        var target = newRate
        if target < 0, !item.canPlayReverse { return }
        if target > 1, !item.canPlayFastForward { target = 1 }
        if target < -1, !item.canPlayFastReverse { target = -1 }

        let duration = item.duration.seconds
        if target > 0, duration.isFinite, player.currentTime().seconds >= duration - 0.001 {
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        player.rate = target
    }

    private func loadIfNeeded() -> Bool {
        guard let url else { return false }
        guard player.currentItem == nil else { return true }

        let item = AVPlayerItem(url: url)
        statusObservation = item.observe(\.status) { [weak self] item, _ in
            let status = item.status
            Task { @MainActor in self?.itemStatusChanged(status) }
        }
        rateObservation = player.observe(\.rate) { [weak self] player, _ in
            let rate = player.rate
            Task { @MainActor in self?.rate = rate }
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.isSeeking else { return }
                self.time = time.seconds
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rate = 0 }
        }
        player.replaceCurrentItem(with: item)
        isLoaded = true
        failed = false
        return true
    }

    private func itemStatusChanged(_ status: AVPlayerItem.Status) {
        guard let item = player.currentItem else { return }
        switch status {
        case .readyToPlay:
            if let pendingSeek {
                self.pendingSeek = nil
                seek(to: pendingSeek)
            }
            if pendingSteps != 0 {
                let frames = pendingSteps
                pendingSteps = 0
                step(frames)
            }
            if let pendingRate {
                self.pendingRate = nil
                apply(rate: pendingRate, to: item)
            }
        case .failed:
            failed = true
            pendingRate = nil
        default:
            break
        }
    }

    /// Runs one seek at a time and then chases the latest target, so scrubbing never queues up.
    private func runSeek() {
        guard let target = seekTarget else { return }
        isSeeking = true
        seekTarget = nil
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.isSeeking = false
                if self.seekTarget != nil { self.runSeek() }
            }
        }
    }

    private func syncTimeSoon() {
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            guard let self, self.player.currentItem != nil else { return }
            self.time = self.player.currentTime().seconds
        }
    }
}
