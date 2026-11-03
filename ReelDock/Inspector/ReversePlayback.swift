import AVFoundation
import QuartzCore

nonisolated struct ReverseFrame: @unchecked Sendable {
    let time: CMTime
    let sample: CMSampleBuffer
}

/// Decodes short stretches of a clip forward, so they can be shown backward.
nonisolated enum ReverseDecoder {
    struct Source: @unchecked Sendable {
        let asset: AVURLAsset
        let track: AVAssetTrack
        let frameRate: Double
        let decodeSize: CGSize
        let rotation: CGFloat
        let hasSampleCursors: Bool
    }

    private static let windowDuration = CMTime(value: 1, timescale: 1)
    private static let longestKeyframeSearch = 3.0
    private static let longestDecodeSide: CGFloat = 1920
    private static let displayRate = 60.0

    static func load(_ url: URL) async -> Source? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let (size, transform, frameRate, hasSampleCursors) = try? await track.load(.naturalSize, .preferredTransform, .nominalFrameRate, .canProvideSampleCursors),
              size.width > 0, size.height > 0 else { return nil }
        return Source(
            asset: asset,
            track: track,
            frameRate: Double(frameRate),
            decodeSize: decodeSize(for: size),
            rotation: rotation(of: transform),
            hasSampleCursors: hasSampleCursors
        )
    }

    /// Sized for a preview, because a backward stretch holds every frame in memory at once.
    static func decodeSize(for size: CGSize) -> CGSize {
        let scale = min(1, longestDecodeSide / max(size.width, size.height))
        func even(_ value: CGFloat) -> CGFloat { (value * scale / 2).rounded() * 2 }
        return CGSize(width: even(size.width), height: even(size.height))
    }

    /// The clockwise turn the clip asks for, in radians. The decoder returns frames unrotated.
    static func rotation(of transform: CGAffineTransform) -> CGFloat {
        atan2(transform.b, transform.a)
    }

    /// How many decoded frames each shown frame stands for, so nothing is decoded only to be skipped by the display.
    static func frameStride(frameRate: Double, speed: Double) -> Int {
        max(1, Int((frameRate * speed / displayRate).rounded()))
    }

    /// Starts on a keyframe where one is near, so nothing is decoded only to be discarded.
    static func window(endingAt end: CMTime, in source: Source) -> CMTimeRange {
        let target = CMTimeMaximum(.zero, end - windowDuration)
        guard source.hasSampleCursors,
              let cursor = source.track.makeSampleCursor(presentationTimeStamp: target) else {
            return CMTimeRange(start: target, end: end)
        }
        let limit = Int64(longestKeyframeSearch * max(source.frameRate, 1))
        var steps: Int64 = 0
        while !cursor.currentSampleSyncInfo.sampleIsFullSync.boolValue, steps < limit {
            guard cursor.stepInDecodeOrder(byCount: -1) == -1 else { break }
            steps += 1
        }
        let start = cursor.presentationTimeStamp
        guard cursor.currentSampleSyncInfo.sampleIsFullSync.boolValue, start < end else {
            return CMTimeRange(start: target, end: end)
        }
        return CMTimeRange(start: CMTimeMaximum(.zero, CMTimeMinimum(start, target)), end: end)
    }

    static func decode(_ range: CMTimeRange, of source: Source, stride: Int) throws -> [ReverseFrame] {
        let reader = try AVAssetReader(asset: source.asset)
        reader.timeRange = range
        let output = AVAssetReaderTrackOutput(track: source.track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: Int(source.decodeSize.width),
            kCVPixelBufferHeightKey as String: Int(source.decodeSize.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }

        var frames: [ReverseFrame] = []
        var index = 0
        while let sample = output.copyNextSampleBuffer() {
            guard !Task.isCancelled else {
                reader.cancelReading()
                return []
            }
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            guard CMSampleBufferGetImageBuffer(sample) != nil, time >= range.start, time < range.end else { continue }
            if index % stride == 0 {
                showImmediately(sample)
                frames.append(ReverseFrame(time: time, sample: sample))
            }
            index += 1
        }
        if reader.status == .failed { throw reader.error ?? CocoaError(.fileReadUnknown) }
        return frames.sorted { $0.time < $1.time }
    }

    /// The display layer would otherwise wait for each frame's timestamp, which runs the wrong way here.
    private static func showImmediately(_ sample: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
              CFArrayGetCount(attachments) > 0 else { return }
        let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(
            dictionary,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
        )
    }
}

