import Foundation

/// Launch flags/environment for QA and verify runs, so tests never touch real state.
struct LaunchConfiguration: Sendable {
    var forceDemo: Bool
    var qaOpenAquarium: Bool
    var stateFileOverride: URL?
    var snapshotPath: String?
    /// QA: programmatically open the menu bar popover and render it to this PNG, then exit.
    var verifyPopoverPath: String?
    /// QA: open the aquarium, select a fish, and render the window content (HUD + detail panel) to
    /// this PNG, then exit.
    var verifyAquariumPath: String?

    static func fromProcess(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> LaunchConfiguration {
        var forceDemo = arguments.contains("--vivarium-demo")
        var stateFile: URL?
        var snapshotPath: String?
        var verifyPopoverPath: String?
        var verifyAquariumPath: String?

        if let index = arguments.firstIndex(of: "--vivarium-state-file"),
           arguments.indices.contains(index + 1) {
            stateFile = URL(fileURLWithPath: arguments[index + 1])
        }
        if stateFile == nil, let path = environment["VIVARIUM_STATE_FILE"], !path.isEmpty {
            stateFile = URL(fileURLWithPath: path)
        }
        if let index = arguments.firstIndex(of: "--vivarium-snapshot"),
           arguments.indices.contains(index + 1) {
            snapshotPath = arguments[index + 1]
        }
        if let index = arguments.firstIndex(of: "--vivarium-verify-popover"),
           arguments.indices.contains(index + 1) {
            verifyPopoverPath = arguments[index + 1]
        }
        if let index = arguments.firstIndex(of: "--vivarium-verify-aquarium"),
           arguments.indices.contains(index + 1) {
            verifyAquariumPath = arguments[index + 1]
        }
        if environment["VIVARIUM_DEMO"] == "1" {
            forceDemo = true
        }

        return LaunchConfiguration(
            forceDemo: forceDemo,
            qaOpenAquarium: arguments.contains("--qa-open-aquarium"),
            stateFileOverride: stateFile,
            snapshotPath: snapshotPath,
            verifyPopoverPath: verifyPopoverPath,
            verifyAquariumPath: verifyAquariumPath
        )
    }
}
