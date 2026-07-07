import Foundation
import VivariumCore

/// Shared shell-command classification used by both the Claude and Codex parsers.
public enum CommandClassifier {
    /// Substring markers that identify a test run (drives `.testing` status and the bug shark).
    private static let testMarkers: [String] = [
        "swift test", "xcodebuild test", "xcodebuild -scheme", "pytest", "npm test", "npm t ",
        "yarn test", "pnpm test", "go test", "cargo test", "jest", "vitest", "rspec",
        "bundle exec rspec", "mvn test", "gradle test", "./gradlew test", "ctest", "tox",
    ]

    private static let reviewMarkers: [String] = [
        "git commit", "git push", "git diff", "git rebase", "git merge", "gh pr",
    ]

    private static let searchPrefixes: [String] = [
        "ls", "cat", "head", "tail", "rg", "grep", "find", "fd", "sed -n", "tree", "which", "stat",
    ]

    public static func isTestCommand(_ command: String) -> Bool {
        let normalized = command.lowercased()
        return testMarkers.contains { normalized.contains($0) }
    }

    public static func status(forCommand command: String) -> AgentStatus {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.lowercased()
        if isTestCommand(normalized) { return .testing }
        if reviewMarkers.contains(where: { normalized.contains($0) }) { return .reviewing }
        if searchPrefixes.contains(where: { normalized.hasPrefix($0 + " ") || normalized == $0 }) {
            return .searching
        }
        return .coding
    }

    /// First shell token, for "Running: swift" style bubbles.
    public static func firstToken(of command: String) -> String {
        command.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces)
            .first ?? command
    }
}

/// Truncates thought-bubble text to a display-safe length, collapsing to the first line.
public func vivariumBubbleText(_ raw: String, limit: Int = 60) -> String {
    let firstLine = raw
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .components(separatedBy: .newlines)
        .first ?? ""
    if firstLine.count <= limit { return firstLine }
    return String(firstLine.prefix(limit - 1)) + "…"
}
