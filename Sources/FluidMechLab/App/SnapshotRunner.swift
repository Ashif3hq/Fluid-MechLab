import AppKit
import Metal
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
                // Select through the sidebar like a click, so a broken sidebar shows up in the log.
                if !selectInSidebar(section, window: window) { select(section) }
                await pause(section == .sensitivity ? 5 : (section == .liveFlow ? 9 : (section == .invasion3D ? 16 : 3)))
                if !window.subtitle.hasPrefix(section.title) {
                    log(dir, "sidebar selection of \(section.title) did not switch the pane (subtitle: \(window.subtitle))")
                }
                save(window, to: dir.appendingPathComponent("\(appearanceName)-\(i + 1)-\(section.rawValue).png"))
                if section == .liveFlow {
                    if let image = LiveFlowSnapshotRegistry.shared.snapshot() {
                        write(NSImage(cgImage: image, size: .zero), to: dir.appendingPathComponent("\(appearanceName)-\(i + 1)-\(section.rawValue)-gpu.png"))
                    }
                    log(dir, "live flow: device=\(MTLCreateSystemDefaultDevice()?.name ?? "none") error=\(LiveFlowSnapshotRegistry.shared.lastError ?? "none")")
                }
                if section == .invasion3D {
                    for (name, image) in Invasion3DSnapshotRegistry.shared.snapshots() {
                        write(NSImage(cgImage: image, size: .zero), to: dir.appendingPathComponent("\(appearanceName)-\(i + 1)-\(section.rawValue)-\(name).png"))
                    }
                    log(dir, "3D invasion: \(Invasion3DSnapshotRegistry.shared.summary)")
                }
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

    /// In snapshot mode, makes sure a document window exists even if the system showed an Open panel at launch.
    static func prepareLaunch() {
        guard let path = ProcessInfo.processInfo.environment["FMLAB_SNAPSHOT_DIR"] else { return }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        log(dir, "launched")
        Task { @MainActor in
            await pause(6)
            guard !hasRun else { return }
            let titles = NSApplication.shared.windows.map { "\($0.className) visible=\($0.isVisible) title=\($0.title)" }
            log(dir, "no study window after 6 s; windows: \(titles.joined(separator: "; ")). Creating a new document.")
            for window in NSApplication.shared.windows where window is NSPanel { window.close() }
            NSDocumentController.shared.newDocument(nil)
        }
    }

    /// Selects a row in the sidebar's outline view, the same path a mouse click takes.
    private static func selectInSidebar(_ section: StudySection, window: NSWindow) -> Bool {
        guard let outline = findOutline(in: window.contentView) else { return false }
        let row: Int
        if let index = StudySection.modelSections.firstIndex(of: section) {
            row = index + 1
        } else if let index = StudySection.simulationSections.firstIndex(of: section) {
            row = StudySection.modelSections.count + 2 + index
        } else {
            return false
        }
        guard row < outline.numberOfRows else { return false }
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        note("sidebar: selected row \(row) of \(outline.numberOfRows), now \(outline.selectedRow); delegate \(outline.delegate.map { String(describing: type(of: $0)) } ?? "none")")
        return true
    }

    private static func findOutline(in view: NSView?) -> NSOutlineView? {
        guard let view else { return nil }
        if let outline = view as? NSOutlineView { return outline }
        for child in view.subviews {
            if let found = findOutline(in: child) { return found }
        }
        return nil
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

    /// Adds a line to the snapshot log when running in snapshot mode.
    static func note(_ message: String) {
        guard let path = ProcessInfo.processInfo.environment["FMLAB_SNAPSHOT_DIR"] else { return }
        log(URL(fileURLWithPath: path, isDirectory: true), message)
    }

    private static func log(_ dir: URL, _ message: String) {
        let url = dir.appendingPathComponent("snapshot-log.txt")
        let previous = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try? (previous + "\(Date()): \(message)\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
