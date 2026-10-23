import Charts
import FlowCore
import SwiftUI

/// Black-oil properties of the study fluid at reservoir temperature.
struct PVTView: View {
    let study: StudyCase
    @Environment(\.unitSystem) private var units

    private struct Property: Identifiable {
        let id: String
        let quantity: Quantity
        let value: KeyPath<PVTPoint, Double>
        let color: Color
    }

    private let properties: [Property] = [
        Property(id: "Solution gas-oil ratio, Rs", quantity: .gasOilRatio, value: \.rs, color: .green),
        Property(id: "Oil formation volume factor, Bo", quantity: .formationVolumeFactor, value: \.bo, color: .orange),
        Property(id: "Oil viscosity, μo", quantity: .viscosity, value: \.oilViscosity, color: .brown),
        Property(id: "Oil density, ρo", quantity: .density, value: \.oilDensity, color: .indigo),
        Property(id: "Gas compressibility factor, Z", quantity: .dimensionless, value: \.z, color: .teal),
        Property(id: "Gas viscosity, μg", quantity: .viscosity, value: \.gasViscosity, color: .pink),
    ]

    var body: some View {
        let fluid = study.fluid
        let temperature = study.reservoir.temperature
        let pb = fluid.bubblePoint(temperature: temperature)
        let table = fluid.table(temperature: temperature, maxPressure: max(study.reservoir.pressure, pb) * 1.2)
        let pbDisplay = Quantity.pressure.display(pb, in: units)

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PaneHeader(section: .fluid)
                StatGrid {
                    StatTile(title: "Bubble point", value: Quantity.pressure.format(pb, digits: 0, in: units),
                             detail: "at \(Quantity.temperature.format(temperature, digits: 0, in: units)), Standing", systemImage: "circle.bottomhalf.filled")
                    StatTile(title: "Oil gravity", value: "\(fluid.apiGravity.formatted(digits: 1)) °API",
                             detail: "specific gravity \(fluid.oilGravity.formatted(digits: 3))", systemImage: "drop")
                    StatTile(title: "Dead-oil viscosity", value: Quantity.viscosity.format(fluid.deadOilViscosity(temperature: temperature), digits: 2, in: units),
                             detail: "Beggs-Robinson", systemImage: "drop.degreesign")
                    StatTile(title: "Reservoir state", value: study.reservoir.pressure > pb ? "Undersaturated" : "Saturated",
                             detail: "reservoir pressure \(Quantity.pressure.format(study.reservoir.pressure, digits: 0, in: units))",
                             systemImage: "square.stack.3d.down.forward")
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), spacing: 16)], spacing: 16) {
                    ForEach(properties) { prop in
                        ChartCard(title: prop.id, subtitle: prop.quantity.symbol(units).isEmpty ? nil : prop.quantity.symbol(units)) {
                            Chart {
                                ForEach(table) { p in
                                    LineMark(x: .value("Pressure", Quantity.pressure.display(p.pressure, in: units)),
                                             y: .value("Value", prop.quantity.display(p[keyPath: prop.value], in: units)))
                                        .foregroundStyle(prop.color)
                                }
                                RuleMark(x: .value("Bubble point", pbDisplay))
                                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                                    .foregroundStyle(.secondary)
                            }
                            .chartXAxisLabel(Quantity.pressure.axisLabel("Pressure", in: units))
                            .frame(height: 200)
                        }
                    }
                }
            }
            .padding(20)
        }
    }
}
