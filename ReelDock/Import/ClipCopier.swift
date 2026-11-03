import CryptoKit
import Darwin
import Foundation

/// Shared between the copy thread and the UI.
nonisolated final class CopyControl: @unchecked Sendable {
    private let lock = NSLock()
    private var paused = false
    private var cancelled = false
    private var bytes: Int64 = 0
    private var verifying = false

    var isPaused: Bool {
        get { lock.withLock { paused } }
        set { lock.withLock { paused = newValue } }
    }

    var isCancelled: Bool { lock.withLock { cancelled } }
    var bytesCopied: Int64 { lock.withLock { bytes } }
    var isVerifying: Bool { lock.withLock { verifying } }

    func cancel() { lock.withLock { cancelled = true } }
    func add(bytes count: Int64) { lock.withLock { bytes += count } }
    func setVerifying(_ value: Bool) { lock.withLock { verifying = value } }

    func beginClip() {
        lock.withLock {
            bytes = 0
            verifying = false
        }
    }
}

nonisolated enum ClipCopier {
    struct Output: Equatable, Sendable {
        let url: URL
        let sha256: String
        let size: Int64
    }

    enum Failure: Error, Equatable {
        case sourceRead(Int32)
        case destinationWrite(Int32)
        case sourceSizeChanged
        case verificationMismatch
        case cancelled
    }

    struct Hooks: Sendable {
        var partCreated: (@Sendable (URL) -> Void)?
        var partFinished: (@Sendable (URL) -> Void)?
        /// Lets tests damage the written data before verification.
        var afterWrite: (@Sendable (URL) -> Void)?

        init(
            partCreated: (@Sendable (URL) -> Void)? = nil,
            partFinished: (@Sendable (URL) -> Void)? = nil,
            afterWrite: (@Sendable (URL) -> Void)? = nil
        ) {
            self.partCreated = partCreated
            self.partFinished = partFinished
            self.afterWrite = afterWrite
        }
    }

    private static let bufferSize = 8 << 20

    /// Copies to a hidden temporary file, verifies what reached the disk, then moves it into place.
    /// The source is opened read-only, and no existing file is ever replaced.
    static func copy(source: URL, toFolder folder: URL, control: CopyControl, hooks: Hooks = Hooks()) throws -> Output {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        } catch {
            throw Failure.sourceRead(ENOENT)
        }
        let expectedSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0

        let part = folder.appendingPathComponent(
            "\(PartFileRegistry.filePrefix)\(source.lastPathComponent)-\(UUID().uuidString.prefix(8))\(PartFileRegistry.fileSuffix)"
        )
        hooks.partCreated?(part)
        var published = false
        defer {
            if !published { try? FileManager.default.removeItem(at: part) }
            hooks.partFinished?(part)
        }

        let sourceHash = try write(source: source, to: part, expectedSize: expectedSize, control: control)
        hooks.afterWrite?(part)

        control.setVerifying(true)
        let writtenHash = try hash(of: part, control: control)
        guard writtenHash == sourceHash else { throw Failure.verificationMismatch }

        var dates: [FileAttributeKey: Any] = [:]
        dates[.creationDate] = attributes[.creationDate]
        dates[.modificationDate] = attributes[.modificationDate]
        try? FileManager.default.setAttributes(dates, ofItemAtPath: part.path)

        let final = try publish(part, as: source.lastPathComponent, in: folder)
        published = true
        return Output(url: final, sha256: writtenHash, size: expectedSize)
    }

    /// Streams the source to disk while hashing what was read.
    private static func write(source: URL, to part: URL, expectedSize: Int64, control: CopyControl) throws -> String {
        let input = open(source.path, O_RDONLY)
        guard input >= 0 else { throw Failure.sourceRead(errno) }
        defer { close(input) }
        _ = fcntl(input, F_NOCACHE, 1)

        let output = open(part.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard output >= 0 else { throw Failure.destinationWrite(errno) }
        defer { close(output) }
        _ = fcntl(output, F_NOCACHE, 1)

        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: bufferSize, alignment: 4096)
        defer { buffer.deallocate() }

        var hasher = SHA256()
        var total: Int64 = 0
        while true {
            try waitIfPaused(control)
            let count = read(input, buffer.baseAddress, bufferSize)
            if count < 0 {
                if errno == EINTR { continue }
                throw Failure.sourceRead(errno)
            }
            if count == 0 { break }

            hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: buffer[0..<count]))
            var offset = 0
            while offset < count {
                let written = Darwin.write(output, buffer.baseAddress! + offset, count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw Failure.destinationWrite(errno)
                }
                offset += written
            }
            total += Int64(count)
            control.add(bytes: Int64(count))
        }
        guard total == expectedSize else { throw Failure.sourceSizeChanged }
        if fcntl(output, F_FULLFSYNC) != 0, fsync(output) != 0 {
            throw Failure.destinationWrite(errno)
        }
        return hexString(hasher.finalize())
    }

    /// Reads back without the cache, so this checks the disk rather than memory.
    private static func hash(of url: URL, control: CopyControl) throws -> String {
        let input = open(url.path, O_RDONLY)
        guard input >= 0 else { throw Failure.destinationWrite(errno) }
        defer { close(input) }
        _ = fcntl(input, F_NOCACHE, 1)

        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: bufferSize, alignment: 4096)
        defer { buffer.deallocate() }

        var hasher = SHA256()
        while true {
            try waitIfPaused(control)
            let count = read(input, buffer.baseAddress, bufferSize)
            if count < 0 {
                if errno == EINTR { continue }
                throw Failure.destinationWrite(errno)
            }
            if count == 0 { break }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: buffer[0..<count]))
        }
        return hexString(hasher.finalize())
    }

    private static func waitIfPaused(_ control: CopyControl) throws {
        while true {
            if control.isCancelled { throw Failure.cancelled }
            guard control.isPaused else { return }
            usleep(100_000)
        }
    }

    /// Takes the first free name. `RENAME_EXCL` makes that atomic, so a file that appears meanwhile can't be replaced.
    private static func publish(_ part: URL, as name: String, in folder: URL) throws -> URL {
        let stem = (name as NSString).deletingPathExtension
        let suffix = (name as NSString).pathExtension
        var attempt = 0
        while true {
            let candidateName: String
            if attempt == 0 {
                candidateName = name
            } else {
                candidateName = suffix.isEmpty ? "\(stem)_\(attempt)" : "\(stem)_\(attempt).\(suffix)"
            }
            let candidate = folder.appendingPathComponent(candidateName)
            if renamex_np(part.path, candidate.path, UInt32(RENAME_EXCL)) == 0 {
                return candidate
            }
            switch errno {
            case EEXIST:
                attempt += 1
            case ENOTSUP, EINVAL:
                // Some external file systems lack RENAME_EXCL.
                if FileManager.default.fileExists(atPath: candidate.path) {
                    attempt += 1
                } else if rename(part.path, candidate.path) == 0 {
                    return candidate
                } else {
                    throw Failure.destinationWrite(errno)
                }
            default:
                throw Failure.destinationWrite(errno)
            }
        }
    }

    private static func hexString(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
