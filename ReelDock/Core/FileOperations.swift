import Foundation

nonisolated enum FileOperationError: LocalizedError, Equatable {
    case cameraCard
    case invalidName
    case nameTaken(String)
    case importing
    case invalidDate
    case itemMissing(String)
    case insideItself(String)
    case originalKept(String, String)

    var errorDescription: String? {
        switch self {
        case .cameraCard: "ReelDock never changes files on a camera card."
        case .invalidName: "Use a name that isn't empty, doesn't start with a period, and has no slash or colon."
        case let .nameTaken(name): "“\(name)” already exists in this folder."
        case .importing: "Files are being copied into or out of this folder. Try again when that finishes."
        case .invalidDate: "Use a date like 2026-10-28, or leave it empty for no date."
        case let .itemMissing(name): "“\(name)” can't be found."
        case let .insideItself(name): "“\(name)” can't go inside itself."
        case let .originalKept(name, reason): "“\(name)” was copied and verified, but the original couldn't go to the Trash, so both exist. \(reason)"
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

    /// Builds the project under a hidden name, so it only appears once it's complete and can't replace anything.
    /// With no template, it starts empty.
    static func createProject(named name: String, in root: URL, from template: URL) throws -> URL {
        guard !isOnCameraCard(root) else { throw FileOperationError.cameraCard }
        guard isValidName(name) else { throw FileOperationError.invalidName }
        let destination = root.appendingPathComponent(name, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw FileOperationError.nameTaken(name) }

        let building = root.appendingPathComponent(
            "\(PartFileRegistry.filePrefix)\(UUID().uuidString)\(PartFileRegistry.fileSuffix)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: building) }
        if FileManager.default.fileExists(atPath: template.path) {
            try FileManager.default.copyItem(at: template, to: building)
            try tidyTemplateCopy(at: building)
        } else {
            try FileManager.default.createDirectory(at: building, withIntermediateDirectories: false)
        }
        // moveItem refuses to replace an existing item.
        try FileManager.default.moveItem(at: building, to: destination)
        return destination
    }

    /// Drops what shouldn't carry over, and dates what's left as new rather than as old as the template.
    private static func tidyTemplateCopy(at folder: URL) throws {
        let items = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        var kept = [folder]
        for item in items {
            if item.lastPathComponent == ".DS_Store" || item.pathExtension.lowercased() == "drp" {
                try FileManager.default.removeItem(at: item)
            } else {
                kept.append(item)
            }
        }
        let now = Date.now
        for item in kept {
            try? FileManager.default.setAttributes([.creationDate: now, .modificationDate: now], ofItemAtPath: item.path)
        }
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
