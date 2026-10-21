import FlowCore
import Foundation
import Observation

/// A result kept on screen as a dashed reference while the user changes inputs.
struct ReferenceRun<Result> {
    let label: String
    let result: Result
}

/// Per-window solver state. Runs the engine off the main thread whenever the study changes.
@MainActor
@Observable
final class SimulationModel {
    private(set) var damage: MudInvasionResult?
    private(set) var nodal: NodalResult?
    private(set) var isRunning = false
    private(set) var lastRunDuration: TimeInterval = 0

    var damageReference: ReferenceRun<MudInvasionResult>?
    var nodalReference: ReferenceRun<NodalResult>?

    private var lastDamageInput: MudInvasionCase?
    private var lastNodalInput: NodalCase?

    /// Damage first (its skin feeds the inflow model), then nodal. Skips stages whose inputs are unchanged.
    func update(for study: StudyCase, force: Bool = false) async {
        isRunning = true
        let start = Date()
        defer {
            isRunning = false
            lastRunDuration = Date().timeIntervalSince(start)
        }

        let damageInput = study.damageCase
        if force || damage == nil || damageInput != lastDamageInput {
            let result = await Task.detached(priority: .userInitiated) {
                MudInvasionSimulator.run(damageInput)
            }.value
            guard !Task.isCancelled else { return }
            damage = result
            lastDamageInput = damageInput
        }

        let nodalInput = study.nodalCase(damageSkin: damage?.skin)
        if force || nodal == nil || nodalInput != lastNodalInput {
            let result = await Task.detached(priority: .userInitiated) {
                NodalAnalysis.solve(nodalInput)
            }.value
            guard !Task.isCancelled else { return }
            nodal = result
            lastNodalInput = nodalInput
        }
    }

    /// Keeps the current results as dashed reference curves.
    func keepAsReference(label: String) {
        if let damage { damageReference = ReferenceRun(label: label, result: damage) }
        if let nodal { nodalReference = ReferenceRun(label: label, result: nodal) }
    }

    func clearReference() {
        damageReference = nil
        nodalReference = nil
    }

    var hasReference: Bool { damageReference != nil || nodalReference != nil }
}
