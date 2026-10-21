import FlowCore
import Foundation
import Observation

enum Workspace: String, CaseIterable, Identifiable {
    case nodal = "Nodal Analysis"
    case damage = "Formation Damage"
    case pvt = "Fluid PVT"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .nodal: "chart.xyaxis.line"
        case .damage: "circle.dashed.inset.filled"
        case .pvt: "drop.halffull"
        }
    }

    var subtitle: String {
        switch self {
        case .nodal: "Inflow vs. tubing outflow, multiphase traverse"
        case .damage: "Mud filtrate and fines invasion near the wellbore"
        case .pvt: "Black-oil correlations"
        }
    }
}

/// Shared document state. Solvers run off the main thread and publish results back here.
@MainActor
@Observable
final class AppState {
    var workspace: Workspace? = .nodal

    var nodalCase = NodalCase()
    var nodalResult: NodalResult?

    var damageCase = MudInvasionCase()
    var damageResult: MudInvasionResult?
    var isRunningDamage = false

    func recomputeNodal() async {
        let input = nodalCase
        let result = await Task.detached(priority: .userInitiated) {
            NodalAnalysis.solve(input)
        }.value
        if input == nodalCase { nodalResult = result }
    }

    func runDamage() async {
        let input = damageCase
        isRunningDamage = true
        let result = await Task.detached(priority: .userInitiated) {
            MudInvasionSimulator.run(input)
        }.value
        if input == damageCase {
            damageResult = result
            isRunningDamage = false
        }
    }

    /// Carries the simulated damage skin into the inflow model.
    func applyDamageSkinToNodal() {
        guard let skin = damageResult?.skin else { return }
        nodalCase.reservoir.skin = (skin * 100).rounded() / 100
        workspace = .nodal
    }
}
