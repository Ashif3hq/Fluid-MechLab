import Charts
import FlowCore
import SwiftUI

/// Black-oil properties for the fluid used in Nodal Analysis, at reservoir temperature.
struct PVTView: View {
    @Environment(AppState.self) private var state

    private struct Property: Identifiable {
        let id: String
        let unit: String
        let value: KeyPath<PVTPoint, Double>
        let color: Color
    }

    private let properties: [Property] = [
        Property(id: "Solution GOR, Rs", unit: "scf/STB", value: \.rs, color: .green),
        Property(id: "Oil FVF, Bo", unit: "rb/STB", value: \.bo, color: .orange),
        Property(id: "Oil viscosity, μo", unit: "cp", value: \.oilViscosity, color: .brown),
        Property(id: "Oil density, ρo", unit: "lbm/ft³", value: \.oilDensity, color: .indigo),
        Property(id: "Gas Z-factor", unit: "", value: \.z, color: .teal),
        Property(id: "Gas viscosity, μg", unit: "cp", value: \.gasViscosity, color: .pink),
    ]

    var body: some View {
        let fluid = state.nodalCase.fluid
        let temperature = state.nodalCase.reservoir.temperature
        let pb = fluid.bubblePoint(temperature: temperature)
        let table = fluid.table(temperature: temperature, maxPressure: max(state.nodalCase.reservoir.pressure, pb) * 1.25)

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    StatTile(title: "Bubble point", value: "\(pb.formatted(digits: 0)) psia", detail: "at \(temperature.formatted(digits: 0)) °F")
                    StatTile(title: "Oil gravity", value: "\(fluid.apiGravity.formatted(digits: 1)) °API", detail: "SG \(fluid.oilGravity.formatted(digits: 3))")
                    StatTile(title: "Dead-oil viscosity", value: "\(fluid.deadOilViscosity(temperature: temperature).formatted(digits: 2)) cp", detail: "Beggs-Robinson")
                }
                Text("Edit the fluid in Nodal Analysis; these curves follow it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], spacing: 16) {
                    ForEach(properties) { prop in
                        ChartCard(title: prop.id, subtitle: prop.unit.isEmpty ? nil : prop.unit) {
                            Chart {
                                ForEach(table) { p in
                                    LineMark(x: .value("Pressure", p.pressure), y: .value(prop.id, p[keyPath: prop.value]))
                                        .foregroundStyle(prop.color)
                                }
                                RuleMark(x: .value("Bubble point", pb))
                                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                                    .foregroundStyle(.secondary)
                            }
                            .chartXAxisLabel("Pressure (psia)")
                            .frame(height: 200)
                        }
                    }
                }
            }
            .padding(20)
        }
    }
}
