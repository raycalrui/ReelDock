import Foundation

/// Finds clips already on disk by file name and size. File name alone isn't enough:
/// real projects hold different clips that share a name.
nonisolated struct ClipIndex: Sendable {
    private var paths: [String: [String]] = [:]

    private static func key(name: String, size: Int64) -> String { "\(name)|\(size)" }

    func paths(name: String, size: Int64) -> [String] {
        paths[Self.key(name: name, size: size)] ?? []
    }

    mutating func add(path: String, name: String, size: Int64) {
        paths[Self.key(name: name, size: size), default: []].append(path)
    }

    /// Scans video folders in every project and in the personal archive.
    static func scan(projectRoot: URL?, mediaRoot: URL?) -> ClipIndex {
        var index = ClipIndex()
        for folder in videoFolders(projectRoot: projectRoot, mediaRoot: mediaRoot) {
            index.addFiles(under: folder)
        }
        return index
    }

    static func videoFolders(projectRoot: URL?, mediaRoot: URL?) -> [URL] {
        var folders: [URL] = []
        let manager = FileManager.default
        if let projectRoot {
            for project in (try? FolderReader.read(projectRoot, showHidden: false)) ?? [] where project.isFolder {
                let children = (try? FolderReader.read(project.url, showHidden: false)) ?? []
                folders += children.filter { $0.isFolder && ImportRouting.isVideoFolderName($0.name) }.map(\.url)
            }
        }
        if let mediaRoot {
            for month in (try? FolderReader.read(mediaRoot, showHidden: false)) ?? [] where month.isFolder {
                let video = month.url.appendingPathComponent("video", isDirectory: true)
                if month.name != ImportRouting.archiveTemplateName, manager.fileExists(atPath: video.path) {
                    folders.append(video)
                }
            }
        }
        return folders
    }

    private mutating func addFiles(under folder: URL) {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return }
        for case let url as URL in enumerator {
            if url.lastPathComponent == "_proxy" {
                enumerator.skipDescendants()
                continue
            }
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            add(path: url.path, name: url.lastPathComponent, size: Int64(values.fileSize ?? 0))
        }
    }
}

/// Where a clip is known to be, independent of which tab is asking.
nonisolated struct ClipPresence: Equatable, Sendable {
    var existingPaths: [String]
    var isInLedger: Bool

    var isNew: Bool { existingPaths.isEmpty && !isInLedger }

    static func resolve(_ clip: CardClip, ledger: ImportLedger, index: ClipIndex) -> ClipPresence {
        let recorded = ledger.entries(matching: clip)
        var paths = recorded.map(\.destination).filter { FileManager.default.fileExists(atPath: $0) }
        for path in index.paths(name: clip.name, size: clip.size) where !paths.contains(path) {
            paths.append(path)
        }
        return ClipPresence(existingPaths: paths, isInLedger: !recorded.isEmpty)
    }

    func status(currentFolder: URL?, projectRoot: URL?, mediaRoot: URL?) -> ClipStatus {
        if let currentFolder {
            let prefix = currentFolder.path + "/"
            if let path = existingPaths.first(where: { $0.hasPrefix(prefix) }) {
                return .inCurrentFolder(path: path)
            }
        }
        if let path = existingPaths.first {
            return .elsewhere(path: path, place: Self.placeName(path: path, projectRoot: projectRoot, mediaRoot: mediaRoot))
        }
        return isInLedger ? .importedMissing : .new
    }

    /// The project's folder name, `media/202611`, or else the containing folder's name.
    static func placeName(path: String, projectRoot: URL?, mediaRoot: URL?) -> String {
        if let projectRoot, path.hasPrefix(projectRoot.path + "/") {
            let relative = path.dropFirst(projectRoot.path.count + 1)
            return relative.split(separator: "/").first.map(String.init) ?? projectRoot.lastPathComponent
        }
        if let mediaRoot, path.hasPrefix(mediaRoot.path + "/") {
            let relative = path.dropFirst(mediaRoot.path.count + 1)
            let month = relative.split(separator: "/").first.map(String.init) ?? ""
            return "\(mediaRoot.lastPathComponent)/\(month)"
        }
        return URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
    }
}

nonisolated enum ClipStatus: Equatable, Sendable {
    case new
    case inCurrentFolder(path: String)
    case elsewhere(path: String, place: String)
    case importedMissing

    var path: String? {
        switch self {
        case let .inCurrentFolder(path), let .elsewhere(path, _): path
        case .new, .importedMissing: nil
        }
    }
}

nonisolated enum ImportRouting {
    static let archiveTemplateName = "template"

    /// `3 video`, `3video`, or plain `video`.
    static func isVideoFolderName(_ name: String) -> Bool {
        (SectionBuilder.numberPrefix(of: name)?.remainder ?? name).caseInsensitiveCompare("video") == .orderedSame
    }

    static func videoFolder(inProject project: URL) -> URL? {
        ((try? FolderReader.read(project, showHidden: false)) ?? [])
            .first { $0.isFolder && isVideoFolderName($0.name) }?.url
    }

    /// `<media root>/YYYYMM/video/<device>`, by the month the clip was shot.
    static func archiveFolder(mediaRoot: URL, clip: CardClip, deviceFolder: String) -> URL? {
        guard let month = clip.time?.month else { return nil }
        return mediaRoot
            .appendingPathComponent(month, isDirectory: true)
            .appendingPathComponent("video", isDirectory: true)
            .appendingPathComponent(deviceFolder, isDirectory: true)
    }

    /// Creates the destination. A new month copies the folder layout of `<media root>/template`.
    static func prepareArchiveFolder(_ folder: URL, mediaRoot: URL) throws {
        let manager = FileManager.default
        let month = folder.deletingLastPathComponent().deletingLastPathComponent()
        if !manager.fileExists(atPath: month.path) {
            try createFolderLayout(from: mediaRoot.appendingPathComponent(archiveTemplateName, isDirectory: true), at: month)
        }
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private static func createFolderLayout(from template: URL, at destination: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        guard let enumerator = manager.enumerator(
            at: template,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let base = template.standardizedFileURL.path
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let relative = String(url.standardizedFileURL.path.dropFirst(base.count + 1))
            try manager.createDirectory(at: destination.appendingPathComponent(relative, isDirectory: true), withIntermediateDirectories: true)
        }
    }

    static func hasEnoughSpace(_ bytes: Int64, at folder: URL) -> Bool {
        // Walk up, since the destination folder may not exist yet.
        var url = folder
        while !FileManager.default.fileExists(atPath: url.path), url.path != "/" {
            url = url.deletingLastPathComponent()
        }
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let available = values.volumeAvailableCapacityForImportantUsage else { return true }
        return available >= bytes
    }
}
