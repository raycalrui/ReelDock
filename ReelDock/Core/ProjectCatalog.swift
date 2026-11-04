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

    /// A date the way the app shows and accepts it.
    static func dateString(_ date: Date, in timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// The part of a folder name after its date.
    static func name(of folderName: String) -> String {
        let prefix = folderName.prefix(9)
        guard prefix.count == 9, prefix.last == "_", prefix.dropLast().allSatisfy(\.isNumber) else { return folderName }
        return String(folderName.dropFirst(9))
    }

    /// The folder name for a date and a name, or nil if the date isn't valid.
    /// An empty date leaves the folder undated. Zero for a month or day is allowed, for a project with no exact date yet.
    static func folderName(date: String, name: String) -> String? {
        let digits = date.filter { !"-/. ".contains($0) }
        guard !digits.isEmpty else { return name }
        guard digits.count == 8, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber),
              let month = Int(digits.dropFirst(4).prefix(2)), let day = Int(digits.suffix(2)),
              isValid(year: Int(digits.prefix(4)) ?? 0, month: month, day: day) else { return nil }
        return "\(digits)_\(name)"
    }

    private static func isValid(year: Int, month: Int, day: Int) -> Bool {
        guard (0...12).contains(month), (0...31).contains(day) else { return false }
        guard month > 0, day > 0 else { return true }
        return DateComponents(calendar: Calendar(identifier: .gregorian), year: year, month: month, day: day).isValidDate
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
