import Foundation

/// When a clip was shot, keeping the camera's own local date rather than converting to the Mac's time zone.
nonisolated struct ClipTime: Hashable, Sendable {
    let date: Date
    /// `2026-11-03`
    let day: String
    /// `13:14`
    let time: String
    /// `202611`
    let month: String

    /// Parses `2026-11-03T13:14:16+08:00`. The digits are checked because this comes from the card.
    init?(recorded text: String) {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: text), text.count >= 16 else { return nil }
        let characters = Array(text)
        let year = String(characters[0..<4])
        let monthDigits = String(characters[5..<7])
        let dayDigits = String(characters[8..<10])
        guard (year + monthDigits + dayDigits).allSatisfy(\.isASCII),
              (year + monthDigits + dayDigits).allSatisfy(\.isNumber) else { return nil }
        self.date = date
        day = "\(year)-\(monthDigits)-\(dayDigits)"
        time = String(characters[11..<16])
        month = year + monthDigits
    }

    init(fileDate date: Date) {
        self.date = date
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let year = String(format: "%04d", parts.year ?? 0)
        let monthDigits = String(format: "%02d", parts.month ?? 0)
        day = "\(year)-\(monthDigits)-\(String(format: "%02d", parts.day ?? 0))"
        time = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        month = year + monthDigits
    }
}

nonisolated struct CardClip: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let size: Int64
    let time: ClipTime?
    var umid: String?
    var durationFrames: Int?
    var frameRateLabel: String?
    var codec: String?
    var width: Int?
    var height: Int?
    var lens: String?
    var gamma: String?
    var thumbnailURL: URL?

    var id: String { url.path }

    var duration: Double? {
        guard let durationFrames, let frameRateLabel,
              let rate = Double(frameRateLabel.trimmingCharacters(in: .letters)), rate > 0 else { return nil }
        return Double(durationFrames) / rate
    }
}

nonisolated struct CameraCard: Identifiable, Hashable, Sendable {
    let volumeURL: URL
    let volumeName: String
    let adapterName: String
    let cameraModel: String?
    /// Folder name under `video` in the personal archive. Nil means the camera isn't known.
    let deviceFolder: String?
    let clips: [CardClip]

    var id: String { volumeURL.path }
}

nonisolated protocol CardAdapter: Sendable {
    var name: String { get }
    func matches(volume: URL) -> Bool
    func read(volume: URL) throws -> CameraCard
}

nonisolated enum CardAdapters {
    static let all: [any CardAdapter] = [SonyCardAdapter()]

    static func adapter(for volume: URL) -> (any CardAdapter)? {
        all.first { $0.matches(volume: volume) }
    }
}

