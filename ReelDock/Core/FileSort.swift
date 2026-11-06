import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated enum FileSortKey: String, Codable, CaseIterable, Sendable {
    case name
    case date
    case size
    case kind

    var title: String {
        switch self {
        case .name: "Name"
        case .date: "Shooting Date"
        case .size: "Size"
        case .kind: "Kind"
        }
    }

    /// The largest file is usually what's being looked for. Dates run oldest first, like clips on a card.
    var startsDescending: Bool { self == .size }
}

/// How a browser orders its files. Folders stay on top by name, so the way into them doesn't move.
nonisolated struct FileSort: Codable, Equatable, Sendable {
    var key: FileSortKey = .name
    var descending = false

    static let standard = FileSort()

    init(key: FileSortKey = .name, descending: Bool = false) {
        self.key = key
        self.descending = descending
    }

    /// Choosing another key starts in that key's usual direction.
    func choosing(_ newKey: FileSortKey) -> FileSort {
        newKey == key ? self : FileSort(key: newKey, descending: newKey.startsDescending)
    }

    /// `dates` holds shooting dates by item ID. A file with no value for the key goes last in either direction.
    func sorted(_ items: [FolderItem], dates: [String: Date] = [:]) -> [FolderItem] {
        let kinds = key == .kind ? Dictionary(items.map { ($0.id, $0.contentType?.localizedDescription ?? "") }, uniquingKeysWith: { first, _ in first }) : [:]

        func byName(_ lhs: FolderItem, _ rhs: FolderItem) -> ComparisonResult {
            lhs.name.localizedStandardCompare(rhs.name)
        }

        func missingLast<Value: Comparable>(_ lhs: Value?, _ rhs: Value?) -> (result: ComparisonResult, isDecided: Bool) {
            switch (lhs, rhs) {
            case let (left?, right?):
                if left == right { return (.orderedSame, false) }
                let order: ComparisonResult = left < right ? .orderedAscending : .orderedDescending
                return (descending ? order.reversed : order, true)
            case (_?, nil): return (.orderedAscending, true)
            case (nil, _?): return (.orderedDescending, true)
            case (nil, nil): return (.orderedSame, false)
            }
        }

        return items.sorted { lhs, rhs in
            if lhs.isFolder != rhs.isFolder { return lhs.isFolder }
            if lhs.isFolder {
                let order = byName(lhs, rhs)
                return (key == .name && descending ? order.reversed : order) == .orderedAscending
            }
            switch key {
            case .name:
                let order = byName(lhs, rhs)
                return (descending ? order.reversed : order) == .orderedAscending
            case .size:
                let order = missingLast(lhs.size, rhs.size)
                if order.isDecided { return order.result == .orderedAscending }
            case .date:
                let order = missingLast(dates[lhs.id], dates[rhs.id])
                if order.isDecided { return order.result == .orderedAscending }
            case .kind:
                let left = kinds[lhs.id] ?? ""
                let right = kinds[rhs.id] ?? ""
                let order = missingLast(left.isEmpty ? nil : left, right.isEmpty ? nil : right)
                if order.isDecided { return order.result == .orderedAscending }
            }
            return byName(lhs, rhs) == .orderedAscending
        }
    }
}

private nonisolated extension ComparisonResult {
    var reversed: ComparisonResult {
        switch self {
        case .orderedAscending: .orderedDescending
        case .orderedDescending: .orderedAscending
        case .orderedSame: .orderedSame
        }
    }
}

/// When a file was shot, from the file's own metadata. A copy's date on disk can be the day it was copied.
nonisolated enum ShootingDate {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Date] = [:]
    private static let longestConcurrentReads = 6

    /// Reads several at once, because a video's date needs its header. Files already read come from memory.
    static func dates(for items: [FolderItem]) async -> [String: Date] {
        var result: [String: Date] = [:]
        var pending: [FolderItem] = []
        for item in items where !item.isFolder {
            if let date = lock.withLock({ cache[cacheKey(item)] }) {
                result[item.id] = date
            } else {
                pending.append(item)
            }
        }
        await withTaskGroup(of: (FolderItem, Date?).self) { group in
            var next = pending.makeIterator()
            func addNext() -> Bool {
                guard let item = next.next() else { return false }
                group.addTask { (item, await read(item.url, contentType: item.contentType)) }
                return true
            }
            for _ in 0..<longestConcurrentReads where !addNext() { break }
            while let (item, date) = await group.next() {
                if let date {
                    result[item.id] = date
                    lock.withLock { cache[cacheKey(item)] = date }
                }
                _ = addNext()
            }
        }
        return result
    }

    private static func cacheKey(_ item: FolderItem) -> String {
        "\(item.id)|\(item.modified?.timeIntervalSince1970 ?? 0)|\(item.size ?? 0)"
    }

    /// Falls back to the file's creation date, which is what a card's clips are copied with.
    static func read(_ url: URL, contentType: UTType?) async -> Date? {
        if let date = BlackmagicClipInfo.read(url)?.time?.date { return date }
        if contentType?.conforms(to: .movie) == true, let date = await movieDate(url) { return date }
        if contentType?.conforms(to: .image) == true, let date = imageDate(url) { return date }
        return (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
    }

    private static func movieDate(_ url: URL) async -> Date? {
        let asset = AVURLAsset(url: url)
        guard let item = try? await asset.load(.creationDate), let date = try? await item.load(.dateValue) else { return nil }
        // Some files leave the header's date at zero, which reads as 1904.
        return date.timeIntervalSince1970 > 0 ? date : nil
    }

    private static func imageDate(_ url: URL) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let text = exif[kCGImagePropertyExifDateTimeOriginal] as? String else { return nil }
        return exifDate(text)
    }

    /// `2026:10:28 13:14:16`, in the camera's local time.
    static func exifDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: text)
    }
}
