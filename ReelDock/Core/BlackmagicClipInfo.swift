import AVFoundation
import Darwin
import Foundation

nonisolated enum ExtendedAttributes {
    static func data(named name: String, of url: URL) -> Data? {
        let size = getxattr(url.path, name, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, size, 0, 0) }
        return read == size ? data : nil
    }

    static func names(of url: URL) -> [String] {
        let size = listxattr(url.path, nil, 0, 0)
        guard size > 0 else { return [] }
        var bytes = [CChar](repeating: 0, count: size)
        guard listxattr(url.path, &bytes, size, 0) == size else { return [] }
        return bytes.split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
    }

    /// Best effort, because a file system may not take them. The file itself is what matters.
    static func copy(from source: URL, to destination: URL, where keep: (String) -> Bool) {
        for name in names(of: source) where keep(name) {
            guard let data = data(named: name, of: source) else { continue }
            _ = data.withUnsafeBytes { setxattr(destination.path, name, $0.baseAddress, data.count, 0, 0) }
        }
    }
}

/// What the Blackmagic Camera app records about a clip, kept in an extended attribute that survives AirDrop.
nonisolated struct BlackmagicClipInfo: Equatable, Sendable {
    static let attributePrefix = "com.blackmagicdesign."
    static let infoAttribute = "com.blackmagicdesign.fileinfo"
    static let thumbnailAttribute = "com.blackmagicdesign.thumbnail"

    var time: ClipTime?
    var cameraType: String?
    var gamma: String?
    var lens: String?
    var codec: String?
    var width: Int?
    var height: Int?
    var frameRate: Double?
    var frameCount: Int?

    private struct Raw: Decodable {
        struct Rational: Decodable {
            var num: Double?
            var den: Double?
        }
        struct Resolution: Decodable {
            var width: Int?
            var height: Int?
        }
        struct Video: Decodable {
            var codec: String?
            var resolution: Resolution?
            var frame_rate: Rational?
            var frame_count: Int?
        }
        struct Common: Decodable {
            var gamma: String?
            var lens_type: String?
        }
        struct Specific: Decodable {
            var camera_type: String?
            var date_recorded: String?
        }
        var creation_date: String?
        var video: Video?
        var common_clip_metadata: Common?
        var file_specific_clip_metadata: Specific?
    }

    static func read(_ url: URL) -> BlackmagicClipInfo? {
        ExtendedAttributes.data(named: infoAttribute, of: url).flatMap(parse)
    }

    static func thumbnail(of url: URL) -> Data? {
        ExtendedAttributes.data(named: thumbnailAttribute, of: url)
    }

    static func parse(_ data: Data) -> BlackmagicClipInfo? {
        guard let raw = try? JSONDecoder().decode(Raw.self, from: data) else { return nil }
        var info = BlackmagicClipInfo()
        info.time = (raw.file_specific_clip_metadata?.date_recorded ?? raw.creation_date)
            .map(addingColonToZone)
            .flatMap(ClipTime.init(recorded:))
        // It becomes a folder name, and it comes from a file. Anything that isn't a plain name means asking instead.
        info.cameraType = raw.file_specific_clip_metadata?.camera_type.flatMap { FileOperations.isValidName($0) ? $0 : nil }
        info.gamma = raw.common_clip_metadata?.gamma
        info.lens = raw.common_clip_metadata?.lens_type
        info.codec = raw.video?.codec
        info.width = raw.video?.resolution?.width
        info.height = raw.video?.resolution?.height
        if let rate = raw.video?.frame_rate, let num = rate.num, let den = rate.den, den > 0 {
            info.frameRate = num / den
        }
        info.frameCount = raw.video?.frame_count
        return info
    }

    /// `+0800` becomes `+08:00`, the form the date parser takes.
    private static func addingColonToZone(_ text: String) -> String {
        guard text.count > 5 else { return text }
        let zone = text.suffix(5)
        guard let sign = zone.first, sign == "+" || sign == "-", zone.dropFirst().allSatisfy(\.isNumber) else { return text }
        return text.dropLast(2) + ":" + text.suffix(2)
    }
}

/// Which log curve footage was shot in, from what the camera wrote, so a LUT is never put on the wrong picture.
nonisolated enum LogGamma: String, Codable, CaseIterable, Sendable {
    case sLog3 = "S-Log3"
    case appleLog = "Apple Log"
    case appleLog2 = "Apple Log 2"
}

nonisolated enum LogFootage {
    /// Sony writes its metadata at the very end of the file. It was 799 bytes from the end on real clips.
    private static let sonyTrailerLength = 8192
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: LogGamma?] = [:]

    static func gamma(of url: URL) async -> LogGamma? {
        let key = cacheKey(url)
        if let known = lock.withLock({ cache[key] }) { return known }
        let found = await read(url)
        lock.withLock { cache[key] = .some(found) }
        return found
    }

    /// What's already been read, for a key press that can't wait. Selecting a clip reads it.
    static func knownGamma(of url: URL) -> LogGamma? {
        let key = cacheKey(url)
        return lock.withLock { cache[key] ?? nil }
    }

    private static func cacheKey(_ url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return "\(url.path)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(values?.fileSize ?? 0)"
    }

    /// The video track's own tag comes first, because it's the only thing that tells Apple Log from Apple Log 2:
    /// Blackmagic Camera calls both "Apple Log".
    private static func read(_ url: URL) async -> LogGamma? {
        if let tag = await logTag(of: url), let gamma = gamma(logTag: tag) { return gamma }
        if let info = BlackmagicClipInfo.read(url) {
            return info.gamma.flatMap(gamma(named:))
        }
        guard url.pathExtension.caseInsensitiveCompare("MP4") == .orderedSame,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        try? handle.seek(toOffset: end > UInt64(sonyTrailerLength) ? end - UInt64(sonyTrailerLength) : 0)
        guard let trailer = try? handle.read(upToCount: sonyTrailerLength) else { return nil }
        return sonyGamma(inTrailer: trailer).flatMap(gamma(named:))
    }

    private static func logTag(of url: URL) async -> String? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let format = try? await track.load(.formatDescriptions).first else { return nil }
        return CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_LogTransferFunction) as? String
    }

    static func gamma(logTag tag: String) -> LogGamma? {
        if tag == kCVImageBufferLogTransferFunction_AppleLog as String { return .appleLog }
        if tag == kCVImageBufferLogTransferFunction_AppleLog2 as String { return .appleLog2 }
        return nil
    }

    /// `s-log3-cine` and `s-log3` are the same curve.
    static func gamma(named name: String) -> LogGamma? {
        let lowered = name.lowercased()
        if lowered.hasPrefix("s-log3") { return .sLog3 }
        if lowered.hasPrefix("apple log 2") { return .appleLog2 }
        if lowered.hasPrefix("apple log") { return .appleLog }
        return nil
    }

    static func sonyGamma(inTrailer data: Data) -> String? {
        guard let text = String(data: data, encoding: .isoLatin1),
              let name = text.range(of: "CaptureGammaEquation"),
              let open = text.range(of: "value=\"", range: name.upperBound..<text.endIndex),
              let close = text.range(of: "\"", range: open.upperBound..<text.endIndex) else { return nil }
        return String(text[open.upperBound..<close.lowerBound])
    }
}