/// Reads Sony XAVC cards. Only ever reads: nothing in the import flow writes to a card.
nonisolated struct SonyCardAdapter: CardAdapter {
    let name = "Sony"
    private static let root = "PRIVATE/M4ROOT"
    private static let deviceFolders = ["ILME-FX3": "FX3", "ILME-FX3A": "FX3"]

    func matches(volume: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let path = volume.appendingPathComponent("\(Self.root)/CLIP").path
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// The folder listing decides which clips exist, so a stale or damaged database can't hide footage.
    /// The XML files only add details.
    func read(volume: URL) throws -> CameraCard {
        let root = volume.appendingPathComponent(Self.root, isDirectory: true)
        let clipFolder = root.appendingPathComponent("CLIP", isDirectory: true)
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        let videoFiles = try FileManager.default
            .contentsOfDirectory(at: clipFolder, includingPropertiesForKeys: Array(keys), options: [])
            .filter { !$0.lastPathComponent.hasPrefix(".") && $0.pathExtension.caseInsensitiveCompare("MP4") == .orderedSame }

        let profile = (try? Data(contentsOf: root.appendingPathComponent("MEDIAPRO.XML"))).map(SonyMediaProfile.parse)
        let thumbnailFolder = root.appendingPathComponent("THMBNL", isDirectory: true)

        let clips = videoFiles.map { url -> CardClip in
            let values = try? url.resourceValues(forKeys: keys)
            let base = url.deletingPathExtension().lastPathComponent
            let metadata = (try? Data(contentsOf: clipFolder.appendingPathComponent("\(base)M01.XML"))).map(SonyClipMetadata.parse)
            let material = profile?.materials[url.lastPathComponent]
            let time = metadata?.creationDate.flatMap(ClipTime.init(recorded:))
                ?? values?.contentModificationDate.map(ClipTime.init(fileDate:))
            let format = material?.videoType.map(SonyVideoType.init(rawValue:))
            let thumbnail = thumbnailFolder.appendingPathComponent("\(base)T01.JPG")

            return CardClip(
                url: url,
                name: url.lastPathComponent,
                size: Int64(values?.fileSize ?? 0),
                time: time,
                umid: material?.umid,
                durationFrames: material?.durationFrames,
                frameRateLabel: material?.frameRate,
                codec: format?.codec,
                width: format?.width,
                height: format?.height,
                lens: metadata?.lens,
                gamma: metadata?.gamma.map(SonyVideoType.gammaName),
                thumbnailURL: FileManager.default.fileExists(atPath: thumbnail.path) ? thumbnail : nil
            )
        }

        let model = profile?.systemKind
        let name = (try? volume.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? volume.lastPathComponent
        return CameraCard(
            volumeURL: volume,
            volumeName: name,
            adapterName: self.name,
            cameraModel: model,
            deviceFolder: model.flatMap { Self.deviceFolders[$0] },
            clips: clips
        )
    }
}

nonisolated struct SonyVideoType {
    let codec: String?
    let width: Int?
    let height: Int?

    /// Parses `HEVC_3840_2160_M10P@L51HT`.
    init(rawValue: String) {
        let parts = rawValue.split(separator: "_")
        codec = parts.first.map(String.init)
        width = parts.count > 1 ? Int(parts[1]) : nil
        height = parts.count > 2 ? Int(parts[2]) : nil
    }

    static func gammaName(_ value: String) -> String {
        switch value.lowercased() {
        case "s-log3-cine": "S-Log3 Cine"
        case "s-log3": "S-Log3"
        case "s-log2": "S-Log2"
        case "rec709": "Rec. 709"
        default: value
        }
    }
}

/// `MEDIAPRO.XML`, the card's clip database.
nonisolated struct SonyMediaProfile {
    struct Material {
        var videoType: String?
        var frameRate: String?
        var durationFrames: Int?
        var umid: String?
    }

    var systemKind: String?
    var materials: [String: Material] = [:]

    static func parse(_ data: Data) -> SonyMediaProfile {
        let collector = XMLAttributeCollector()
        collector.parse(data)
        var profile = SonyMediaProfile()
        for element in collector.elements {
            switch element.name {
            case "System":
                profile.systemKind = element.attributes["systemKind"]
            case "Material":
                // Keep only the file name. The path on the card is never used to locate anything.
                guard let uri = element.attributes["uri"], let name = uri.split(separator: "/").last else { continue }
                profile.materials[String(name)] = Material(
                    videoType: element.attributes["videoType"],
                    frameRate: element.attributes["fps"],
                    durationFrames: element.attributes["dur"].flatMap(Int.init),
                    umid: element.attributes["umid"]
                )
            default:
                break
            }
        }
        return profile
    }
}

/// `<clip>M01.XML`, one per clip.
nonisolated struct SonyClipMetadata {
    var creationDate: String?
    var lens: String?
    var gamma: String?

    static func parse(_ data: Data) -> SonyClipMetadata {
        let collector = XMLAttributeCollector()
        collector.parse(data)
        var metadata = SonyClipMetadata()
        for element in collector.elements {
            switch element.name {
            case "CreationDate":
                metadata.creationDate = element.attributes["value"]
            case "Lens":
                metadata.lens = element.attributes["modelName"]
            case "Item" where element.attributes["name"] == "CaptureGammaEquation":
                metadata.gamma = element.attributes["value"]
            default:
                break
            }
        }
        return metadata
    }
}

nonisolated private final class XMLAttributeCollector: NSObject, XMLParserDelegate {
    private(set) var elements: [(name: String, attributes: [String: String])] = []

    func parse(_ data: Data) {
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = self
        parser.parse()
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) {
        elements.append((elementName, attributes))
    }
}

/// Clips shot close together, so a whole shoot can be selected at once.
nonisolated struct ClipGroup: Identifiable, Hashable, Sendable {
    let clips: [CardClip]

    var id: String { clips.first?.id ?? "" }
    var totalSize: Int64 { clips.reduce(0) { $0 + $1.size } }

    var title: String {
        guard let first = clips.first?.time else { return "Unknown date" }
        guard let last = clips.last?.time, last.time != first.time else { return "\(first.day)  \(first.time)" }
        return "\(first.day)  \(first.time) – \(last.time)"
    }
}

nonisolated enum ClipGrouping {
    static let gap: TimeInterval = 60 * 60

    /// Splits by day and by gaps over an hour. Shoots and the clips within them run oldest to newest.
    static func groups(_ clips: [CardClip]) -> [ClipGroup] {
        let dated = clips.filter { $0.time != nil }.sorted { lhs, rhs in
            if lhs.time!.date != rhs.time!.date { return lhs.time!.date < rhs.time!.date }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        var result: [[CardClip]] = []
        for clip in dated {
            if let previous = result.last?.last?.time,
               previous.day == clip.time!.day,
               clip.time!.date.timeIntervalSince(previous.date) <= gap {
                result[result.count - 1].append(clip)
            } else {
                result.append([clip])
            }
        }
        var groups = result.map(ClipGroup.init(clips:))
        let undated = clips.filter { $0.time == nil }
        if !undated.isEmpty { groups.append(ClipGroup(clips: undated)) }
        return groups
    }
}
