import SwiftUI

@main
struct VivariumApp: App {
    var body: some Scene {
        MenuBarExtra("Vivarium", systemImage: "fish") {
            Text("Vivarium")
                .padding()
        }
        .menuBarExtraStyle(.window)
    }
}
