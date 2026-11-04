import AppKit
import CoreServices

nonisolated struct FinderTag: Identifiable, Hashable, Sendable {
    let name: String
    /// Finder's color number: 0 none, 1 gray, 2 green, 3 purple, 4 blue, 5 yellow, 6 red, 7 orange.
    let colorIndex: Int

    var id: String { name }

    var color: NSColor? {
        switch colorIndex {
        case 1: .systemGray
        case 2: .systemGreen
        case 3: .systemPurple
        case 4: .systemBlue
        case 5: .systemYellow
        case 6: .systemRed
        case 7: .systemOrange
        default: nil
        }
    }
}

nonisolated struct TagChoice: Identifiable, Hashable, Sendable {
    enum State: Hashable, Sendable {
        case none
        case some
        case all
    }

    let tag: FinderTag
    let state: State

    var id: String { tag.id }
}

/// Finder tags, the same ones Finder shows and sets.
nonisolated enum FinderTags {
    private static let attribute = "com.apple.metadata:_kMDItemUserTags"
    /// Finder's menu order: red, orange, yellow, green, blue, purple, gray.
    private static let standardOrder = [6, 7, 5, 2, 4, 3, 1]

    /// Each stored tag is `Name` or `Name\n7`, where the number is its color.
    static func parse(_ data: Data) -> [FinderTag] {
        guard let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String] else { return [] }
        return list.compactMap { entry in
            let parts = entry.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            guard let name = parts.first, !name.isEmpty else { return nil }
            let color = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
            return FinderTag(name: String(name), colorIndex: (0...7).contains(color) ? color : 0)
        }
    }

    /// Reads the attribute directly, because the file system's tag names leave out each tag's color.
    static func read(_ url: URL) -> [FinderTag] {
        url.withUnsafeFileSystemRepresentation { path -> [FinderTag] in
            guard let path else { return [] }
            let size = getxattr(path, attribute, nil, 0, 0, 0)
            guard size > 0 else { return [] }
            var data = Data(count: size)
            let read = data.withUnsafeMutableBytes { getxattr(path, attribute, $0.baseAddress, size, 0, 0) }
            return read == size ? parse(data) : []
        }
    }

    /// Goes through the system, which also sets the Finder color and keeps each known tag's color.
    static func write(_ names: [String], to url: URL) throws {
        guard !FileOperations.isOnCameraCard(url) else { throw FileOperationError.cameraCard }
        try (url as NSURL).setResourceValue(names, forKey: .tagNamesKey)
    }

    static func names(_ current: [String], setting name: String, enabled: Bool) -> [String] {
        let others = current.filter { $0 != name }
        return enabled ? others + [name] : others
    }

    /// The colors every item has, by any tag of that color. This is what the row of color dots shows checked.
    static func sharedColors(among current: [[FinderTag]]) -> Set<Int> {
        guard let first = current.first else { return [] }
        return current.dropFirst().reduce(Set(first.map(\.colorIndex))) { $0.intersection($1.map(\.colorIndex)) }.subtracting([0])
    }

    /// Turning a color off removes every tag of that color, not only the one named after it.
    static func names(_ current: [FinderTag], settingColorOf tag: FinderTag, enabled: Bool) -> [String] {
        let others = current.filter { $0.colorIndex != tag.colorIndex }.map(\.name)
        guard enabled else { return others }
        return current.contains { $0.colorIndex == tag.colorIndex } ? current.map(\.name) : others + [tag.name]
    }

    static func isValidName(_ name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !name.contains("\n")
    }

    /// `labels` is the system's localized list, indexed by color number.
    static func standardTags(labels: [String]) -> [FinderTag] {
        standardOrder.compactMap { index in
            labels.indices.contains(index) ? FinderTag(name: labels[index], colorIndex: index) : nil
        }
    }

    /// macOS has no public list of Finder's tags. Its preferences name the tags in its sidebar and the ones that have been opened there.
    static func names(inFinderPreferences preferences: [String: Any]) -> [String] {
        let suffix = "_Tag_ViewSettings"
        let opened = (preferences["ViewSettingsDictionary"] as? [String: Any] ?? [:]).keys
            .filter { $0.hasSuffix(suffix) }
            .map { String($0.dropLast(suffix.count)) }
        let inSidebar = preferences["FavoriteTagNames"] as? [String] ?? []
        return (opened + inSidebar).filter(isValidName)
    }

    /// Every tag on a file Spotlight has indexed, with its color.
    static func inSpotlight(limit: Int = 5000) -> [FinderTag] {
        guard let query = MDQueryCreate(kCFAllocatorDefault, "kMDItemUserTags == \"*\"" as CFString, nil, nil) else { return [] }
        MDQuerySetMaxCount(query, limit)
        guard MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return [] }
        var tags = Set<FinderTag>()
        for index in 0..<MDQueryGetResultCount(query) {
            guard let result = MDQueryGetResultAtIndex(query, index) else { continue }
            let item = Unmanaged<MDItem>.fromOpaque(result).takeUnretainedValue()
            guard let path = MDItemCopyAttribute(item, kMDItemPath) as? String else { continue }
            tags.formUnion(read(URL(fileURLWithPath: path)))
        }
        return Array(tags)
    }

    /// What can be found of the tags on this Mac. A tag only seen in Finder's preferences has no known color.
    static func onThisMac() -> [FinderTag] {
        let preferences = UserDefaults(suiteName: "com.apple.finder")?.dictionaryRepresentation() ?? [:]
        return inSpotlight() + names(inFinderPreferences: preferences).map { FinderTag(name: $0, colorIndex: 0) }
    }

    /// The standard tags first, then every other tag in use, each marked by how many items have it.
    /// A name seen with and without a color keeps the color.
    static func choices(standard: [FinderTag], seen: [FinderTag], current: [[FinderTag]]) -> [TagChoice] {
        let inUse = seen + current.flatMap { $0 }
        var known = standard
        var names = Set(standard.map(\.name))
        let others = inUse
            .sorted {
                let order = $0.name.localizedStandardCompare($1.name)
                return order == .orderedSame ? $0.colorIndex > $1.colorIndex : order == .orderedAscending
            }
            .filter { names.insert($0.name).inserted }
        known += others
        return known.map { tag in
            let count = current.filter { $0.contains { $0.name == tag.name } }.count
            let state: TagChoice.State = count == 0 ? .none : (count == current.count ? .all : .some)
            return TagChoice(tag: tag, state: state)
        }
    }
}
