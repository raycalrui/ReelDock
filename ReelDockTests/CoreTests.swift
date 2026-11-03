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
