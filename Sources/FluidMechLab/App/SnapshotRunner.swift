import AppKit
import FlowCore
import SwiftUI

/// Renders every screen to PNG and quits, when launched with FMLAB_SNAPSHOT_DIR set.
/// CI uses this to produce screenshots for design review; it does nothing in normal use.
@MainActor
enum SnapshotRunner {
    private static var hasRun = false

    static func runIfRequested(
        select: (StudySection) -> Void,
        applyPreset: (String) -> Void,
        showPresets: (Bool) -> Void,
        units: (UnitSystem) -> Void
    ) async {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["FMLAB_SNAPSHOT_DIR"], !hasRun else { return }
        hasRun = true
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        if let preset = env["FMLAB_SNAPSHOT_PRESET"] { applyPreset(preset) }
        await pause(2)
        guard let window = documentWindow() else {
            log(dir, "no document window found")
            NSApplication.shared.terminate(nil)
            return
        }
        window.setFrame(NSRect(x: 0, y: 0, width: 1440, height: 900), display: true)

        for (appearanceName, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            NSApplication.shared.appearance = NSAppearance(named: appearance)
            for (i, section) in StudySection.allCases.enumerated() {
                select(section)
                await pause(section == .sensitivity ? 5 : 3)
                save(window, to: dir.appendingPathComponent("\(appearanceName)-\(i + 1)-\(section.rawValue).png"))
                if section == .model3D, let image = Well3DSnapshotRegistry.shared.view?.snapshot() {
                    write(image, to: dir.appendingPathComponent("\(appearanceName)-\(i + 1)-\(section.rawValue)-scene.png"))
                }
            }
        }

        NSApplication.shared.appearance = NSAppearance(named: .aqua)
        units(.si)
        select(.nodal)
        await pause(2)
        save(window, to: dir.appendingPathComponent("si-units-nodal.png"))
        units(.field)

        select(.architecture)
        showPresets(true)
        await pause(2)
        if let sheet = window.attachedSheet {
            save(sheet, to: dir.appendingPathComponent("preset-library.png"))
        }
        showPresets(false)
        await pause(1)

        log(dir, "done")
        NSApplication.shared.terminate(nil)
    }

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private static func documentWindow() -> NSWindow? {
        NSApplication.shared.windows.first { $0.isVisible && $0.styleMask.contains(.titled) && !($0 is NSPanel) }
    }

    /// Captures the whole window including title bar and toolbar.
    private static func save(_ window: NSWindow, to url: URL) {
        guard let view = window.contentView?.superview ?? window.contentView else { return }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    private static func write(_ image: NSImage, to url: URL) {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return }
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    private static func log(_ dir: URL, _ message: String) {
        try? message.write(to: dir.appendingPathComponent("snapshot-log.txt"), atomically: true, encoding: .utf8)
    }
}
