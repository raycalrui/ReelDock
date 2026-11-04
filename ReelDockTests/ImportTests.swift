import Foundation
import Testing
@testable import ReelDock

private struct ImportFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReelDockImportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func url(_ path: String) -> URL { root.appendingPathComponent(path) }

    @discardableResult
    func write(_ path: String, _ text: String) throws -> URL {
        try write(path, Data(text.utf8))
    }

    @discardableResult
    func write(_ path: String, _ data: Data) throws -> URL {
        let target = url(path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target)
        return target
    }

    func folder(_ path: String) throws {
        try FileManager.default.createDirectory(at: url(path), withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    /// An invented card with the layout and metadata of a Sony XAVC card.
    func makeSonyCard(clips: [(name: String, recorded: String, frames: Int)], volume: String = "card") throws -> URL {
        let materials = clips.map { clip in
            let base = (clip.name as NSString).deletingPathExtension
            return """
            <Material uri="./CLIP/\(clip.name)" type="MP4" videoType="HEVC_3840_2160_M10P@L51HT" audioType="LPCM24" fps="59.94p" dur="\(clip.frames)" ch="2" umid="UMID-\(base)">
              <RelevantInfo uri="./CLIP/\(base)M01.XML" type="XML"/>
            </Material>
            """
        }.joined(separator: "\n")
        try write("\(volume)/PRIVATE/M4ROOT/MEDIAPRO.XML", """
        <?xml version="1.0" encoding="UTF-8"?>
        <MediaProfile xmlns="http://xmlns.sony.net/pro/metadata/mediaprofile" version="2.30">
          <Properties><System systemId="TEST" systemKind="ILME-FX3A"/></Properties>
          <Contents>\(materials)</Contents>
        </MediaProfile>
        """)
        for clip in clips {
            let base = (clip.name as NSString).deletingPathExtension
            try write("\(volume)/PRIVATE/M4ROOT/CLIP/\(clip.name)", "video-\(clip.name)")
            try write("\(volume)/PRIVATE/M4ROOT/CLIP/\(base)M01.XML", """
            <?xml version="1.0" encoding="UTF-8"?>
            <NonRealTimeMeta xmlns="urn:schemas-professionalDisc:nonRealTimeMeta:ver.2.20">
              <CreationDate value="\(clip.recorded)"/>
              <Lens modelName="FE Test Lens"/>
              <AcquisitionRecord><Group name="CameraUnitMetadataSet"><Item name="CaptureGammaEquation" value="s-log3-cine"/></Group></AcquisitionRecord>
            </NonRealTimeMeta>
            """)
            try write("\(volume)/PRIVATE/M4ROOT/THMBNL/\(base)T01.JPG", "jpg")
        }
        return url(volume)
    }
}

@Suite struct SonyAdapterTests {
    @Test func readsClipsAndMetadataAndIgnoresSidecars() throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }
        let volume = try fixture.makeSonyCard(clips: [("A0001.MP4", "2026-11-03T13:14:16+08:00", 210)])
        try fixture.write("card/PRIVATE/M4ROOT/CLIP/._A0001.MP4", "appledouble")

        let adapter = SonyCardAdapter()
        #expect(adapter.matches(volume: volume))
        let card = try adapter.read(volume: volume)

        #expect(card.cameraModel == "ILME-FX3A")
        #expect(card.deviceFolder == "FX3")
        #expect(card.clips.map(\.name) == ["A0001.MP4"])
        let clip = try #require(card.clips.first)
        #expect(clip.umid == "UMID-A0001")
        #expect(clip.codec == "HEVC")
        #expect(clip.width == 3840)
        #expect(clip.height == 2160)
        #expect(clip.frameRateLabel == "59.94p")
        #expect(abs((clip.duration ?? 0) - 3.5035) < 0.001)
        #expect(clip.lens == "FE Test Lens")
        #expect(clip.gamma == "S-Log3 Cine")
        #expect(clip.time?.month == "202611")
        #expect(clip.time?.day == "2026-11-03")
        #expect(clip.time?.time == "13:14")
        #expect(clip.thumbnailURL?.lastPathComponent == "A0001T01.JPG")
    }

    @Test func keepsTheCameraDateAcrossTimeZones() {
        // Just after midnight on the camera, which is still the previous month in UTC.
        let time = ClipTime(recorded: "2026-11-01T00:10:00+08:00")
        #expect(time?.month == "202611")
        #expect(time?.day == "2026-11-01")
    }

    @Test func rejectsBadDates() {
        #expect(ClipTime(recorded: "garbage") == nil)
        #expect(ClipTime(recorded: "") == nil)
    }

    @Test func missingDatabaseStillListsEveryClip() throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }
        let volume = try fixture.makeSonyCard(clips: [("A0001.MP4", "2026-11-03T13:14:16+08:00", 210)])
        try FileManager.default.removeItem(at: fixture.url("card/PRIVATE/M4ROOT/MEDIAPRO.XML"))

        let card = try SonyCardAdapter().read(volume: volume)
        #expect(card.clips.map(\.name) == ["A0001.MP4"])
        #expect(card.clips[0].time?.day == "2026-11-03")
        #expect(card.cameraModel == nil)
        #expect(card.deviceFolder == nil)
    }

    @Test func damagedDatabaseAndClipMissingFromItAreStillListed() throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }
        let volume = try fixture.makeSonyCard(clips: [("A0001.MP4", "2026-11-03T13:14:16+08:00", 210)])
        try fixture.write("card/PRIVATE/M4ROOT/CLIP/A0002.MP4", "not in the database")
        try fixture.write("card/PRIVATE/M4ROOT/MEDIAPRO.XML", "<broken")

        let card = try SonyCardAdapter().read(volume: volume)
        #expect(Set(card.clips.map(\.name)) == ["A0001.MP4", "A0002.MP4"])
    }

    @Test func databaseEntryForAMissingFileIsNotListed() throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }
        let volume = try fixture.makeSonyCard(clips: [("A0001.MP4", "2026-11-03T13:14:16+08:00", 210)])
        try FileManager.default.removeItem(at: fixture.url("card/PRIVATE/M4ROOT/CLIP/A0001.MP4"))
        #expect(try SonyCardAdapter().read(volume: volume).clips.isEmpty)
    }

    @Test func otherVolumesDoNotMatch() throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }
        try fixture.folder("plain/DCIM")
        #expect(!SonyCardAdapter().matches(volume: fixture.url("plain")))
    }
}

