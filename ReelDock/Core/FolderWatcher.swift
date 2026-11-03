import CoreServices
import Foundation

/// Reports which directories changed under a folder. Delivered on the main queue.
final class FolderWatcher {
    struct Change {
        let directories: Set<String>
        /// Events were coalesced, so any directory may have changed.
        let needsFullRescan: Bool
        let rootChanged: Bool
    }

    private nonisolated(unsafe) var stream: FSEventStreamRef?
    private let onChange: (Change) -> Void

    init?(path: String, onChange: @escaping (Change) -> Void) {
        self.onChange = onChange

        var context = FSEventStreamContext(
            version: 0,
            info: nil,
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        context.info = Unmanaged.passUnretained(self).toOpaque()

        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            var directories = Set<String>()
            var rescan = false
            var rootChanged = false
            for index in 0..<count {
                let flag = Int(flags[index])
                if flag & kFSEventStreamEventFlagMustScanSubDirs != 0 { rescan = true }
                if flag & kFSEventStreamEventFlagRootChanged != 0 { rootChanged = true }
                if index < list.count {
                    let path = list[index]
                    directories.insert(path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path)
                }
            }
            let change = Change(directories: directories, needsFullRescan: rescan, rootChanged: rootChanged)
            MainActor.assumeIsolated {
                Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue().onChange(change)
            }
        }

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
        ) else { return nil }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
