import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated enum ImageEditorError: LocalizedError {
    case unreadable
    case severalImages
    case cantWrite

    var errorDescription: String? {
        switch self {
        case .unreadable: "The image can't be read."
        case .severalImages: "This file holds more than one image, which saving would lose."
        case .cantWrite: "The edited image couldn't be written."
        }
    }
}

/// Rotates and crops images. Originals are never written to: an edit is built and checked under a hidden name,
/// then published as a new file, or in the original's place once the original is in the Trash.
nonisolated enum ImageEditor {
    /// Formats that hold one flat image. RAW has no writer, and saving a PSD or PDF would lose its layers or pages.
    private static let editableTypes: [UTType] = [.jpeg, .png, .heic, .heif, .tiff]
    private static let lossyQuality = 0.95

    static func canEdit(_ type: UTType?) -> Bool {
        guard let type, !type.conforms(to: .rawImage) else { return false }
        return editableTypes.contains { type.conforms(to: $0) }
    }

    /// The full-size image, turned the way it's meant to be seen.
    static func load(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw ImageEditorError.unreadable }
        guard CGImageSourceGetCount(source) == 1 else { throw ImageEditorError.severalImages }
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, options) else { throw ImageEditorError.unreadable }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        return try upright(image, orientation: properties?[kCGImagePropertyOrientation] as? Int ?? 1)
    }

    static func rotated(_ image: CGImage, clockwise: Bool) throws -> CGImage {
        try upright(image, orientation: clockwise ? 6 : 8)
    }

    /// `rect` is in pixels from the top left.
    static func cropped(_ image: CGImage, to rect: CGRect) throws -> CGImage {
        guard let result = image.cropping(to: rect) else { throw ImageEditorError.unreadable }
        return result
    }

    /// Applies an EXIF orientation. The transforms are in Core Graphics' bottom-left coordinates.
    private static func upright(_ image: CGImage, orientation: Int) throws -> CGImage {
        guard orientation != 1 else { return image }
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let transform: CGAffineTransform
        switch orientation {
        case 2: transform = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: width, ty: 0)
        case 3: transform = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: width, ty: height)
        case 4: transform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: height)
        case 5: transform = CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: height, ty: width)
        case 6: transform = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: width)
        case 7: transform = CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        case 8: transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: height, ty: 0)
        default: return image
        }
        let swapsSides = orientation >= 5
        guard let context = context(like: image, width: swapsSides ? image.height : image.width, height: swapsSides ? image.width : image.height) else {
            throw ImageEditorError.unreadable
        }
        context.interpolationQuality = .none
        context.concatenate(transform)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else { throw ImageEditorError.unreadable }
        return result
    }

    /// Keeps the image's depth and color space where Core Graphics can draw in them.
    private static func context(like image: CGImage, width: Int, height: Int) -> CGContext? {
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let premultiplied = CGImageAlphaInfo.premultipliedLast.rawValue
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: image.bitsPerComponent, bytesPerRow: 0, space: space, bitmapInfo: image.bitmapInfo.rawValue)
            ?? CGContext(data: nil, width: width, height: height, bitsPerComponent: image.bitsPerComponent, bytesPerRow: 0, space: space, bitmapInfo: premultiplied)
            ?? CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: premultiplied)
    }

    // MARK: Saving

    /// `photo.jpg` becomes `photo edited.jpg`, then `photo edited 2.jpg`.
    static func editedName(for name: String, attempt: Int) -> String {
        let stem = (name as NSString).deletingPathExtension
        let suffix = (name as NSString).pathExtension
        let edited = attempt == 0 ? "\(stem) edited" : "\(stem) edited \(attempt + 1)"
        return suffix.isEmpty ? edited : "\(edited).\(suffix)"
    }

    static func saveCopy(_ image: CGImage, of source: URL) throws -> URL {
        let part = try buildPart(image, of: source)
        defer { try? FileManager.default.removeItem(at: part) }
        return try ClipCopier.publish(part, in: source.deletingLastPathComponent()) { editedName(for: source.lastPathComponent, attempt: $0) }
    }

    /// Only touches the original once the new version is complete. If it can't take the name, the original comes back.
    static func replace(
        _ source: URL,
        with image: CGImage,
        trash: (URL) throws -> FileOperations.TrashedItem
    ) throws -> FileOperations.TrashedItem {
        let part = try buildPart(image, of: source)
        defer { try? FileManager.default.removeItem(at: part) }
        if let created = try? FileManager.default.attributesOfItem(atPath: source.path)[.creationDate] {
            try? FileManager.default.setAttributes([.creationDate: created], ofItemAtPath: part.path)
        }
        let trashed = try trash(source)
        do {
            // Something taking the name in this instant isn't overwritten.
            _ = try ClipCopier.publish(part, in: source.deletingLastPathComponent()) {
                $0 == 0 ? source.lastPathComponent : editedName(for: source.lastPathComponent, attempt: $0 - 1)
            }
            return trashed
        } catch {
            try? FileOperations.restore(trashed)
            throw error
        }
    }

    private static func buildPart(_ image: CGImage, of source: URL) throws -> URL {
        guard let original = CGImageSourceCreateWithURL(source as CFURL, nil), let type = CGImageSourceGetType(original) else {
            throw ImageEditorError.unreadable
        }
        let part = source.deletingLastPathComponent().appendingPathComponent(
            "\(PartFileRegistry.filePrefix)\(UUID().uuidString)\(PartFileRegistry.fileSuffix)"
        )
        do {
            guard let destination = CGImageDestinationCreateWithURL(part as CFURL, type, 1, nil) else { throw ImageEditorError.cantWrite }
            let properties = CGImageSourceCopyPropertiesAtIndex(original, 0, nil) as? [CFString: Any] ?? [:]
            CGImageDestinationAddImage(destination, image, editedProperties(properties, of: image) as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw ImageEditorError.cantWrite }

            guard let written = CGImageSourceCreateWithURL(part as CFURL, nil),
                  let check = CGImageSourceCopyPropertiesAtIndex(written, 0, nil) as? [CFString: Any],
                  check[kCGImagePropertyPixelWidth] as? Int == image.width,
                  check[kCGImagePropertyPixelHeight] as? Int == image.height else { throw ImageEditorError.cantWrite }
            // Finder tags and permissions, but not the dates: the file did change.
            _ = copyfile(source.path, part.path, nil, copyfile_flags_t(COPYFILE_XATTR | COPYFILE_SECURITY))
            return part
        } catch {
            try? FileManager.default.removeItem(at: part)
            throw error
        }
    }

    /// Keeps the metadata. The pixels are already upright, so the orientation has to stop saying otherwise.
    static func editedProperties(_ properties: [CFString: Any], of image: CGImage) -> [CFString: Any] {
        var result = properties
        result[kCGImagePropertyOrientation] = 1
        result[kCGImagePropertyPixelWidth] = nil
        result[kCGImagePropertyPixelHeight] = nil
        if var tiff = result[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            result[kCGImagePropertyTIFFDictionary] = tiff
        }
        if var exif = result[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = image.width
            exif[kCGImagePropertyExifPixelYDimension] = image.height
            result[kCGImagePropertyExifDictionary] = exif
        }
        result[kCGImageDestinationLossyCompressionQuality] = lossyQuality
        return result
    }
}

