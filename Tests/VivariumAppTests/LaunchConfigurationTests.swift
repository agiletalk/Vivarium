import Foundation
import Testing
@testable import Vivarium

@Suite("LaunchConfiguration")
struct LaunchConfigurationTests {
    @Test("Defaults are all off/absent with a bare argument list")
    func defaults() {
        let config = LaunchConfiguration.fromProcess(arguments: ["Vivarium"], environment: [:])
        #expect(config.forceDemo == false)
        #expect(config.qaOpenAquarium == false)
        #expect(config.stateFileOverride == nil)
        #expect(config.snapshotPath == nil)
        #expect(config.verifyPopoverPath == nil)
        #expect(config.verifyAquariumPath == nil)
    }

    @Test("--vivarium-demo and VIVARIUM_DEMO=1 both force demo")
    func demoFlags() {
        #expect(LaunchConfiguration.fromProcess(arguments: ["x", "--vivarium-demo"], environment: [:]).forceDemo)
        #expect(LaunchConfiguration.fromProcess(arguments: ["x"], environment: ["VIVARIUM_DEMO": "1"]).forceDemo)
        #expect(LaunchConfiguration.fromProcess(arguments: ["x"], environment: ["VIVARIUM_DEMO": "0"]).forceDemo == false)
    }

    @Test("Path-valued flags read the following argument")
    func pathFlags() {
        let config = LaunchConfiguration.fromProcess(
            arguments: [
                "x",
                "--qa-open-aquarium",
                "--vivarium-snapshot", "/tmp/shot.png",
                "--vivarium-verify-popover", "/tmp/pop.png",
                "--vivarium-verify-aquarium", "/tmp/aq.png",
                "--vivarium-state-file", "/tmp/state.json",
            ],
            environment: [:]
        )
        #expect(config.qaOpenAquarium)
        #expect(config.snapshotPath == "/tmp/shot.png")
        #expect(config.verifyPopoverPath == "/tmp/pop.png")
        #expect(config.verifyAquariumPath == "/tmp/aq.png")
        #expect(config.stateFileOverride == URL(fileURLWithPath: "/tmp/state.json"))
    }

    @Test("An explicit --vivarium-state-file wins over VIVARIUM_STATE_FILE")
    func stateFilePrecedence() {
        let config = LaunchConfiguration.fromProcess(
            arguments: ["x", "--vivarium-state-file", "/tmp/arg.json"],
            environment: ["VIVARIUM_STATE_FILE": "/tmp/env.json"]
        )
        #expect(config.stateFileOverride == URL(fileURLWithPath: "/tmp/arg.json"))
    }

    @Test("VIVARIUM_STATE_FILE is used when no argument is given")
    func stateFileFromEnv() {
        let config = LaunchConfiguration.fromProcess(
            arguments: ["x"],
            environment: ["VIVARIUM_STATE_FILE": "/tmp/env.json"]
        )
        #expect(config.stateFileOverride == URL(fileURLWithPath: "/tmp/env.json"))
    }

    @Test("A trailing path flag with no value is ignored, not a crash")
    func danglingFlag() {
        let config = LaunchConfiguration.fromProcess(arguments: ["x", "--vivarium-snapshot"], environment: [:])
        #expect(config.snapshotPath == nil)
    }
}
