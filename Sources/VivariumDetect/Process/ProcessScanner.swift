import Foundation
import VivariumCore

/// One-shot process-table scanner: runs `/bin/ps` directly (no shell), classifies rows, and
/// aggregates per-provider activity. The polling cadence loop is owned by the coordinator.
public actor ProcessScanner {
    public init() {}

    /// Returns a sample for every `AgentProvider` (zeroed when no processes matched)
    /// so callers can detect transitions to sleeping.
    public func sample() throws -> [AgentProvider: ProviderSample] {
        let output = try runPS()
        let rows = ProviderClassifier.parsePSOutput(output)
        return ProviderClassifier.aggregate(rows)
    }

    private func runPS() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-Axo", "pid=,pcpu=,state=,args="]

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        try process.run()
        // Drain stdout fully BEFORE waitUntilExit: ps output exceeds the pipe buffer on busy
        // machines, and waiting first would deadlock (ps blocked writing, us blocked waiting).
        let data = try stdout.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
