import FlowCore
import SwiftUI

/// Right-hand inspector: the inputs that matter for the selected section.
struct InspectorView: View {
    let section: StudySection
    @Binding var study: StudyCase

    var body: some View {
        Form {
            switch section {
            case .architecture, .model3D:
                StudyInfoSection(study: $study)
                WellInspector(study: $study)
            case .fluid:
                FluidInspector(study: $study)
            case .damage, .liveFlow, .sensitivity:
                DrillingInspector(study: $study)
                RockInspector(study: $study)
            case .invasion3D:
                Invasion3DInspector(options: $study.invasionOptions)
                DrillingInspector(study: $study)
                RockInspector(study: $study)
            case .nodal:
                ReservoirInspector(study: $study)
                ProductionInspector(study: $study)
            }
        }
        .formStyle(.grouped)
    }
}

private struct StudyInfoSection: View {
    @Binding var study: StudyCase

    var body: some View {
        Section("Study") {
            TextField("Title", text: $study.title)
            TextField("Well name", text: $study.well.name)
            if let basedOn = study.basedOn {
                LabeledContent("Based on", value: basedOn)
            }
            TextField("Notes", text: $study.notes, axis: .vertical)
                .lineLimit(3...8)
        }
    }
}

private struct WellInspector: View {
    @Binding var study: StudyCase

    var body: some View {
        Section("Trajectory") {
            ParameterRow(title: "Kick-off point", value: $study.well.trajectory.kickoffDepth, range: 0...15000, quantity: .depth, digits: 0,
                         help: "Measured depth where the well starts to build angle.")
            ParameterRow(title: "Build rate", value: $study.well.trajectory.buildRate, range: 0.5...10, quantity: .buildRate, digits: 1,
                         help: "Rate of inclination increase in the build section.")
            ParameterRow(title: "Hold inclination", value: $study.well.trajectory.holdInclination, range: 0...85, quantity: .angle, digits: 1,
                         help: "Tangent angle from vertical. 0 gives a vertical well.")
            ParameterRow(title: "Azimuth", value: $study.well.trajectory.azimuth, range: 0...360, quantity: .angle, digits: 0,
                         help: "Direction of the tangent section, degrees from north.")
            ParameterRow(title: "Total depth", value: $study.well.totalDepth, range: 500...30000, quantity: .depth, digits: 0)
        }
        Section("Reservoir interval") {
            ParameterRow(title: "Top (TVD)", value: $study.well.reservoirTop, range: 100...25000, quantity: .depth, digits: 0)
            ParameterRow(title: "Bottom (TVD)", value: $study.well.reservoirBottom, range: 100...25000, quantity: .depth, digits: 0)
            ParameterRow(title: "Bit size", value: $study.well.reservoirBitSize, range: 3.5...17.5, quantity: .diameter, digits: 3,
                         help: "Hole size across the pay. Sets the wellbore radius for inflow and for mud invasion.")
        }
        Section("Wellhead") {
            ParameterRow(title: "Flowing pressure", value: $study.well.wellheadPressure, range: 14.7...5000, quantity: .pressure, digits: 0,
                         help: "Back-pressure at the wellhead (separator, choke and flowline).")
            ParameterRow(title: "Flowing temperature", value: $study.well.wellheadTemperature, range: 32...300, quantity: .temperature, digits: 0)
        }
    }
}

private struct FluidInspector: View {
    @Binding var study: StudyCase

    var body: some View {
        Section("Oil and gas") {
            ParameterRow(title: "Oil gravity", value: $study.fluid.apiGravity, range: 8...60, quantity: .dimensionless, digits: 1,
                         help: "Stock-tank oil gravity in °API. Heavy < 22, medium 22–31, light > 31.")
            ParameterRow(title: "Gas gravity", value: $study.fluid.gasGravity, range: 0.55...1.4, quantity: .dimensionless, digits: 3,
                         help: "Separator gas specific gravity relative to air.")
            ParameterRow(title: "Solution GOR", value: $study.fluid.solutionGOR, range: 10...3000, quantity: .gasOilRatio, digits: 0,
                         help: "Gas dissolved in the oil at the bubble point. Sets the bubble-point pressure.")
            ParameterRow(title: "Oil compressibility", value: $study.fluid.oilCompressibility, range: 1e-6...5e-5, quantity: .dimensionless, digits: 7,
                         help: "Undersaturated oil compressibility, 1/psi.")
        }
        Section("Water") {
            ParameterRow(title: "Water gravity", value: $study.fluid.waterGravity, range: 1...1.25, quantity: .dimensionless, digits: 3,
                         help: "Formation water specific gravity; higher for saltier brines.")
        }
        Section("Conditions") {
            ParameterRow(title: "Reservoir temperature", value: $study.reservoir.temperature, range: 60...400, quantity: .temperature, digits: 0)
            ParameterRow(title: "Reservoir pressure", value: $study.reservoir.pressure, range: 200...20000, quantity: .pressure, digits: 0)
        }
    }
}

private struct DrillingInspector: View {
    @Binding var study: StudyCase

