import Foundation

enum BrowserMode: String, Codable, Sendable {
    case sections
    case single
}

nonisolated struct FolderSection: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case numbered(Int)
        case folder
        case looseFiles
    }

    let kind: Kind
    let url: URL
    let title: String
    /// Nil when the folder could not be read, which is different from empty.
    let itemCount: Int?
    var tags: [FinderTag] = []

    var id: String { kind == .looseFiles ? "files:\(url.path)" : url.path }
    var isFilesOnly: Bool { kind == .looseFiles }

    var isNumbered: Bool {
        if case .numbered = kind { return true }
        return false
    }

    /// Everyday folders start open. In a folder with no numbered layout, everything starts open.
    func startsExpanded(amongNumberedSections hasNumbered: Bool) -> Bool {
        guard hasNumbered else { return true }
        return isNumbered && SectionBuilder.defaultExpandedKeys.contains(preferenceKey)
    }

    /// Pictures read better as a grid, and everything else starts as a list.
    var startsAsGrid: Bool {
        SectionBuilder.gridKeys.contains(preferenceKey)
    }

    /// More items earn more height, within limits, but footage always gets the most.
    func defaultWeight(itemCount: Int?) -> Double {
        if preferenceKey == SectionBuilder.footageKey { return SectionBuilder.footageWeight }
        return 1 + Double(min(itemCount ?? 1, SectionBuilder.weightItemLimit)) * 0.2
    }

    /// Identifies the section across projects, so `3 video` and `3video` share layout preferences.
    var preferenceKey: String {
        switch kind {
        case .looseFiles:
            "__files"
        case .numbered:
            (SectionBuilder.numberPrefix(of: title)?.remainder ?? title).lowercased()
        case .folder:
            title.lowercased()
        }
    }
}

nonisolated enum SectionBuilder {
    static let looseFilesTitle = "Files"
    static let defaultExpandedKeys: Set<String> = ["output", "video", "cover"]
    static let gridKeys: Set<String> = ["cover", "picture", "pictures", "photo", "photos"]
    static let footageKey = "video"
    /// A single browser has no section name, so all of them share one set of view options.
    static let singleBrowserKey = "__single"
    static let weightItemLimit = 24
    /// Above the largest weight item count can reach, which is 5.8.
    static let footageWeight = 8.0

    /// Matches `3 video` and `3video`, but not date-named folders such as `20261028_example`.
    static func numberPrefix(of name: String) -> (number: Int, remainder: String)? {
        let digits = name.prefix(while: \.isNumber)
        guard (1...2).contains(digits.count), let number = Int(digits) else { return nil }
        let remainder = name.dropFirst(digits.count).drop(while: \.isWhitespace)
        guard let first = remainder.first, first.isLetter else { return nil }
        return (number, String(remainder))
    }

    static func build(folder: URL, showHidden: Bool) throws -> [FolderSection] {
        let items = try FolderReader.read(folder, showHidden: showHidden)

        var numbered: [(number: Int, section: FolderSection)] = []
        var others: [FolderSection] = []
        for item in items where item.isFolder {
            let count = (try? FolderReader.read(item.url, showHidden: showHidden).count)
            if let prefix = numberPrefix(of: item.name) {
                let section = FolderSection(kind: .numbered(prefix.number), url: item.url, title: item.name, itemCount: count, tags: item.tags)
                numbered.append((prefix.number, section))
            } else {
                others.append(FolderSection(kind: .folder, url: item.url, title: item.name, itemCount: count, tags: item.tags))
            }
        }
        numbered.sort {
            if $0.number != $1.number { return $0.number < $1.number }
            return $0.section.title.localizedStandardCompare($1.section.title) == .orderedAscending
        }

        var sections = numbered.map(\.section) + others
        let looseFiles = items.filter { !$0.isFolder }
        if !looseFiles.isEmpty {
            sections.append(FolderSection(kind: .looseFiles, url: folder, title: looseFilesTitle, itemCount: looseFiles.count))
        }
        return sections
    }

    static func defaultMode(for folder: URL, projectRoot: URL?) -> BrowserMode {
        if let projectRoot, folder.deletingLastPathComponent().canonicalPath == projectRoot.canonicalPath {
            return .sections
        }
        let items = (try? FolderReader.read(folder, showHidden: false)) ?? []
        return items.contains { $0.isFolder && numberPrefix(of: $0.name) != nil } ? .sections : .single
    }
}
