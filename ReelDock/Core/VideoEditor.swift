import AVFoundation
import Darwin
import Foundation
import UniformTypeIdentifiers

nonisolated enum VideoEditorError: LocalizedError {
    case noMovieData
    case compressedHeader
    case noVideoTrack
    case unusualRotation
    case notEnoughSpace
    case cantExport
    case checkFailed

    var errorDescription: String? {
        switch self {
        case .noMovieData: "This file's movie header couldn't be found."
        case .compressedHeader: "This file's movie header is compressed, so it can't be changed in place."
        case .noVideoTrack: "This file has no video track."
        case .unusualRotation: "This video is scaled or skewed, not just turned, so it can't be rotated in place."
        case .notEnoughSpace: "There isn't enough free space for the new file."
        case .cantExport: "This video can't be trimmed without re-encoding it."
        case .checkFailed: "The new file didn't match what was asked for, so it wasn't saved."
        }
    }
}

/// In and out points, in seconds. A mark that would leave nothing between them clears the other, as in editing apps.
nonisolated struct TrimMarks: Hashable, Sendable {
    var inPoint: Double?
    var outPoint: Double?

    var isEmpty: Bool { inPoint == nil && outPoint == nil }

    mutating func markIn(_ seconds: Double) {
        inPoint = seconds
        if let outPoint, outPoint <= seconds { self.outPoint = nil }
    }

    mutating func markOut(_ seconds: Double) {
        outPoint = seconds
        if let inPoint, inPoint >= seconds { self.inPoint = nil }
    }

    /// An unmarked end means the start or end of the clip. Nil when that leaves nothing, or the whole clip.
    func range(duration: Double) -> ClosedRange<Double>? {
        let start = max(0, inPoint ?? 0)
        let end = min(duration, outPoint ?? duration)
        guard start < end, start > 0 || end < duration else { return nil }
        return start...end
    }
}

/// A track's display matrix, in the order the file stores it. a, b, c, d, tx, and ty are 16.16 fixed point.
nonisolated struct TrackMatrix: Hashable, Sendable {
    var a: Int32, b: Int32, u: Int32
    var c: Int32, d: Int32, v: Int32
    var tx: Int32, ty: Int32, w: Int32

    private static let one: Int32 = 0x10000

    /// A quarter turn, moved back into positive coordinates. Width and height are the track's, in 16.16.
    /// Nil unless the matrix only turns or mirrors, since anything else has no clean quarter turn.
    func rotated(clockwise: Bool, width: Int32, height: Int32) -> TrackMatrix? {
        let isStraight = abs(Int64(a)) == Int64(Self.one) && abs(Int64(d)) == Int64(Self.one) && b == 0 && c == 0
        let isTurned = abs(Int64(b)) == Int64(Self.one) && abs(Int64(c)) == Int64(Self.one) && a == 0 && d == 0
        guard isStraight || isTurned else { return nil }

        let corners = [(Int64(0), Int64(0)), (Int64(width), Int64(0)), (Int64(0), Int64(height)), (Int64(width), Int64(height))]
        let xs = corners.map { (Int64(a) * $0.0 + Int64(c) * $0.1) / Int64(Self.one) + Int64(tx) }
        let ys = corners.map { (Int64(b) * $0.0 + Int64(d) * $0.1) / Int64(Self.one) + Int64(ty) }
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return nil }

        var result = self
        if clockwise {
            // x' = maxY - y, y' = x - minX
            result.a = -b
            result.c = -d
            result.tx = Int32(clamping: maxY - Int64(ty))
            result.b = a
            result.d = c
            result.ty = Int32(clamping: Int64(tx) - minX)
        } else {
            // x' = y - minY, y' = maxX - x
            result.a = b
            result.c = d
            result.tx = Int32(clamping: Int64(ty) - minY)
            result.b = -a
            result.d = -c
            result.ty = Int32(clamping: maxX - Int64(tx))
        }
        return result
    }
}

