import CoreServices
import Foundation

public struct FileChange: Sendable, Equatable {
    public var path: String

    public init(path: String) {
        self.path = path
    }
}

/// FSEvents wrapper yielding coalesced per-file changes under the given roots.
/// `@unchecked Sendable`: wraps the FSEventStream C API; all mutable state is guarded by `lock`.
public final class FileActivityStream: @unchecked Sendable {
    private let roots: [URL]
    private let latency: TimeInterval
    private let queue = DispatchQueue(label: "vivarium.detect.fsevents")

    private let lock = NSLock()
    private var streamRef: FSEventStreamRef?
    private var continuation: AsyncStream<FileChange>.Continuation?
    private var consumed = false
    private var stopped = false

    public init(roots: [URL], latency: TimeInterval = 0.5) {
        self.roots = roots
        self.latency = latency
    }

    deinit {
        stop()
    }

    /// Starts the FSEventStream on a private dispatch queue and yields every changed path
    /// (unfiltered — consumers filter). Single consumer: calling this twice is a programmer error.
    public func changes() -> AsyncStream<FileChange> {
        lock.lock()
        precondition(!consumed, "FileActivityStream.changes() may only be called once")
        consumed = true
        lock.unlock()

        let (stream, continuation) = AsyncStream<FileChange>.makeStream()

        lock.lock()
        if stopped {
            lock.unlock()
            continuation.finish()
            return stream
        }
        self.continuation = continuation
        lock.unlock()

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<FileActivityStream>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<FileActivityStream>.fromOpaque(info).release()
            },
            copyDescription: nil
        )

        let flags = FSEventStreamCreateFlags(
            UInt32(kFSEventStreamCreateFlagFileEvents) | UInt32(kFSEventStreamCreateFlagNoDefer)
        )
        guard let created = FSEventStreamCreate(
            nil,
            fileActivityStreamCallback,
            &context,
            roots.map(\.path) as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            lock.lock()
            self.continuation = nil
            lock.unlock()
            continuation.finish()
            return stream
        }

        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)

        lock.lock()
        if stopped {
            // stop() raced with startup: tear the fresh stream down immediately.
            lock.unlock()
            FSEventStreamStop(created)
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            continuation.finish()
            return stream
        }
        streamRef = created
        lock.unlock()

        continuation.onTermination = { [weak self] _ in
            self?.stop()
        }
        return stream
    }

    public func stop() {
        lock.lock()
        stopped = true
        let stream = streamRef
        streamRef = nil
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()

        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        continuation?.finish()
    }

    fileprivate func emit(paths: [String]) {
        lock.lock()
        let continuation = self.continuation
        lock.unlock()
        guard let continuation else { return }
        for path in paths {
            continuation.yield(FileChange(path: path))
        }
    }
}

private let fileActivityStreamCallback: FSEventStreamCallback = { _, info, numEvents, eventPaths, _, _ in
    guard let info else { return }
    let stream = Unmanaged<FileActivityStream>.fromOpaque(info).takeUnretainedValue()
    // Without kFSEventStreamCreateFlagUseCFTypes, eventPaths is a char** of UTF-8 paths.
    let cPaths = eventPaths.assumingMemoryBound(to: UnsafeMutablePointer<CChar>?.self)
    var paths: [String] = []
    paths.reserveCapacity(numEvents)
    for index in 0..<numEvents {
        guard let cPath = cPaths[index] else { continue }
        paths.append(String(cString: cPath))
    }
    stream.emit(paths: paths)
}
