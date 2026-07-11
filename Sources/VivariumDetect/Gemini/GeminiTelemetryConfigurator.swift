import Foundation

/// Writes the telemetry block into `~/.gemini/settings.json` so Gemini CLI emits the local log the
/// monitor reads. Only invoked when the user turns Gemini detection ON — enabling it mutates the
/// user's Gemini config, so it is opt-in, never automatic.
public enum GeminiTelemetryConfigurator {
    /// Ensures local file telemetry (with prompts) is enabled, preserving every other Gemini setting
    /// and reusing an already-configured `outfile` (so Vivarium coexists with other telemetry
    /// consumers rather than clobbering their sink). Returns the resolved outfile path, or nil on
    /// failure.
    ///
    /// `otlpEndpoint: ""` is required: without it Gemini keeps trying the default gRPC collector at
    /// localhost:4317 and never writes the file (google-gemini/gemini-cli#5063).
    @discardableResult
    public static func enableTelemetry() -> String? {
        let url = GeminiTelemetryConfig.settingsURL

        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url), !data.isEmpty {
            guard let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                // The file exists but is unparseable (corrupt or JSONC). Never overwrite it —
                // clobbering would destroy every other Gemini setting the user has.
                return nil
            }
            root = existing
        }

        var telemetry = (root["telemetry"] as? [String: Any]) ?? [:]
        let outfile = (telemetry["outfile"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? GeminiTelemetryConfig.defaultOutfilePath
        telemetry["enabled"] = true
        telemetry["target"] = "local"
        telemetry["otlpEndpoint"] = ""
        telemetry["outfile"] = outfile
        telemetry["logPrompts"] = true
        root["telemetry"] = telemetry

        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let resolvedOutfile = (outfile as NSString).expandingTildeInPath
        try? fileManager.createDirectory(
            at: URL(fileURLWithPath: resolvedOutfile).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        guard let data = try? JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return nil }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            return nil
        }
        return resolvedOutfile
    }
}
