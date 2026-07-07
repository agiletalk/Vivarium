import Foundation
import VivariumCore

/// One parsed row of `ps -Axo pid=,pcpu=,state=,args=` output.
public struct ProcessRow: Sendable, Equatable {
    public var pid: Int32
    public var cpuPercent: Double
    public var state: String
    public var args: String

    public init(pid: Int32, cpuPercent: Double, state: String, args: String) {
        self.pid = pid
        self.cpuPercent = cpuPercent
        self.state = state
        self.args = args
    }

    /// BSD process state "R" means runnable (on CPU or in the run queue).
    public var isRunnable: Bool { state.contains("R") }

    /// Zombies are dead processes awaiting reap; they carry no activity signal.
    public var isZombie: Bool { state.contains("Z") }
}

/// Pure classification rules mapping process-table rows to agent providers.
public enum ProviderClassifier {
    /// Codex.app (the Electron GUI) spawns helpers whose argv mentions the `codex` binary but
    /// which are not agent activity — updaters, crash handlers, renderer helpers, etc.
    private static let codexDenylist: [String] = [
        "Sparkle",
        "crashpad",
        "Codex (Service)",
        "Codex (Renderer)",
        "Codex.app/Contents/MacOS/Codex",
        "SkyComputerUse",
        "node_repl",
        "bare-modifier-monitor",
    ]

    /// nil = not an agent process. Matches on the exact basename of argv[0]
    /// (first whitespace-separated token of `args`, which may be an absolute path), case-sensitive.
    public static func classify(_ row: ProcessRow) -> AgentProvider? {
        let args = row.args
        let firstToken = args
            .drop(while: { $0 == " " || $0 == "\t" })
            .prefix(while: { $0 != " " && $0 != "\t" })
        guard !firstToken.isEmpty else { return nil }
        let basename = firstToken.split(separator: "/").last.map(String.init) ?? String(firstToken)

        switch basename {
        case "claude":
            return .claude
        case "codex":
            if codexDenylist.contains(where: { args.contains($0) }) { return nil }
            return .codex
        case "gemini":
            return .gemini
        case "node":
            if args.contains("@google/gemini-cli") || args.contains("/gemini.js") {
                return .gemini
            }
            return nil
        case "cursor-agent":
            // Exact basename only — never substring-match "cursor":
            // "CursorUIViewService" is a macOS system process.
            return .cursor
        default:
            return nil
        }
    }

    /// Parses `ps -Axo pid=,pcpu=,state=,args=` output: three whitespace-separated columns,
    /// then args as the rest of the line. Unparseable lines are skipped.
    public static func parsePSOutput(_ output: String) -> [ProcessRow] {
        output.split(separator: "\n", omittingEmptySubsequences: true).compactMap(parseLine)
    }

    private static func parseLine(_ line: Substring) -> ProcessRow? {
        var rest = line

        func nextToken() -> Substring? {
            rest = rest.drop(while: { $0 == " " || $0 == "\t" })
            guard !rest.isEmpty else { return nil }
            let token = rest.prefix(while: { $0 != " " && $0 != "\t" })
            rest = rest.dropFirst(token.count)
            return token
        }

        guard
            let pidToken = nextToken(),
            let cpuToken = nextToken(),
            let stateToken = nextToken(),
            let pid = Int32(pidToken),
            let cpu = Double(cpuToken)
        else { return nil }

        let args = rest.drop(while: { $0 == " " || $0 == "\t" })
        guard !args.isEmpty else { return nil }
        return ProcessRow(pid: pid, cpuPercent: cpu, state: String(stateToken), args: String(args))
    }

    /// Classifies and aggregates rows into one sample per provider. Every `AgentProvider` is
    /// present in the result (zeroed when absent) so callers can detect transitions to sleeping.
    /// Zombie rows are skipped entirely.
    public static func aggregate(_ rows: [ProcessRow]) -> [AgentProvider: ProviderSample] {
        var samples: [AgentProvider: ProviderSample] = [:]
        for provider in AgentProvider.allCases {
            samples[provider] = ProviderSample(
                provider: provider, processCount: 0, runnableCount: 0, totalCPUPercent: 0
            )
        }
        for row in rows where !row.isZombie {
            guard let provider = classify(row) else { continue }
            samples[provider]?.processCount += 1
            if row.isRunnable {
                samples[provider]?.runnableCount += 1
            }
            samples[provider]?.totalCPUPercent += row.cpuPercent
        }
        return samples
    }
}

/// Aggregated process-scan activity for one provider at one instant.
public struct ProviderSample: Sendable, Equatable {
    public var provider: AgentProvider
    public var processCount: Int
    public var runnableCount: Int
    public var totalCPUPercent: Double

    public init(provider: AgentProvider, processCount: Int, runnableCount: Int, totalCPUPercent: Double) {
        self.provider = provider
        self.processCount = processCount
        self.runnableCount = runnableCount
        self.totalCPUPercent = totalCPUPercent
    }

    /// Runnable processes are weighted heavily: a runnable agent is busy even when the CPU
    /// percentage hasn't caught up yet (pcpu is a decaying average).
    public var score: Double { totalCPUPercent + 4.0 * Double(runnableCount) }

    public var level: ActivityLevel {
        switch score {
        case ..<1: .sleeping
        case ..<15: .walking
        case ..<40: .running
        default: .sprinting
        }
    }
}
