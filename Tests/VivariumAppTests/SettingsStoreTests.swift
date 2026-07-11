import Foundation
import Testing
@testable import Vivarium

@MainActor
@Suite("SettingsStore")
struct SettingsStoreTests {
    /// A throwaway, isolated `UserDefaults` suite so tests never touch the real app domain.
    private func makeDefaults() -> (defaults: UserDefaults, name: String) {
        let name = "viv.test.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test("Provider detection defaults on; behavior toggles default off")
    func defaults() {
        let (d, name) = makeDefaults()
        defer { d.removePersistentDomain(forName: name) }

        let settings = SettingsStore(defaults: d)
        #expect(settings.providersClaudeEnabled)
        #expect(settings.providersCodexEnabled)
        #expect(settings.providersCopilotEnabled)
        #expect(settings.providersOpencodeEnabled)
        #expect(settings.demoMode == false)
        #expect(settings.menuBarAnimation == false)
        #expect(settings.energyLowPower == false)
        #expect(settings.notifyWhenWaiting == false)
    }

    @Test("Toggle changes persist and are re-read by a fresh store")
    func persistence() {
        let (d, name) = makeDefaults()
        defer { d.removePersistentDomain(forName: name) }

        let first = SettingsStore(defaults: d)
        first.providersCodexEnabled = false
        first.providersOpencodeEnabled = false
        first.demoMode = true
        first.energyLowPower = true
        first.menuBarAnimation = true
        first.notifyWhenWaiting = true

        let second = SettingsStore(defaults: d)
        #expect(second.providersClaudeEnabled)           // untouched → still default true
        #expect(second.providersCodexEnabled == false)
        #expect(second.providersCopilotEnabled)          // untouched → still default true
        #expect(second.providersOpencodeEnabled == false)
        #expect(second.demoMode)
        #expect(second.energyLowPower)
        #expect(second.menuBarAnimation)
        #expect(second.notifyWhenWaiting)
    }

    @Test("Launch-at-login is inert outside an .app bundle")
    func launchAtLoginGuardedByBundle() {
        let (d, name) = makeDefaults()
        defer { d.removePersistentDomain(forName: name) }

        let settings = SettingsStore(defaults: d)
        // The test host runs from an .xctest bundle, not an .app, so this path must be a safe no-op.
        #expect(settings.isAppBundle == false)
        #expect(settings.launchAtLoginEnabled == false)
        settings.setLaunchAtLogin(true)
        #expect(settings.launchAtLoginEnabled == false)
    }
}
