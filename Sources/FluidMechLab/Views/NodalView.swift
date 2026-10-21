import Charts
import FlowCore
import SwiftUI

struct NodalView: View {
    let study: StudyCase
    @Environment(SimulationModel.self) private var sim

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PaneHeader(section: .nodal, trailing: sim.isRunning ? "Solving…" : nil)
                if let result = sim.nodal {
                    NodalResults(study: study, result: result, damageSkin: sim.damage?.skin, reference: sim.nodalReference)
                } else {
                    ProgressView("Solving nodal analysis…")
                        .frame(maxWidth: .infinity, minHeight: 300)
                }
            }
            .padding(20)
        }
    }
}

private struct NodalResults: View {
    let study: StudyCase
    let result: NodalResult
    let damageSkin: Double?
    let reference: ReferenceRun<NodalResult>?

    @Environment(\.unitSystem) private var units

    private var totalSkin: Double {
        study.reservoir.skin + (study.includeDamageSkin ? (damageSkin ?? 0) : 0)
    }

    /// Keeps the operating point in view: the VLP climbs steeply towards the AOF and would flatten everything else.
    private var rateAxisMax: Double {
        let aof = result.absoluteOpenFlow
        guard let rate = result.operatingPoint?.rate else { return aof }
        return min(aof, max(rate * 2.5, aof * 0.2))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StatGrid {
                if let op = result.operatingPoint {
                    StatTile(title: "Operating rate", value: Quantity.liquidRate.format(op.rate, digits: 0, in: units),
                             detail: referenceDetail ?? "liquid at stock-tank conditions", systemImage: "drop.fill", tint: .blue)
                    StatTile(title: "Flowing bottomhole pressure", value: Quantity.pressure.format(op.pressure, digits: 0, in: units),
                             detail: "at mid-perforations", systemImage: "gauge.with.dots.needle.50percent")
                    StatTile(title: "Oil rate", value: Quantity.liquidRate.format(op.rate * (1 - study.waterCut), digits: 0, in: units),
                             detail: "water cut \((study.waterCut * 100).formatted(digits: 0)) %", systemImage: "flame")
                } else {
                    StatTile(title: "Operating point", value: "No natural flow",
                             detail: "the tubing needs more pressure than the reservoir can deliver; consider artificial lift",
                             systemImage: "exclamationmark.triangle.fill", tint: .orange)
                }
                StatTile(title: "Total skin", value: totalSkin.formatted(digits: 2),
                         detail: skinBreakdown, systemImage: "circle.dashed.inset.filled", tint: totalSkin > 2 ? .red : .orange)
                StatTile(title: "Productivity index", value: Quantity.productivityIndex.format(result.productivityIndex, digits: 2, in: units),
                         detail: "above the bubble point", systemImage: "arrow.up.right")
                StatTile(title: "Absolute open flow", value: Quantity.liquidRate.format(result.absoluteOpenFlow, digits: 0, in: units),
                         detail: "rate at zero bottomhole pressure", systemImage: "arrow.up.to.line")
            }

            if let reference {
                ReferenceBadge(label: reference.label)
            }

            ChartCard(title: "Nodal analysis", subtitle: "Inflow performance (Darcy + Vogel) against tubing outflow (Beggs-Brill)") {
                NodalChart(
                    ipr: points(result.ipr), vlp: points(result.vlp),
                    referenceIPR: reference.map { points($0.result.ipr) } ?? [],
                    referenceVLP: reference.map { points($0.result.vlp) } ?? [],
                    operating: result.operatingPoint.map { XY(id: 0, x: Quantity.liquidRate.display($0.rate, in: units), y: Quantity.pressure.display($0.pressure, in: units)) },
                    operatingLabel: result.operatingPoint.map {
                        "\(Quantity.liquidRate.format($0.rate, digits: 0, in: units)) at \(Quantity.pressure.format($0.pressure, digits: 0, in: units))"
                    } ?? "",
                    bubblePoint: Quantity.pressure.display(result.bubblePoint, in: units),
                    xLabel: Quantity.liquidRate.axisLabel("Liquid rate", in: units),
                    yLabel: Quantity.pressure.axisLabel("Bottomhole pressure", in: units),
                    xMax: Quantity.liquidRate.display(rateAxisMax, in: units),
                    yMax: Quantity.pressure.display(study.reservoir.pressure * 1.15, in: units))
                    .frame(height: 340)
            }

            HStack(alignment: .top, spacing: 16) {
                ChartCard(title: "Pressure traverse", subtitle: "Up the tubing at the operating rate, coloured by flow pattern") {
                    Chart(result.traverse) { p in
                        PointMark(x: .value("Pressure", Quantity.pressure.display(p.pressure, in: units)),
                                  y: .value("Depth", Quantity.depth.display(p.depth, in: units)))
                            .symbolSize(16)
                            .foregroundStyle(by: .value("Pattern", p.pattern.rawValue))
                    }
                    .chartYScale(domain: .automatic(includesZero: true, reversed: true))
                    .chartXAxisLabel(Quantity.pressure.axisLabel("Pressure", in: units))
                    .chartYAxisLabel(Quantity.depth.axisLabel("Measured depth", in: units))
                    .frame(height: 300)
                }
                ChartCard(title: "Liquid holdup", subtitle: "Fraction of the tubing filled with liquid") {
                    Chart(result.traverse) { p in
                        LineMark(x: .value("Holdup", p.holdup), y: .value("Depth", Quantity.depth.display(p.depth, in: units)))
                            .foregroundStyle(.teal)
                    }
                    .chartXScale(domain: 0...1)
                    .chartYScale(domain: .automatic(includesZero: true, reversed: true))
                    .chartXAxisLabel("Liquid holdup")
                    .chartYAxisLabel(Quantity.depth.axisLabel("Measured depth", in: units))
                    .frame(height: 300)
                }
                ChartCard(title: "Gradient split", subtitle: "Hydrostatic and friction share of the pressure gradient") {
                    Chart {
                        ForEach(result.traverse) { p in
                            AreaMark(x: .value("Depth", Quantity.depth.display(p.depth, in: units)), y: .value("psi/ft", p.elevationGradient))
                                .foregroundStyle(by: .value("Term", "Hydrostatic"))
                            AreaMark(x: .value("Depth", Quantity.depth.display(p.depth, in: units)), y: .value("psi/ft", p.frictionGradient))
                                .foregroundStyle(by: .value("Term", "Friction"))
                        }
                    }
                    .chartXAxisLabel(Quantity.depth.axisLabel("Measured depth", in: units))
                    .chartYAxisLabel("Gradient (psi/ft)")
                    .frame(height: 300)
                }
            }
        }
    }

    private func points(_ curve: [CurvePoint]) -> [XY] {
        curve.enumerated().map { i, p in
            XY(id: i, x: Quantity.liquidRate.display(p.rate, in: units), y: Quantity.pressure.display(p.pressure, in: units))
        }
    }

    private var skinBreakdown: String {
        let damage = study.includeDamageSkin ? (damageSkin ?? 0) : 0
        return "completion \(study.reservoir.skin.formatted(digits: 2)) + mud damage \(damage.formatted(digits: 2))"
    }

    private var referenceDetail: String? {
        guard let reference, let rate = reference.result.operatingPoint?.rate else { return nil }
        return "reference \(Quantity.liquidRate.format(rate, digits: 0, in: units))"
    }
}

