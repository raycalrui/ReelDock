import Foundation

nonisolated struct LedgerEntry: Codable, Equatable, Sendable {
    var umid: String?
    var name: String
    var size: Int64
    var sha256: String
    var destination: String
    var importedAt: Date
}

/// Append-only record of imported clips, stored outside projects and cards.
nonisolated final class ImportLedger: @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()
    private var entries: [LedgerEntry] = []

    init(fileURL: URL) {
        self.fileURL = fileURL
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        let decoder = Self.decoder
        // A damaged line loses that one record, not the rest of the history.
        entries = text.split(separator: "\n").compactMap {
            try? decoder.decode(LedgerEntry.self, from: Data($0.utf8))
        }
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    func append(_ entry: LedgerEntry) throws {
        var line = try Self.encoder.encode(entry)
        line.append(0x0A)
        try lock.withLock {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            entries.append(entry)
        }
    }

    /// UMID identifies a clip exactly. Name and size cover clips with no UMID on record.
    func entries(matching clip: CardClip) -> [LedgerEntry] {
        lock.withLock {
            entries.filter { entry in
                if let umid = clip.umid, let recorded = entry.umid { return umid == recorded }
                return entry.name == clip.name && entry.size == clip.size
            }
        }
    }
}

/// Tracks temporary files in use, so ones left by a crash can be removed on next launch.
nonisolated final class PartFileRegistry: @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()
    private var paths: Set<String> = []

    static let filePrefix = ".reeldock-"
    static let fileSuffix = ".part"

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func add(_ url: URL) {
        lock.withLock {
            paths.insert(url.path)
            save()
        }
    }

    func remove(_ url: URL) {
        lock.withLock {
            paths.remove(url.path)
            save()
        }
    }

    /// Only deletes files that carry the temporary name, whatever the record says.
    func removeLeftovers() {
        lock.withLock {
            guard let data = try? Data(contentsOf: fileURL),
                  let saved = try? JSONDecoder().decode([String].self, from: data) else { return }
            for path in saved {
                let name = (path as NSString).lastPathComponent
                if name.hasPrefix(Self.filePrefix), name.hasSuffix(Self.fileSuffix) {
                    try? FileManager.default.removeItem(atPath: path)
                }
            }
            paths = []
            save()
        }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(Array(paths)).write(to: fileURL, options: .atomic)
    }
}
