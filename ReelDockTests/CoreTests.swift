import AppKit
import Foundation
import Testing
@testable import ReelDock

private struct Fixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReelDockTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func folder(_ path: String) throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
    }

    func file(_ path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite struct SectionBuilderTests {
    @Test func numberPrefixAcceptsBothSpellings() {
        #expect(SectionBuilder.numberPrefix(of: "3 video")?.number == 3)
        #expect(SectionBuilder.numberPrefix(of: "3 video")?.remainder == "video")
        #expect(SectionBuilder.numberPrefix(of: "3video")?.remainder == "video")
        #expect(SectionBuilder.numberPrefix(of: "0 project")?.number == 0)
    }

    @Test func numberPrefixRejectsDateFoldersAndOthers() {
        #expect(SectionBuilder.numberPrefix(of: "20261028_example") == nil)
        #expect(SectionBuilder.numberPrefix(of: "1_Day0") == nil)
        #expect(SectionBuilder.numberPrefix(of: "_proxy") == nil)
        #expect(SectionBuilder.numberPrefix(of: "heritage-broll") == nil)
        #expect(SectionBuilder.numberPrefix(of: "12") == nil)
    }

    @Test func buildsSectionsInOrder() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.file("3 video/clip.MP4")
        try fixture.folder("0 project")
        try fixture.file("1output/render.mov")
        try fixture.folder("heritage-broll")
        try fixture.folder("20261028_example")
        try fixture.folder("_proxy")
        try fixture.file("brief.xlsx")
        try fixture.file(".DS_Store")

        let sections = try SectionBuilder.build(folder: fixture.root, showHidden: false)
        #expect(sections.map(\.title) == ["0 project", "1output", "3 video", "_proxy", "20261028_example", "heritage-broll", "Files"])
        #expect(sections[0].itemCount == 0)
        #expect(sections[2].itemCount == 1)
        #expect(sections[6].isFilesOnly)
        #expect(sections[6].itemCount == 1)
    }

    @Test func showHiddenOnlyAffectsRealHiddenFiles() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.folder("3 video")
        try fixture.folder("_proxy")
        try fixture.file(".DS_Store")

        #expect(try SectionBuilder.build(folder: fixture.root, showHidden: false).map(\.title) == ["3 video", "_proxy"])
        #expect(try SectionBuilder.build(folder: fixture.root, showHidden: true).map(\.title) == ["3 video", "_proxy", "Files"])
    }

    @Test func footageOutweighsAnySectionByDefault() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.folder("3 video")
        try fixture.folder("2 cover")
        let sections = try SectionBuilder.build(folder: fixture.root, showHidden: false)
        let video = try #require(sections.first { $0.preferenceKey == "video" })
        let cover = try #require(sections.first { $0.preferenceKey == "cover" })
        #expect(video.defaultWeight(itemCount: 1) > cover.defaultWeight(itemCount: 10_000))
    }

    @Test func onlyEverydaySectionsStartExpanded() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        for name in ["0 project", "1 output", "2 cover", "3video", "4 audio", "5 picture", "_proxy", "heritage-broll"] {
            try fixture.folder("standard/\(name)")
        }
        try fixture.file("standard/brief.xlsx")
        try fixture.folder("code/output")
        try fixture.folder("code/data")

        let standard = try SectionBuilder.build(folder: fixture.root.appendingPathComponent("standard"), showHidden: false)
        let open = standard.filter { $0.startsExpanded(amongNumberedSections: true) }.map(\.title)
        #expect(open == ["1 output", "2 cover", "3video"])

        let code = try SectionBuilder.build(folder: fixture.root.appendingPathComponent("code"), showHidden: false)
        #expect(code.allSatisfy { $0.startsExpanded(amongNumberedSections: false) })
    }

    @Test func spellingsShareAPreferenceKey() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.folder("a/3 video")
        try fixture.folder("b/3video")
        let first = try SectionBuilder.build(folder: fixture.root.appendingPathComponent("a"), showHidden: false)
        let second = try SectionBuilder.build(folder: fixture.root.appendingPathComponent("b"), showHidden: false)
        #expect(first[0].preferenceKey == "video")
        #expect(second[0].preferenceKey == "video")
    }

    @Test func defaultModeFollowsSpec() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.folder("project/20261103_code/data")
        try fixture.folder("numbered/1 output")
        try fixture.folder("media/video")
        let projectRoot = fixture.root.appendingPathComponent("project")

        #expect(SectionBuilder.defaultMode(for: projectRoot.appendingPathComponent("20261103_code"), projectRoot: projectRoot) == .sections)
        #expect(SectionBuilder.defaultMode(for: fixture.root.appendingPathComponent("numbered"), projectRoot: projectRoot) == .sections)
        #expect(SectionBuilder.defaultMode(for: fixture.root.appendingPathComponent("media"), projectRoot: projectRoot) == .single)
    }
}

