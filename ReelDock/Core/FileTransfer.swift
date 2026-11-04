import Darwin
import Foundation

/// Copies and moves between folders. Nothing here overwrites a file or deletes one permanently:
/// copies are built and verified under a hidden name first, and a move across volumes sends the original to the Trash.
nonisolated enum FileTransfer {
    enum Kind: Hashable, Sendable {
        case copy
        case move
    }

    struct Item: Hashable, Sendable {
        let source: URL
        let result: URL
        /// Where the original went when a move crossed volumes.
        var trashedOriginal: URL?
    }

    /// Refuses what can never work, before anything is queued.
    static func validate(sources: [URL], destination: URL, kind: Kind) throws {
        guard !FileOperations.isOnCameraCard(destination) else { throw FileOperationError.cameraCard }
        let target = destination.canonicalPath
        for source in sources {
            guard FileManager.default.fileExists(atPath: source.path) else {
                throw FileOperationError.itemMissing(source.lastPathComponent)
            }
            if kind == .move, FileOperations.isOnCameraCard(source) { throw FileOperationError.cameraCard }
            guard target.relocated(from: source.canonicalPath, to: "") == nil else {
                throw FileOperationError.insideItself(source.lastPathComponent)
            }
        }
    }

    /// A move into the folder an item is already in does nothing.
    static func itemsThatWouldChange(_ sources: [URL], destination: URL, kind: Kind) -> [URL] {
        guard kind == .move else { return sources }
        return sources.filter { $0.deletingLastPathComponent().canonicalPath != destination.canonicalPath }
    }

    /// Finder's rule: a drag moves within a volume and copies across volumes. Option forces a copy, and Command forces a move.
    /// A card's files are only ever copied. Nil when the drop would do nothing or can never work.
    static func dropKind(sources: [URL], destination: URL, canCopy: Bool, canMove: Bool, forcesMove: Bool) -> Kind? {
        guard !sources.isEmpty else { return nil }
        let kind: Kind
        if sources.contains(where: FileOperations.isOnCameraCard) {
            guard canCopy else { return nil }
            kind = .copy
        } else if forcesMove {
            kind = .move
        } else if canMove, canCopy {
            kind = sources.allSatisfy { isSameVolume($0, destination) } ? .move : .copy
        } else if canMove {
            kind = .move
        } else if canCopy {
            kind = .copy
        } else {
            return nil
        }
        guard (try? validate(sources: sources, destination: destination, kind: kind)) != nil,
              !itemsThatWouldChange(sources, destination: destination, kind: kind).isEmpty else { return nil }
        return kind
    }

    static func isSameVolume(_ first: URL, _ second: URL) -> Bool {
        guard let left = try? first.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier,
              let right = try? second.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier else { return false }
        return left.isEqual(right)
    }

    /// The bytes that have to be written. A move within a volume writes none.
    static func bytesToWrite(sources: [URL], destination: URL, kind: Kind) -> Int64 {
        sources.reduce(0) { total, source in
            kind == .move && isSameVolume(source, destination) ? total : total + size(of: source)
        }
    }

    private static func size(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        if let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true {
            return Int64(values.fileSize ?? 0)
        }
        let contents = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys))
        return contents?.reduce(Int64(0)) { total, entry in
            guard let entry = entry as? URL, let values = try? entry.resourceValues(forKeys: keys), values.isRegularFile == true else { return total }
            return total + Int64(values.fileSize ?? 0)
        } ?? 0
    }

    /// `clip.mp4` becomes `clip copy.mp4` when copied, and `clip 2.mp4` when moved onto a taken name.
    static func candidateName(for name: String, isFolder: Bool, kind: Kind, attempt: Int) -> String {
        guard attempt > 0 else { return name }
        let stem = isFolder ? name : (name as NSString).deletingPathExtension
        let suffix = isFolder ? "" : (name as NSString).pathExtension
        let numbered: String
        switch kind {
        case .copy: numbered = attempt == 1 ? "\(stem) copy" : "\(stem) copy \(attempt)"
        case .move: numbered = "\(stem) \(attempt + 1)"
        }
        return suffix.isEmpty ? numbered : "\(numbered).\(suffix)"
    }

    static func perform(
        _ source: URL,
        kind: Kind,
        destination: URL,
        control: CopyControl,
        hooks: ClipCopier.Hooks = ClipCopier.Hooks()
    ) throws -> Item {
        let name = source.lastPathComponent
        let isFolder = isPlainFolder(source)
        let nameForAttempt = { candidateName(for: name, isFolder: isFolder, kind: kind, attempt: $0) }

        if kind == .move, isSameVolume(source, destination) {
            return Item(source: source, result: try ClipCopier.publish(source, in: destination, name: nameForAttempt))
        }

        let building = destination.appendingPathComponent(
            "\(PartFileRegistry.filePrefix)\(UUID().uuidString)\(PartFileRegistry.fileSuffix)",
            isDirectory: true
        )
        hooks.partCreated?(building)
        defer {
            try? FileManager.default.removeItem(at: building)
            hooks.partFinished?(building)
        }
        do {
            try FileManager.default.createDirectory(at: building, withIntermediateDirectories: false)
        } catch {
            throw ClipCopier.Failure.destinationWrite((error as NSError).code == NSFileWriteNoPermissionError ? EACCES : EIO)
        }
        try copyTree(source, into: building, control: control, hooks: hooks)
        let result = try ClipCopier.publish(building.appendingPathComponent(name), in: destination, name: nameForAttempt)

        guard kind == .move else { return Item(source: source, result: result) }
        var trashed: NSURL?
        do {
            try FileManager.default.trashItem(at: source, resultingItemURL: &trashed)
        } catch {
            throw FileOperationError.originalKept(name, error.localizedDescription)
        }
        return Item(source: source, result: result, trashedOriginal: trashed as URL?)
    }

    static func describe(_ error: any Error) -> String {
        guard let failure = error as? ClipCopier.Failure else { return error.localizedDescription }
        switch failure {
        case .cancelled: return "Cancelled"
        case .verificationMismatch: return "Verification failed twice. The copy wasn't saved."
        case .sourceSizeChanged: return "A file changed size while copying."
        case let .sourceRead(code): return "Can't read a file: \(String(cString: strerror(code)))"
        case let .destinationWrite(code): return "Can't write to the destination: \(String(cString: strerror(code)))"
        }
    }

    private static func isPlainFolder(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey])
        return values?.isDirectory == true && values?.isPackage != true && values?.isSymbolicLink != true
    }

    /// Every file goes through the verified copier. Sockets and the like are skipped, since reading one could hang.
    private static func copyTree(_ source: URL, into folder: URL, control: CopyControl, hooks: ClipCopier.Hooks) throws {
        let manager = FileManager.default
        let copy = folder.appendingPathComponent(source.lastPathComponent)
        let values = try? source.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
        do {
            if values?.isSymbolicLink == true {
                let target = try manager.destinationOfSymbolicLink(atPath: source.path)
                try manager.createSymbolicLink(atPath: copy.path, withDestinationPath: target)
            } else if values?.isDirectory == true {
                try manager.createDirectory(at: copy, withIntermediateDirectories: false)
                for child in try manager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
                where !child.lastPathComponent.hasPrefix(PartFileRegistry.filePrefix) {
                    try copyTree(child, into: copy, control: control, hooks: hooks)
                }
                // Only extended attributes and dates, because a read-only mode could stop the folder being moved into place.
                _ = copyfile(source.path, copy.path, nil, copyfile_flags_t(COPYFILE_XATTR))
                if let attributes = try? manager.attributesOfItem(atPath: source.path) {
                    var dates: [FileAttributeKey: Any] = [:]
                    dates[.creationDate] = attributes[.creationDate]
                    dates[.modificationDate] = attributes[.modificationDate]
                    try? manager.setAttributes(dates, ofItemAtPath: copy.path)
                }
            } else if values?.isRegularFile == true {
                let output = try copyFile(source, into: folder, control: control, hooks: hooks)
                // Finder tags and permissions. The copier already set the dates.
                _ = copyfile(source.path, output.path, nil, copyfile_flags_t(COPYFILE_METADATA))
            }
        } catch let failure as ClipCopier.Failure {
            throw failure
        } catch {
            throw ClipCopier.Failure.sourceRead((error as NSError).code == NSFileReadNoPermissionError ? EACCES : EIO)
        }
    }

    /// A mismatch is retried once, in case the fault was transient.
    private static func copyFile(_ source: URL, into folder: URL, control: CopyControl, hooks: ClipCopier.Hooks) throws -> URL {
        control.setVerifying(false)
        do {
            return try ClipCopier.copy(source: source, toFolder: folder, control: control, hooks: hooks).url
        } catch ClipCopier.Failure.verificationMismatch {
            control.setVerifying(false)
            return try ClipCopier.copy(source: source, toFolder: folder, control: control, hooks: hooks).url
        }
    }
}
