import Foundation

/// An AI coding agent product that Vivarium can detect and visualize.
public enum AgentProvider: String, Codable, Sendable, CaseIterable, Hashable {
    case claude
    case codex
    case gemini
    case cursor
    case opencode
    case copilot
    /// Legacy/rare-visitor dolphin; retained for state compatibility, not detected live.
    case gpt

    public var species: FishSpecies {
        switch self {
        case .claude: .whale
        case .codex: .octopus
        case .gemini: .jellyfish
        case .cursor: .pufferfish
        case .opencode: .dolphin
        case .copilot: .seaTurtle
        case .gpt: .dolphin
        }
    }

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .gemini: "Gemini"
        case .cursor: "Cursor"
        case .opencode: "OpenCode"
        case .copilot: "Copilot"
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
    case seaTurtle

    /// Title-cased species name for the fish detail panel's "{provider} · {species}" pill.
    public var displayName: String {
        switch self {
        case .whale: "Whale"
        case .octopus: "Octopus"
        case .jellyfish: "Jellyfish"
        case .pufferfish: "Pufferfish"
        case .dolphin: "Dolphin"
        case .seaTurtle: "Sea Turtle"
        }
    }
}