@Suite struct FolderReaderTests {
    @Test func sortsFoldersFirstInFinderOrder() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.file("clip10.mp4")
        try fixture.file("clip2.mp4")
        try fixture.folder("zeta")

        let names = try FolderReader.read(fixture.root, showHidden: false).map(\.name)
        #expect(names == ["zeta", "clip2.mp4", "clip10.mp4"])
    }

    @Test func packagesAreFiles() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.folder("Example.app/Contents")

        let items = try FolderReader.read(fixture.root, showHidden: false)
        #expect(items.first?.isFolder == false)
    }

    @Test func symlinkToFolderIsNavigable() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.folder("target")
        try FileManager.default.createSymbolicLink(
            at: fixture.root.appendingPathComponent("link"),
            withDestinationURL: fixture.root.appendingPathComponent("target")
        )
        let link = try FolderReader.read(fixture.root, showHidden: false).first { $0.name == "link" }
        #expect(link?.isFolder == true)
    }
}

@Suite struct ProjectCatalogTests {
    @Test func renameEditsTheDateAndName() {
        #expect(ProjectCatalog.name(of: "20261028_example shoot") == "example shoot")
        #expect(ProjectCatalog.name(of: "20261000_") == "")
        #expect(ProjectCatalog.name(of: "misc") == "misc")
        #expect(ProjectCatalog.name(of: "2026102_x") == "2026102_x")

        #expect(ProjectCatalog.folderName(date: "2026-11-03", name: "new") == "20261103_new")
        #expect(ProjectCatalog.folderName(date: "20261103", name: "new") == "20261103_new")
        #expect(ProjectCatalog.folderName(date: "2026/11/03", name: "new") == "20261103_new")
        #expect(ProjectCatalog.folderName(date: "", name: "new") == "new")
        #expect(ProjectCatalog.folderName(date: "2026-10-00", name: "new") == "20261000_new")
        #expect(ProjectCatalog.folderName(date: "2028-02-29", name: "new") == "20280229_new")
    }

    @Test func todayUsesTheLocalDate() throws {
        // 2026-11-03 20:00 UTC is already the next day in Shanghai.
        let date = Date(timeIntervalSince1970: 1_793_736_000)
        #expect(ProjectCatalog.dateString(date, in: try #require(TimeZone(identifier: "UTC"))) == "2026-11-03")
        #expect(ProjectCatalog.dateString(date, in: try #require(TimeZone(identifier: "Asia/Shanghai"))) == "2026-11-04")
        #expect(ProjectCatalog.folderName(date: ProjectCatalog.dateString(date), name: "new") != nil)
    }

    @Test func renameRefusesABadDate() {
        for date in ["2026", "2026-13-01", "2026-02-30", "2027-02-29", "abcd-ef-gh", "2026-1-3", "٢٠٢٦١١٠٣", "0000-00-00"] {
            #expect(ProjectCatalog.folderName(date: date, name: "new") == nil, "\(date)")
        }
        #expect(ProjectCatalog.folderName(date: "", name: "00000000_new") == nil)
    }

