import AppKit
import FlowCore
import SwiftUI

@main
struct FluidMechLabApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        DocumentGroup(newDocument: StudyDocument()) { file in
            StudyWindow(document: file.$document)
        }
        .defaultSize(width: 1440, height: 900)
        .commands { StudyCommands() }

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Lets `swift run` from Terminal behave like a normal app with a Dock icon and menu bar.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
