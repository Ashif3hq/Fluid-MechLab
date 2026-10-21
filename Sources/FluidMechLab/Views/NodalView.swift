import Charts
import FlowCore
import SwiftUI

struct NodalView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        HStack(spacing: 0) {
            Form {
                Section("Reservoir") {
                    ParameterRow(title: "Pressure", value: $state.nodalCase.reservoir.pressure, range: 1000...10000, unit: "psia", digits: 0)
                    ParameterRow(title: "Temperature", value: $state.nodalCase.reservoir.temperature, range: 100...350, unit: "°F", digits: 0)
                    ParameterRow(title: "Permeability", value: $state.nodalCase.reservoir.permeability, range: 0.1...2000, unit: "md", digits: 1, logarithmic: true)
                    ParameterRow(title: "Net pay", value: $state.nodalCase.reservoir.thickness, range: 5...300, unit: "ft", digits: 0)
                    ParameterRow(title: "Skin", value: $state.nodalCase.reservoir.skin, range: -4...40, unit: "", digits: 2)
                    ParameterRow(title: "Drainage radius", value: $state.nodalCase.reservoir.drainageRadius, range: 200...5000, unit: "ft", digits: 0)
                }
                Section("Fluid") {
                    ParameterRow(title: "Oil gravity", value: $state.nodalCase.fluid.apiGravity, range: 10...55, unit: "°API", digits: 1)
                    ParameterRow(title: "Gas gravity", value: $state.nodalCase.fluid.gasGravity, range: 0.55...1.3, unit: "air = 1", digits: 2)
                    ParameterRow(title: "Solution GOR", value: $state.nodalCase.fluid.solutionGOR, range: 50...2500, unit: "scf/STB", digits: 0)
                    ParameterRow(title: "Producing GOR", value: $state.nodalCase.producingGOR, range: 50...5000, unit: "scf/STB", digits: 0)
                    ParameterRow(title: "Water cut", value: $state.nodalCase.waterCut, range: 0...0.98, unit: "fraction", digits: 2)
                }
                Section("Well") {
                    ParameterRow(title: "Measured depth", value: $state.nodalCase.well.measuredDepth, range: 1000...20000, unit: "ft", digits: 0)
                    ParameterRow(title: "Deviation", value: $state.nodalCase.well.deviation, range: 0...80, unit: "°", digits: 0)
                    ParameterRow(title: "Tubing ID", value: $state.nodalCase.well.tubingID, range: 1.5...6.5, unit: "in", digits: 3)
                    ParameterRow(title: "Wellhead pressure", value: $state.nodalCase.well.wellheadPressure, range: 50...3000, unit: "psia", digits: 0)
                    ParameterRow(title: "Wellhead temp.", value: $state.nodalCase.well.wellheadTemperature, range: 40...250, unit: "°F", digits: 0)
                }
                Section {
                    Button("Reset to example well") { state.nodalCase = NodalCase() }
                }
            }
            .formStyle(.grouped)
            .frame(width: 380)

            Divider()

            ScrollView {
                if let result = state.nodalResult {
                    NodalResults(result: result)
                        .padding(20)
                } else {
                    ProgressView().padding(40)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .task(id: state.nodalCase) {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            await state.recomputeNodal()
        }
    }
}

private struct NodalResults: View {
    let result: NodalResult

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                if let op = result.operatingPoint {
                    StatTile(title: "Operating rate", value: "\(op.rate.formatted(digits: 0)) STB/d", detail: "liquid at stock-tank conditions")
                    StatTile(title: "Flowing BHP", value: "\(op.pressure.formatted(digits: 0)) psia", detail: "at mid-perforations")
                } else {
                    StatTile(title: "Operating point", value: "No natural flow", detail: "tubing needs more pressure than the reservoir delivers; consider artificial lift", tint: .orange)
                }
                StatTile(title: "Productivity index", value: "\(result.productivityIndex.formatted(digits: 2))", detail: "STB/d/psi above bubble point")
                StatTile(title: "AOF", value: "\(result.absoluteOpenFlow.formatted(digits: 0)) STB/d", detail: "absolute open flow")
                StatTile(title: "Bubble point", value: "\(result.bubblePoint.formatted(digits: 0)) psia", detail: "Standing correlation")
            }

            ChartCard(title: "Nodal analysis", subtitle: "Inflow performance (Darcy + Vogel) against tubing outflow (Beggs-Brill)") {
                Chart {
                    ForEach(result.ipr) { p in
                        LineMark(x: .value("Liquid rate", p.rate), y: .value("Pressure", p.pressure), series: .value("Curve", "IPR"))
                            .foregroundStyle(by: .value("Curve", "Inflow (IPR)"))
                    }
                    ForEach(result.vlp) { p in
                        LineMark(x: .value("Liquid rate", p.rate), y: .value("Pressure", p.pressure), series: .value("Curve", "VLP"))
                            .foregroundStyle(by: .value("Curve", "Outflow (VLP)"))
                    }
                    if let op = result.operatingPoint {
                        PointMark(x: .value("Liquid rate", op.rate), y: .value("Pressure", op.pressure))
                            .symbolSize(140)
                            .foregroundStyle(.red)
                            .annotation(position: .topTrailing) {
                                Text("\(op.rate.formatted(digits: 0)) STB/d @ \(op.pressure.formatted(digits: 0)) psia")
                                    .font(.caption.bold())
                                    .padding(4)
                                    .background(.background, in: RoundedRectangle(cornerRadius: 4))
                            }
                    }
                    RuleMark(y: .value("Bubble point", result.bubblePoint))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .foregroundStyle(.secondary)
                }
                .chartXAxisLabel("Liquid rate (STB/d)")
                .chartYAxisLabel("Bottomhole pressure (psia)")
                .frame(height: 320)
            }

            HStack(alignment: .top, spacing: 16) {
                ChartCard(title: "Pressure traverse", subtitle: "Along the tubing at the operating rate, coloured by flow pattern") {
                    Chart(result.traverse) { p in
                        PointMark(x: .value("Pressure", p.pressure), y: .value("Depth", p.depth))
                            .symbolSize(14)
                            .foregroundStyle(by: .value("Pattern", p.pattern.rawValue))
                    }
                    .chartYScale(domain: .automatic(includesZero: true, reversed: true))
                    .chartXAxisLabel("Pressure (psia)")
                    .chartYAxisLabel("Measured depth (ft)")
                    .frame(height: 300)
                }
                ChartCard(title: "Liquid holdup", subtitle: "Fraction of tubing area filled with liquid (slip vs. no-slip)") {
                    Chart(result.traverse) { p in
                        LineMark(x: .value("Holdup", p.holdup), y: .value("Depth", p.depth))
                            .foregroundStyle(.blue)
                    }
                    .chartXScale(domain: 0...1)
                    .chartYScale(domain: .automatic(includesZero: true, reversed: true))
                    .chartXAxisLabel("Liquid holdup")
                    .chartYAxisLabel("Measured depth (ft)")
                    .frame(height: 300)
                }
            }
        }
    }
}