    @Test func newProjectCopiesTheTemplate() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.folder("00000000_template/0 project")
        try fixture.folder("00000000_template/3 video/FX3")
        try fixture.file("00000000_template/.DS_Store")
        try fixture.file("00000000_template/0 project/.DS_Store")
        try fixture.file("00000000_template/0 project/base.drp")
        try fixture.file("00000000_template/4 audio/bgm.mp3")
        let template = fixture.root.appendingPathComponent("00000000_template")
        let old = Date(timeIntervalSince1970: 1_000_000_000)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: template.path)

        let made = try FileOperations.createProject(named: "20261104_new", in: fixture.root, from: template)

        let manager = FileManager.default
        #expect(made.lastPathComponent == "20261104_new")
        #expect(manager.fileExists(atPath: made.appendingPathComponent("3 video/FX3").path))
        #expect(manager.fileExists(atPath: made.appendingPathComponent("4 audio/bgm.mp3").path))
        #expect(!manager.fileExists(atPath: made.appendingPathComponent(".DS_Store").path))
        #expect(!manager.fileExists(atPath: made.appendingPathComponent("0 project/.DS_Store").path))
        #expect(!manager.fileExists(atPath: made.appendingPathComponent("0 project/base.drp").path))
        #expect(manager.fileExists(atPath: template.appendingPathComponent(".DS_Store").path))
        #expect(manager.fileExists(atPath: template.appendingPathComponent("0 project/base.drp").path))
        let modified = try #require(try manager.attributesOfItem(atPath: made.path)[.modificationDate] as? Date)
        #expect(modified > old)
        #expect(try manager.contentsOfDirectory(atPath: fixture.root.path).sorted() == ["00000000_template", "20261104_new"])
    }

    @Test func newProjectNeverReplacesAFolder() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.folder("00000000_template/3 video")
        try fixture.file("20261104_taken/3 video/clip.mp4")
        let template = fixture.root.appendingPathComponent("00000000_template")

        #expect(throws: FileOperationError.nameTaken("20261104_taken")) {
            try FileOperations.createProject(named: "20261104_taken", in: fixture.root, from: template)
        }
        #expect(throws: FileOperationError.invalidName) {
            try FileOperations.createProject(named: "a/b", in: fixture.root, from: template)
        }
        let manager = FileManager.default
        #expect(manager.fileExists(atPath: fixture.root.appendingPathComponent("20261104_taken/3 video/clip.mp4").path))
        #expect(try manager.contentsOfDirectory(atPath: fixture.root.path).sorted() == ["00000000_template", "20261104_taken"])
    }

    @Test func newProjectStartsEmptyWithoutATemplate() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let made = try FileOperations.createProject(
            named: "20261104_new",
            in: fixture.root,
            from: fixture.root.appendingPathComponent("00000000_template")
        )
        #expect(try FileManager.default.contentsOfDirectory(atPath: made.path).isEmpty)
        #expect(try ProjectCatalog.list(root: fixture.root).map(\.folderName) == ["20261104_new"])
    }

    @Test func newProjectLeavesNothingBehindWhenTheCopyFails() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let manager = FileManager.default
        try fixture.file("00000000_template/secret/clip.mp4")
        let locked = fixture.root.appendingPathComponent("00000000_template/secret")
        try manager.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        #expect(throws: (any Error).self) {
            try FileOperations.createProject(named: "20261104_new", in: fixture.root, from: fixture.root.appendingPathComponent("00000000_template"))
        }
        #expect(try manager.contentsOfDirectory(atPath: fixture.root.path) == ["00000000_template"])
    }

    @Test func projectsFilterByNameAndTag() {
        let green = FinderTag(name: "Green", colorIndex: 2)
        let bgm = FinderTag(name: "BGM", colorIndex: 5)
        func project(_ name: String, _ tags: [FinderTag]) -> ProjectEntry {
            var entry = ProjectCatalog.entry(for: URL(fileURLWithPath: "/p/\(name)"))
            entry.tags = tags
            return entry
        }
        let projects = [project("20261101_alpha", [green]), project("20261102_beta", [green, bgm]), project("20261103_gamma", [])]

        #expect(ProjectCatalog.filter(projects, query: "", tag: nil).count == 3)
        #expect(ProjectCatalog.filter(projects, query: "", tag: "Green").map(\.title) == ["alpha", "beta"])
        #expect(ProjectCatalog.filter(projects, query: "BET", tag: "Green").map(\.title) == ["beta"])
        #expect(ProjectCatalog.filter(projects, query: "gamma", tag: "Green").isEmpty)
        #expect(ProjectCatalog.tags(in: projects).map(\.name) == ["BGM", "Green"])
    }

    @Test func tabsFollowARenamedFolder() {
        let tab = TabSnapshot(
            folderPath: "/p/20261028_old",
            mode: .sections,
            openPaths: ["/p/20261028_old/3 video": ["/p/20261028_old/3 video/a"], "single": ["/elsewhere/a"]]
        )
        let moved = tab.relocated(from: "/p/20261028_old", to: "/p/20261028_new")
        #expect(moved?.folderPath == "/p/20261028_new")
        #expect(moved?.openPaths["/p/20261028_new/3 video"] == ["/p/20261028_new/3 video/a"])
        #expect(moved?.openPaths["single"] == ["/elsewhere/a"])
        // A folder whose name only starts the same isn't inside it.
        #expect("/p/20261028_older".relocated(from: "/p/20261028_old", to: "/p/x") == nil)
        #expect(tab.relocated(from: "/p/20261028_o", to: "/p/x") == nil)
    }

    @Test func listsNewestFirstWithoutTemplates() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.folder("00000000_template")
        try fixture.folder("00000000_template_drp")
        try fixture.folder("20260514_older")
        try fixture.folder("20261028_newer")
        try fixture.folder("20261000_")
        try fixture.folder("misc")
        try fixture.file("notes.txt")

        let projects = try ProjectCatalog.list(root: fixture.root)
        #expect(projects.map(\.folderName) == ["20261028_newer", "20261000_", "20260514_older", "misc"])
    }

    @Test func parsesTitlesAndDates() {
        let entry = ProjectCatalog.entry(for: URL(fileURLWithPath: "/x/20261028_example shoot"))
        #expect(entry.title == "example shoot")
        #expect(entry.displayDate == "2026-10-28")

        let unnamed = ProjectCatalog.entry(for: URL(fileURLWithPath: "/x/20261000_"))
        #expect(unnamed.title == "20261000_")

        let undated = ProjectCatalog.entry(for: URL(fileURLWithPath: "/x/misc"))
        #expect(undated.dateStamp == nil)
    }
}