@Suite struct ClipGroupingTests {
    private func clip(_ name: String, _ recorded: String) -> CardClip {
        CardClip(url: URL(fileURLWithPath: "/card/\(name)"), name: name, size: 1, time: ClipTime(recorded: recorded))
    }

    @Test func splitsByDayAndHourLongGapsOldestFirst() {
        let groups = ClipGrouping.groups([
            clip("a", "2026-11-02T10:00:00+08:00"),
            clip("b", "2026-11-02T10:50:00+08:00"),
            clip("c", "2026-11-02T12:00:00+08:00"),
            clip("d", "2026-11-03T09:00:00+08:00"),
        ])
        #expect(groups.map { $0.clips.map(\.name) } == [["a", "b"], ["c"], ["d"]])
        #expect(groups[0].title == "2026-11-02  10:00 – 10:50")
        #expect(groups[2].title == "2026-11-03  09:00")
    }

    @Test func midnightStartsANewGroup() {
        let groups = ClipGrouping.groups([
            clip("a", "2026-11-02T23:50:00+08:00"),
            clip("b", "2026-11-03T00:10:00+08:00"),
        ])
        #expect(groups.count == 2)
    }

    @Test func undatedClipsGoLast() {
        let undated = CardClip(url: URL(fileURLWithPath: "/card/x"), name: "x", size: 1, time: nil)
        let groups = ClipGrouping.groups([undated, clip("a", "2026-11-02T10:00:00+08:00")])
        #expect(groups.map { $0.clips.map(\.name) } == [["a"], ["x"]])
        #expect(groups[1].title == "Unknown date")
    }
}

@Suite struct ClipStatusTests {
    private func clip(_ name: String, size: Int64, umid: String? = nil) -> CardClip {
        CardClip(url: URL(fileURLWithPath: "/card/\(name)"), name: name, size: size, time: nil, umid: umid)
    }