/// Plays a clip backward at full frame rate, for the slow speeds where `AVPlayer` shows about a third of the frames.
/// It stays behind only if decoding can't keep up, rather than skipping ahead.
final class ReverseEngine {
    /// Faster than this, `AVPlayer` is already smooth.
    static let maximumSpeed: Float = 2
    private static let tickInterval = 1.0 / 120
    private static let readAhead = 0.6

    private(set) var position: CMTime
    var onFrame: ((ReverseFrame) -> Void)?
    var onLoaded: ((ReverseDecoder.Source) -> Void)?
    var onFinished: (() -> Void)?
    var onFailed: (() -> Void)?

    private let url: URL
    private var speed: Double
    private var source: ReverseDecoder.Source?
    private var pending: [ReverseFrame] = []
    private var nextEnd: CMTime
    private var decoding: Task<Void, Never>?
    private var loading: Task<Void, Never>?
    private var timer: Timer?
    private var generation = 0
    private var anchorPosition: Double
    private var anchorClock = CACurrentMediaTime()

    init(url: URL, from position: CMTime, speed: Double) {
        self.url = url
        self.position = position
        self.speed = speed
        nextEnd = position + CMTime(value: 1, timescale: 1000)
        anchorPosition = position.seconds
    }

    func start() {
        let url = url
        loading = Task { [weak self] in
            let source = await ReverseDecoder.load(url)
            guard let self, !Task.isCancelled else { return }
            guard let source else {
                self.stop()
                self.onFailed?()
                return
            }
            self.source = source
            self.onLoaded?(source)
            self.decodeIfNeeded()
        }
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        loading?.cancel()
        decoding?.cancel()
        decoding = nil
        generation += 1
        pending = []
    }

    func setSpeed(_ newSpeed: Double) {
        reanchor()
        speed = newSpeed
    }

    func jump(to seconds: Double) {
        decoding?.cancel()
        decoding = nil
        generation += 1
        pending = []
        position = CMTime(seconds: seconds, preferredTimescale: 600)
        nextEnd = position + CMTime(value: 1, timescale: 1000)
        reanchor()
        decodeIfNeeded()
    }

    private func reanchor() {
        anchorPosition = position.seconds
        anchorClock = CACurrentMediaTime()
    }

    private func tick() {
        let target = anchorPosition - speed * (CACurrentMediaTime() - anchorClock)
        var shown: ReverseFrame?
        while let last = pending.last, last.time.seconds >= target {
            shown = pending.removeLast()
        }
        if let shown {
            position = shown.time
            onFrame?(shown)
        }
        if pending.isEmpty {
            if decoding == nil, nextEnd <= .zero, source != nil {
                stop()
                onFinished?()
                return
            }
            reanchor()
        }
        decodeIfNeeded()
    }

    private func decodeIfNeeded() {
        guard decoding == nil, nextEnd > .zero, let source else { return }
        let buffered = position.seconds - (pending.first?.time.seconds ?? position.seconds)
        guard buffered < Self.readAhead * speed else { return }

        let end = nextEnd
        let stride = ReverseDecoder.frameStride(frameRate: source.frameRate, speed: speed)
        let generation = generation
        decoding = Task.detached(priority: .userInitiated) { [weak self] in
            let range = ReverseDecoder.window(endingAt: end, in: source)
            let result = Result { try ReverseDecoder.decode(range, of: source, stride: stride) }
            await self?.finishDecoding(result, start: range.start, generation: generation)
        }
    }

    private func finishDecoding(_ result: Result<[ReverseFrame], any Error>, start: CMTime, generation: Int) {
        guard generation == self.generation else { return }
        decoding = nil
        switch result {
        case let .success(frames):
            pending = frames + pending
            nextEnd = start
        case .failure:
            stop()
            onFailed?()
        }
    }
}
