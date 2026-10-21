import Charts
import FlowCore
import SwiftUI

struct FormationDamageView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        HStack(spacing: 0) {
            Form {
                Section("Rock") {
                    ParameterRow(title: "Permeability", value: $state.damageCase.permeability, range: 0.1...5000, unit: "md", digits: 1, logarithmic: true)
                    ParameterRow(title: "Porosity", value: $state.damageCase.porosity, range: 0.03...0.40, unit: "fraction", digits: 3)
                    ParameterRow(title: "Displaceable pore fraction", value: $state.damageCase.displaceableFraction, range: 0.1...1, unit: "1−Swi−Sor", digits: 2)
                    ParameterRow(title: "Wellbore radius", value: $state.damageCase.wellboreRadius, range: 2...12, unit: "in", digits: 2)
                }
                Section("Mud and drilling") {
                    ParameterRow(title: "Overbalance", value: $state.damageCase.overbalance, range: 50...3000, unit: "psi", digits: 0)
                    ParameterRow(title: "Exposure time", value: $state.damageCase.exposureTime, range: 1...240, unit: "hours", digits: 1)
                    ParameterRow(title: "Filtrate viscosity", value: $state.damageCase.filtrateViscosity, range: 0.2...20, unit: "cp", digits: 2)
                    ParameterRow(title: "Mud solids", value: $state.damageCase.mudSolidsFraction, range: 0.01...0.4, unit: "vol. frac.", digits: 3)
                    ParameterRow(title: "Cake permeability", value: $state.damageCase.cakePermeability, range: 1e-5...0.1, unit: "md", digits: 5, logarithmic: true)
                    ParameterRow(title: "Cake porosity", value: $state.damageCase.cakePorosity, range: 0.1...0.7, unit: "fraction", digits: 2)
                    ParameterRow(title: "Equilibrium cake", value: $state.damageCase.equilibriumCakeThickness, range: 0...10, unit: "mm (0 = static)", digits: 2)
                    ParameterRow(title: "Bridging thickness", value: $state.damageCase.bridgingThickness, range: 0.01...3, unit: "mm", digits: 2)
                }
                Section("Fines (deep-bed filtration)") {
                    ParameterRow(title: "Fines concentration", value: $state.damageCase.finesConcentration, range: 0...0.05, unit: "vol. frac.", digits: 4)
                    ParameterRow(title: "Filtration coeff. λ₀", value: $state.damageCase.filtrationCoefficient, range: 1...500, unit: "1/m", digits: 1, logarithmic: true)
                    ParameterRow(title: "Damage coeff. β", value: $state.damageCase.damageCoefficient, range: 10...5000, unit: "", digits: 0, logarithmic: true)
                    ParameterRow(title: "Max retention σmax", value: $state.damageCase.maxRetention, range: 0.001...0.1, unit: "vol. frac.", digits: 3)
                }
                Section("Filtrate-rock interaction") {
                    ParameterRow(title: "k multiplier in invaded zone", value: $state.damageCase.filtrateDamageFactor, range: 0.05...1, unit: "k/k₀", digits: 2)
                }
                Section {
                    Button("Reset to defaults") { state.damageCase = MudInvasionCase() }
                }
            }
            .formStyle(.grouped)
            .frame(width: 400)

            Divider()

            ScrollView {
                if let result = state.damageResult {
                    DamageResults(result: result, isRunning: state.isRunningDamage) {
                        state.applyDamageSkinToNodal()
                    }
                    .padding(20)
                } else {
                    ProgressView("Simulating invasion…").padding(40)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .task(id: state.damageCase) {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await state.runDamage()
        }
    }
}

private struct DamageResults: View {
    let result: MudInvasionResult
    let isRunning: Bool
    let applySkin: () -> Void

