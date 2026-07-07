import Foundation

/// An AI coding agent product that Vivarium can detect and visualize.
public enum AgentProvider: String, Codable, Sendable, CaseIterable, Hashable {
    case claude
    case codex
    case gemini
    case cursor
    /// Generic/unclassified agents and the demo dolphin.
    case gpt

    public var species: FishSpecies {
        switch self {
        case .claude: .whale
        case .codex: .octopus
        case .gemini: .jellyfish
        case .cursor: .pufferfish
        case .gpt: .dolphin
        }
    }

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .gemini: "Gemini"
        case .cursor: "Cursor"
        case .gpt: "GPT"
        }
    }
}

public enum FishSpecies: String, Codable, Sendable, CaseIterable, Hashable {
    case whale
    case octopus
    case jellyfish
    case pufferfish
    case dolphin
}
