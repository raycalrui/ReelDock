import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated enum FrameGrabberError: LocalizedError, Equatable {
    case noPicture
    case cantWrite

    var errorDescription: String? {
        switch self {
        case .noPicture: "This frame couldn't be read from the video."
        case .cantWrite: "The picture couldn't be written."
        }
    }
}

/// Saves one frame of a video as a full-size HEIC picture, graded the way the preview shows it.
nonisolated enum FrameGrabber {
    static let pictureKeys: Set<String> = ["picture", "pictures"]
    private static let quality = 0.95

    /// The project's picture section, numbered or not, when the video is inside a project that has one.
    /// Otherwise the video's own folder.
    static func destination(for video: URL, projectRoot: URL?) -> URL {
        let beside = video.deletingLastPathComponent()
        guard let project = project(containing: video, projectRoot: projectRoot),
              let entries = try? FileManager.default.contentsOfDirectory(
                  at: project, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
              ) else { return beside }
        let pictures = entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .filter { pictureKeys.contains(sectionKey(of: $0.lastPathComponent)) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        return pictures.first ?? beside
    }

    /// The top-level folder under the projects folder that holds the video.
    static func project(containing video: URL, projectRoot: URL?) -> URL? {
        guard let projectRoot else { return nil }
        let root = projectRoot.canonicalPath
        var folder = video.deletingLastPathComponent()
        while folder.path != "/" {
            let parent = folder.deletingLastPathComponent()
            if parent.canonicalPath == root { return folder }
            if parent.path == folder.path { break }
            folder = parent
        }
        return nil
    }

    /// `5 picture` and `5picture` are both `picture`, as for sections.
    static func sectionKey(of name: String) -> String {
        (SectionBuilder.numberPrefix(of: name)?.remainder ?? name).lowercased()
    }

    /// `C0012.MP4` at 1:23 and 12 frames becomes `C0012 00-01-23-12.heic`, then `C0012 00-01-23-12 2.heic`.
    /// Colons would show as slashes in Finder.
    static func frameName(for video: URL, seconds: Double, frameRate: Double?, attempt: Int) -> String {
        let stem = video.deletingPathExtension().lastPathComponent
        let code = Timecode.format(seconds, frameRate: frameRate).replacingOccurrences(of: ":", with: "-")
        let base = "\(stem) \(code)"
        return attempt == 0 ? "\(base).heic" : "\(base) \(attempt + 1).heic"
    }

    static func frameRate(of video: URL) async -> Double? {
        guard let track = try? await AVURLAsset(url: video).loadTracks(withMediaType: .video).first,
              let rate = try? await track.load(.nominalFrameRate), rate > 0 else { return nil }
        return Double(rate)
    }

    /// Exactly the frame at `time`, at the video's full size and upright.
    static func frame(of video: URL, at time: CMTime, grade: PreviewGrade?) async throws -> CGImage {
        let asset = AVURLAsset(url: video)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        if let grade {
            // The poster's brightness, which matches Resolve, not the video layer's.
            guard let composition = await grade.composition(for: asset) else { throw FrameGrabberError.noPicture }
            generator.videoComposition = composition
        }
        do {
            return try await generator.image(at: time).image
        } catch {
            throw FrameGrabberError.noPicture
        }
    }

    /// Written to a hidden part file, checked, then given its name, so nothing is replaced or left half-written.
    static func save(_ image: CGImage, in folder: URL, name: (Int) -> String) throws -> URL {
        let part = folder.appendingPathComponent("\(PartFileRegistry.filePrefix)\(UUID().uuidString)\(PartFileRegistry.fileSuffix)")
        defer { try? FileManager.default.removeItem(at: part) }
        guard let destination = CGImageDestinationCreateWithURL(part as CFURL, UTType.heic.identifier as CFString, 1, nil) else {
            throw FrameGrabberError.cantWrite
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination),
              let written = CGImageSourceCreateWithURL(part as CFURL, nil),
              let check = CGImageSourceCopyPropertiesAtIndex(written, 0, nil) as? [CFString: Any],
              check[kCGImagePropertyPixelWidth] as? Int == image.width,
              check[kCGImagePropertyPixelHeight] as? Int == image.height else { throw FrameGrabberError.cantWrite }
        return try ClipCopier.publish(part, in: folder, name: name)
    }
}
