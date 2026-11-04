import AVFoundation
import AppKit
import QuickLookThumbnailing

/// Memory cache over Quick Look thumbnails, which the system also caches on disk.
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let images = NSCache<NSString, NSImage>()

    private init() {
        images.countLimit = 600
    }

    private func key(_ url: URL, _ modified: Date?, _ size: CGFloat) -> String {
        "\(url.path)|\(modified?.timeIntervalSince1970 ?? 0)|\(Int(size))"
    }

    func cached(_ url: URL, modified: Date?, size: CGFloat) -> NSImage? {
        images.object(forKey: key(url, modified, size) as NSString)
    }

    @discardableResult
    func request(
        _ url: URL,
        modified: Date?,
        size: CGFloat,
        scale: CGFloat,
        completion: @escaping @MainActor (NSImage) -> Void
    ) -> QLThumbnailGenerator.Request {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: size, height: size),
            scale: scale,
            representationTypes: [.lowQualityThumbnail, .thumbnail]
        )
        let cacheKey = key(url, modified, size)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            guard let cgImage = representation?.cgImage else { return }
            Task { @MainActor in
                let result = NSImage(cgImage: cgImage, size: .zero)
                self.images.setObject(result, forKey: cacheKey as NSString)
                completion(result)
            }
        }
        return request
    }

    /// A video's actual first frame. Quick Look chooses a frame of its own, usually further in.
    func firstFrame(of url: URL, modified: Date?, size: CGFloat, scale: CGFloat) async -> NSImage? {
        let cacheKey = "first|" + key(url, modified, size)
        if let image = images.object(forKey: cacheKey as NSString) { return image }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: size * scale, height: size * scale)
        guard let cgImage = try? await generator.image(at: .zero).image else { return nil }
        let result = NSImage(cgImage: cgImage, size: .zero)
        images.setObject(result, forKey: cacheKey as NSString)
        return result
    }

    func cancel(_ request: QLThumbnailGenerator.Request) {
        QLThumbnailGenerator.shared.cancel(request)
    }
}
