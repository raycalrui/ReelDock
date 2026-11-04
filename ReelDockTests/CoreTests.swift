import AVFoundation
import AppKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
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

    @Test func aTagSeenWithAndWithoutAColorKeepsTheColor() {
        let choices = FinderTags.choices(
            standard: [],
            seen: [FinderTag(name: "Music", colorIndex: 0), FinderTag(name: "Music", colorIndex: 4), FinderTag(name: "Work", colorIndex: 0)],
            current: []
        )
        #expect(choices.map(\.tag.name) == ["Music", "Work"])
        #expect(choices.first?.tag.colorIndex == 4)
    }

    @Test func finderPreferencesNameItsTags() {
        let preferences: [String: Any] = [
            "FavoriteTagNames": ["", "Red", "Music"],
            "ViewSettingsDictionary": ["Work_Tag_ViewSettings": [String: Any](), "Work_Tag_ViewStyle": "clmv", "ListViewSettings": [String: Any]()],
            "ShowRecentTags": true,
        ]
        #expect(Set(FinderTags.names(inFinderPreferences: preferences)) == ["Red", "Music", "Work"])
        #expect(FinderTags.names(inFinderPreferences: [:]).isEmpty)
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

@Suite struct ImageEditorTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ImageEditorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A 3 by 2 image where every pixel differs, read back from the top left.
    private func testImage() throws -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try #require(CGContext(data: nil, width: 3, height: 2, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for x in 0..<3 {
            for y in 0..<2 {
                context.setFillColor(red: CGFloat(x) / 3, green: CGFloat(y) / 2, blue: 0.5, alpha: 1)
                context.fill(CGRect(x: x, y: 1 - y, width: 1, height: 1))
            }
        }
        return try #require(context.makeImage())
    }

    private func pixels(_ image: CGImage) throws -> [[UInt32]] {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        var bytes = [UInt32](repeating: 0, count: image.width * image.height)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        #expect(drawn)
        return (0..<image.height).map { y in Array(bytes[(y * image.width)..<((y + 1) * image.width)]) }
    }

    private func write(_ image: CGImage, to url: URL, type: UTType = .png, properties: [CFString: Any] = [:]) throws {
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
    }

    @Test func rotatingTurnsPixelsAndFourTurnsComeBack() throws {
        let image = try testImage()
        let original = try pixels(image)
        let right = try ImageEditor.rotated(image, clockwise: true)
        #expect((right.width, right.height) == (2, 3))
        // Clockwise, the top left moves to the top right, and the bottom left to the top left.
        #expect(try pixels(right)[0][1] == original[0][0])
        #expect(try pixels(right)[0][0] == original[1][0])
        #expect(try pixels(right)[2][1] == original[0][2])
        let left = try ImageEditor.rotated(image, clockwise: false)
        #expect(try pixels(left)[0][0] == original[0][2])
        #expect(try pixels(left)[2][0] == original[0][0])
        var turned = image
        for _ in 0..<4 { turned = try ImageEditor.rotated(turned, clockwise: true) }
        #expect(try pixels(turned) == original)
    }

    @Test func croppingMeasuresFromTheTopLeft() throws {
        let image = try testImage()
        let original = try pixels(image)
        let cropped = try ImageEditor.cropped(image, to: CGRect(x: 1, y: 1, width: 2, height: 1))
        #expect(try pixels(cropped) == [[original[1][1], original[1][2]]])
    }

    /// ImageIO's own upright thumbnail is the reference for every orientation.
    @Test(arguments: 1...8) func loadingFollowsTheFilesOrientation(orientation: Int) throws {
        let url = try folder().appendingPathComponent("image.png")
        try write(testImage(), to: url, properties: [kCGImagePropertyOrientation: orientation])
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let reference = try #require(CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 3,
        ] as CFDictionary))
        #expect(try pixels(ImageEditor.load(url)) == pixels(reference))
    }

    @Test func onlyFlatFormatsCanBeEdited() {
        #expect(ImageEditor.canEdit(.jpeg))
        #expect(ImageEditor.canEdit(.png))
        #expect(ImageEditor.canEdit(.heic))
        #expect(ImageEditor.canEdit(.tiff))
        #expect(!ImageEditor.canEdit(.pdf))
        #expect(!ImageEditor.canEdit(UTType("com.adobe.photoshop-image")))
        #expect(!ImageEditor.canEdit(UTType("com.sony.arw-raw-image")))
        #expect(!ImageEditor.canEdit(.movie))
        #expect(!ImageEditor.canEdit(nil))
    }

    @Test func aFileWithSeveralImagesIsRefused() throws {
        let url = try folder().appendingPathComponent("several.tiff")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 2, nil))
        CGImageDestinationAddImage(destination, try testImage(), nil)
        CGImageDestinationAddImage(destination, try testImage(), nil)
        #expect(CGImageDestinationFinalize(destination))
        #expect(throws: ImageEditorError.self) { try ImageEditor.load(url) }
    }

    @Test func aCopyLeavesTheOriginalAndNeverTakesAName() throws {
        let directory = try folder()
        let url = directory.appendingPathComponent("photo.jpg")
        try write(testImage(), to: url, type: .jpeg)
        let before = try Data(contentsOf: url)
        let turned = try ImageEditor.rotated(ImageEditor.load(url), clockwise: true)

        let first = try ImageEditor.saveCopy(turned, of: url)
        let second = try ImageEditor.saveCopy(turned, of: url)
        #expect(first.lastPathComponent == "photo edited.jpg")
        #expect(second.lastPathComponent == "photo edited 2.jpg")
        #expect(try Data(contentsOf: url) == before)
        let saved = try ImageEditor.load(first)
        #expect((saved.width, saved.height) == (2, 3))
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(Set(names) == ["photo.jpg", "photo edited.jpg", "photo edited 2.jpg"])
    }

    @Test func savingKeepsMetadataAndClearsTheOrientation() throws {
        let directory = try folder()
        let url = directory.appendingPathComponent("photo.jpg")
        try write(testImage(), to: url, type: .jpeg, properties: [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifLensModel: "Test Lens"],
        ])
        let upright = try ImageEditor.load(url)
        #expect((upright.width, upright.height) == (2, 3))
        let copy = try ImageEditor.saveCopy(upright, of: url)
        let source = try #require(CGImageSourceCreateWithURL(copy as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyOrientation] as? Int ?? 1 == 1)
        #expect((properties[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifLensModel] as? String == "Test Lens")
        #expect(try ImageEditor.load(copy).width == 2)
    }

    @Test func replacingTrashesTheOriginalAndKeepsTags() throws {
        let directory = try folder()
        let holding = try folder()
        let url = directory.appendingPathComponent("photo.png")
        try write(testImage(), to: url)
        try (url as NSURL).setResourceValue(["Blue"], forKey: .tagNamesKey)
        let before = try Data(contentsOf: url)

        let trashed = try ImageEditor.replace(url, with: ImageEditor.rotated(ImageEditor.load(url), clockwise: true)) { source in
            let held = holding.appendingPathComponent(source.lastPathComponent)
            try FileManager.default.moveItem(at: source, to: held)
            return FileOperations.TrashedItem(original: source, trashed: held)
        }
        #expect(try Data(contentsOf: trashed.trashed) == before)
        #expect(try ImageEditor.load(url).width == 2)
        #expect(FinderTags.read(url).map(\.name) == ["Blue"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["photo.png"])
    }

    @Test func aFailedTrashChangesNothing() throws {
        let directory = try folder()
        let url = directory.appendingPathComponent("photo.png")
        try write(testImage(), to: url)
        let before = try Data(contentsOf: url)
        #expect(throws: ImageEditorError.self) {
            _ = try ImageEditor.replace(url, with: try testImage()) { _ in throw ImageEditorError.cantWrite }
        }
        #expect(try Data(contentsOf: url) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["photo.png"])
    }

    @Test func cropSelectionStaysInsideTheImage() {
        let rect = CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4)
        func close(_ a: CGRect, _ b: CGRect) -> Bool {
            abs(a.minX - b.minX) < 0.0001 && abs(a.minY - b.minY) < 0.0001 && abs(a.width - b.width) < 0.0001 && abs(a.height - b.height) < 0.0001
        }
        #expect(CropGeometry.grip(at: CGPoint(x: 0.2, y: 0.2), of: rect, toleranceX: 0.01, toleranceY: 0.01) == .topLeft)
        #expect(CropGeometry.grip(at: CGPoint(x: 0.6, y: 0.4), of: rect, toleranceX: 0.01, toleranceY: 0.01) == .right)
        #expect(CropGeometry.grip(at: CGPoint(x: 0.4, y: 0.4), of: rect, toleranceX: 0.01, toleranceY: 0.01) == .move)
        #expect(CropGeometry.grip(at: CGPoint(x: 0.9, y: 0.9), of: rect, toleranceX: 0.01, toleranceY: 0.01) == .draw)
        let moved = CropGeometry.dragged(rect, grip: .move, from: CGPoint(x: 0.4, y: 0.4), to: CGPoint(x: 5, y: -5))
        #expect(close(moved, CGRect(x: 0.6, y: 0, width: 0.4, height: 0.4)))
        let squeezed = CropGeometry.dragged(rect, grip: .right, from: .zero, to: CGPoint(x: 0, y: 0.5))
        #expect(close(squeezed, CGRect(x: 0.2, y: 0.2, width: CropGeometry.minimumSize, height: 0.4)))
        let drawn = CropGeometry.dragged(rect, grip: .draw, from: CGPoint(x: 0.8, y: 0.8), to: CGPoint(x: 0.5, y: 2))
        #expect(close(drawn, CGRect(x: 0.5, y: 0.8, width: 0.3, height: 0.2)))
        #expect(CropGeometry.pixelRect(CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5), imageWidth: 3, imageHeight: 3).maxX <= 3)
        #expect(CropGeometry.pixelRect(CGRect(x: 0, y: 0, width: 0.0001, height: 0.0001), imageWidth: 3, imageHeight: 3).width == 1)
    }
}

