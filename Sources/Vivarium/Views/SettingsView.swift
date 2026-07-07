import SwiftUI
import VivariumCore

struct SettingsView: View {
    let store: VivariumStore
    @Bindable var settings: SettingsStore

    var body: some View {
        TabView {
            GeneralSettingsTab(settings: settings)
                .tabItem { Label("General", systemImage: "gearshape") }
            ProviderSettingsTab(settings: settings)
                .tabItem { Label("Providers", systemImage: "point.3.filled.connected.trianglepath.dotted") }
            AquariumSettingsTab(store: store, settings: settings)
                .tabItem { Label("Aquarium", systemImage: "water.waves") }
        }
        .frame(width: 460, height: 320)
    }
}

private struct GeneralSettingsTab: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { settings.launchAtLoginEnabled },
                    set: { settings.setLaunchAtLogin($0) }
                ))
                .disabled(!settings.isAppBundle)

                if !settings.isAppBundle {
                    Text("Available once Vivarium is installed as an app bundle.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle("Animate menu bar icon", isOn: $settings.menuBarAnimation)
                Text("Adds a subtle pulse while agents are active.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Low-power mode", isOn: $settings.energyLowPower)
                Text("Reduces animation and rendering work to save battery.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { settings.refreshLaunchAtLogin() }
    }
}

private struct ProviderSettingsTab: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        Form {
            Section("Claude Code") {
                Toggle("Detect Claude sessions", isOn: $settings.providersClaudeEnabled)
                DirectoryStatus(path: "~/.claude", exists: Self.directoryExists("~/.claude"))
            }
            Section("Codex") {
                Toggle("Detect Codex sessions", isOn: $settings.providersCodexEnabled)
                DirectoryStatus(path: "~/.codex", exists: Self.directoryExists("~/.codex"))
            }
        }
        .formStyle(.grouped)
    }

    private static func directoryExists(_ tildePath: String) -> Bool {
        let expanded = (tildePath as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir) && isDir.boolValue
    }
}

private struct DirectoryStatus: View {
    let path: String
    let exists: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: exists ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(exists ? .green : .secondary)
            Text(exists ? "\(path) found" : "\(path) not found")
                .foregroundStyle(.secondary)
        }
        .font(.footnote)
    }
}

private struct AquariumSettingsTab: View {
    let store: VivariumStore
    @Bindable var settings: SettingsStore

    @State private var showResetConfirmation = false

    var body: some View {
        Form {
            Section {
                Toggle("Demo mode", isOn: $settings.demoMode)
                Text("Populate the aquarium with a scripted demo. Applies on next launch.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Reset Aquarium…", role: .destructive) {
                    showResetConfirmation = true
                }
                Text("Clears all fish, memory, and progress.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Reset the aquarium?",
            isPresented: $showResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset Aquarium", role: .destructive) {
                store.resetAquarium()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently clears all fish, accumulated memory, and reef progress.")
        }
    }
}
