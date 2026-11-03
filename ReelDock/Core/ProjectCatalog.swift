import Foundation

nonisolated struct ProjectEntry: Identifiable, Hashable, Sendable {
    let url: URL
    let folderName: String
    /// The eight digits of a `YYYYMMDD_name` folder.
    let dateStamp: String?
    let title: String
    var tags: [FinderTag] = []

    var id: String { url.path }

    var displayDate: String? {
        guard let dateStamp else { return nil }
        return "\(dateStamp.prefix(4))-\(dateStamp.dropFirst(4).prefix(2))-\(dateStamp.suffix(2))"
    }
}

nonisolated enum ProjectCatalog {
    private static let templatePrefix = "00000000_"

    static func isTemplate(_ folderName: String) -> Bool {
        folderName.hasPrefix(templatePrefix)
    }

    static func entry(for url: URL) -> ProjectEntry {
        let name = url.lastPathComponent
        let digits = name.prefix(8)
        let rest = name.dropFirst(8)
        if digits.count == 8, digits.allSatisfy(\.isNumber), rest.first == "_" {
            let title = rest.dropFirst().trimmingCharacters(in: .whitespaces)
            return ProjectEntry(url: url, folderName: name, dateStamp: String(digits), title: title.isEmpty ? name : title)
        }
        return ProjectEntry(url: url, folderName: name, dateStamp: nil, title: name)
    }

    /// Lists projects newest first. Folders without a date follow in name order.
    static func list(root: URL) throws -> [ProjectEntry] {
        try FolderReader.read(root, showHidden: false)
            .filter { $0.isFolder && !isTemplate($0.name) }
            .map { item in
                var project = entry(for: item.url)
                project.tags = item.tags
                return project
            }
            .sorted { lhs, rhs in
                switch (lhs.dateStamp, rhs.dateStamp) {
                case let (left?, right?) where left != right:
                    return left > right
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                default:
                    return lhs.folderName.localizedStandardCompare(rhs.folderName) == .orderedAscending
                }
            }
    }
}