    @Test func scanMatchesNameAndSizeNotNameAlone() throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }
        try fixture.write("project/20261028_a/3 video/C1.MP4", "12345")
        try fixture.write("project/20261028_a/3 video/nested/C2.MP4", "12345")
        try fixture.write("project/20261028_a/_proxy/C3.MP4", "12345")
        try fixture.write("project/20261028_a/1 output/C4.MP4", "12345")
        try fixture.write("media/202611/video/FX3/C5.MP4", "12345")
        try fixture.write("media/template/video/FX3/C6.MP4", "12345")

        let ledger = ImportLedger(fileURL: fixture.url("ledger.jsonl"))
        let index = ClipIndex.scan(projectRoot: fixture.url("project"), mediaRoot: fixture.url("media"))
        func present(_ name: String, _ size: Int64 = 5) -> Bool {
            !ClipPresence.resolve(clip(name, size: size), ledger: ledger, index: index).isNew
        }

        #expect(present("C1.MP4"))
        #expect(present("C2.MP4"))
        #expect(present("C5.MP4"))
        #expect(!present("C1.MP4", 42), "same name, different size is a different clip")
        #expect(!present("C3.MP4"), "proxy folders aren't scanned")
        #expect(!present("C4.MP4"), "only video folders are scanned")
        #expect(!present("C6.MP4"), "the archive template isn't scanned")
    }

    @Test func statusDependsOnTheCurrentFolder() throws {
        let root = URL(fileURLWithPath: "/v/project")
        let media = URL(fileURLWithPath: "/v/media")
        let inProject = ClipPresence(existingPaths: ["/v/project/20261028_a/3 video/C.MP4"], isInLedger: false)

        #expect(inProject.status(currentFolder: root.appendingPathComponent("20261028_a"), projectRoot: root, mediaRoot: media)
            == .inCurrentFolder(path: "/v/project/20261028_a/3 video/C.MP4"))
        #expect(inProject.status(currentFolder: root.appendingPathComponent("20261028_a b"), projectRoot: root, mediaRoot: media)
            == .elsewhere(path: "/v/project/20261028_a/3 video/C.MP4", place: "20261028_a"))

        let inArchive = ClipPresence(existingPaths: ["/v/media/202611/video/FX3/C.MP4"], isInLedger: true)
        #expect(inArchive.status(currentFolder: nil, projectRoot: root, mediaRoot: media)
            == .elsewhere(path: "/v/media/202611/video/FX3/C.MP4", place: "media/202611"))

        #expect(ClipPresence(existingPaths: [], isInLedger: true).status(currentFolder: nil, projectRoot: root, mediaRoot: media) == .importedMissing)
        #expect(ClipPresence(existingPaths: [], isInLedger: false).status(currentFolder: nil, projectRoot: root, mediaRoot: media) == .new)
    }

    @Test func ledgerRecognizesAClipByUMIDAfterItWasRenamed() throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }
        let renamed = try fixture.write("elsewhere/renamed.MP4", "12345")
        let ledger = ImportLedger(fileURL: fixture.url("ledger.jsonl"))
        try ledger.append(LedgerEntry(umid: "U1", name: "C1.MP4", size: 5, sha256: "x", destination: renamed.path, importedAt: Date()))

        let presence = ClipPresence.resolve(clip("C1.MP4", size: 5, umid: "U1"), ledger: ledger, index: ClipIndex())
        #expect(presence.existingPaths == [renamed.path])

        // A different UMID is a different clip, even with the same name and size.
        let other = ClipPresence.resolve(clip("C1.MP4", size: 5, umid: "U2"), ledger: ledger, index: ClipIndex())
        #expect(other.isNew)
    }

    @Test func ledgerSurvivesReloadAndADamagedLine() throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }
        let file = fixture.url("support/ledger.jsonl")
        let ledger = ImportLedger(fileURL: file)
        try ledger.append(LedgerEntry(umid: "U1", name: "C1.MP4", size: 5, sha256: "x", destination: "/gone", importedAt: Date()))
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{damaged\n".utf8))
        try handle.close()
        let later = ImportLedger(fileURL: file)
        try later.append(LedgerEntry(umid: "U2", name: "C2.MP4", size: 6, sha256: "y", destination: "/gone2", importedAt: Date()))

        let reloaded = ImportLedger(fileURL: file)
        #expect(reloaded.entries(matching: clip("C1.MP4", size: 5, umid: "U1")).count == 1)
        #expect(reloaded.entries(matching: clip("C2.MP4", size: 6, umid: "U2")).count == 1)
    }
}

