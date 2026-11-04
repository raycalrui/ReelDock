import AVFoundation
import Accelerate
import Foundation

/// An audio file's loudness over time, from 0 to 1 relative to its own loudest moment, so quiet recordings still show.
/// Levels are averages, because a long recording's levels are all near the top and hide its shape.
nonisolated enum WaveformReader {
    /// Enough for the inspector at its widest on a Retina display.
    static let levelCount = 1600

    /// Reads the whole file, which takes under a second even for an hour of WAV on a fast drive. Stops if the task is cancelled.
    static func read(_ url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw CocoaError(.fileReadCorruptFile) }
        let duration = try await asset.load(.duration).seconds
        let format = try await track.load(.formatDescriptions).first
        guard let format, let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee, duration > 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
        defer { reader.cancelReading() }

        let channels = max(1, Int(description.mChannelsPerFrame))
        let totalFrames = max(1, Int(duration * description.mSampleRate))
        var sums = [Double](repeating: 0, count: levelCount)
        var counts = [Int](repeating: 0, count: levelCount)
        var samples = [Float]()
        var frame = 0
        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let count = length / MemoryLayout<Float>.size
            if samples.count < count { samples = [Float](repeating: 0, count: count) }
            samples.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            samples.withUnsafeBufferPointer { pointer in
                addEnergy(pointer.baseAddress!, count: count, channels: channels, startFrame: frame, totalFrames: totalFrames, sums: &sums, counts: &counts)
            }
            frame += count / channels
        }
        if reader.status == .failed { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
        return normalized(zip(sums, counts).map { $1 > 0 ? Float(($0 / Double($1)).squareRoot()) : 0 })
    }

    /// Adds to each slice of the file its samples' squares, across all channels, for an average loudness at the end.
    private static func addEnergy(_ samples: UnsafePointer<Float>, count: Int, channels: Int, startFrame: Int, totalFrames: Int, sums: inout [Double], counts: inout [Int]) {
        var index = 0
        while index < count {
            let currentFrame = startFrame + index / channels
            let level = min(sums.count - 1, currentFrame * sums.count / totalFrames)
            // The last slice also takes anything past the file's stated length.
            let nextFrame = level == sums.count - 1 ? Int.max / 2 : (level + 1) * totalFrames / sums.count
            let end = min(count, max(index + channels, (nextFrame - startFrame) * channels))
            var energy: Float = 0
            vDSP_svesq(samples + index, 1, &energy, vDSP_Length(end - index))
            sums[level] += Double(energy)
            counts[level] += end - index
            index = end
        }
    }

    static func normalized(_ levels: [Float]) -> [Float] {
        guard let loudest = levels.max(), loudest > 0 else { return levels }
        return levels.map { $0 / loudest }
    }

    /// One value per bar, each the loudest of the levels it covers, so short sounds don't fall between bars.
    static func bars(_ levels: [Float], count: Int) -> [Float] {
        guard count > 0, !levels.isEmpty else { return [] }
        return (0..<count).map { bar in
            let start = bar * levels.count / count
            let end = max(start + 1, (bar + 1) * levels.count / count)
            return levels[start..<min(end, levels.count)].max() ?? 0
        }
    }
}

/// Keeps waveforms already read, so returning to a file shows its waveform at once.
final class WaveformCache {
    static let shared = WaveformCache()

    private final class Entry {
        let levels: [Float]
        init(_ levels: [Float]) { self.levels = levels }
    }

    private let entries = NSCache<NSString, Entry>()

    private init() {
        entries.countLimit = 100
    }

    /// Nil if the file can't be read, or the task was cancelled.
    func levels(for url: URL, modified: Date?) async -> [Float]? {
        let key = "\(url.path)|\(modified?.timeIntervalSince1970 ?? 0)" as NSString
        if let entry = entries.object(forKey: key) { return entry.levels }
        let task = Task.detached(priority: .utility) { try await WaveformReader.read(url) }
        let result = await withTaskCancellationHandler {
            try? await task.value
        } onCancel: {
            task.cancel()
        }
        if let result { entries.setObject(Entry(result), forKey: key) }
        return result
    }
}