/// Trims and rotates MP4 and QuickTime files without re-encoding them.
nonisolated enum VideoEditor {
    static func canEdit(_ type: UTType?) -> Bool {
        guard let type else { return false }
        let types = [UTType.mpeg4Movie, .quickTimeMovie, UTType("com.apple.m4v-video")].compactMap { $0 }
        return types.contains { type.conforms(to: $0) }
    }

    // MARK: Rotate

    private static let maximumHeaderSize: UInt64 = 512 * 1024 * 1024
    private static let matrixSize = 36

    /// Changes only the video tracks' display matrices in the file's header, so it's instant whatever the file's size,
    /// the picture and sound stay byte for byte, and a turn the other way undoes it.
    static func rotate(_ url: URL, clockwise: Bool) throws {
        guard !FileOperations.isOnCameraCard(url) else { throw FileOperationError.cameraCard }
        let tracks = try videoTrackHeaders(in: url)
        let patches = try tracks.map { track -> (offset: UInt64, old: Data, new: Data) in
            guard let turned = track.matrix.rotated(clockwise: clockwise, width: track.width, height: track.height) else {
                throw VideoEditorError.unusualRotation
            }
            return (track.matrixOffset, encode(track.matrix), encode(turned))
        }

        let descriptor = open(url.path, O_RDWR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        var written: [(offset: UInt64, old: Data, new: Data)] = []
        do {
            for patch in patches {
                try write(patch.new, at: patch.offset, to: descriptor)
                written.append(patch)
            }
            guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch {
            for patch in written { try? write(patch.old, at: patch.offset, to: descriptor) }
            throw error
        }
    }

    private static func write(_ data: Data, at offset: UInt64, to descriptor: Int32) throws {
        let count = data.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, data.count, off_t(offset)) }
        guard count == data.count else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    struct TrackHeader: Hashable, Sendable {
        let matrixOffset: UInt64
        let matrix: TrackMatrix
        let width: Int32
        let height: Int32
    }

    static func videoTrackHeaders(in url: URL) throws -> [TrackHeader] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let (offset, size) = try findMovieBox(handle)
        guard size <= maximumHeaderSize else { throw VideoEditorError.noMovieData }
        try handle.seek(toOffset: offset)
        guard let movie = try handle.read(upToCount: Int(size)), UInt64(movie.count) == size else { throw VideoEditorError.noMovieData }

        let children = boxes(in: movie, 0..<movie.count)
        if children.contains(where: { $0.type == "cmov" }) { throw VideoEditorError.compressedHeader }
        let headers = children.filter { $0.type == "trak" }.compactMap { track -> TrackHeader? in
            let parts = boxes(in: movie, track.payload)
            guard let media = parts.first(where: { $0.type == "mdia" }),
                  let handler = boxes(in: movie, media.payload).first(where: { $0.type == "hdlr" }),
                  handler.payload.count >= 12,
                  movie[(handler.payload.lowerBound + 8)..<(handler.payload.lowerBound + 12)] == Data("vide".utf8),
                  let header = parts.first(where: { $0.type == "tkhd" }) else { return nil }
            return parseTrackHeader(movie, header.payload, base: offset)
        }
        guard !headers.isEmpty else { throw VideoEditorError.noVideoTrack }
        return headers
    }

    /// Walks the top level of the file. Media data can be gigabytes, so it's skipped, not read.
    private static func findMovieBox(_ handle: FileHandle) throws -> (offset: UInt64, size: UInt64) {
        let fileSize = try handle.seekToEnd()
        var position: UInt64 = 0
        while position + 8 <= fileSize {
            try handle.seek(toOffset: position)
            guard let header = try handle.read(upToCount: 16), header.count >= 8 else { break }
            var size = UInt64(uint32(header, 0))
            var headerSize: UInt64 = 8
            if size == 1 {
                guard header.count == 16 else { break }
                size = (UInt64(uint32(header, 8)) << 32) | UInt64(uint32(header, 12))
                headerSize = 16
            } else if size == 0 {
                size = fileSize - position
            }
            guard size >= headerSize, position + size <= fileSize else { break }
            if header[4..<8] == Data("moov".utf8) {
                return (position + headerSize, size - headerSize)
            }
            position += size
        }
        throw VideoEditorError.noMovieData
    }

    private static func boxes(in data: Data, _ range: Range<Int>) -> [(type: String, payload: Range<Int>)] {
        var result: [(type: String, payload: Range<Int>)] = []
        var position = range.lowerBound
        while position + 8 <= range.upperBound {
            var size = Int(uint32(data, position))
            var headerSize = 8
            if size == 1 {
                guard position + 16 <= range.upperBound, uint32(data, position + 8) == 0 else { break }
                size = Int(uint32(data, position + 12))
                headerSize = 16
            } else if size == 0 {
                size = range.upperBound - position
            }
            guard size >= headerSize, position + size <= range.upperBound else { break }
            let type = String(decoding: data[(position + 4)..<(position + 8)], as: UTF8.self)
            result.append((type, (position + headerSize)..<(position + size)))
            position += size
        }
        return result
    }

    /// After the version and flags come the dates, track ID, and duration, whose size depends on the version.
    /// Then 16 bytes of layer, group, and volume, the matrix, and the size.
    private static func parseTrackHeader(_ data: Data, _ payload: Range<Int>, base: UInt64) -> TrackHeader? {
        guard let version = payload.isEmpty ? nil : data[payload.lowerBound] else { return nil }
        let start = payload.lowerBound + 4 + (version == 1 ? 32 : 20) + 16
        guard start + matrixSize + 8 <= payload.upperBound else { return nil }
        let value = { (index: Int) in Int32(bitPattern: uint32(data, start + index * 4)) }
        return TrackHeader(
            matrixOffset: base + UInt64(start),
            matrix: TrackMatrix(a: value(0), b: value(1), u: value(2), c: value(3), d: value(4), v: value(5), tx: value(6), ty: value(7), w: value(8)),
            width: value(9),
            height: value(10)
        )
    }

    private static func uint32(_ data: Data, _ offset: Int) -> UInt32 {
        let start = data.startIndex + offset
        return data[start..<(start + 4)].reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private static func encode(_ matrix: TrackMatrix) -> Data {
        var data = Data()
        for value in [matrix.a, matrix.b, matrix.u, matrix.c, matrix.d, matrix.v, matrix.tx, matrix.ty, matrix.w] {
            withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    // MARK: Trim

    /// `clip.mp4` becomes `clip trimmed.mp4`, then `clip trimmed 2.mp4`.
    static func trimmedName(for name: String, attempt: Int) -> String {
        let stem = (name as NSString).deletingPathExtension
        let suffix = (name as NSString).pathExtension
        let trimmed = attempt == 0 ? "\(stem) trimmed" : "\(stem) trimmed \(attempt + 1)"
        return suffix.isEmpty ? trimmed : "\(trimmed).\(suffix)"
    }

    /// A hidden folder beside the file, which the part file registry can clear after a crash.
    static func makePartFolder(beside source: URL) throws -> URL {
        let folder = source.deletingLastPathComponent().appendingPathComponent(
            "\(PartFileRegistry.filePrefix)\(UUID().uuidString)\(PartFileRegistry.fileSuffix)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        return folder
    }

    /// Copies the marked range's samples as they are, using an edit list to start on the exact frame.
    /// The result is checked, and takes the source's Finder tags and permissions. Cancelling the task stops it.
    static func exportTrim(
        of source: URL,
        marks: TrimMarks,
        into partFolder: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let asset = AVURLAsset(url: source, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let duration = try await asset.load(.duration).seconds
        guard let range = marks.range(duration: duration) else { throw VideoEditorError.checkFailed }

        let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0
        let needed = Int64(Double(size) * (range.upperBound - range.lowerBound) / duration)
        if let free = try? partFolder.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity, Int64(free) < needed {
            throw VideoEditorError.notEnoughSpace
        }

        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw VideoEditorError.cantExport
        }
        let timescale: CMTimeScale = 600_000
        session.timeRange = CMTimeRange(
            start: CMTime(seconds: range.lowerBound, preferredTimescale: timescale),
            end: CMTime(seconds: range.upperBound, preferredTimescale: timescale)
        )
        let type: AVFileType = switch source.pathExtension.lowercased() {
        case "mov", "qt": .mov
        case "m4v": .m4v
        default: .mp4
        }
        let output = partFolder.appendingPathComponent(source.lastPathComponent)

        nonisolated(unsafe) let watched = session
        let watcher = Task {
            for await state in watched.states(updateInterval: 0.2) {
                if case let .exporting(current) = state { progress(current.fractionCompleted) }
            }
        }
        defer { watcher.cancel() }
        try await session.export(to: output, as: type)

        let result = AVURLAsset(url: output, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let resultDuration = try await result.load(.duration).seconds
        let videoTracks = try await result.loadTracks(withMediaType: .video)
        guard !videoTracks.isEmpty, abs(resultDuration - (range.upperBound - range.lowerBound)) < 0.5 else {
            throw VideoEditorError.checkFailed
        }
        _ = copyfile(source.path, output.path, nil, copyfile_flags_t(COPYFILE_XATTR | COPYFILE_SECURITY))
        return output
    }

    static func publishCopy(_ built: URL, of source: URL) throws -> URL {
        try ClipCopier.publish(built, in: source.deletingLastPathComponent()) { trimmedName(for: source.lastPathComponent, attempt: $0) }
    }

    /// Only touches the original once the new version is complete. If it can't take the name, the original comes back.
    static func publishReplacing(
        _ source: URL,
        with built: URL,
        trash: (URL) throws -> FileOperations.TrashedItem
    ) throws -> FileOperations.TrashedItem {
        if let created = try? FileManager.default.attributesOfItem(atPath: source.path)[.creationDate] {
            try? FileManager.default.setAttributes([.creationDate: created], ofItemAtPath: built.path)
        }
        let trashed = try trash(source)
        do {
            // Something taking the name in this instant isn't overwritten.
            _ = try ClipCopier.publish(built, in: source.deletingLastPathComponent()) {
                $0 == 0 ? source.lastPathComponent : trimmedName(for: source.lastPathComponent, attempt: $0 - 1)
            }
            return trashed
        } catch {
            try? FileOperations.restore(trashed)
            throw error
        }
    }
}
