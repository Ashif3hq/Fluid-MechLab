import AppKit
import SwiftUI

@main
struct FluidMechLabApp: App {
    @State private var state = AppState()

    init() {
        // Lets `swift run` from Terminal show a normal app with a Dock icon and menu bar.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("Fluid MechLab") {
            ContentView()
                .environment(state)
                .frame(minWidth: 1100, minHeight: 720)
                .onAppear { NSApplication.shared.activate(ignoringOtherApps: true) }
        }
        .windowToolbarStyle(.unified)
    }
}
