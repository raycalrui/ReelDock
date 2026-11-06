import AVFoundation
import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import ReelDock

private struct FeatureFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReelDockFeatureTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func url(_ path: String) -> URL { root.appendingPathComponent(path) }

    @discardableResult
    func write(_ path: String, _ data: Data = Data("x".utf8)) throws -> URL {
        let target = url(path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target)
        return target
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func setAttribute(_ name: String, _ data: Data, on url: URL) {
    _ = data.withUnsafeBytes { setxattr(url.path, name, $0.baseAddress, data.count, 0, 0) }
}

private let blackmagicInfo = Data("""
{"filename":"Test001_10221612_C006.mov","size_in_bytes":"1","creation_date":"2026-10-22T16:12:20+0800",
"video":{"codec":"HEVC (H.265)","resolution":{"width":3840,"height":2160},"frame_rate":{"num":60000,"den":1001},"frame_count":600},
"common_clip_metadata":{"lens_type":"Phone 24mm","gamma":"Apple Log"},
"file_specific_clip_metadata":{"camera_type":"iPhone 18 Pro","date_recorded":"2026-10-22T16:12:22+0800"}}
""".utf8)

@Suite struct FileSortTests {
    private func file(_ name: String, size: Int64? = 1, type: UTType? = .mpeg4Movie) -> FolderItem {
        FolderItem(url: URL(fileURLWithPath: "/x/\(name)"), name: name, isFolder: false, size: size, modified: nil, contentType: type)
    }

    private func folder(_ name: String) -> FolderItem {
        FolderItem(url: URL(fileURLWithPath: "/x/\(name)"), name: name, isFolder: true, size: nil, modified: nil, contentType: .folder)
    }

    @Test func foldersStayOnTopWhateverTheOrder() {
        let items = [file("a", size: 5), folder("z"), file("b", size: 9), folder("y")]
        for key in FileSortKey.allCases {
            let sorted = FileSort(key: key, descending: key == .size).sorted(items)
            #expect(sorted.prefix(2).map(\.isFolder) == [true, true])
        }
    }

    @Test func nameUsesFindersNumberOrderBothWays() {
        let items = [file("clip 10"), file("clip 2"), file("clip 1")]
        #expect(FileSort().sorted(items).map(\.name) == ["clip 1", "clip 2", "clip 10"])
        #expect(FileSort(key: .name, descending: true).sorted(items).map(\.name) == ["clip 10", "clip 2", "clip 1"])
    }

    @Test func sizeBreaksTiesByNameAndPutsUnknownLast() {
        let items = [file("b", size: 5), file("a", size: 5), file("big", size: 9), file("none", size: nil)]
        #expect(FileSort(key: .size, descending: true).sorted(items).map(\.name) == ["big", "a", "b", "none"])
        #expect(FileSort(key: .size).sorted(items).map(\.name) == ["a", "b", "big", "none"])
    }

    @Test func datesComeFromWhatsPassedInAndUnknownGoesLast() {
        let items = [file("late"), file("early"), file("unknown")]
        let dates = [items[0].id: Date(timeIntervalSince1970: 200), items[1].id: Date(timeIntervalSince1970: 100)]
        #expect(FileSort(key: .date).sorted(items, dates: dates).map(\.name) == ["early", "late", "unknown"])
        #expect(FileSort(key: .date, descending: true).sorted(items, dates: dates).map(\.name) == ["late", "early", "unknown"])
    }

    @Test func kindGroupsTypesTogether() {
        let items = [file("z.jpg", type: .jpeg), file("a.mov", type: .quickTimeMovie), file("b.jpg", type: .jpeg), file("c.bin", type: nil)]
        let sorted = FileSort(key: .kind).sorted(items).map(\.name)
        #expect(sorted.last == "c.bin")
        #expect(sorted.firstIndex(of: "b.jpg")! + 1 == sorted.firstIndex(of: "z.jpg")!)
    }

    @Test func choosingAKeyStartsInItsUsualDirection() {
        #expect(FileSort().choosing(.size) == FileSort(key: .size, descending: true))
        #expect(FileSort(key: .size, descending: true).choosing(.date) == FileSort(key: .date, descending: false))
        // Choosing the same one again keeps what was set.
        #expect(FileSort(key: .date, descending: true).choosing(.date).descending)
    }

    @Test func shootingDatePrefersTheCamerasRecord() async throws {
        let fixture = try FeatureFixture()
        defer { fixture.remove() }
        let clip = try fixture.write("a.mov")
        setAttribute(BlackmagicClipInfo.infoAttribute, blackmagicInfo, on: clip)
        let date = await ShootingDate.read(clip, contentType: .quickTimeMovie)
        #expect(date == ISO8601DateFormatter().date(from: "2026-10-22T16:12:22+08:00"))
        // A file with nothing better falls back to when it was made.
        let plain = try fixture.write("b.txt")
        #expect(await ShootingDate.read(plain, contentType: .plainText) != nil)
    }

    @Test func exifDatesParse() {
        let parts = ShootingDate.exifDate("2026:10:28 13:14:16").map { Calendar.current.dateComponents([.year, .month, .day, .hour], from: $0) }
        #expect(parts?.year == 2026 && parts?.month == 10 && parts?.day == 28 && parts?.hour == 13)
        #expect(ShootingDate.exifDate("not a date") == nil)
    }
}

@Suite struct SectionViewOptionTests {
    @Test func pictureSectionsStartAsGrids() {
        func section(_ title: String) -> FolderSection {
            FolderSection(kind: .numbered(1), url: URL(fileURLWithPath: "/x/\(title)"), title: title, itemCount: 1)
        }
        #expect(section("2 cover").startsAsGrid)
        #expect(section("5 picture").startsAsGrid)
        #expect(!section("3 video").startsAsGrid)
        #expect(!section("1 output").startsAsGrid)
    }

    @Test func settingsKeepViewOptionsAndReadOlderFiles() throws {
        var settings = AppSettings()
        settings.sections["picture"] = SectionPreference(sort: FileSort(key: .date, descending: true), isGrid: false)
        settings.previewLUTs = ["S-Log3": "/x/a.cube"]
        settings.usesPreviewLUTs = true
        settings.projectArchive = "/Volumes/Backup/archive"
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
        let older = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"sections":{"video":{"collapsed":true}}}"#.utf8))
        #expect(older.sections["video"]?.collapsed == true && older.sections["video"]?.sort == nil)
        #expect(older.previewLUTs.isEmpty && !older.usesPreviewLUTs && older.projectArchive == nil)
    }
}

