import Foundation

nonisolated enum SubtitleConverterError: LocalizedError, Equatable {
    case unknownEncoding(String)
    case cantConvert(String)

    var errorDescription: String? {
        switch self {
        case let .unknownEncoding(name): "“\(name)” isn't in UTF-8 or UTF-16."
        case let .cantConvert(name): "“\(name)” couldn't be converted."
        }
    }
}

/// Makes a Traditional Chinese copy of a subtitle file, with the same transform as the system's
/// "Convert Text to Traditional Chinese" service. Timecodes and line endings pass through untouched.
nonisolated enum SubtitleConverter {
    /// A subtitle that isn't marked as Traditional already.
    static func canConvert(_ item: FolderItem) -> Bool {
        guard !item.isFolder, (item.name as NSString).pathExtension.lowercased() == "srt" else { return false }
        return languageMark("tc", in: (item.name as NSString).deletingPathExtension) == nil
    }

    /// `name sc.srt` becomes `name tc.srt`, and `name sc1.srt` becomes `name tc1.srt`. Anything else gains ` tc`.
    static func traditionalName(for name: String, attempt: Int) -> String {
        let stem = (name as NSString).deletingPathExtension
        let fileExtension = (name as NSString).pathExtension
        var result = stem + " tc"
        if let mark = languageMark("sc", in: stem) {
            let code = stem[mark] == "SC" ? "TC" : "tc"
            result = stem.replacingCharacters(in: mark, with: code)
        }
        if attempt > 0 { result += " \(attempt + 1)" }
        return fileExtension.isEmpty ? result : "\(result).\(fileExtension)"
    }

    /// Where the code is, as the last word of the name, with an optional number after it.
    private static func languageMark(_ code: String, in stem: String) -> Range<String.Index>? {
        guard let range = stem.range(of: "(^|[ _-])\(code)[0-9]*$", options: [.regularExpression, .caseInsensitive]) else { return nil }
        let word = stem[range]
        let start = word.first?.isLetter == true ? word.startIndex : word.index(after: word.startIndex)
        return start..<stem.index(start, offsetBy: code.count)
    }

    /// Keeps the file's encoding, and its byte order mark if it has one.
    static func convert(_ data: Data, name: String) throws -> Data {
        let marks: [(bytes: [UInt8], encoding: String.Encoding)] = [
            ([0xEF, 0xBB, 0xBF], .utf8), ([0xFF, 0xFE], .utf16LittleEndian), ([0xFE, 0xFF], .utf16BigEndian),
        ]
        let found = marks.first { data.starts(with: $0.bytes) }
        let encoding = found?.encoding ?? .utf8
        let mark = Data(found?.bytes ?? [])
        guard let text = String(data: data.dropFirst(mark.count), encoding: encoding) else {
            throw SubtitleConverterError.unknownEncoding(name)
        }
        guard let converted = text.applyingTransform(StringTransform("Simplified-Traditional"), reverse: false)?.data(using: encoding) else {
            throw SubtitleConverterError.cantConvert(name)
        }
        return mark + converted
    }

    /// Writes beside the source and never replaces anything. A name that's taken gets a number.
    static func createTraditionalVersion(of source: URL) throws -> URL {
        let converted = try convert(Data(contentsOf: source), name: source.lastPathComponent)
        let folder = source.deletingLastPathComponent()
        let part = folder.appendingPathComponent(".\(UUID().uuidString).reeldock-part")
        defer { try? FileManager.default.removeItem(at: part) }
        try converted.write(to: part, options: .withoutOverwriting)
        // Finder's tags come along, as they do with Duplicate.
        _ = copyfile(source.path, part.path, nil, copyfile_flags_t(COPYFILE_XATTR | COPYFILE_SECURITY))
        guard try Data(contentsOf: part) == converted else { throw SubtitleConverterError.cantConvert(source.lastPathComponent) }
        return try ClipCopier.publish(part, in: folder) { traditionalName(for: source.lastPathComponent, attempt: $0) }
    }
}
