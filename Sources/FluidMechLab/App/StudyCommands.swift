import FlowCore
import SwiftUI

/// Actions the focused study window exposes to the menu bar.
struct StudyActions {
    var select: (StudySection) -> Void
    var rerun: () -> Void
    var keepReference: () -> Void
    var clearReference: () -> Void
    var showPresets: () -> Void
    var toggleInspector: () -> Void
    var exportCSV: () -> Void
    var hasReference: Bool
}

private struct StudyActionsKey: FocusedValueKey {
    typealias Value = StudyActions
}

extension FocusedValues {
    var studyActions: StudyActions? {
        get { self[StudyActionsKey.self] }
        set { self[StudyActionsKey.self] = newValue }
    }
}

struct StudyCommands: Commands {
    @FocusedValue(\.studyActions) private var actions

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Divider()
            ForEach(StudySection.allCases) { section in
                Button(section.title) { actions?.select(section) }
                    .keyboardShortcut(section.shortcut, modifiers: .command)
                    .disabled(actions == nil)
            }
            Divider()
            Button("Show or Hide Inspector") { actions?.toggleInspector() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(actions == nil)
        }

        CommandMenu("Simulation") {
            Button("Run Again") { actions?.rerun() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(actions == nil)
            Divider()
            Button("Keep Results as Reference") { actions?.keepReference() }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(actions == nil)
            Button("Clear Reference") { actions?.clearReference() }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(actions?.hasReference != true)
            Divider()
            Button("Preset Library…") { actions?.showPresets() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(actions == nil)
        }

        CommandGroup(after: .importExport) {
            Button("Export Results as CSV…") { actions?.exportCSV() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(actions == nil)
        }
    }
}