    var body: some View {
        Section("Drilling") {
            ParameterRow(title: "Overbalance", value: $study.mud.overbalance, range: 50...4000, quantity: .pressure, digits: 0,
                         help: "Mud pressure minus pore pressure. Drives filtrate into the rock.")
            ParameterRow(title: "Exposure time", value: $study.mud.exposureTime, range: 1...240, quantity: .hours, digits: 1,
                         help: "How long the pay is exposed to mud before completion.")
            ParameterRow(title: "Equilibrium cake", value: $study.mud.equilibriumCakeThickness, range: 0...10, quantity: .millimetres, digits: 2,
                         help: "Cake thickness where erosion by circulation balances deposition. 0 means static filtration.")
        }
        Section("Mud and filter cake") {
            ParameterRow(title: "Mud solids", value: $study.mud.mudSolidsFraction, range: 0.01...0.4, quantity: .fraction, digits: 3,
                         help: "Volume fraction of solids in the mud that build the external cake.")
            ParameterRow(title: "Cake permeability", value: $study.mud.cakePermeability, range: 1e-5...0.1, quantity: .permeability, digits: 5, logarithmic: true,
                         help: "Lower values mean better fluid-loss control.")
            ParameterRow(title: "Cake porosity", value: $study.mud.cakePorosity, range: 0.1...0.7, quantity: .fraction, digits: 2)
            ParameterRow(title: "Bridging thickness", value: $study.mud.bridgingThickness, range: 0.01...3, quantity: .millimetres, digits: 2,
                         help: "Cake thickness at which fine particles stop entering the rock. Ends the spurt period.")
            ParameterRow(title: "Filtrate viscosity", value: $study.mud.filtrateViscosity, range: 0.2...20, quantity: .viscosity, digits: 2)
        }
        Section("Fines (deep-bed filtration)") {
            ParameterRow(title: "Fines concentration", value: $study.mud.finesConcentration, range: 0...0.05, quantity: .fraction, digits: 4,
                         help: "Volume fraction of fine solids carried into the rock during spurt.")
            ParameterRow(title: "Filtration coefficient λ₀", value: $study.mud.filtrationCoefficient, range: 1...500, quantity: .perMetre, digits: 1, logarithmic: true,
                         help: "Capture probability per metre travelled. Large values trap fines close to the wall.")
            ParameterRow(title: "Damage coefficient β", value: $study.mud.damageCoefficient, range: 10...5000, quantity: .dimensionless, digits: 0, logarithmic: true,
                         help: "Permeability sensitivity to retained fines: k = k₀ / (1 + βσ).")
            ParameterRow(title: "Max retention σmax", value: $study.mud.maxRetention, range: 0.001...0.1, quantity: .fraction, digits: 3,
                         help: "Retained volume fraction at which capture stops.")
        }
        Section("Filtrate-rock interaction") {
            ParameterRow(title: "k multiplier in filtrate zone", value: $study.mud.filtrateDamageFactor, range: 0.05...1, quantity: .fraction, digits: 2,
                         help: "Lumps clay swelling, water block and wettability change. 1 means the filtrate does no harm.")
            ParameterRow(title: "Displaceable pore fraction", value: $study.mud.displaceableFraction, range: 0.1...1, quantity: .fraction, digits: 2,
                         help: "1 − Swi − Sor: share of the pore space the filtrate can occupy.")
        }
    }
}

private struct RockInspector: View {
    @Binding var study: StudyCase

    var body: some View {
        Section {
            ParameterRow(title: "Permeability", value: $study.reservoir.permeability, range: 0.01...5000, quantity: .permeability, digits: 2, logarithmic: true)
            ParameterRow(title: "Porosity", value: $study.reservoir.porosity, range: 0.02...0.45, quantity: .fraction, digits: 3)
            LabeledContent("Wellbore radius") {
                Text(Quantity.diameter.format(study.well.reservoirBitSize / 2, digits: 3, in: unitsFromEnvironment))
            }
            .help("Half the bit size in Well Architecture.")
        } header: {
            Text("Formation")
        } footer: {
            Text("Shared with Nodal Analysis.").font(.caption).foregroundStyle(.secondary)
        }
    }

    @Environment(\.unitSystem) private var unitsFromEnvironment
}

private struct ReservoirInspector: View {
    @Binding var study: StudyCase

    var body: some View {
        Section("Reservoir") {
            ParameterRow(title: "Pressure", value: $study.reservoir.pressure, range: 200...20000, quantity: .pressure, digits: 0,
                         help: "Average reservoir pressure in the drainage area.")
            ParameterRow(title: "Temperature", value: $study.reservoir.temperature, range: 60...400, quantity: .temperature, digits: 0)
            ParameterRow(title: "Permeability", value: $study.reservoir.permeability, range: 0.01...5000, quantity: .permeability, digits: 2, logarithmic: true)
            ParameterRow(title: "Net pay", value: $study.reservoir.thickness, range: 2...500, quantity: .depth, digits: 0)
            ParameterRow(title: "Porosity", value: $study.reservoir.porosity, range: 0.02...0.45, quantity: .fraction, digits: 3)
            ParameterRow(title: "Drainage radius", value: $study.reservoir.drainageRadius, range: 200...6000, quantity: .depth, digits: 0)
        }
        Section("Skin") {
            ParameterRow(title: "Completion skin", value: $study.reservoir.skin, range: -5...30, quantity: .dimensionless, digits: 2,
                         help: "Perforation, partial penetration and deviation skin, excluding mud damage.")
            Toggle("Add simulated mud-damage skin", isOn: $study.includeDamageSkin)
                .help("Uses the skin from Formation Damage in the inflow model.")
        }
    }
}

private struct ProductionInspector: View {
    @Binding var study: StudyCase

    var body: some View {
        Section("Production") {
            ParameterRow(title: "Water cut", value: $study.waterCut, range: 0...0.98, quantity: .fraction, digits: 2)
            ParameterRow(title: "Producing GOR", value: $study.producingGOR, range: 10...6000, quantity: .gasOilRatio, digits: 0,
                         help: "Total produced gas per stock-tank barrel. Above Rs means free gas in the tubing.")
            ParameterRow(title: "Wellhead pressure", value: $study.well.wellheadPressure, range: 14.7...5000, quantity: .pressure, digits: 0)
            ParameterRow(title: "Tubing ID", value: $study.well.tubing.innerDiameter, range: 1...7, quantity: .diameter, digits: 3)
        }
    }
}