@Suite struct SettingsStoreTests {
    @Test func roundTrips() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = SettingsStore(directory: fixture.root.appendingPathComponent("support"))
        var settings = AppSettings()
        settings.projectRoot = "/x"
        settings.favorites = ["/y"]
        settings.windows = [WindowSnapshot(tabs: [TabSnapshot(folderPath: "/x/a", mode: .single, openPaths: ["single": ["/x/a/b"]])], selectedTab: 0)]
        try store.save(settings)
        #expect(store.load() == settings)
    }

    @Test func toleratesMissingKeys() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data(#"{"projectRoot":"/x"}"#.utf8).write(to: fixture.root.appendingPathComponent("settings.json"))
        let settings = SettingsStore(directory: fixture.root).load()
        #expect(settings.projectRoot == "/x")
        #expect(settings.favorites.isEmpty)
    }

    @Test func ignoresWeightsSavedOnTheOldScale() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data(#"{"sections":{"video":{"weight":2.8,"collapsed":false}}}"#.utf8)
            .write(to: fixture.root.appendingPathComponent("settings.json"))
        let preference = SettingsStore(directory: fixture.root).load().sections["video"]
        #expect(preference?.heightWeight == nil)
        #expect(preference?.collapsed == false)
    }

    @Test func keepsUnreadableFileAside() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data("not json".utf8).write(to: fixture.root.appendingPathComponent("settings.json"))
        let settings = SettingsStore(directory: fixture.root).load()
        #expect(settings == AppSettings())
        #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("settings.unreadable.json").path))
    }
}

@Suite struct MediaInfoTests {
    @Test func namesCommonCodecs() {
        #expect(MediaInfoReader.codecName(0x68766331) == "HEVC")
        #expect(MediaInfoReader.codecName(0x61766331) == "H.264")
        #expect(MediaInfoReader.codecName(0x61706368) == "ProRes 422 HQ")
    }
}