@Suite struct DownloadedClipTests {
    @Test func parsesWhatTheCameraRecorded() throws {
        let info = try #require(BlackmagicClipInfo.parse(blackmagicInfo))
        #expect(info.time?.day == "2026-10-22")
        #expect(info.time?.time == "16:12")
        #expect(info.time?.month == "202610")
        #expect(info.cameraType == "iPhone 18 Pro")
        #expect(info.gamma == "Apple Log")
        #expect(info.width == 3840 && info.height == 2160)
        #expect(info.frameCount == 600)
        #expect(abs((info.frameRate ?? 0) - 59.94) < 0.01)
        #expect(BlackmagicClipInfo.parse(Data("not json".utf8)) == nil)
    }

    /// It becomes a folder name, and it comes from a file that arrived from elsewhere.
    @Test func aCameraNameThatIsntAPlainNameIsIgnored() throws {
        for name in ["../../elsewhere", "a/b", ".hidden", "", "with:colon"] {
            let json = Data(#"{"file_specific_clip_metadata":{"camera_type":"\#(name)"}}"#.utf8)
            #expect(try #require(BlackmagicClipInfo.parse(json)).cameraType == nil)
        }
    }

    @Test func onlyClipsTheCameraMadeAreListed() async throws {
        let fixture = try FeatureFixture()
        defer { fixture.remove() }
        #expect(await DownloadedClips.read(fixture.root) == nil)

        try fixture.write("movie from the web.mp4")
        try fixture.write("notes.txt")
        #expect(await DownloadedClips.read(fixture.root) == nil)

        let clip = try fixture.write("Test001_10221612_C006.mov", Data(repeating: 1, count: 100))
        setAttribute(BlackmagicClipInfo.infoAttribute, blackmagicInfo, on: clip)
        let hidden = try fixture.write(".Test001_10221612_C007.mov")
        setAttribute(BlackmagicClipInfo.infoAttribute, blackmagicInfo, on: hidden)

        let listed = await DownloadedClips.read(fixture.root)
        let card = try #require(listed)
        #expect(card.isFolderSource)
        #expect(card.clips.map(\.name) == ["Test001_10221612_C006.mov"])
        let found = try #require(card.clips.first)
        #expect(found.size == 100)
        #expect(found.deviceFolder == "iPhone 18 Pro")
        #expect(found.time?.month == "202610")
        #expect(abs((found.duration ?? 0) - 10.01) < 0.05)
    }

    @Test func eachClipGoesToItsOwnCamerasArchiveFolder() throws {
        let fixture = try FeatureFixture()
        defer { fixture.remove() }
        let info = try #require(BlackmagicClipInfo.parse(blackmagicInfo))
        let clip = DownloadedClips.clip(fixture.url("a.mov"), info: info, size: 1, modified: nil)
        let folder = ImportRouting.archiveFolder(mediaRoot: fixture.url("media"), clip: clip, deviceFolder: try #require(clip.deviceFolder))
        #expect(folder?.path == fixture.url("media/202610/video/iPhone 18 Pro").path)
    }

    @Test func aCopyKeepsTheCamerasMetadataButNotQuarantine() throws {
        let fixture = try FeatureFixture()
        defer { fixture.remove() }
        let source = try fixture.write("a.mov", Data(repeating: 7, count: 1000))
        setAttribute(BlackmagicClipInfo.infoAttribute, blackmagicInfo, on: source)
        setAttribute("com.apple.quarantine", Data("0081;0;sharingd;".utf8), on: source)
        try FileManager.default.createDirectory(at: fixture.url("out"), withIntermediateDirectories: true)
        let output = try ClipCopier.copy(source: source, toFolder: fixture.url("out"), control: CopyControl()) {
            $0.hasPrefix(BlackmagicClipInfo.attributePrefix)
        }
        #expect(BlackmagicClipInfo.read(output.url)?.cameraType == "iPhone 18 Pro")
        #expect(!ExtendedAttributes.names(of: output.url).contains("com.apple.quarantine"))
    }

    @Test func aClipInTheProjectArchiveCountsAsImported() throws {
        let fixture = try FeatureFixture()
        defer { fixture.remove() }
        let copy = try fixture.write("archive/20260101_old/3 video/clip.mov", Data(repeating: 1, count: 5))
        let index = ClipIndex.scan(projectRoot: fixture.url("none"), mediaRoot: nil, archiveRoot: fixture.url("archive"))
        // The system can report a temporary folder under /private, so only the end of the path is compared.
        #expect(index.paths(name: "clip.mov", size: 5).map { $0.hasSuffix("archive/20260101_old/3 video/clip.mov") } == [true])
        #expect(ClipPresence.placeName(path: copy.path, projectRoot: nil, mediaRoot: nil, archiveRoot: fixture.url("archive")) == "20260101_old")
    }
}

@Suite struct LogFootageTests {
    @Test func namesMapToCurves() {
        #expect(LogFootage.gamma(named: "s-log3-cine") == .sLog3)
        #expect(LogFootage.gamma(named: "s-log3") == .sLog3)
        #expect(LogFootage.gamma(named: "Apple Log") == .appleLog)
        #expect(LogFootage.gamma(named: "Apple Log 2") == .appleLog2)
        #expect(LogFootage.gamma(named: "Rec.709") == nil)
        #expect(LogFootage.gamma(named: "rec709") == nil)
    }

    /// As written by Blackmagic Camera on an iPhone 16 Pro and an iPhone 18 Pro.
    @Test func theTrackTagTellsTheTwoAppleLogsApart() {
        #expect(LogFootage.gamma(logTag: "com.apple.rec2020.apple-log") == .appleLog)
        #expect(LogFootage.gamma(logTag: "com.apple.apple-wide-gamut.apple-log") == .appleLog2)
        #expect(LogFootage.gamma(logTag: "something else") == nil)
    }

    @Test func readsSonysTrailerAndTheCamerasAttribute() async throws {
        let fixture = try FeatureFixture()
        defer { fixture.remove() }
        var sony = Data(repeating: 0, count: 100_000)
        sony.append(Data(#"<Item name="CaptureGammaEquation" value="s-log3-cine"/>"#.utf8))
        sony.append(Data(repeating: 0, count: 700))
        let sonyClip = try fixture.write("a.MP4", sony)
        #expect(await LogFootage.gamma(of: sonyClip) == .sLog3)

        var standard = Data(repeating: 0, count: 100_000)
        standard.append(Data(#"<Item name="CaptureGammaEquation" value="rec709"/>"#.utf8))
        let standardClip = try fixture.write("b.MP4", standard)
        #expect(await LogFootage.gamma(of: standardClip) == nil)

        // A file from anywhere else has no curve on record, so a LUT never lands on a finished video.
        let output = try fixture.write("output.mov", Data(repeating: 0, count: 100))
        #expect(await LogFootage.gamma(of: output) == nil)

        let phone = try fixture.write("c.mov")
        setAttribute(BlackmagicClipInfo.infoAttribute, blackmagicInfo, on: phone)
        #expect(await LogFootage.gamma(of: phone) == .appleLog)
        #expect(LogFootage.knownGamma(of: phone) == .appleLog)
    }
}

@Suite struct CubeLUTTests {
    private func cubeText(size: Int, _ value: (Float, Float, Float) -> (Float, Float, Float)) -> String {
        var lines = ["TITLE \"Test\"", "LUT_3D_SIZE \(size)"]
        let step = 1 / Float(size - 1)
        for blue in 0..<size {
            for green in 0..<size {
                for red in 0..<size {
                    let result = value(Float(red) * step, Float(green) * step, Float(blue) * step)
                    lines.append("\(result.0) \(result.1) \(result.2)")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    @Test func parsesTitleSizeAndValues() throws {
        let lut = try CubeLUT(text: cubeText(size: 2) { (1 - $0, 1 - $1, 1 - $2) })
        #expect(lut.title == "Test")
        #expect(lut.cube?.size == 2)
        #expect(lut.apply(SIMD3(1, 0, 0.25)) == SIMD3(0, 1, 0.75))
    }

    @Test func rejectsBadFiles() {
        #expect(throws: CubeLUT.ParseError.missingSize) { try CubeLUT(text: "0 0 0") }
        #expect(throws: CubeLUT.ParseError.wrongEntryCount(expected: 8, found: 1)) { try CubeLUT(text: "LUT_3D_SIZE 2\n0 0 0") }
        #expect(throws: CubeLUT.ParseError.badLine(2)) { try CubeLUT(text: "LUT_3D_SIZE 2\n1 2 x") }
    }

    @Test func aLargeCubeIsSampledDownToWhatCoreImageTakes() throws {
        let lut = try CubeLUT(text: cubeText(size: 65) { ($0, $1, $2) })
        let cube = lut.colorCube(maxDimension: 64)
        #expect(cube.dimension == 64)
        #expect(cube.data.count == 64 * 64 * 64 * 4 * MemoryLayout<Float>.size)
    }

    /// Goes through a real composition and image generator, so it also covers the compositor and its rotation.
    @Test func compositionShowsTheFrameThroughTheLUTUpright() async throws {
        let fixture = try FeatureFixture()
        defer { fixture.remove() }
        let clip = fixture.url("clip.mov")
        // Stored 64×32, and shown turned a quarter clockwise.
        try await makeClip(clip, transform: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 32, ty: 0))
        let grade = PreviewGrade(lut: try CubeLUT(text: cubeText(size: 2) { (1 - $0, 1 - $1, 1 - $2) }))

        let asset = AVURLAsset(url: clip)
        let composition = try #require(await grade.composition(for: asset))
        #expect(composition.renderSize == CGSize(width: 32, height: 64))
        // The player shows untagged output darker than the same frame as a picture.
        #expect(composition.colorPrimaries == AVVideoColorPrimaries_ITU_R_709_2)
        #expect(composition.colorTransferFunction == AVVideoTransferFunction_ITU_R_709_2)
        #expect(composition.colorYCbCrMatrix == AVVideoYCbCrMatrix_ITU_R_709_2)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.videoComposition = composition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: .zero).image
        #expect(image.width == 32 && image.height == 64)

        // The clip's left half is bright and its right half dark. Turned clockwise, bright is on top, and the LUT inverts it.
        let rep = NSBitmapImageRep(cgImage: image)
        let top = try #require(rep.colorAt(x: 16, y: 8)?.usingColorSpace(.deviceRGB))
        let bottom = try #require(rep.colorAt(x: 16, y: 56)?.usingColorSpace(.deviceRGB))
        #expect(top.greenComponent < 0.3)
        #expect(bottom.greenComponent > 0.7)
    }

    /// A video layer shows Rec. 709 with a gamma of 2.4 and a picture with 1.961, so frames for a layer are re-encoded.
    @Test func framesForAVideoLayerAreReencodedToLookLikeAPicture() throws {
        let grade = PreviewGrade(lut: try CubeLUT(text: cubeText(size: 2) { ($0, $1, $2) }))
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary, &buffer)
        let source = try #require(buffer)
        CVPixelBufferLockBaseAddress(source, [])
        // Opaque, or Core Image would divide by alpha first and the curve would land on 1.
        let pixels = try #require(CVPixelBufferGetBaseAddress(source)).assumingMemoryBound(to: UInt8.self)
        for offset in stride(from: 0, to: CVPixelBufferGetDataSize(source), by: 4) {
            pixels[offset] = 100
            pixels[offset + 1] = 100
            pixels[offset + 2] = 100
            pixels[offset + 3] = 255
        }
        CVPixelBufferUnlockBaseAddress(source, [])

        func green(forVideoLayer: Bool) throws -> Double {
            var created: CVPixelBuffer?
            CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary, &created)
            let output = try #require(created)
            try grade.render(grade.image(from: source, forVideoLayer: forVideoLayer), into: output)
            CVPixelBufferLockBaseAddress(output, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(output, .readOnly) }
            let base = try #require(CVPixelBufferGetBaseAddress(output))
            return Double(base.load(fromByteOffset: 1, as: UInt8.self)) / 255
        }
        let picture = try green(forVideoLayer: false)
        let layer = try green(forVideoLayer: true)
        #expect(abs(picture - 100.0 / 255) < 0.01)
        #expect(abs(layer - pow(picture, 1.961 / 2.4)) < 0.01)
    }

    @Test func gradedSamplesKeepTheirSizeAndTime() throws {
        let grade = PreviewGrade(lut: try CubeLUT(text: cubeText(size: 2) { (1 - $0, 1 - $1, 1 - $2) }))
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 32, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary, &buffer)
        let source = try #require(buffer)
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: source, formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 60), presentationTimeStamp: CMTime(value: 7, timescale: 60), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        let description = try #require(format)
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: source, formatDescription: description, sampleTiming: &timing, sampleBufferOut: &sample)
        let frame = try #require(sample)

        var pool: CVPixelBufferPool?
        let graded = try #require(grade.gradedSample(frame, pool: &pool))
        let output = try #require(CMSampleBufferGetImageBuffer(graded))
        #expect(CVPixelBufferGetWidth(output) == 64 && CVPixelBufferGetHeight(output) == 32)
        #expect(CMSampleBufferGetPresentationTimeStamp(graded) == CMTime(value: 7, timescale: 60))
    }

    /// Half bright and half dark, so a wrong turn shows.
    private func makeClip(_ url: URL, transform: CGAffineTransform) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 64,
            AVVideoHeightKey: 32,
        ])
        input.transform = transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64,
            kCVPixelBufferHeightKey as String: 32,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<5 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var created: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, try #require(adaptor.pixelBufferPool), &created)
            let buffer = try #require(created)
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
            let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<32 {
                for x in 0..<64 {
                    let pixel = base + y * bytesPerRow + x * 4
                    let value: UInt8 = x < 32 ? 235 : 16
                    pixel[0] = value
                    pixel[1] = value
                    pixel[2] = value
                    pixel[3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
    }
}
