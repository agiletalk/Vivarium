import SwiftUI

@main
struct VivariumApp: App {
    @NSApplicationDelegateAdaptor(VivariumAppDelegate.self) private var appDelegate

    var body: some Scene {
        // The menu bar presence is a classic NSStatusItem owned by the AppDelegate (see
        // MenuBarController); this scene only provides the Settings window.
        Settings {
            SettingsView(store: appDelegate.store, settings: appDelegate.settings)
        }
    }
}