@Suite struct FileOperationsTests {
    private func makeFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ReelDockFileOps-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func newFoldersGetUniqueNames() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(try FileOperations.createFolder(in: folder).lastPathComponent == "untitled folder")
        #expect(try FileOperations.createFolder(in: folder).lastPathComponent == "untitled folder 2")
        #expect(try FileOperations.createFolder(in: folder).lastPathComponent == "untitled folder 3")
    }

    @Test func renameNeverReplacesAnotherFile() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appendingPathComponent("a.mov")
        let second = folder.appendingPathComponent("b.mov")
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)

        #expect(throws: FileOperationError.nameTaken("b.mov")) {
            try FileOperations.rename(first, to: "b.mov")
        }
        #expect(try String(contentsOf: first, encoding: .utf8) == "first")
        #expect(try String(contentsOf: second, encoding: .utf8) == "second")

        let renamed = try FileOperations.rename(first, to: "c.mov")
        #expect(renamed.lastPathComponent == "c.mov")
        #expect(try String(contentsOf: renamed, encoding: .utf8) == "first")
        #expect(!FileManager.default.fileExists(atPath: first.path))
    }

    @Test func renameCanChangeOnlyTheCase() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("clip.mov")
        try Data("clip".utf8).write(to: file)

        _ = try FileOperations.rename(file, to: "CLIP.mov")
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(names == ["CLIP.mov"])
    }

    @Test func renameRejectsBadNames() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("clip.mov")
        try Data("clip".utf8).write(to: file)

        for name in ["", "   ", ".hidden", "a/b", "a:b"] {
            #expect(throws: FileOperationError.invalidName) {
                try FileOperations.rename(file, to: name)
            }
        }
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func trashCanBeRestoredWithoutReplacingAnything() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("clip.mov")
        try Data("original".utf8).write(to: file)

        let result = FileOperations.moveToTrash([file])
        #expect(result.error == nil)
        let item = try #require(result.moved.first)
        defer { try? FileManager.default.removeItem(at: item.trashed) }
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(FileManager.default.fileExists(atPath: item.trashed.path))

        try Data("newer".utf8).write(to: file)
        #expect(throws: FileOperationError.nameTaken("clip.mov")) {
            try FileOperations.restore(item)
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == "newer")

        try FileManager.default.removeItem(at: file)
        try FileOperations.restore(item)
        #expect(try String(contentsOf: file, encoding: .utf8) == "original")
    }

    @Test func trashStopsAtAFailureAndReportsWhatMoved() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("clip.mov")
        try Data("clip".utf8).write(to: file)
        let missing = folder.appendingPathComponent("missing.mov")

        let result = FileOperations.moveToTrash([file, missing])
        defer { result.moved.forEach { try? FileManager.default.removeItem(at: $0.trashed) } }
        #expect(result.moved.map(\.original) == [file])
        #expect(result.error != nil)
    }
}

@Suite struct PlaybackTests {
    @Test func reverseDecodingFitsAPreview() {
        #expect(ReverseDecoder.decodeSize(for: CGSize(width: 3840, height: 2160)) == CGSize(width: 1920, height: 1080))
        #expect(ReverseDecoder.decodeSize(for: CGSize(width: 2160, height: 3840)) == CGSize(width: 1080, height: 1920))
        #expect(ReverseDecoder.decodeSize(for: CGSize(width: 1280, height: 720)) == CGSize(width: 1280, height: 720))
    }

    @Test func reverseDecodingSkipsWhatTheDisplayCantShow() {
        #expect(ReverseDecoder.frameStride(frameRate: 59.94, speed: 1) == 1)
        #expect(ReverseDecoder.frameStride(frameRate: 59.94, speed: 2) == 2)
        #expect(ReverseDecoder.frameStride(frameRate: 23.976, speed: 2) == 1)
        #expect(ReverseDecoder.frameStride(frameRate: 119.88, speed: 1) == 2)
    }

    @Test func reverseRotationReadsTheClipsTransform() {
        let quarter = ReverseDecoder.rotation(of: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 2160, ty: 0))
        #expect(abs(quarter - .pi / 2) < 0.001)
        #expect(ReverseDecoder.rotation(of: .identity) == 0)
    }

    @Test func shuttleDoublesThenCaps() {
        #expect(Shuttle.rate(after: 0, forward: true) == 1)
        #expect(Shuttle.rate(after: 1, forward: true) == 2)
        #expect(Shuttle.rate(after: 4, forward: true) == 8)
        #expect(Shuttle.rate(after: 8, forward: true) == 8)
        #expect(Shuttle.rate(after: -1, forward: false) == -2)
        #expect(Shuttle.rate(after: -8, forward: false) == -8)
    }

    @Test func shuttleChangingDirectionRestartsAtNormalSpeed() {
        #expect(Shuttle.rate(after: 4, forward: false) == -1)
        #expect(Shuttle.rate(after: -4, forward: true) == 1)
        #expect(Shuttle.rate(after: 0, forward: false) == -1)
    }

    @Test func timecodeCountsFramesAtTheRoundedRate() {
        #expect(Timecode.format(0, frameRate: 59.94) == "00:00:00")
        #expect(Timecode.format(1.5, frameRate: 60) == "00:01:30")
        #expect(Timecode.format(61, frameRate: 24) == "01:01:00")
        #expect(Timecode.format(3661, frameRate: 30) == "1:01:01:00")
        #expect(Timecode.format(-1, frameRate: 30) == "00:00:00")
    }

    @Test func frameGridShowsOnlyWholeRows() {
        let layout = FrameGridLayout(size: CGSize(width: 408, height: 300), aspect: 16.0 / 9.0)
        #expect(layout.columns == 3)
        #expect(layout.tileSize.width == CGFloat(400) / 3)
        #expect(layout.rows == 3)
        #expect(FrameGridLayout(size: CGSize(width: 408, height: 20), aspect: 16.0 / 9.0).count == 0)
        #expect(FrameGridLayout(size: CGSize(width: 500, height: 300), aspect: 16.0 / 9.0).columns == 4)
        #expect(FrameGridLayout(size: CGSize(width: 408, height: 300), aspect: 9.0 / 16.0).columns == 5)
    }
}

