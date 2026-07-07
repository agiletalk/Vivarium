import Foundation

extension FishID {
    /// Process-scan fish created from `providerActivity` events (no session binding).
    var isProviderScan: Bool { rawValue.hasPrefix("provider|") }
}

/// Shared lookup/log helpers for the event handler and ticker.
enum EngineSupport {
    static func fishIndex(of id: FishID, in state: EcosystemState) -> Int? {
        state.fish.firstIndex { $0.id == id }
    }

    static func bindingIndex(forKey key: SessionKey, in state: EcosystemState) -> Int? {
        state.sessions.firstIndex { $0.key == key }
    }

    /// Index of the fish bound to a live session, if both binding and fish exist.
    static func boundFishIndex(forKey key: SessionKey, in state: EcosystemState) -> Int? {
        guard let bi = bindingIndex(forKey: key, in: state) else { return nil }
        return fishIndex(of: state.sessions[bi].fishID, in: state)
    }

    /// Sets a fish's status, emitting `fishStatusChanged` only on an actual transition.
    static func setStatus(
        _ status: AgentStatus,
        fishAt index: Int,
        in state: inout EcosystemState,
        events: inout [EcosystemEvent]
    ) {
        guard state.fish[index].status != status else { return }
        state.fish[index].status = status
        events.append(.fishStatusChanged(state.fish[index].id, status))
    }

    /// Appends a log line (consuming one entity ID) and enforces the 20-line cap.
    static func log(_ message: String, in state: inout EcosystemState, now: Date) {
        let line = LogLine(id: state.nextEntityID, message: message, at: now)
        state.nextEntityID += 1
        state.eventLog.append(line)
        if state.eventLog.count > 20 {
            state.eventLog.removeFirst(state.eventLog.count - 20)
        }
    }

    /// Buckets fatigue into 0.05 steps so the scene only hears about visible changes.
    /// Floor-based with a tiny epsilon to absorb accumulated floating-point error.
    static func quantizedFatigue(_ value: Double) -> Int {
        Int(((value + 1e-9) / 0.05).rounded(.down))
    }

    /// Truncates evidence text to a shark-label-sized string (≤ `limit` characters).
    static func truncated(_ text: String, to limit: Int = 40) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }

    static func displayName(for provider: AgentProvider, project: String) -> String {
        "\(provider.displayName) · \(project)"
    }
}
