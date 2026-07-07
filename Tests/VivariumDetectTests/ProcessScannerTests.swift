import Foundation
import Testing
import VivariumCore
@testable import VivariumDetect

@Suite("ProcessScanner")
struct ProcessScannerTests {
    // MARK: - Classification (real ps lines from this machine)

    @Test(
        "classify matches exact argv[0] basename",
        arguments: [
            ("25989   0.2 S+   claude", AgentProvider.claude),
            ("65276  36.8 R+   claude --enable-auto-mode", .claude),
            ("55329   0.1 S    /Applications/Codex.app/Contents/Resources/codex", .codex),
            ("55192   0.0 S    /Applications/Codex.app/Contents/MacOS/Codex", nil),
            (
                " 1929   0.0 S    /System/Library/Frameworks/AppKit.framework/Versions/C/XPCServices/CursorUIViewService.xpc/Contents/MacOS/CursorUIViewService",
                nil
            ),
            ("  123   1.0 S    node /usr/local/lib/node_modules/@google/gemini-cli/dist/gemini.js", .gemini),
            ("  124   0.0 S    node /some/other/app.js", nil),
            ("  125   2.0 R    cursor-agent --serve", .cursor),
            ("  126   0.5 S    gemini --model pro", .gemini),
            (
                "55401   0.3 S    /Applications/Codex.app/Contents/Resources/codex --type=renderer Codex (Renderer)",
                nil
            ),
            ("55402   0.1 S    /Applications/Codex.app/Contents/Resources/codex Sparkle updater", nil),
            ("55403   0.0 S    /Applications/Codex.app/Contents/Resources/codex crashpad_handler", nil),
        ] as [(String, AgentProvider?)]
    )
    func classifyLine(line: String, expected: AgentProvider?) throws {
        let rows = ProviderClassifier.parsePSOutput(line)
        let row = try #require(rows.first)
        #expect(rows.count == 1)
        #expect(ProviderClassifier.classify(row) == expected)
    }

    // MARK: - Parsing

    @Test("parsePSOutput extracts pid, pcpu, state, and args (rest of line)")
    func parseFields() throws {
        let output = """
        25989   0.2 S+   claude
        65276  36.8 R+   claude --enable-auto-mode
         1929   0.0 S    /System/Library/CursorUIViewService.xpc/Contents/MacOS/CursorUIViewService

        garbage line without numbers
        """
        let rows = ProviderClassifier.parsePSOutput(output)
        #expect(rows.count == 3)

        let first = try #require(rows.first)
        #expect(first.pid == 25989)
        #expect(abs(first.cpuPercent - 0.2) < 1e-9)
        #expect(first.state == "S+")
        #expect(first.args == "claude")

        let second = rows[1]
        #expect(second.pid == 65276)
        #expect(abs(second.cpuPercent - 36.8) < 1e-9)
        #expect(second.state == "R+")
        #expect(second.args == "claude --enable-auto-mode")
        #expect(second.isRunnable)
        #expect(!first.isRunnable)
    }

    // MARK: - Score and level boundaries

    @Test(
        "level boundaries: <1 sleeping, <15 walking, <40 running, else sprinting",
        arguments: [
            (0.9, ActivityLevel.sleeping),
            (1.0, .walking),
            (14.9, .walking),
            (15.0, .running),
            (39.9, .running),
            (40.0, .sprinting),
        ] as [(Double, ActivityLevel)]
    )
    func levelBoundaries(cpu: Double, expected: ActivityLevel) {
        let sample = ProviderSample(provider: .claude, processCount: 1, runnableCount: 0, totalCPUPercent: cpu)
        #expect(abs(sample.score - cpu) < 1e-9)
        #expect(sample.level == expected)
    }

    @Test("score weighs each runnable process as 4 points")
    func scoreFormula() {
        let sample = ProviderSample(provider: .codex, processCount: 3, runnableCount: 2, totalCPUPercent: 10)
        #expect(abs(sample.score - 18.0) < 1e-9)
        #expect(sample.level == .running)
    }

    // MARK: - Aggregation

    @Test("two claude rows sum cpu and counts")
    func aggregationSums() throws {
        let output = """
        25989   0.2 S+   claude
        65276  36.8 R+   claude --enable-auto-mode
        """
        let samples = ProviderClassifier.aggregate(ProviderClassifier.parsePSOutput(output))
        let claude = try #require(samples[.claude])
        #expect(claude.processCount == 2)
        #expect(claude.runnableCount == 1)
        #expect(abs(claude.totalCPUPercent - 37.0) < 1e-9)
    }

    @Test("aggregate returns a zeroed sample for every provider")
    func aggregateCoversAllProviders() throws {
        let samples = ProviderClassifier.aggregate([])
        #expect(Set(samples.keys) == Set(AgentProvider.allCases))
        for provider in AgentProvider.allCases {
            let sample = try #require(samples[provider])
            #expect(sample.processCount == 0)
            #expect(sample.runnableCount == 0)
            #expect(sample.totalCPUPercent == 0)
            #expect(sample.level == .sleeping)
        }
    }

    @Test("zombie rows are excluded from aggregation")
    func zombieExcluded() throws {
        let output = """
          999  50.0 Z    claude
        25989   0.2 S+   claude
        """
        let samples = ProviderClassifier.aggregate(ProviderClassifier.parsePSOutput(output))
        let claude = try #require(samples[.claude])
        #expect(claude.processCount == 1)
        #expect(claude.runnableCount == 0)
        #expect(abs(claude.totalCPUPercent - 0.2) < 1e-9)
    }

    // MARK: - Integration smoke

    @Test("ProcessScanner.sample() runs ps and returns a sample for every provider")
    func scannerSmoke() async throws {
        let scanner = ProcessScanner()
        let samples = try await scanner.sample()
        #expect(Set(samples.keys) == Set(AgentProvider.allCases))
        for sample in samples.values {
            #expect(sample.processCount >= 0)
            #expect(sample.runnableCount <= sample.processCount)
            #expect(sample.totalCPUPercent >= 0)
        }
    }
}
