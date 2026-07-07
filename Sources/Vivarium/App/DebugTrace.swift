import Foundation

/// Lightweight file tracer for diagnosing launch/menu-bar issues, enabled only when
/// `VIVARIUM_TRACE=<path>` is set. Bypasses the unified log (which is awkward to read in
/// sandbimited/headless contexts). No-op otherwise.
enum DebugTrace {
    private static let path: String? = ProcessInfo.processInfo.environment["VIVARIUM_TRACE"]
    private static let queue = DispatchQueue(label: "com.agiletalk.Vivarium.trace")

    static func log(_ message: @autoclosure () -> String) {
        guard let path else { return }
        let line = "\(Date().timeIntervalSince1970) \(message())\n"
        queue.async {
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? line.data(using: .utf8)?.write(to: URL(fileURLWithPath: path))
            }
        }
    }
}
