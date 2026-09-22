import CoreServices
import Foundation

public struct FileEvent: Sendable {
    public let url: URL
    public let inode: UInt64?
    public let flags: UInt32
    public let id: UInt64

    public var isCreation: Bool {
        flags & UInt32(kFSEventStreamEventFlagItemCreated) != 0
            && flags & UInt32(kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemIsDir) != 0
    }

    public var isFileRename: Bool {
        flags & UInt32(kFSEventStreamEventFlagItemRenamed) != 0
            && flags & UInt32(kFSEventStreamEventFlagItemIsFile) != 0
    }

    public var isDirectoryRename: Bool {
        flags & UInt32(kFSEventStreamEventFlagItemRenamed) != 0
            && flags & UInt32(kFSEventStreamEventFlagItemIsDir) != 0
    }

    public var requiresRescan: Bool {
        flags & UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
            | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged) != 0
    }
}

private final class EventSink {
    let paths: MonitoredPaths
    let receive: @Sendable ([FileEvent]) -> Void
    init(paths: MonitoredPaths, receive: @escaping @Sendable ([FileEvent]) -> Void) {
        self.paths = paths
        self.receive = receive
    }
}

/// Own this object on one actor. Events arrive on a private serial queue.
public final class FolderEvents {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.ashbench.allomer.file-events", qos: .utility)

    public init(folders: [URL], excluding: [URL] = [], ignoreSystemFiles: Bool = false, ignoreOwnChanges: Bool = false,
                receive: @escaping @Sendable ([FileEvent]) -> Void) throws {
        guard !folders.isEmpty, folders.allSatisfy(\.isFileURL), excluding.allSatisfy(\.isFileURL) else {
            throw ConversionError.message("Choose at least one folder to monitor.")
        }
        let paths = MonitoredPaths(folders: folders, excluding: excluding, ignoreSystemFiles: ignoreSystemFiles)
        // Every event under a skipped folder is filtered out, so watching one would report success and convert nothing.
        guard paths.folders.contains(where: paths.contains) else {
            throw ConversionError.message(
                "Every watched folder is inside a location this app skips. Check the excluded folders and the option to ignore system and cache files.")
        }
        let sink = EventSink(paths: paths, receive: receive)
        var context = FSEventStreamContext(version: 0,
            info: Unmanaged.passUnretained(sink).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<EventSink>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                if let info { Unmanaged<EventSink>.fromOpaque(info).release() }
            }, copyDescription: nil)
        stream = withExtendedLifetime(sink) {
            FSEventStreamCreate(nil, { _, context, count, paths, flags, ids in
                guard let context else { return }
                let sink = Unmanaged<EventSink>.fromOpaque(context).takeUnretainedValue()
                let array = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as NSArray
                var events: [FileEvent] = []
                for index in 0..<min(count, array.count) {
                    guard let data = array[index] as? [String: Any], let path = data["path"] as? String else { continue }
                    // An old name may already be gone. Keep URL identity independent of existence.
                    let file = URL(fileURLWithPath: path, isDirectory: false)
                    let inode = (data["fileID"] as? NSNumber)?.uint64Value
                    let event = FileEvent(url: file, inode: inode, flags: flags[index], id: ids[index])
                    if event.requiresRescan {
                        events.append(event)
                        continue
                    }
                    guard sink.paths.contains(file) else { continue }
                    // The old filename no longer exists, so resolve its parent only.
                    let url = file.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
                        .appendingPathComponent(file.lastPathComponent, isDirectory: false)
                    guard sink.paths.contains(url) else { continue }
                    events.append(FileEvent(url: url, inode: inode, flags: flags[index], id: ids[index]))
                }
                if !events.isEmpty { sink.receive(events) }
            }, &context, paths.folders.map(\.path) as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3,
               FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
                   | kFSEventStreamCreateFlagUseExtendedData | kFSEventStreamCreateFlagWatchRoot
                   | (ignoreOwnChanges ? kFSEventStreamCreateFlagIgnoreSelf : 0)))
        }
        guard let stream else { throw ConversionError.message("Folder monitoring could not be created.") }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            stop()
            throw ConversionError.message("Folder monitoring could not start.")
        }
    }

    public func stop() {
        guard let stream else { return }
        self.stream = nil
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    deinit { stop() }
}
