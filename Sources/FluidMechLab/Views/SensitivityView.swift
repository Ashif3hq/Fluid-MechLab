import Charts
import FlowCore
import SwiftUI

/// Sweeps one damage parameter and shows how skin, productivity and rate respond.
struct SensitivityView: View {
    let study: StudyCase
    @Environment(\.unitSystem) private var units

    @State private var parameter: SweepParameter = .overbalance
    @State private var lower = 100.0
    @State private var upper = 3000.0
    @State private var count = 12
    @State private var points: [SensitivityPoint] = []
    @State private var isRunning = false

    private struct Request: Equatable {
        let study: StudyCase
        let parameter: SweepParameter
        let lower: Double
        let upper: Double
        let count: Int
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PaneHeader(section: .sensitivity, trailing: isRunning ? "Running \(count) simulations…" : nil)
                controls
                if points.isEmpty {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    results
                }
            }
            .padding(20)
        }
        .onChange(of: parameter) { _, new in
            let range = new.defaultRange(around: study[keyPath: new.keyPath])
            lower = range.lowerBound
            upper = range.upperBound
        }
        .task(id: Request(study: study, parameter: parameter, lower: lower, upper: upper, count: count)) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, upper > lower else { return }
            isRunning = true
            let base = study, p = parameter, values = parameter.values(in: lower...upper, count: count)
            let result = await Task.detached(priority: .userInitiated) {
                SensitivityStudy.run(base, parameter: p, values: values)
            }.value
            guard !Task.isCancelled else { return }
            points = result
            isRunning = false
        }
    }

    private var controls: some View {
        GroupBox {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Picker("Parameter", selection: $parameter) {
                    ForEach(SweepParameter.allCases) { Text($0.rawValue).tag($0) }
                }
                .frame(maxWidth: 300)
                LabeledContent("From") {
                    TextField("From", value: displayBinding($lower), format: .number)
                        .frame(width: 80)
                }
                LabeledContent("To") {
                    TextField("To", value: displayBinding($upper), format: .number)
                        .frame(width: 80)
                }
                Text(parameter.quantity.symbol(units)).foregroundStyle(.secondary)
                Stepper("\(count) points", value: $count, in: 4...30)
                Spacer()
                Text(parameter.isLogarithmic ? "Logarithmic spacing" : "Linear spacing")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(4)
        }
    }

    private func displayBinding(_ value: Binding<Double>) -> Binding<Double> {
        Binding(
            get: { parameter.quantity.display(value.wrappedValue, in: units) },
            set: { value.wrappedValue = parameter.quantity.engine($0, from: units) }
        )
    }

    private var current: Double { study[keyPath: parameter.keyPath] }

    private var xLabel: String { parameter.quantity.axisLabel(parameter.rawValue, in: units) }

    private func x(_ v: Double) -> Double { parameter.quantity.display(v, in: units) }

    @ViewBuilder
    private var results: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 420), spacing: 16)], spacing: 16) {
            ChartCard(title: "Damage skin", subtitle: "Skin after cake lift-off") {
                sweepChart(\.skin, color: .red, yLabel: "Skin")
            }
            ChartCard(title: "Productivity ratio", subtitle: "Damaged ÷ undamaged productivity") {
                sweepChart(\.productivityRatio, color: .orange, yLabel: "J / J₀")
            }
            ChartCard(title: "Invasion depth", subtitle: "Filtrate front and internal filter cake") {
                Chart {
                    ForEach(points) { p in
                        LineMark(x: .value("x", x(p.value)), y: .value("Depth", Quantity.invasionDepth.display(p.filtrateInvasionDepth, in: units)),
                                 series: .value("Depth", "Filtrate"))
                            .foregroundStyle(by: .value("Depth", "Filtrate front"))
                        LineMark(x: .value("x", x(p.value)), y: .value("Depth", Quantity.invasionDepth.display(p.solidsInvasionDepth, in: units)),
                                 series: .value("Depth", "Solids"))
                            .foregroundStyle(by: .value("Depth", "Solids"))
                    }
                    RuleMark(x: .value("Current", x(current))).foregroundStyle(.secondary)
                }
                .chartXAxisLabel(xLabel)
                .chartYAxisLabel(Quantity.invasionDepth.axisLabel("Depth", in: units))
                .chartXScale(type: parameter.isLogarithmic ? .log : .linear)
                .frame(height: 220)
            }
            ChartCard(title: "Operating rate", subtitle: "Natural-flow liquid rate with this damage") {
                Chart {
                    ForEach(points.filter { $0.operatingRate != nil }) { p in
                        LineMark(x: .value("x", x(p.value)), y: .value("Rate", Quantity.liquidRate.display(p.operatingRate ?? 0, in: units)))
                            .foregroundStyle(.blue)
                        PointMark(x: .value("x", x(p.value)), y: .value("Rate", Quantity.liquidRate.display(p.operatingRate ?? 0, in: units)))
                            .foregroundStyle(.blue)
                            .symbolSize(20)
                    }
                    RuleMark(x: .value("Current", x(current))).foregroundStyle(.secondary)
                }
                .chartXAxisLabel(xLabel)
                .chartYAxisLabel(Quantity.liquidRate.axisLabel("Liquid rate", in: units))
                .chartXScale(type: parameter.isLogarithmic ? .log : .linear)
                .frame(height: 220)
            }
        }

        ChartCard(title: "Results table") {
            Table(points) {
                TableColumn(xLabel) { p in Text(x(p.value).formatted(digits: parameter.isLogarithmic ? 4 : 2)).monospacedDigit() }
                TableColumn("Skin") { p in Text(p.skin.formatted(digits: 2)).monospacedDigit() }
                TableColumn("PR") { p in Text("\((p.productivityRatio * 100).formatted(digits: 1)) %").monospacedDigit() }
                TableColumn("Filtrate") { p in Text(Quantity.invasionDepth.format(p.filtrateInvasionDepth, digits: 1, in: units)).monospacedDigit() }
                TableColumn("Solids") { p in Text(Quantity.invasionDepth.format(p.solidsInvasionDepth, digits: 2, in: units)).monospacedDigit() }
                TableColumn("Rate") { p in
                    Text(p.operatingRate.map { Quantity.liquidRate.format($0, digits: 0, in: units) } ?? "no flow").monospacedDigit()
                }
            }
            .frame(minHeight: 260)
        }
    }

    private func sweepChart(_ value: KeyPath<SensitivityPoint, Double>, color: Color, yLabel: String) -> some View {
        Chart {
            ForEach(points) { p in
                LineMark(x: .value("x", x(p.value)), y: .value(yLabel, p[keyPath: value]))
                    .foregroundStyle(color)
                PointMark(x: .value("x", x(p.value)), y: .value(yLabel, p[keyPath: value]))
                    .foregroundStyle(color)
                    .symbolSize(20)
            }
            RuleMark(x: .value("Current", x(current)))
                .foregroundStyle(.secondary)
                .annotation(position: .top, alignment: .leading) {
                    Text("current").font(.caption2).foregroundStyle(.secondary)
                }
        }
        .chartXAxisLabel(xLabel)
        .chartYAxisLabel(yLabel)
        .chartXScale(type: parameter.isLogarithmic ? .log : .linear)
        .frame(height: 220)
    }
}