@Suite struct FinderTagTests {
    private func plist(_ entries: [String]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: entries, format: .binary, options: 0)
    }

    @Test func parsesNamesAndColors() throws {
        let tags = FinderTags.parse(try plist(["Orange\n7", "Green\n2", "No Color", "Odd\n99", "Blank\n"]))
        #expect(tags.map(\.name) == ["Orange", "Green", "No Color", "Odd", "Blank"])
        #expect(tags.map(\.colorIndex) == [7, 2, 0, 0, 0])
        #expect(FinderTags.parse(Data("junk".utf8)).isEmpty)
    }

    @Test func writtenTagsReadBackWithColors() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ReelDockTags-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("clip.mov")
        try Data("clip".utf8).write(to: file)
        #expect(FinderTags.read(file).isEmpty)

        // Standard tag names only, so a test can't add a new name to Finder's tag list.
        let labels = NSWorkspace.shared.fileLabels
        try FinderTags.write([labels[7], labels[2]], to: file)
        #expect(FinderTags.read(file).map(\.name) == [labels[7], labels[2]])
        #expect(FinderTags.read(file).map(\.colorIndex) == [7, 2])
        #expect(try String(contentsOf: file, encoding: .utf8) == "clip")

        try FinderTags.write([], to: file)
        #expect(FinderTags.read(file).isEmpty)
    }

    @Test func folderReaderIncludesTags() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ReelDockTags-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("tagged"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let label = NSWorkspace.shared.fileLabels[2]
        try FinderTags.write([label], to: folder.appendingPathComponent("tagged"))

        let items = try FolderReader.read(folder, showHidden: false)
        #expect(items.first?.tags.map(\.colorIndex) == [2])
    }

    @Test func colorsCountOnlyWhenEveryItemHasThem() {
        let green = FinderTag(name: "Green", colorIndex: 2)
        let done = FinderTag(name: "Done", colorIndex: 2)
        let red = FinderTag(name: "Red", colorIndex: 6)
        let plain = FinderTag(name: "BGM", colorIndex: 0)
        #expect(FinderTags.sharedColors(among: [[green, red], [done]]) == [2])
        #expect(FinderTags.sharedColors(among: [[green], []]) == [])
        #expect(FinderTags.sharedColors(among: [[plain]]) == [])
        #expect(FinderTags.sharedColors(among: []) == [])
    }

    @Test func settingAColorActsOnEveryTagOfThatColor() {
        let green = FinderTag(name: "Green", colorIndex: 2)
        let done = FinderTag(name: "Done", colorIndex: 2)
        let plain = FinderTag(name: "BGM", colorIndex: 0)
        #expect(FinderTags.names([plain], settingColorOf: green, enabled: true) == ["BGM", "Green"])
        // A tag of that color already counts, so turning it on adds nothing.
        #expect(FinderTags.names([done, plain], settingColorOf: green, enabled: true) == ["Done", "BGM"])
        #expect(FinderTags.names([done, green, plain], settingColorOf: green, enabled: false) == ["BGM"])
    }

    @Test func settingATagKeepsTheOthers() {
        #expect(FinderTags.names(["A", "B"], setting: "C", enabled: true) == ["A", "B", "C"])
        #expect(FinderTags.names(["A", "B"], setting: "A", enabled: true) == ["B", "A"])
        #expect(FinderTags.names(["A", "B"], setting: "A", enabled: false) == ["B"])
    }

    @Test func choicesListStandardTagsFirstAndMarkMixedSelections() {
        let labels = ["None", "Gray", "Green", "Purple", "Blue", "Yellow", "Red", "Orange"]
        let standard = FinderTags.standardTags(labels: labels)
        #expect(standard.map(\.name) == ["Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Gray"])

        let green = FinderTag(name: "Green", colorIndex: 2)
        let custom = FinderTag(name: "Client", colorIndex: 0)
        let seen = FinderTag(name: "Archive", colorIndex: 4)
        let choices = FinderTags.choices(standard: standard, seen: [seen], current: [[green, custom], [green]])
        #expect(choices.map(\.tag.name).suffix(2) == ["Archive", "Client"])
        #expect(choices.count == 9)
        #expect(choices.first { $0.tag.name == "Green" }?.state == .all)
        #expect(choices.first { $0.tag.name == "Client" }?.state == .some)
        #expect(choices.first { $0.tag.name == "Red" }?.state == TagChoice.State.none)
    }
}

