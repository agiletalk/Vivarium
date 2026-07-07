import SwiftUI

@main
struct VivariumApp: App {
    @NSApplicationDelegateAdaptor(VivariumAppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarPopoverView(store: appDelegate.store) {
                appDelegate.openAquarium()
            }
        } label: {
            MenuBarLabel(store: appDelegate.store, settings: appDelegate.settings)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(store: appDelegate.store, settings: appDelegate.settings)
        }
    }
}