/// A display-unit chart point.
struct XY: Identifiable {
    let id: Int
    let x: Double
    let y: Double
}

/// IPR/VLP chart with optional dashed reference curves and the operating point.
private struct NodalChart: View {
    let ipr: [XY]
    let vlp: [XY]
    let referenceIPR: [XY]
    let referenceVLP: [XY]
    let operating: XY?
    let operatingLabel: String
    let bubblePoint: Double
    let xLabel: String
    let yLabel: String
    let xMax: Double
    let yMax: Double

    var body: some View {
        Chart {
            ForEach(ipr) { p in
                LineMark(x: .value("Rate", p.x), y: .value("Pressure", p.y), series: .value("Curve", "IPR"))
                    .foregroundStyle(by: .value("Curve", "Inflow (IPR)"))
            }
            ForEach(vlp) { p in
                LineMark(x: .value("Rate", p.x), y: .value("Pressure", p.y), series: .value("Curve", "VLP"))
                    .foregroundStyle(by: .value("Curve", "Outflow (VLP)"))
            }
            ForEach(referenceIPR) { p in
                LineMark(x: .value("Rate", p.x), y: .value("Pressure", p.y), series: .value("Curve", "IPR reference"))
                    .foregroundStyle(by: .value("Curve", "Reference"))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            }
            ForEach(referenceVLP) { p in
                LineMark(x: .value("Rate", p.x), y: .value("Pressure", p.y), series: .value("Curve", "VLP reference"))
                    .foregroundStyle(by: .value("Curve", "Reference"))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            }
            if let operating {
                PointMark(x: .value("Rate", operating.x), y: .value("Pressure", operating.y))
                    .symbolSize(150)
                    .foregroundStyle(.red)
                    .annotation(position: .topTrailing, spacing: 6) {
                        Text(operatingLabel)
                            .font(.caption.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                    }
            }
            RuleMark(y: .value("Bubble point", bubblePoint))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .foregroundStyle(.secondary)
                .annotation(position: .top, alignment: .leading) {
                    Text("Bubble point").font(.caption2).foregroundStyle(.secondary)
                }
        }
        .chartForegroundStyleScale(["Inflow (IPR)": Color.green, "Outflow (VLP)": Color.blue, "Reference": Color.gray])
        .chartXScale(domain: 0...max(xMax, 1))
        .chartYScale(domain: 0...max(yMax, 1))
        .chartPlotStyle { $0.clipped() }
        .chartXAxisLabel(xLabel)
        .chartYAxisLabel(yLabel)
    }
}
