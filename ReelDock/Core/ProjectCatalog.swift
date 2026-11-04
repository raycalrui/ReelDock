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
    /// What a new project is copied from, inside the projects folder.
    static let templateName = "00000000_template"

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
    /// A name that would read as a template is refused too, since templates aren't listed.
    static func folderName(date: String, name: String) -> String? {
        let digits = date.filter { !"-/. ".contains($0) }
        guard !digits.isEmpty else { return isTemplate(name) ? nil : name }
        guard digits != "00000000", digits.count == 8, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber),
              let month = Int(digits.dropFirst(4).prefix(2)), let day = Int(digits.suffix(2)),
              isValid(year: Int(digits.prefix(4)) ?? 0, month: month, day: day) else { return nil }
        return "\(digits)_\(name)"
    }

    private static func isValid(year: Int, month: Int, day: Int) -> Bool {
        guard (0...12).contains(month), (0...31).contains(day) else { return false }
        guard month > 0, day > 0 else { return true }
        return DateComponents(calendar: Calendar(identifier: .gregorian), year: year, month: month, day: day).isValidDate
    }

    /// The project folder a path is in, or nil if it isn't inside one.
    static func projectName(containing path: String, root: String) -> String? {
        guard path.hasPrefix(root + "/") else { return nil }
        return path.dropFirst(root.count + 1).split(separator: "/").first.map(String.init)
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

    static func filter(_ projects: [ProjectEntry], query: String, tag: String?) -> [ProjectEntry] {
        let query = query.trimmingCharacters(in: .whitespaces)
        return projects.filter { project in
            (query.isEmpty || project.folderName.localizedCaseInsensitiveContains(query))
                && (tag == nil || project.tags.contains { $0.name == tag })
        }
    }

    /// Every tag on the projects, once each, in name order.
    static func tags(in projects: [ProjectEntry]) -> [FinderTag] {
        var seen = Set<String>()
        return projects.flatMap(\.tags)
            .filter { seen.insert($0.name).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
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

/// What a project holds, shown in the project lists.
nonisolated struct ProjectStats: Hashable, Sendable {
    let fileCount: Int
    let size: Int64

    var fileLabel: String { fileCount == 1 ? "1 file" : "\(fileCount) files" }

    static func read(_ folder: URL) -> ProjectStats? {
        FolderSummary.read(folder)?.total
    }
}

/// What a folder holds, shown in the inspector when nothing is selected.
nonisolated struct FolderSummary: Hashable, Sendable {
    struct Section: Hashable, Sendable, Identifiable {
        let name: String
        let stats: ProjectStats

        var id: String { name }
    }

    let total: ProjectStats
    /// The folders at its top level, in Finder's name order.
    let sections: [Section]
    let videos: Int
    let pictures: Int
    let audio: Int
    let created: Date?
    let modified: Date?

    /// What's left of the total outside the sections: loose files, and anything hidden at the top level.
    var outsideSections: ProjectStats {
        ProjectStats(
            fileCount: total.fileCount - sections.map(\.stats.fileCount).reduce(0, +),
            size: total.size - sections.map(\.stats.size).reduce(0, +)
        )
    }

    /// The size covers everything, to match Finder. The count skips what the browser hides, and a package is one file.
    /// Returns nil if cancelled, since an opened folder can be far larger than a project.
    static func read(_ folder: URL) -> FolderSummary? {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isPackageKey, .fileSizeKey, .contentTypeKey]
        guard (try? folder.checkResourceIsReachable()) == true,
              let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: Array(keys)) else { return nil }
        var fileCount = 0
        var size: Int64 = 0
        var videos = 0
        var pictures = 0
        var audio = 0
        var sections: [(name: String, fileCount: Int, size: Int64)] = []
        var section: Int?
        // Set inside something the count leaves out: a hidden folder or a package.
        var uncountedLevel: Int?
        for case let url as URL in enumerator {
            if Task.isCancelled { return nil }
            if let level = uncountedLevel, enumerator.level <= level { uncountedLevel = nil }
            let values = try? url.resourceValues(forKeys: keys)
            let isHidden = url.lastPathComponent.hasPrefix(".")
            if enumerator.level == 1 {
                section = nil
                if values?.isDirectory == true, values?.isPackage != true, !isHidden {
                    sections.append((url.lastPathComponent, 0, 0))
                    section = sections.count - 1
                }
            }
            let bytes = Int64(values?.fileSize ?? 0)
            size += bytes
            if let section { sections[section].size += bytes }
            guard uncountedLevel == nil else { continue }
            let isPackage = values?.isPackage == true
            if isHidden || isPackage { uncountedLevel = enumerator.level }
            guard !isHidden, isPackage || values?.isRegularFile == true else { continue }
            fileCount += 1
            if let section { sections[section].fileCount += 1 }
            if let type = values?.contentType {
                if type.conforms(to: .movie) { videos += 1 }
                else if type.conforms(to: .image) { pictures += 1 }
                else if type.conforms(to: .audio) { audio += 1 }
            }
        }
        let dates = try? folder.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return FolderSummary(
            total: ProjectStats(fileCount: fileCount, size: size),
            sections: sections
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                .map { Section(name: $0.name, stats: ProjectStats(fileCount: $0.fileCount, size: $0.size)) },
            videos: videos,
            pictures: pictures,
            audio: audio,
            created: dates?.creationDate,
            modified: dates?.contentModificationDate
        )
    }
}

/// Picks the picture that stands for a project in the project lists.
nonisolated enum ProjectThumbnail {
    enum Source: Hashable, Sendable {
        case cover(FolderItem)
        case firstFrame(FolderItem)
    }

    private static let coverKey = "cover"
    private static let videoKey = "video"
    /// How far to look through folders inside `3 video`, since real projects can nest deep proxy trees there.
    private static let videoFolderDepth = 2

    /// `cover 169.jpg` or `cover sc 169.jpg`, but not `cover.jpg` or `cover_01_00_11_69.jpg`.
    static func isWideCover(_ item: FolderItem) -> Bool {
        guard !item.isFolder, item.contentType?.conforms(to: .image) == true else { return false }
        let stem = (item.name as NSString).deletingPathExtension.lowercased()
        guard stem.hasPrefix(coverKey), stem.hasSuffix("169") else { return false }
        return stem.dropLast(3).last?.isNumber == false
    }

    /// A wide cover if there is one, otherwise the first video. Reads only the folders it needs.
    static func source(in project: URL) -> Source? {
        guard let sections = try? FolderReader.read(project, showHidden: false) else { return nil }
        if let folder = sections.first(where: { sectionKey(of: $0) == coverKey }),
           let cover = (try? FolderReader.read(folder.url, showHidden: false))?.first(where: isWideCover) {
            return .cover(cover)
        }
        guard let folder = sections.first(where: { sectionKey(of: $0) == videoKey }),
              let video = firstVideo(in: folder.url, depth: videoFolderDepth) else { return nil }
        return .firstFrame(video)
    }

    /// The project whose thumbnail a changed directory could affect, or nil.
    static func projectName(affectedBy directory: String, root: String) -> String? {
        guard let project = ProjectCatalog.projectName(containing: directory, root: root) else { return nil }
        let parts = directory.dropFirst(root.count + 1).split(separator: "/").map(String.init)
        guard parts.count > 1 else { return project }
        let key = SectionBuilder.numberPrefix(of: parts[1])?.remainder.lowercased()
        return key == coverKey || key == videoKey ? project : nil
    }

    private static func sectionKey(of item: FolderItem) -> String? {
        guard item.isFolder else { return nil }
        return SectionBuilder.numberPrefix(of: item.name)?.remainder.lowercased()
    }

    /// Videos beside a folder come before anything inside it.
    private static func firstVideo(in folder: URL, depth: Int) -> FolderItem? {
        guard let items = try? FolderReader.read(folder, showHidden: false) else { return nil }
        if let video = items.first(where: \.isVideo) { return video }
        guard depth > 0 else { return nil }
        for item in items where item.isFolder {
            if let video = firstVideo(in: item.url, depth: depth - 1) { return video }
        }
        return nil
    }
}