@Suite struct VideoEditorTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("VideoEditorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Each frame is a different shade, so a frame can be told from its neighbors. 32 by 16, at 10 frames a second.
    private func makeClip(_ url: URL, type: AVFileType, frames: Int = 30, transform: CGAffineTransform = .identity) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: type)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 32, AVVideoHeightKey: 16,
        ])
        input.transform = transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 32, kCVPixelBufferHeightKey as String: 16,
        ])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for index in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 32, 16, kCVPixelFormatType_32BGRA, nil, &buffer)
            let pixels = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(CVPixelBufferGetBaseAddress(pixels), Int32(20 + index * 7), CVPixelBufferGetDataSize(pixels))
            CVPixelBufferUnlockBaseAddress(pixels, [])
            #expect(adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: 10)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
    }

    private func transform(of url: URL) async throws -> CGAffineTransform {
        let track = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first)
        return try await track.load(.preferredTransform)
    }

    private func shownSize(of url: URL) async throws -> CGSize {
        let track = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize).applying(try await track.load(.preferredTransform))
        return CGSize(width: abs(size.width), height: abs(size.height))
    }

    private func brightness(of url: URL, at seconds: Double) async throws -> Int {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
        let context = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return Int(context.data!.assumingMemoryBound(to: UInt8.self).pointee)
    }

    @Test func marksClearWhatTheyPass() {
        var marks = TrimMarks()
        #expect(marks.isEmpty)
        marks.markIn(5)
        marks.markOut(8)
        #expect(marks.range(duration: 10) == 5...8)
        marks.markIn(9)
        #expect(marks.outPoint == nil)
        #expect(marks.range(duration: 10) == 9...10)
        marks.markOut(2)
        #expect(marks.inPoint == nil)
        #expect(marks.range(duration: 10) == 0...2)
    }

    @Test func marksThatKeepEverythingOrNothingHaveNoRange() {
        #expect(TrimMarks(inPoint: 0, outPoint: 10).range(duration: 10) == nil)
        #expect(TrimMarks(inPoint: 10, outPoint: nil).range(duration: 10) == nil)
        #expect(TrimMarks().range(duration: 10) == nil)
    }

    @Test func fourQuarterTurnsComeBack() throws {
        let one: Int32 = 0x10000
        let start = TrackMatrix(a: one, b: 0, u: 0, c: 0, d: one, v: 0, tx: 0, ty: 0, w: 0x4000_0000)
        let width = 1920 * one
        let height = 1080 * one
        let right = try #require(start.rotated(clockwise: true, width: width, height: height))
        #expect(right == TrackMatrix(a: 0, b: one, u: 0, c: -one, d: 0, v: 0, tx: height, ty: 0, w: 0x4000_0000))
        #expect(right.rotated(clockwise: false, width: width, height: height) == start)
        var turned = start
        for _ in 0..<4 { turned = try #require(turned.rotated(clockwise: true, width: width, height: height)) }
        #expect(turned == start)
        var left = start
        for _ in 0..<4 { left = try #require(left.rotated(clockwise: false, width: width, height: height)) }
        #expect(left == start)
        #expect(TrackMatrix(a: one / 2, b: 0, u: 0, c: 0, d: one / 2, v: 0, tx: 0, ty: 0, w: 0).rotated(clockwise: true, width: width, height: height) == nil)
    }

    @Test(arguments: [("clip.mp4", AVFileType.mp4), ("clip.mov", AVFileType.mov)])
    func rotatingChangesOnlyTheMatrix(name: String, type: AVFileType) async throws {
        let url = try folder().appendingPathComponent(name)
        try await makeClip(url, type: type)
        let before = try Data(contentsOf: url)
        let header = try #require(try VideoEditor.videoTrackHeaders(in: url).first)

        try VideoEditor.rotate(url, clockwise: true)
        let after = try Data(contentsOf: url)
        #expect(after.count == before.count)
        let offset = Int(header.matrixOffset)
        let differing = zip(before, after).enumerated().filter { $0.element.0 != $0.element.1 }.map(\.offset)
        #expect(!differing.isEmpty)
        #expect(differing.allSatisfy { (offset..<(offset + 36)).contains($0) })
        #expect(try await shownSize(of: url) == CGSize(width: 16, height: 32))
        let turned = try await transform(of: url)
        #expect((turned.a, turned.b, turned.c, turned.d) == (0, 1, -1, 0))
        #expect(try await brightness(of: url, at: 1) > 0)

        try VideoEditor.rotate(url, clockwise: false)
        #expect(try Data(contentsOf: url) == before)
        for _ in 0..<4 { try VideoEditor.rotate(url, clockwise: true) }
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func aFileThatIsntAMovieIsLeftAlone() throws {
        let url = try folder().appendingPathComponent("not.mp4")
        let bytes = Data(repeating: 7, count: 4096)
        try bytes.write(to: url)
        #expect(throws: VideoEditorError.self) { try VideoEditor.rotate(url, clockwise: true) }
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test func aTrimStartsOnTheMarkedFrameAndKeepsTheRotation() async throws {
        let directory = try folder()
        let url = directory.appendingPathComponent("clip.mov")
        try await makeClip(url, type: .mov)
        try VideoEditor.rotate(url, clockwise: true)
        let before = try Data(contentsOf: url)
        let part = try VideoEditor.makePartFolder(beside: url)
        let built = try await VideoEditor.exportTrim(of: url, marks: TrimMarks(inPoint: 1.3, outPoint: 2.3), into: part) { _ in }

        let duration = try await AVURLAsset(url: built).load(.duration).seconds
        #expect(abs(duration - 1) < 0.15)
        #expect(try await shownSize(of: built) == CGSize(width: 16, height: 32))
        let expected = try await brightness(of: url, at: 1.3)
        let actual = try await brightness(of: built, at: 0)
        #expect(abs(expected - actual) <= 3)
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func aCopyTakesAFreeNameAndKeepsTheOriginal() async throws {
        let directory = try folder()
        let url = directory.appendingPathComponent("clip.mp4")
        try await makeClip(url, type: .mp4)
        try (url as NSURL).setResourceValue(["Blue"], forKey: .tagNamesKey)
        let before = try Data(contentsOf: url)
        for expected in ["clip trimmed.mp4", "clip trimmed 2.mp4"] {
            let part = try VideoEditor.makePartFolder(beside: url)
            let built = try await VideoEditor.exportTrim(of: url, marks: TrimMarks(inPoint: 1, outPoint: nil), into: part) { _ in }
            let copy = try VideoEditor.publishCopy(built, of: url)
            #expect(copy.lastPathComponent == expected)
            #expect(FinderTags.read(copy).map(\.name) == ["Blue"])
            try FileManager.default.removeItem(at: part)
        }
        #expect(try Data(contentsOf: url) == before)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(Set(names) == ["clip.mp4", "clip trimmed.mp4", "clip trimmed 2.mp4"])
    }

    @Test func replacingPutsTheOriginalAsideAndAFailedTrashChangesNothing() async throws {
        let directory = try folder()
        let holding = try folder()
        let url = directory.appendingPathComponent("clip.mp4")
        try await makeClip(url, type: .mp4)
        let before = try Data(contentsOf: url)
        let part = try VideoEditor.makePartFolder(beside: url)
        let built = try await VideoEditor.exportTrim(of: url, marks: TrimMarks(inPoint: nil, outPoint: 1), into: part) { _ in }

        #expect(throws: VideoEditorError.self) {
            _ = try VideoEditor.publishReplacing(url, with: built) { _ in throw VideoEditorError.cantExport }
        }
        #expect(try Data(contentsOf: url) == before)

        let trashed = try VideoEditor.publishReplacing(url, with: built) { source in
            let held = holding.appendingPathComponent(source.lastPathComponent)
            try FileManager.default.moveItem(at: source, to: held)
            return FileOperations.TrashedItem(original: source, trashed: held)
        }
        #expect(try Data(contentsOf: trashed.trashed) == before)
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        #expect(abs(duration - 1) < 0.15)
    }

    @Test func onlyMP4AndQuickTimeCanBeEdited() {
        #expect(VideoEditor.canEdit(.mpeg4Movie))
        #expect(VideoEditor.canEdit(.quickTimeMovie))
        #expect(!VideoEditor.canEdit(.avi))
        #expect(!VideoEditor.canEdit(.png))
        #expect(!VideoEditor.canEdit(nil))
    }
}

@Suite struct WaveformTests {
    /// Silence with a loud burst starting at `burst` of the way through. 10 seconds at 8 kHz.
    private func makeAudio(channels: AVAudioChannelCount = 1, burst: Double, level: Float = 0.1) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WaveformTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("audio.wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8000, channels: channels))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames: AVAudioFrameCount = 80000
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let start = Int(Double(frames) * burst)
        // Only the last channel, so a peak has to look across channels.
        let channel = try #require(buffer.floatChannelData?[Int(channels) - 1])
        for index in start..<min(start + 800, Int(frames)) { channel[index] = level }
        try file.write(from: buffer)
        return url
    }

    @Test(arguments: [AVAudioChannelCount(1), 2])
    func levelsFallWhereTheSoundIs(channels: AVAudioChannelCount) async throws {
        let levels = try await WaveformReader.read(try makeAudio(channels: channels, burst: 0.5))
        #expect(levels.count == WaveformReader.levelCount)
        let loud = levels.indices.filter { levels[$0] > 0.5 }
        #expect(!loud.isEmpty)
        let middle = Double(WaveformReader.levelCount) / 2
        #expect(abs(Double(loud[0]) - middle) <= 2)
        #expect(Double(loud[loud.count - 1]) < middle + Double(WaveformReader.levelCount) * 0.015)
        #expect(levels[10] < 0.01)
    }

    @Test func quietSoundsAreScaledUp() async throws {
        let levels = try await WaveformReader.read(try makeAudio(burst: 0.2, level: 0.05))
        #expect(abs((levels.max() ?? 0) - 1) < 0.001)
    }

    @Test func silenceStaysFlat() {
        #expect(WaveformReader.normalized([0, 0, 0]) == [0, 0, 0])
    }

    @Test func aSteadySoundHasALevelBelowItsPeak() async throws {
        let levels = try await WaveformReader.read(try makeAudio(burst: 0.5))
        #expect(levels.filter { $0 > 0.9 }.count >= 2)
    }

    @Test func barsKeepShortSounds() {
        var levels = [Float](repeating: 0, count: 1600)
        levels[801] = 1
        let bars = WaveformReader.bars(levels, count: 100)
        #expect(bars.count == 100)
        #expect(bars[50] == 1)
        #expect(bars.filter { $0 > 0 }.count == 1)
        #expect(WaveformReader.bars(levels, count: 0).isEmpty)
        #expect(WaveformReader.bars([0.5], count: 4) == [0.5, 0.5, 0.5, 0.5])
    }

    @Test func aFileThatIsntAudioThrows() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("WaveformTests-\(UUID().uuidString).wav")
        try Data(repeating: 1, count: 100).write(to: url)
        await #expect(throws: (any Error).self) { try await WaveformReader.read(url) }
    }
}

@Suite struct ProjectThumbnailTests {
    private func makeProject(_ files: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for file in files {
            let url = root.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        }
        return root
    }

    private func name(_ source: ProjectThumbnail.Source?) -> String? {
        switch source {
        case .cover(let item): "cover:\(item.name)"
        case .firstFrame(let item): "video:\(item.name)"
        case nil: nil
        }
    }

    @Test func widePictureNamesAreCovers() throws {
        let project = try makeProject([
            "cover 169.jpg", "cover sc 169.png", "COVER 2 169.JPG",
            "cover.jpg", "cover sc 43.jpg", "cover_01_00_11_69.jpg", "cover 1169.jpg", "poster 169.jpg", "cover 169.mov",
        ])
        defer { try? FileManager.default.removeItem(at: project) }
        let matches = try FolderReader.read(project, showHidden: false).filter(ProjectThumbnail.isWideCover).map(\.name)
        #expect(Set(matches) == ["cover 169.jpg", "cover sc 169.png", "COVER 2 169.JPG"])
    }

    @Test func coverWinsOverVideoInNameOrder() throws {
        let project = try makeProject(["2 cover/cover tc 169.jpg", "2 cover/cover sc 169.jpg", "3 video/a.mp4"])
        defer { try? FileManager.default.removeItem(at: project) }
        #expect(name(ProjectThumbnail.source(in: project)) == "cover:cover sc 169.jpg")
    }

    @Test func otherCoversFallBackToTheFirstVideo() throws {
        let project = try makeProject(["2cover/cover.jpg", "3video/clip 10.mp4", "3video/clip 2.MOV", "3video/.hidden.mp4", "3video/note.txt"])
        defer { try? FileManager.default.removeItem(at: project) }
        #expect(name(ProjectThumbnail.source(in: project)) == "video:clip 2.MOV")
    }

    @Test func videosBesideFoldersComeFirstAndNestingIsBounded() throws {
        let beside = try makeProject(["3 video/a/inner.mp4", "3 video/z.mp4"])
        let nested = try makeProject(["3 video/a/b/inner.mp4"])
        let tooDeep = try makeProject(["3 video/a/b/c/inner.mp4"])
        defer { [beside, nested, tooDeep].forEach { try? FileManager.default.removeItem(at: $0) } }
        #expect(name(ProjectThumbnail.source(in: beside)) == "video:z.mp4")
        #expect(name(ProjectThumbnail.source(in: nested)) == "video:inner.mp4")
        #expect(ProjectThumbnail.source(in: tooDeep) == nil)
    }

    @Test func aProjectWithNeitherHasNoSource() throws {
        let project = try makeProject(["1 output/final.mp4", "cover 169.jpg"])
        defer { try? FileManager.default.removeItem(at: project) }
        #expect(ProjectThumbnail.source(in: project) == nil)
    }

    @Test func onlyCoverAndVideoChangesAffectAThumbnail() {
        let root = "/projects"
        #expect(ProjectThumbnail.projectName(affectedBy: "/projects/a", root: root) == "a")
        #expect(ProjectThumbnail.projectName(affectedBy: "/projects/a/2 cover", root: root) == "a")
        #expect(ProjectThumbnail.projectName(affectedBy: "/projects/a/3video/FX3", root: root) == "a")
        #expect(ProjectThumbnail.projectName(affectedBy: "/projects/a/1 output", root: root) == nil)
        #expect(ProjectThumbnail.projectName(affectedBy: "/projects", root: root) == nil)
        #expect(ProjectThumbnail.projectName(affectedBy: "/projects-old/a", root: root) == nil)
    }
}

@Suite struct ProjectStatsTests {
    private func makeFolder(_ files: [String: Int]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (file, size) in files {
            let url = root.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(count: size).write(to: url)
        }
        return root
    }

    @Test func countsNestedFilesAndAddsTheirSizes() throws {
        let folder = try makeFolder(["a.mp4": 100, "3 video/b.mp4": 20, "3 video/FX3/c.mp4": 3])
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(ProjectStats.read(folder) == ProjectStats(fileCount: 3, size: 123))
    }

    @Test func hiddenFilesAddToTheSizeButNotTheCount() throws {
        let folder = try makeFolder([".DS_Store": 7, ".git/objects/x": 10, ".git/config": 1, "a.mp4": 100, "z/b.mp4": 2])
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(ProjectStats.read(folder) == ProjectStats(fileCount: 2, size: 120))
    }

    @Test func aPackageCountsAsOneFile() throws {
        let folder = try makeFolder(["notes.rtfd/TXT.rtf": 5, "notes.rtfd/image.png": 6, "after.mp4": 1])
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(ProjectStats.read(folder) == ProjectStats(fileCount: 2, size: 12))
    }

    @Test func linksAreNotFollowed() throws {
        let outside = try makeFolder(["big.mp4": 1000])
        let folder = try makeFolder(["a.mp4": 1])
        defer { [outside, folder].forEach { try? FileManager.default.removeItem(at: $0) } }
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link"), withDestinationURL: outside)
        let stats = try #require(ProjectStats.read(folder))
        #expect(stats.fileCount == 1)
        #expect(stats.size < 1000)
    }

    @Test func aMissingOrEmptyFolder() throws {
        let folder = try makeFolder([:])
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(ProjectStats.read(folder) == ProjectStats(fileCount: 0, size: 0))
        #expect(ProjectStats.read(folder.appendingPathComponent("gone")) == nil)
    }

    @Test func fileLabelIsSingularForOne() {
        #expect(ProjectStats(fileCount: 1, size: 0).fileLabel == "1 file")
        #expect(ProjectStats(fileCount: 2, size: 0).fileLabel == "2 files")
    }

    @Test func changesAreTracedToTheirProject() {
        #expect(ProjectCatalog.projectName(containing: "/projects/a/1 output/x", root: "/projects") == "a")
        #expect(ProjectCatalog.projectName(containing: "/projects", root: "/projects") == nil)
        #expect(ProjectCatalog.projectName(containing: "/projects-old/a", root: "/projects") == nil)
    }
}
