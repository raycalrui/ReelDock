import Foundation
import UniformTypeIdentifiers

nonisolated extension URL {
    /// The real path of an existing item, matching the form FSEvents reports.
    var canonicalPath: String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

nonisolated struct FolderItem: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    /// True for folders the browser can enter. Packages behave as files.
    let isFolder: Bool
    let size: Int64?
    let modified: Date?
    let contentType: UTType?
    var tags: [FinderTag] = []

    var id: String { url.path }

    var isVideo: Bool { contentType?.conforms(to: .movie) ?? false }
    var isPlayable: Bool { !isFolder && contentType?.conforms(to: .audiovisualContent) == true }
    var canPreviewFullScreen: Bool { isVideo || contentType?.conforms(to: .image) == true }
    var hasVisualThumbnail: Bool {
        guard let contentType else { return false }
        return contentType.conforms(to: .movie) || contentType.conforms(to: .image) || contentType.conforms(to: .pdf)
    }
}

nonisolated enum FolderReader {
    private static let keys: Set<URLResourceKey> = [
        .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isHiddenKey,
        .fileSizeKey, .contentModificationDateKey, .contentTypeKey,
    ]

    /// Reads one folder level, folders first, then in Finder's name order.
    static func read(_ folder: URL, showHidden: Bool) throws -> [FolderItem] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: Array(keys),
            options: []
        )
        let items = urls.compactMap { url -> FolderItem? in
            let values = try? url.resourceValues(forKeys: keys)
            let name = url.lastPathComponent
            if !showHidden, name.hasPrefix(".") || values?.isHidden == true { return nil }
            return FolderItem(
                url: url,
                name: name,
                isFolder: isNavigableFolder(url, values: values),
                size: values?.fileSize.map(Int64.init),
                modified: values?.contentModificationDate,
                contentType: values?.contentType,
                tags: FinderTags.read(url)
            )
        }
        return items.sorted(by: sortsBefore)
    }

    static func sortsBefore(_ lhs: FolderItem, _ rhs: FolderItem) -> Bool {
        if lhs.isFolder != rhs.isFolder { return lhs.isFolder }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    private static func isNavigableFolder(_ url: URL, values: URLResourceValues?) -> Bool {
        if values?.isSymbolicLink == true {
            let target = try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            return target?.isDirectory == true && target?.isPackage != true
        }
        return values?.isDirectory == true && values?.isPackage != true
    }
}
