import SwiftUI

/// The sidebar destinations of a study window.
enum StudySection: String, CaseIterable, Identifiable, Hashable {
    case architecture
    case model3D
    case fluid
    case damage
    case liveFlow
    case nodal
    case sensitivity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .architecture: "Well Architecture"
        case .model3D: "3D Model"
        case .fluid: "Fluid & PVT"
        case .damage: "Formation Damage"
        case .liveFlow: "Live Flow"
        case .nodal: "Nodal Analysis"
        case .sensitivity: "Sensitivity Study"
        }
    }

    var systemImage: String {
        switch self {
        case .architecture: "rectangle.split.3x1"
        case .model3D: "cube.transparent"
        case .fluid: "drop.halffull"
        case .damage: "circle.dashed.inset.filled"
        case .liveFlow: "play.circle"
        case .nodal: "chart.xyaxis.line"
        case .sensitivity: "slider.horizontal.3"
        }
    }

    var subtitle: String {
        switch self {
        case .architecture: "Casing, completion and trajectory"
        case .model3D: "Well path, strings and damaged zone in 3D"
        case .fluid: "Black-oil correlations"
        case .damage: "Mud filtrate and fines invasion near the wellbore"
        case .liveFlow: "Real-time GPU simulation of invasion around the borehole"
        case .nodal: "Reservoir inflow against tubing outflow"
        case .sensitivity: "How damage and rate respond to one parameter"
        }
    }

    /// Keyboard shortcut digit in the View menu.
    var shortcut: KeyEquivalent {
        KeyEquivalent(Character("\(StudySection.allCases.firstIndex(of: self)! + 1)"))
    }

    static let modelSections: [StudySection] = [.architecture, .model3D, .fluid]
    static let simulationSections: [StudySection] = [.damage, .liveFlow, .nodal, .sensitivity]
}
