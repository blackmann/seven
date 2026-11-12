import CoreServices
import Foundation

/// Watches the same folders searched by the catalog, including their subfolders.
@MainActor
final class ApplicationCatalogMonitor {
    private final class Handler {
        let roots: [String]
        let onChange: @MainActor () -> Void
        init(roots: [String], onChange: @escaping @MainActor () -> Void) {
            self.roots = roots
            self.onChange = onChange
        }
    }

    private let searchRoots: [URL]
    private let onChange: @MainActor () -> Void
    private var stream: FSEventStreamRef?
    private var watchedPaths: [String] = []
    private var handler: Handler?

    init(roots: [URL], onChange: @escaping @MainActor () -> Void) {
        self.searchRoots = roots
        self.onChange = onChange
        refreshWatchedDirectories()
    }

    func refreshWatchedDirectories() {
        let roots = searchRoots.map { $0.resolvingSymlinksInPath().standardizedFileURL.path }
        let paths = Array(Set(roots.map { path -> String in
            // A user may create ~/Applications after seven has already started.
            var directory = URL(fileURLWithPath: path, isDirectory: true)
            var isDirectory: ObjCBool = false
            while !FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) || !isDirectory.boolValue {
                let parent = directory.deletingLastPathComponent()
                if parent.path == directory.path { break }
                directory = parent
            }
            return directory.path
        })).sorted()
        guard paths != watchedPaths || roots != handler?.roots || stream == nil else { return }
        stop()
        watchedPaths = paths
        guard !paths.isEmpty else { return }
        let handler = Handler(roots: roots, onChange: onChange)
        self.handler = handler
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(handler).toOpaque(), retain: { info in
            guard let info else { return nil }
            _ = Unmanaged<Handler>.fromOpaque(info).retain()
            return info
        }, release: { info in
            if let info { Unmanaged<Handler>.fromOpaque(info).release() }
        }, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(nil, { _, info, count, eventPaths, eventFlags, _ in
            guard let info else { return }
            let handler = Unmanaged<Handler>.fromOpaque(info).takeUnretainedValue()
            let paths = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            MainActor.assumeIsolated {
                for index in 0..<count {
                    let path = String(cString: paths[index])
                    let needsFullScan = eventFlags[index] & FSEventStreamEventFlags(
                        kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged |
                        kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped) != 0
                    // Ancestors are watched only to detect missing roots being created.
                    if needsFullScan || handler.roots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
                        handler.onChange()
                        break
                    }
                }
            }
        }, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2, flags) else { return }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        if !FSEventStreamStart(stream) { stop() }
    }

    private func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        handler = nil
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