/// The crop selection, as fractions of the image from its top left.
nonisolated enum CropGeometry {
    enum Grip: Hashable, Sendable {
        case topLeft, top, topRight, left, right, bottomLeft, bottom, bottomRight
        case move
        /// Dragging outside the selection draws a new one.
        case draw
    }

    static let minimumSize: CGFloat = 0.02

    /// Where an image of `size` sits when fitted into `bounds`.
    static func fittedRect(_ size: CGSize, in bounds: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let width = size.width * scale
        let height = size.height * scale
        return CGRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height)
    }

    /// `toleranceX` and `toleranceY` are how close to an edge counts, as fractions.
    static func grip(at point: CGPoint, of rect: CGRect, toleranceX: CGFloat, toleranceY: CGFloat) -> Grip {
        let nearLeft = abs(point.x - rect.minX) <= toleranceX
        let nearRight = abs(point.x - rect.maxX) <= toleranceX
        let nearTop = abs(point.y - rect.minY) <= toleranceY
        let nearBottom = abs(point.y - rect.maxY) <= toleranceY
        let withinX = point.x >= rect.minX - toleranceX && point.x <= rect.maxX + toleranceX
        let withinY = point.y >= rect.minY - toleranceY && point.y <= rect.maxY + toleranceY
        guard withinX, withinY else { return .draw }
        switch (nearLeft, nearRight, nearTop, nearBottom) {
        case (true, _, true, _): return .topLeft
        case (_, true, true, _): return .topRight
        case (true, _, _, true): return .bottomLeft
        case (_, true, _, true): return .bottomRight
        case (true, _, _, _): return .left
        case (_, true, _, _): return .right
        case (_, _, true, _): return .top
        case (_, _, _, true): return .bottom
        default: return .move
        }
    }

    /// The selection after dragging `grip` from `start` to `current`. It stays inside the image and never gets too small to see.
    static func dragged(_ rect: CGRect, grip: Grip, from start: CGPoint, to current: CGPoint) -> CGRect {
        let point = CGPoint(x: min(1, max(0, current.x)), y: min(1, max(0, current.y)))
        if grip == .draw {
            let origin = CGPoint(x: min(1, max(0, start.x)), y: min(1, max(0, start.y)))
            return span(origin, point)
        }
        if grip == .move {
            let x = min(1 - rect.width, max(0, rect.minX + current.x - start.x))
            let y = min(1 - rect.height, max(0, rect.minY + current.y - start.y))
            return CGRect(x: x, y: y, width: rect.width, height: rect.height)
        }
        var left = rect.minX
        var right = rect.maxX
        var top = rect.minY
        var bottom = rect.maxY
        if [.topLeft, .left, .bottomLeft].contains(grip) { left = min(point.x, right - minimumSize) }
        if [.topRight, .right, .bottomRight].contains(grip) { right = max(point.x, left + minimumSize) }
        if [.topLeft, .top, .topRight].contains(grip) { top = min(point.y, bottom - minimumSize) }
        if [.bottomLeft, .bottom, .bottomRight].contains(grip) { bottom = max(point.y, top + minimumSize) }
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    private static func span(_ first: CGPoint, _ second: CGPoint) -> CGRect {
        var left = min(first.x, second.x)
        var top = min(first.y, second.y)
        let width = max(abs(first.x - second.x), minimumSize)
        let height = max(abs(first.y - second.y), minimumSize)
        left = min(left, 1 - width)
        top = min(top, 1 - height)
        return CGRect(x: left, y: top, width: width, height: height)
    }

    static func pixelRect(_ rect: CGRect, imageWidth: Int, imageHeight: Int) -> CGRect {
        let width = CGFloat(imageWidth)
        let height = CGFloat(imageHeight)
        let left = (rect.minX * width).rounded()
        let top = (rect.minY * height).rounded()
        return CGRect(
            x: left,
            y: top,
            width: max(1, min(width - left, (rect.width * width).rounded())),
            height: max(1, min(height - top, (rect.height * height).rounded()))
        )
    }
}
