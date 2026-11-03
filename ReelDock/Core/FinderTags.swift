import AppKit

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

    static func isValidName(_ name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !name.contains("\n")
    }

    /// `labels` is the system's localized list, indexed by color number.
    static func standardTags(labels: [String]) -> [FinderTag] {
        standardOrder.compactMap { index in
            labels.indices.contains(index) ? FinderTag(name: labels[index], colorIndex: index) : nil
        }
    }

    /// The standard tags first, then every other tag in use, each marked by how many items have it.
    static func choices(standard: [FinderTag], seen: [FinderTag], current: [[FinderTag]]) -> [TagChoice] {
        let inUse = seen + current.flatMap { $0 }
        var known = standard
        var names = Set(standard.map(\.name))
        let others = inUse
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .filter { names.insert($0.name).inserted }
        known += others
        return known.map { tag in
            let count = current.filter { $0.contains { $0.name == tag.name } }.count
            let state: TagChoice.State = count == 0 ? .none : (count == current.count ? .all : .some)
            return TagChoice(tag: tag, state: state)
        }
    }
}
