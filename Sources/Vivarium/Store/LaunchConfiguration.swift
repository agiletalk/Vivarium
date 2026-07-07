import Foundation

/// Launch flags/environment for QA and verify runs, so tests never touch real state.
struct LaunchConfiguration: Sendable {
    var forceDemo: Bool
    var qaOpenAquarium: Bool
    var stateFileOverride: URL?

    static func fromProcess(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> LaunchConfiguration {
        var forceDemo = arguments.contains("--vivarium-demo")
        var stateFile: URL?

        if let index = arguments.firstIndex(of: "--vivarium-state-file"),
           arguments.indices.contains(index + 1) {
            stateFile = URL(fileURLWithPath: arguments[index + 1])
        }
        if stateFile == nil, let path = environment["VIVARIUM_STATE_FILE"], !path.isEmpty {
            stateFile = URL(fileURLWithPath: path)
        }
        if environment["VIVARIUM_DEMO"] == "1" {
            forceDemo = true
        }

        return LaunchConfiguration(
            forceDemo: forceDemo,
            qaOpenAquarium: arguments.contains("--qa-open-aquarium"),
            stateFileOverride: stateFile
        )
    }
}