@Suite struct FileTransferTests {
    private func children(_ url: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
    }

    @Test func dropsMoveWithinAVolumeUnlessACopyIsForced() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.file("a/clip.mp4")
        try fixture.folder("a/inner")
        try fixture.folder("b")
        let clip = fixture.root.appendingPathComponent("a/clip.mp4")
        let inner = fixture.root.appendingPathComponent("a/inner")
        let a = fixture.root.appendingPathComponent("a")
        let b = fixture.root.appendingPathComponent("b")
        func kind(_ sources: [URL], _ destination: URL, copy: Bool = true, move: Bool = true, force: Bool = false) -> FileTransfer.Kind? {
            FileTransfer.dropKind(sources: sources, destination: destination, canCopy: copy, canMove: move, forcesMove: force)
        }

        #expect(kind([clip], b) == .move)
        #expect(kind([clip], b, move: false) == .copy)
        #expect(kind([clip], b, copy: false, move: false, force: true) == .move)
        #expect(kind([clip], b, copy: false, move: false) == nil)
        // Back where it came from: nothing to do, unless it's a copy.
        #expect(kind([clip], a) == nil)
        #expect(kind([clip], a, move: false) == .copy)
        // A folder can't go inside itself, even as a copy.
        #expect(kind([inner], inner) == nil)
        #expect(kind([a], inner) == nil)
        #expect(kind([a], inner, move: false) == nil)
        #expect(kind([], b) == nil)
        #expect(kind([fixture.root.appendingPathComponent("missing.mp4")], b) == nil)
    }

    @Test func namesNeverCollide() {
        #expect(FileTransfer.candidateName(for: "a.mp4", isFolder: false, kind: .copy, attempt: 0) == "a.mp4")
        #expect(FileTransfer.candidateName(for: "a.mp4", isFolder: false, kind: .copy, attempt: 1) == "a copy.mp4")
        #expect(FileTransfer.candidateName(for: "a.mp4", isFolder: false, kind: .copy, attempt: 2) == "a copy 2.mp4")
        #expect(FileTransfer.candidateName(for: "a.mp4", isFolder: false, kind: .move, attempt: 1) == "a 2.mp4")
        #expect(FileTransfer.candidateName(for: "v1.2", isFolder: true, kind: .copy, attempt: 1) == "v1.2 copy")
    }

    @Test func copiesAFolderWithEverythingInIt() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.file("source/a.mp4")
        try fixture.file("source/nested/deep/b.mov")
        try fixture.file("source/.hidden")
        try fixture.folder("source/empty")
        try fixture.folder("target")
        let source = fixture.root.appendingPathComponent("source")
        let manager = FileManager.default
        try manager.createSymbolicLink(atPath: source.appendingPathComponent("link").path, withDestinationPath: "a.mp4")
        let old = Date(timeIntervalSince1970: 1_000_000_000)
        try manager.setAttributes([.modificationDate: old], ofItemAtPath: source.appendingPathComponent("a.mp4").path)
        try FinderTags.write(["Green"], to: source.appendingPathComponent("a.mp4"))

        let item = try FileTransfer.perform(source, kind: .copy, destination: fixture.root.appendingPathComponent("target"), control: CopyControl())

        #expect(item.result.lastPathComponent == "source")
        #expect(try children(item.result) == [".hidden", "a.mp4", "empty", "link", "nested"])
        #expect(manager.fileExists(atPath: item.result.appendingPathComponent("nested/deep/b.mov").path))
        #expect(try manager.destinationOfSymbolicLink(atPath: item.result.appendingPathComponent("link").path) == "a.mp4")
        let copied = item.result.appendingPathComponent("a.mp4")
        #expect(FinderTags.read(copied).map(\.name) == ["Green"])
        #expect(try manager.attributesOfItem(atPath: copied.path)[.modificationDate] as? Date == old)
        #expect(try children(fixture.root.appendingPathComponent("target")) == ["source"])
        #expect(manager.fileExists(atPath: source.appendingPathComponent("a.mp4").path))
    }

    @Test func aPasteBesideTheOriginalGetsANewName() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.file("clip.mp4")
        let source = fixture.root.appendingPathComponent("clip.mp4")
        let first = try FileTransfer.perform(source, kind: .copy, destination: fixture.root, control: CopyControl())
        let second = try FileTransfer.perform(source, kind: .copy, destination: fixture.root, control: CopyControl())
        #expect(first.result.lastPathComponent == "clip copy.mp4")
        #expect(second.result.lastPathComponent == "clip copy 2.mp4")
    }

    @Test func aMoveWithinAVolumeRenamesWithoutReplacing() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.file("from/clip.mp4")
        try Data("original".utf8).write(to: fixture.root.appendingPathComponent("clip.mp4"))
        let source = fixture.root.appendingPathComponent("from/clip.mp4")
        let inode = try FileManager.default.attributesOfItem(atPath: source.path)[.systemFileNumber] as? Int

        let item = try FileTransfer.perform(source, kind: .move, destination: fixture.root, control: CopyControl())

        #expect(item.result.lastPathComponent == "clip 2.mp4")
        #expect(item.trashedOriginal == nil)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(try FileManager.default.attributesOfItem(atPath: item.result.path)[.systemFileNumber] as? Int == inode)
        #expect(try Data(contentsOf: fixture.root.appendingPathComponent("clip.mp4")) == Data("original".utf8))
    }

    @Test func aDamagedCopyIsNeverPublished() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.file("source/clip.mp4")
        try fixture.folder("target")
        let hooks = ClipCopier.Hooks(afterWrite: { part in
            try? Data("damaged".utf8).write(to: part)
        })

        #expect(throws: ClipCopier.Failure.verificationMismatch) {
            try FileTransfer.perform(
                fixture.root.appendingPathComponent("source"),
                kind: .copy,
                destination: fixture.root.appendingPathComponent("target"),
                control: CopyControl(),
                hooks: hooks
            )
        }
        #expect(try children(fixture.root.appendingPathComponent("target")).isEmpty)
    }

    @Test func aCancelledCopyLeavesNothing() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.file("clip.mp4")
        try fixture.folder("target")
        let control = CopyControl()
        control.cancel()
        #expect(throws: ClipCopier.Failure.cancelled) {
            try FileTransfer.perform(fixture.root.appendingPathComponent("clip.mp4"), kind: .copy, destination: fixture.root.appendingPathComponent("target"), control: control)
        }
        #expect(try children(fixture.root.appendingPathComponent("target")).isEmpty)
        #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("clip.mp4").path))
    }

    @Test func aFolderCantGoInsideItself() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.folder("a/b")
        let folder = fixture.root.appendingPathComponent("a")
        for destination in [folder, folder.appendingPathComponent("b")] {
            #expect(throws: FileOperationError.insideItself("a")) {
                try FileTransfer.validate(sources: [folder], destination: destination, kind: .copy)
            }
        }
        #expect(throws: FileOperationError.itemMissing("gone")) {
            try FileTransfer.validate(sources: [fixture.root.appendingPathComponent("gone")], destination: fixture.root, kind: .copy)
        }
        #expect(FileTransfer.itemsThatWouldChange([folder], destination: fixture.root, kind: .move).isEmpty)
        #expect(FileTransfer.itemsThatWouldChange([folder], destination: fixture.root, kind: .copy) == [folder])
    }

    @MainActor @Test func onlyBusyFoldersAreRefused() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.file("project/3 video/clip.mp4")
        try fixture.folder("elsewhere")
        let registry = PartFileRegistry(fileURL: fixture.root.appendingPathComponent("parts.json"))
        let queue = FileTransferQueue(registry: registry)
        queue.setPaused(true)
        let video = fixture.root.appendingPathComponent("project/3 video")
        queue.enqueue(.copy, sources: [video.appendingPathComponent("clip.mp4")], destination: fixture.root.appendingPathComponent("elsewhere")) { _, _, _ in }

        #expect(queue.isBusy(with: fixture.root.appendingPathComponent("project")))
        #expect(queue.isBusy(with: video))
        #expect(queue.isBusy(with: video.appendingPathComponent("clip.mp4")))
        #expect(queue.isBusy(with: fixture.root.appendingPathComponent("elsewhere")))
        #expect(!queue.isBusy(with: fixture.root.appendingPathComponent("other")))
        queue.cancelAll()
    }
}