    /// Show the profile out to a little beyond the deepest damage.
    private var profileExtent: Double {
        max(result.filtrateInvasionDepth, result.solidsInvasionDepth) * 1.3 + 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                StatTile(title: "Damage skin", value: result.skin.formatted(digits: 2), detail: "after cake lift-off", tint: result.skin > 2 ? .red : .accentColor)
                StatTile(title: "Productivity ratio", value: "\((result.productivityRatio * 100).formatted(digits: 1)) %", detail: "J damaged / J clean")
                StatTile(title: "Filtrate invasion", value: "\(result.filtrateInvasionDepth.formatted(digits: 1)) in", detail: "beyond borehole wall")
                StatTile(title: "Solids invasion", value: "\(result.solidsInvasionDepth.formatted(digits: 2)) in", detail: "internal filter cake")
                StatTile(title: "Mud cake", value: "\(result.finalCakeThickness.formatted(digits: 2)) mm", detail: "spurt \(result.spurtLoss.formatted(digits: 3)) cm³/cm²")
            }

            HStack {
                Button("Use this skin in Nodal Analysis", action: applySkin)
                    .buttonStyle(.borderedProminent)
                if isRunning { ProgressView().controlSize(.small) }
                Spacer()
            }

            HStack(alignment: .top, spacing: 16) {
                ChartCard(title: "Permeability impairment", subtitle: "k/k₀ with distance from the borehole wall") {
                    Chart(result.profile.filter { $0.depthIntoFormation <= profileExtent }) { p in
                        AreaMark(x: .value("Depth into formation", p.depthIntoFormation), yStart: .value("k/k₀", p.permeabilityRatio), yEnd: .value("Clean", 1.0))
                            .foregroundStyle(.red.opacity(0.18))
                        LineMark(x: .value("Depth into formation", p.depthIntoFormation), y: .value("k/k₀", p.permeabilityRatio))
                            .foregroundStyle(.red)
                    }
                    .chartYScale(domain: 0...1.05)
                    .chartXAxisLabel("Depth into formation (in)")
                    .chartYAxisLabel("k / k₀")
                    .frame(height: 260)
                }
                ChartCard(title: "Retained fines", subtitle: "Deposited particle volume fraction σ (internal cake)") {
                    Chart(result.profile.filter { $0.depthIntoFormation <= max(result.solidsInvasionDepth * 2, 0.5) }) { p in
                        AreaMark(x: .value("Depth into formation", p.depthIntoFormation), y: .value("σ", p.retained))
                            .foregroundStyle(.brown.opacity(0.5))
                    }
                    .chartXAxisLabel("Depth into formation (in)")
                    .chartYAxisLabel("σ (vol. fraction)")
                    .frame(height: 260)
                }
            }

            HStack(alignment: .top, spacing: 16) {
                ChartCard(title: "Fluid loss", subtitle: "Cumulative filtrate per unit area of borehole wall") {
                    Chart(result.history) { h in
                        LineMark(x: .value("Time", h.time), y: .value("Filtrate", h.cumulativeFiltrate))
                            .foregroundStyle(.blue)
                    }
                    .chartXAxisLabel("Time (hours)")
                    .chartYAxisLabel("Filtrate (cm³/cm²)")
                    .frame(height: 220)
                }
                ChartCard(title: "Invasion front and mud cake", subtitle: "Filtrate front depth (in) and external cake thickness (mm)") {
                    Chart {
                        ForEach(result.history) { h in
                            LineMark(x: .value("Time", h.time), y: .value("Value", h.filtrateFrontDepth), series: .value("Series", "front"))
                                .foregroundStyle(by: .value("Series", "Filtrate front (in)"))
                        }
                        ForEach(result.history) { h in
                            LineMark(x: .value("Time", h.time), y: .value("Value", h.cakeThickness), series: .value("Series", "cake"))
                                .foregroundStyle(by: .value("Series", "Cake thickness (mm)"))
                        }
                    }
                    .chartXAxisLabel("Time (hours)")
                    .frame(height: 220)
                }
            }

            Text("Model: Darcy flow in series through mud cake and the radial invaded zone; cake growth with erosion limit; Iwasaki deep-bed filtration of fines with k = k₀·F/(1+βσ); skin from the generalised Hawkins integral. Calibrate λ₀, β and F against coreflood return-permeability tests.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
