import Foundation

nonisolated enum FileOperationError: LocalizedError, Equatable {
    case cameraCard
    case invalidName
    case nameTaken(String)
    case importing
    case invalidDate

    var errorDescription: String? {
        switch self {
        case .cameraCard: "ReelDock never changes files on a camera card."
        case .invalidName: "Use a name that isn't empty, doesn't start with a period, and has no slash or colon."
        case let .nameTaken(name): "“\(name)” already exists in this folder."
        case .importing: "Clips are being imported into this project. Try again when the import finishes."
        case .invalidDate: "Use a date like 2026-10-28, or leave it empty for no date."
        }
    }
}

/// File changes made from the browser. Nothing here overwrites a file or deletes one permanently.
nonisolated enum FileOperations {
    struct TrashedItem: Hashable, Sendable {
        let original: URL
        let trashed: URL
    }

    /// Asks the volume itself, so a card is protected even before the card monitor has seen it.
    static func isOnCameraCard(_ url: URL) -> Bool {
        guard let volume = try? url.resourceValues(forKeys: [.volumeURLKey]).volume, volume.path != "/" else { return false }
        return CardAdapters.adapter(for: volume) != nil
    }

    static func uniqueFolderName(in folder: URL, base: String = "untitled folder") -> String {
        var name = base
        var number = 2
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
            name = "\(base) \(number)"
            number += 1
        }
        return name
    }

    static func createFolder(in folder: URL) throws -> URL {
        guard !isOnCameraCard(folder) else { throw FileOperationError.cameraCard }
        let url = folder.appendingPathComponent(uniqueFolderName(in: folder), isDirectory: true)
        // Creating without intermediates fails if another process took the name first.
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    static func isValidName(_ name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !name.hasPrefix(".")
            && !name.contains("/")
            && !name.contains(":")
    }

    /// Returns the new location. Changing only a name's case is allowed, since it can't replace another file.
    static func rename(_ url: URL, to name: String) throws -> URL {
        guard !isOnCameraCard(url) else { throw FileOperationError.cameraCard }
        guard isValidName(name) else { throw FileOperationError.invalidName }
        let destination = url.deletingLastPathComponent().appendingPathComponent(name)
        guard destination.lastPathComponent != url.lastPathComponent else { return url }

        if FileManager.default.fileExists(atPath: destination.path) {
            guard destination.canonicalPath == url.canonicalPath else { throw FileOperationError.nameTaken(name) }
            guard Darwin.rename(url.path, destination.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return destination
        }
        // moveItem refuses to replace an existing item.
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }

    /// Stops at the first failure, reporting what was already moved so it can still be undone.
    static func moveToTrash(_ urls: [URL]) -> (moved: [TrashedItem], error: (any Error)?) {
        var moved: [TrashedItem] = []
        for url in urls {
            do {
                guard !isOnCameraCard(url) else { throw FileOperationError.cameraCard }
                var resulting: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
                moved.append(TrashedItem(original: url, trashed: (resulting as URL?) ?? url))
            } catch {
                return (moved, error)
            }
        }
        return (moved, nil)
    }

    /// Fails rather than replacing anything created at the original path in the meantime.
    static func restore(_ item: TrashedItem) throws {
        guard !FileManager.default.fileExists(atPath: item.original.path) else {
            throw FileOperationError.nameTaken(item.original.lastPathComponent)
        }
        try FileManager.default.moveItem(at: item.trashed, to: item.original)
    }
}
