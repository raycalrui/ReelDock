import Foundation

nonisolated struct SectionPreference: Codable, Equatable, Sendable {
    /// Saved after a divider drag. Named apart from the old `weight` key, whose values used another default scale.
    var heightWeight: Double?
    var collapsed: Bool?
}

nonisolated struct TabSnapshot: Codable, Equatable, Sendable {
    var folderPath: String
    var mode: BrowserMode
    /// Open folder chain per browser, keyed by section ID.
    var openPaths: [String: [String]]
}

nonisolated struct WindowSnapshot: Codable, Equatable, Sendable {
    var tabs: [TabSnapshot]
    var selectedTab: Int
}

nonisolated struct AppSettings: Codable, Equatable, Sendable {
    var projectRoot: String?
    var mediaRoot: String?
    var favorites: [String] = []
    var sections: [String: SectionPreference] = [:]
    var windows: [WindowSnapshot] = []
    var showHidden = false
    var importPanelFraction: Double?
    /// The display full-screen previews open on.
    var previewDisplay: String?

    init() {}

    /// Tolerates missing keys so older settings files keep working.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projectRoot = try container.decodeIfPresent(String.self, forKey: .projectRoot)
        mediaRoot = try container.decodeIfPresent(String.self, forKey: .mediaRoot)
        favorites = try container.decodeIfPresent([String].self, forKey: .favorites) ?? []
        sections = try container.decodeIfPresent([String: SectionPreference].self, forKey: .sections) ?? [:]
        windows = try container.decodeIfPresent([WindowSnapshot].self, forKey: .windows) ?? []
        showHidden = try container.decodeIfPresent(Bool.self, forKey: .showHidden) ?? false
        importPanelFraction = try container.decodeIfPresent(Double.self, forKey: .importPanelFraction)
        previewDisplay = try container.decodeIfPresent(String.self, forKey: .previewDisplay)
    }
}

nonisolated struct SettingsStore: Sendable {
    let directory: URL

    static var standardDirectory: URL {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["REELDOCK_SUPPORT_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        #endif
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("ReelDock", isDirectory: true)
    }

    private var fileURL: URL { directory.appendingPathComponent("settings.json") }

    /// Keeps an unreadable file aside rather than overwriting it with defaults.
    func load() -> AppSettings {
        guard let data = try? Data(contentsOf: fileURL) else { return AppSettings() }
        do {
            return try JSONDecoder().decode(AppSettings.self, from: data)
        } catch {
            let backup = directory.appendingPathComponent("settings.unreadable.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            return AppSettings()
        }
    }

    func save(_ settings: AppSettings) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: fileURL, options: .atomic)
    }
}