@Suite struct ImportRoutingTests {
    @Test func findsVideoFolderInAnySpelling() throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }
        try fixture.folder("a/3 video")
        try fixture.folder("b/3video")
        try fixture.folder("c/Video")
        try fixture.folder("d/1 output")
        #expect(ImportRouting.videoFolder(inProject: fixture.url("a"))?.lastPathComponent == "3 video")
        #expect(ImportRouting.videoFolder(inProject: fixture.url("b"))?.lastPathComponent == "3video")
        #expect(ImportRouting.videoFolder(inProject: fixture.url("c"))?.lastPathComponent == "Video")
        #expect(ImportRouting.videoFolder(inProject: fixture.url("d")) == nil)
    }

    @Test func archiveUsesTheShootingMonthAndCopiesTheTemplateLayout() throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }
        try fixture.folder("media/template/video/FX3")
        try fixture.folder("media/template/audio/Recorder")
        try fixture.write("media/template/.DS_Store", "x")
        let media = fixture.url("media")
        let clip = CardClip(
            url: URL(fileURLWithPath: "/card/A.MP4"),
            name: "A.MP4",
            size: 1,
            time: ClipTime(recorded: "2026-09-30T23:50:00+08:00")
        )

        let folder = try #require(ImportRouting.archiveFolder(mediaRoot: media, clip: clip, deviceFolder: "FX3"))
        #expect(folder.path.hasSuffix("/media/202609/video/FX3"))
        try ImportRouting.prepareArchiveFolder(folder, mediaRoot: media)

        let manager = FileManager.default
        #expect(manager.fileExists(atPath: folder.path))
        #expect(manager.fileExists(atPath: fixture.url("media/202609/audio/Recorder").path))
        #expect(!manager.fileExists(atPath: fixture.url("media/202609/.DS_Store").path))
    }

    @Test func existingMonthIsNotRebuiltAndMissingDeviceFolderIsAdded() throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }
        try fixture.folder("media/template/audio/Recorder")
        try fixture.write("media/202611/video/keep.txt", "x")
        let folder = fixture.url("media/202611/video/FX3")
        try ImportRouting.prepareArchiveFolder(folder, mediaRoot: fixture.url("media"))
        #expect(FileManager.default.fileExists(atPath: folder.path))
        #expect(FileManager.default.fileExists(atPath: fixture.url("media/202611/video/keep.txt").path))
        #expect(!FileManager.default.fileExists(atPath: fixture.url("media/202611/audio").path))
    }

    @Test func archiveWithoutTemplateStillWorks() throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }
        let folder = fixture.url("media/202611/video/FX3")
        try ImportRouting.prepareArchiveFolder(folder, mediaRoot: fixture.url("media"))
        #expect(FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func clipWithoutADateHasNoArchiveFolder() {
        let clip = CardClip(url: URL(fileURLWithPath: "/card/A.MP4"), name: "A.MP4", size: 1, time: nil)
        #expect(ImportRouting.archiveFolder(mediaRoot: URL(fileURLWithPath: "/m"), clip: clip, deviceFolder: "FX3") == nil)
    }

    @Test func spaceCheckComparesAgainstTheVolume() throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }
        #expect(ImportRouting.hasEnoughSpace(1, at: fixture.url("does/not/exist/yet")))
        #expect(!ImportRouting.hasEnoughSpace(Int64.max, at: fixture.root))
    }
}

@Suite struct ClipCopierTests {
    private func contents(_ folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    @Test func copiesVerifiesAndKeepsDates() throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }
        let payload = Data((0..<(9 << 20)).map { UInt8($0 & 0xFF) })
        let source = try fixture.write("card/clip.MP4", payload)
        let shot = Date(timeIntervalSince1970: 1_790_000_000)
        try FileManager.default.setAttributes([.modificationDate: shot, .creationDate: shot], ofItemAtPath: source.path)
        try fixture.folder("dest")

        let control = CopyControl()
        let output = try ClipCopier.copy(source: source, toFolder: fixture.url("dest"), control: control)

