import Foundation
import Observation
import ServiceManagement
import VivariumDetect

/// User preferences, backed by `UserDefaults`. UI-only surface for the app shell; the store owns
/// runtime truth. Launch-at-login is delegated to `SMAppService` and only functions when we run
/// as a real `.app` bundle.
@MainActor
@Observable
final class SettingsStore {
    var providersClaudeEnabled: Bool {
        didSet { defaults.set(providersClaudeEnabled, forKey: Keys.providersClaudeEnabled) }
    }
    var providersCodexEnabled: Bool {
        didSet { defaults.set(providersCodexEnabled, forKey: Keys.providersCodexEnabled) }
    }
    var providersCopilotEnabled: Bool {
        didSet { defaults.set(providersCopilotEnabled, forKey: Keys.providersCopilotEnabled) }
    }
    var providersOpencodeEnabled: Bool {
        didSet { defaults.set(providersOpencodeEnabled, forKey: Keys.providersOpencodeEnabled) }
    }
    /// Gemini is opt-in (default off): enabling it writes a telemetry block into `~/.gemini/settings.json`
    /// so the CLI emits the local log the monitor reads. Applies on the next Vivarium launch.
    var providersGeminiEnabled: Bool {
        didSet {
            defaults.set(providersGeminiEnabled, forKey: Keys.providersGeminiEnabled)
            if providersGeminiEnabled { GeminiTelemetryConfigurator.enableTelemetry() }
        }
    }
    var demoMode: Bool {
        didSet { defaults.set(demoMode, forKey: Keys.demoMode) }
    }
    var menuBarAnimation: Bool {
        didSet { defaults.set(menuBarAnimation, forKey: Keys.menuBarAnimation) }
    }
    var energyLowPower: Bool {
        didSet { defaults.set(energyLowPower, forKey: Keys.energyLowPower) }
    }

    /// Mirror of `SMAppService.mainApp.status`, kept observable so the toggle reflects changes.
    private(set) var launchAtLoginEnabled = false

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.providersClaudeEnabled = defaults.object(forKey: Keys.providersClaudeEnabled) as? Bool ?? true
        self.providersCodexEnabled = defaults.object(forKey: Keys.providersCodexEnabled) as? Bool ?? true
        self.providersCopilotEnabled = defaults.object(forKey: Keys.providersCopilotEnabled) as? Bool ?? true
        self.providersOpencodeEnabled = defaults.object(forKey: Keys.providersOpencodeEnabled) as? Bool ?? true
        self.providersGeminiEnabled = defaults.object(forKey: Keys.providersGeminiEnabled) as? Bool ?? false
        self.demoMode = defaults.bool(forKey: Keys.demoMode)
        self.menuBarAnimation = defaults.bool(forKey: Keys.menuBarAnimation)
        self.energyLowPower = defaults.bool(forKey: Keys.energyLowPower)
        refreshLaunchAtLogin()
    }

    /// Launch-at-login only works for a registered `.app`; a bare SwiftPM executable can't register.
    var isAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    func refreshLaunchAtLogin() {
        guard isAppBundle else {
            launchAtLoginEnabled = false
            return
        }
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard isAppBundle else { return }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Vivarium: launch-at-login change failed: \(error.localizedDescription)")
        }
        refreshLaunchAtLogin()
    }

    private enum Keys {
        static let providersClaudeEnabled = "providersClaudeEnabled"
        static let providersCodexEnabled = "providersCodexEnabled"
        static let providersCopilotEnabled = "providersCopilotEnabled"
        static let providersOpencodeEnabled = "providersOpencodeEnabled"
        static let providersGeminiEnabled = "providersGeminiEnabled"
        static let demoMode = "demoMode"
        static let menuBarAnimation = "menuBarAnimation"
        static let energyLowPower = "energyLowPower"
    }
}
