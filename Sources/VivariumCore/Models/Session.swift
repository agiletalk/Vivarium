import Foundation

/// Identity of one detected agent session (one transcript file / one process-scan pseudo-session).
public struct SessionKey: Hashable, Sendable, Codable {
    public var provider: AgentProvider
    public var sessionID: String

    public init(provider: AgentProvider, sessionID: String) {
        self.provider = provider
        self.sessionID = sessionID
    }
}

/// Everything Detection knows about a session, used to bind it to a fish.
public struct SessionDescriptor: Sendable, Codable, Equatable {
    public var key: SessionKey
    /// Absolute project path from the transcript's `cwd`. Used only as a label — never stat'd.
    public var projectPath: String?
    /// Normalized identity for the resident-fish binding: standardized `cwd`, or the provider name
    /// when no path is available (process-scan-only providers).
    public var projectKey: String
    /// Short human name, e.g. "Vivarium" (last path component).
    public var projectDisplayName: String
    public var gitBranch: String?
    /// Session title when known (Claude `ai-title` record / Codex `thread_name`).
    public var title: String?
    public var model: String?
    public var isSubagent: Bool
    public var parentSessionID: String?
    public var startedAt: Date

    public init(
        key: SessionKey,
        projectPath: String? = nil,
        projectKey: String,
        projectDisplayName: String,
        gitBranch: String? = nil,
        title: String? = nil,
        model: String? = nil,
        isSubagent: Bool = false,
        parentSessionID: String? = nil,
        startedAt: Date
    ) {
        self.key = key
        self.projectPath = projectPath
        self.projectKey = projectKey
        self.projectDisplayName = projectDisplayName
        self.gitBranch = gitBranch
        self.title = title
        self.model = model
        self.isSubagent = isSubagent
        self.parentSessionID = parentSessionID
        self.startedAt = startedAt
    }

    /// Derives a projectKey/displayName pair from a raw `cwd` value.
    public static func projectIdentity(fromCwd cwd: String?, provider: AgentProvider) -> (key: String, displayName: String) {
        guard let cwd, !cwd.isEmpty else {
            return (provider.rawValue, provider.displayName)
        }
        let standardized = (cwd as NSString).standardizingPath
        let name = (standardized as NSString).lastPathComponent
        return (standardized, name.isEmpty ? provider.displayName : name)
    }
}