        #expect(output.url.lastPathComponent == "clip.MP4")
        #expect(try Data(contentsOf: output.url) == payload)
        #expect(output.size == Int64(payload.count))
        #expect(output.sha256.count == 64)
        #expect(control.bytesCopied == Int64(payload.count))
        #expect(try contents(fixture.url("dest")) == ["clip.MP4"], "no temporary file remains")
        let attributes = try FileManager.default.attributesOfItem(atPath: output.url.path)
        #expect(attributes[.modificationDate] as? Date == shot)
        #expect(attributes[.creationDate] as? Date == shot)
    }

    @Test func neverOverwritesAnExistingFile() throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }
        let source = try fixture.write("card/clip.MP4", "new")
        try fixture.write("dest/clip.MP4", "original")
        try fixture.write("dest/clip_1.MP4", "also original")

        let output = try ClipCopier.copy(source: source, toFolder: fixture.url("dest"), control: CopyControl())

        #expect(output.url.lastPathComponent == "clip_2.MP4")
        #expect(try String(contentsOf: fixture.url("dest/clip.MP4"), encoding: .utf8) == "original")
        #expect(try String(contentsOf: fixture.url("dest/clip_1.MP4"), encoding: .utf8) == "also original")
        #expect(try String(contentsOf: output.url, encoding: .utf8) == "new")
    }

    @Test func aDamagedWriteIsNeverPublished() throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }
        let source = try fixture.write("card/clip.MP4", "the original bytes")
        try fixture.folder("dest")
        let hooks = ClipCopier.Hooks(afterWrite: { part in
            try? Data("damaged".utf8).write(to: part)
        })

        #expect(throws: ClipCopier.Failure.verificationMismatch) {
            try ClipCopier.copy(source: source, toFolder: fixture.url("dest"), control: CopyControl(), hooks: hooks)
        }
        #expect(try contents(fixture.url("dest")).isEmpty)
    }

    @Test func cancelLeavesNothingBehind() throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }
        let source = try fixture.write("card/clip.MP4", "bytes")
        try fixture.folder("dest")
        let control = CopyControl()
        control.cancel()

        #expect(throws: ClipCopier.Failure.cancelled) {
            try ClipCopier.copy(source: source, toFolder: fixture.url("dest"), control: control)
        }
        #expect(try contents(fixture.url("dest")).isEmpty)
    }

    @Test func missingSourceAndUnwritableDestinationAreDistinguished() throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }
        try fixture.folder("dest")
        #expect(throws: ClipCopier.Failure.sourceRead(ENOENT)) {
            try ClipCopier.copy(source: fixture.url("card/none.MP4"), toFolder: fixture.url("dest"), control: CopyControl())
        }
        let source = try fixture.write("card/clip.MP4", "bytes")
        #expect(throws: ClipCopier.Failure.destinationWrite(ENOENT)) {
            try ClipCopier.copy(source: source, toFolder: fixture.url("no/folder"), control: CopyControl())
        }
    }

    @Test func sourceIsNeverModified() throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }
        let source = try fixture.write("card/clip.MP4", "bytes")
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: source.path)
        let before = try FileManager.default.attributesOfItem(atPath: source.path)[.modificationDate] as? Date
        try fixture.folder("dest")

        _ = try ClipCopier.copy(source: source, toFolder: fixture.url("dest"), control: CopyControl())

        #expect(try FileManager.default.attributesOfItem(atPath: source.path)[.modificationDate] as? Date == before)
        #expect(try Data(contentsOf: source) == Data("bytes".utf8))
    }

    @Test func registryRemovesOnlyTemporaryFilesAfterACrash() throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }
        let part = try fixture.write("dest/.reeldock-clip.MP4-abc.part", "partial")
        let footage = try fixture.write("dest/clip.MP4", "footage")
        let registry = PartFileRegistry(fileURL: fixture.url("support/in-progress.json"))
        registry.add(part)
        registry.add(footage) // A bad record must not be able to delete footage.

        PartFileRegistry(fileURL: fixture.url("support/in-progress.json")).removeLeftovers()

        #expect(!FileManager.default.fileExists(atPath: part.path))
        #expect(FileManager.default.fileExists(atPath: footage.path))
    }
}
