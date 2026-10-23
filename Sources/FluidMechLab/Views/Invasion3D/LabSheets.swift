import AppKit
import Charts
import FlowCore
import FlowGPU
import Metal
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Verification

/// Runs the verification suite and shows each case's errors and observed order of convergence.
struct VerificationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var scheme: Invasion3DOptions.Scheme = .tvd
    @State private var cases: [InvasionVerification.Case] = []
    @State private var gpu: GPUAgreement?
    @State private var isRunning = false
    @State private var elapsed: TimeInterval = 0

    struct GPUAgreement: Sendable {
        var device: String
        var filtrateDifference: Double
        var pressureDifference: Double
        var massBalance: Double
        var error: String?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Verification").font(.title2.weight(.semibold))
                    Text("Problems with known solutions, solved by the same code as the 3D model, on refined grids.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Transport", selection: $scheme) {
                    ForEach(Invasion3DOptions.Scheme.allCases) { Text($0.title).tag($0) }
                }
                .fixedSize()
                .disabled(isRunning)
                Button(isRunning ? "Running…" : "Run") { run() }
                    .disabled(isRunning)
                    .keyboardShortcut(.defaultAction)
            }

            if cases.isEmpty {
                ContentUnavailableView {
                    Label(isRunning ? "Running the suite" : "Not run yet", systemImage: isRunning ? "hourglass" : "checkmark.seal")
                } description: {
                    Text("Seven cases: exact steady flow, layered anisotropic rock, Iwasaki–Herzig deep-bed filtration, the filtrate front, cake-controlled filtration, mass balance and symmetry. Then the GPU solver is compared with the double-precision CPU reference.")
                }
                .frame(maxWidth: .infinity, minHeight: 280)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(cases) { c in caseCard(c) }
                        gpuCard
                    }
                }
                .frame(minHeight: 380)
                HStack {
                    let passed = cases.filter(\.passed).count
                    Label("\(passed) of \(cases.count) passed in \(elapsed.formatted(.number.precision(.fractionLength(1)))) s",
                          systemImage: passed == cases.count ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(passed == cases.count ? .green : .orange)
                    Spacer()
                    Button("Save Report…") { saveReport() }
                }
            }

            Text("Verification shows that the equations are solved correctly. Validation, showing that the equations describe a given rock and mud, needs laboratory data: use Calibrate, then compare runs against held-back coreflood results.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
            }
        }
        .padding(20)
        .frame(width: 760)
    }

    private func caseCard(_ c: InvasionVerification.Case) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: c.passed ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(c.passed ? .green : .red)
                Text("\(c.id)  \(c.title)").font(.headline)
                Spacer()
                if let order = c.observedOrder {
                    Text("observed order \(order.formatted(digits: 2))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            Text("Reference: \(c.reference). \(c.metric). Expected: \(c.expected).")
                .font(.caption)
                .foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 2) {
                ForEach(c.levels) { level in
                    GridRow {
                        Text(level.label)
                        Text("\(level.cells) cells").foregroundStyle(.secondary)
                        Text(String(format: "%.3e", level.error)).monospacedDigit()
                    }
                }
            }
            .font(.caption)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private var gpuCard: some View {
        if let gpu {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    let ok = gpu.error == nil && gpu.filtrateDifference < 0.01 && gpu.pressureDifference < 1e-3
                    Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").foregroundStyle(ok ? .green : .orange)
                    Text("G1  GPU against CPU reference").font(.headline)
                }
                if let error = gpu.error {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("\(gpu.device), heterogeneous layered rock, 16 × 16 × 6 cells, 15 min exposure, full physics.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(String(format: "Cumulative filtrate differs by %.2e (relative), largest pressure difference %.2e of overbalance, GPU mass balance %.1e.",
                                gpu.filtrateDifference, gpu.pressureDifference, gpu.massBalance))
                        .font(.caption)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func run() {
        isRunning = true
        cases = []
        gpu = nil
        let scheme = scheme
        let start = Date()
        Task {
            let result = await Task.detached(priority: .userInitiated) { InvasionVerification.run(scheme: scheme) }.value
            let agreement = await Task.detached(priority: .userInitiated) { VerificationSheet.compareGPU() }.value
            cases = result
            gpu = agreement
            elapsed = Date().timeIntervalSince(start)
            isRunning = false
        }
    }

    nonisolated static func compareGPU() -> GPUAgreement {
        guard let device = MTLCreateSystemDefaultDevice() else {
            return GPUAgreement(device: "none", filtrateDifference: 0, pressureDifference: 0, massBalance: 0, error: "This Mac has no Metal device.")
        }
        var c = MudInvasionCase()
        c.exposureTime = 0.25
        var options = Invasion3DOptions()
        options.heterogeneity = 0.7
        options.horizontalCorrelation = 1.5
        options.verticalCorrelation = 0.4
        options.intervalLength = 6
        options.domainDepth = 4
        let setup = Invasion3DSetup(c, options: options, sizeOverride: (16, 16, 6))
        do {
            let gpu = try Invasion3DGPU(setup: setup, device: device)
            let cpu = Invasion3DSolver(setup: setup)
            cpu.advance(by: setup.exposureTime)
            gpu.advance(by: setup.exposureTime)
            gpu.waitUntilIdle()
            let a = cpu.stats, b = gpu.stats
            let p = gpu.readPressure()
            var worst = 0.0
            for i in p.indices { worst = max(worst, abs(Double(p[i]) - cpu.pressure[i])) }
            return GPUAgreement(device: device.name, filtrateDifference: abs(b.cumulativeFiltrate / a.cumulativeFiltrate - 1),
                                pressureDifference: worst, massBalance: b.massBalanceError, error: nil)
        } catch {
            return GPUAgreement(device: device.name, filtrateDifference: 0, pressureDifference: 0, massBalance: 0, error: String(describing: error))
        }
    }

    private func saveReport() {
        var lines = ["# Fluid MechLab 3D invasion verification", "", "Transport scheme: \(scheme.title)", "Date: \(Date().formatted())", ""]
        for c in cases {
            lines.append("## \(c.id) \(c.title): \(c.passed ? "PASS" : "FAIL")")
            lines.append("Reference: \(c.reference). Metric: \(c.metric). Expected: \(c.expected).")
            lines.append("")
            lines.append("| Grid | Cells | Error |")
            lines.append("|---|---|---|")
            for l in c.levels { lines.append("| \(l.label) | \(l.cells) | \(String(format: "%.4e", l.error)) |") }
            if let order = c.observedOrder { lines.append("\nObserved order: \(String(format: "%.3f", order))") }
            lines.append("")
        }
        if let gpu, gpu.error == nil {
            lines.append("## G1 GPU against CPU reference (\(gpu.device))")
            lines.append(String(format: "Filtrate difference %.3e, pressure difference %.3e, GPU mass balance %.2e", gpu.filtrateDifference, gpu.pressureDifference, gpu.massBalance))
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "3D invasion verification.md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Calibration

/// Fits model parameters to laboratory filter-press and return-permeability tests.
struct CalibrationSheet: View {
    @Binding var mud: MudInvasionCase
    @Environment(\.dismiss) private var dismiss
    @State private var tab = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Lab Calibration").font(.title2.weight(.semibold))
                    Text("Fit the cake and damage parameters of this study to your own measurements.").foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Test", selection: $tab) {
                    Text("Filter press").tag(0)
                    Text("Return permeability").tag(1)
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            if tab == 0 {
                FilterPressPanel(mud: $mud)
            } else {
                ReturnPermeabilityPanel(mud: $mud)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 820, height: 600)
    }
}

private struct FilterPressPanel: View {
    @Binding var mud: MudInvasionCase
    @State private var text = "time_min, volume_mL\n1, 3.2\n2, 4.1\n4, 5.4\n7.5, 7.0\n10, 7.9\n15, 9.5\n20, 10.8\n25, 11.9\n30, 12.9\n"
    @State private var area = 45.8
    @State private var pressure = 100.0
    @State private var viscosity = 1.0
    @State private var solids = 0.1
    @State private var cakePorosity = 0.4
    @State private var cake = 0.0
    @State private var applied = false

    private var test: FilterPressTest {
        let rows = Calibration.parseTwoColumns(text)
        var t = FilterPressTest(times: rows.map(\.0), volumes: rows.map(\.1))
        t.area = area
        t.pressureDrop = pressure
        t.viscosity = viscosity
        t.mudSolidsFraction = solids
        t.cakePorosity = cakePorosity
        t.finalCakeThickness = cake > 0 ? cake : nil
        return t
    }

    var body: some View {
        let result = Result { try Calibration.fit(test) }
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Cumulative filtrate against time").font(.headline)
                    Spacer()
                    Button("Import CSV…") { importCSV() }
                }
                TextEditor(text: $text)
                    .font(.system(.caption, design: .monospaced))
                    .frame(height: 150)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                Form {
                    LabeledContent("Filtration area") { number($area, "cm²") }
                    LabeledContent("Differential pressure") { number($pressure, "psi") }
                    LabeledContent("Filtrate viscosity") { number($viscosity, "cp") }
                    LabeledContent("Mud solids fraction") { number($solids, "") }
                    LabeledContent("Cake porosity") { number($cakePorosity, "") }
                    LabeledContent("Measured final cake") { number($cake, "mm (0 = not measured)") }
                }
                .formStyle(.columns)
                Text("API low-pressure cell: 45.8 cm², 100 psi. HPHT cell: about 22.6 cm²; the API fluid loss is reported on the API area.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .frame(width: 340)

            VStack(alignment: .leading, spacing: 10) {
                switch result {
                case .success(let fit):
                    fitChart(fit)
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                        row("Spurt loss", String(format: "%.4f ± %.4f cm (95 %%)", fit.spurt, fit.spurtConfidence))
                        row("√t slope", String(format: "%.4f ± %.4f cm/√min", fit.slope, fit.slopeConfidence))
                        row("R²", String(format: "%.5f", fit.rSquared))
                        row("API fluid loss (30 min)", String(format: "%.1f mL", fit.apiFluidLoss))
                        row("Cake growth α", String(format: "%.3f cm³ cake per cm³ filtrate", fit.cakeGrowth))
                        row("Cake permeability", String(format: "%.3g md", fit.cakePermeability))
                        row("Bridging thickness", String(format: "%.3f mm", fit.bridgingThickness))
                    }
                    .font(.callout)
                    Text("Static filtration: V/A = V_spurt + m√t, with m² = 2 k_c Δp / (μ α). The bridging thickness is the cake built by the spurt volume, h_b = α V_spurt, which is when this model stops fines from entering.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer()
                        Button(applied ? "Applied" : "Apply to Study") {
                            mud.cakePermeability = fit.cakePermeability
                            mud.bridgingThickness = max(fit.bridgingThickness, 0.001)
                            mud.mudSolidsFraction = solids
                            mud.cakePorosity = cakePorosity
                            applied = true
                        }
                        .disabled(applied)
                        .help("Sets cake permeability, bridging thickness, mud solids and cake porosity")
                    }
                case .failure(let error):
                    ContentUnavailableView("No fit", systemImage: "chart.xyaxis.line", description: Text(String(describing: error)))
                }
            }
        }
        .onChange(of: text) { applied = false }
    }

    private func fitChart(_ fit: FilterPressFit) -> some View {
        let points = zip(test.times, test.volumes).filter { $0.0 > 0 }.map { (x: $0.0.squareRoot(), y: $0.1 / area) }
        let maxX = points.map(\.x).max() ?? 1
        return Chart {
            ForEach(Array(points.enumerated()), id: \.offset) { _, p in
                PointMark(x: .value("√t", p.x), y: .value("V/A", p.y)).foregroundStyle(.blue)
            }
            LineMark(x: .value("√t", 0.0), y: .value("V/A", fit.spurt)).foregroundStyle(.orange)
            LineMark(x: .value("√t", maxX), y: .value("V/A", fit.spurt + fit.slope * maxX)).foregroundStyle(.orange)
        }
        .chartXAxisLabel("√t (√min)")
        .chartYAxisLabel("V/A (cm)")
        .frame(height: 220)
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
    }

    private func number(_ value: Binding<Double>, _ unit: String) -> some View {
        HStack(spacing: 4) {
            TextField("", value: value, format: .number).frame(width: 70).multilineTextAlignment(.trailing)
            Text(unit).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func importCSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .tabSeparatedText, .plainText]
        guard panel.runModal() == .OK, let url = panel.url, let content = try? String(contentsOf: url, encoding: .utf8) else { return }
        text = content
    }
}

private struct ReturnPermeabilityPanel: View {
    @Binding var mud: MudInvasionCase
    @State private var initial = 150.0
    @State private var returned = 90.0
    @State private var length = 5.0
    @State private var injected = 2.0
    @State private var solidsFree = false
    @State private var applied = false

    private var test: ReturnPermeabilityTest {
        var t = ReturnPermeabilityTest(initialPermeability: initial, returnPermeability: returned)
        t.coreLength = length
        t.injectedPerArea = injected
        t.solidsFree = solidsFree
        return t
    }

    var body: some View {
        let t = test
        let beta = t.damageCoefficient(filtrateFactor: mud.filtrateDamageFactor, filtrationCoefficient: mud.filtrationCoefficient,
                                       finesConcentration: mud.finesConcentration)
        HStack(alignment: .top, spacing: 24) {
            Form {
                LabeledContent("Initial permeability") { number($initial, "md") }
                LabeledContent("Return permeability") { number($returned, "md") }
                LabeledContent("Core length") { number($length, "cm") }
                LabeledContent("Filtrate injected") { number($injected, "cm³/cm²") }
                Toggle("Solids-free filtrate test", isOn: $solidsFree)
            }
            .formStyle(.columns)
            .frame(width: 340)

            VStack(alignment: .leading, spacing: 10) {
                Text("Return permeability ratio \(t.ratio.formatted(digits: 3))").font(.title3.weight(.semibold))
                if solidsFree {
                    Text("With solids-free filtrate only the filtrate damage factor F is affected, so F = k_return / k₀ = \(t.ratio.formatted(digits: 3)).")
                    applyButton { mud.filtrateDamageFactor = min(max(t.ratio, 0.01), 1) }
                } else if let beta {
                    Text("Using this study's F = \(mud.filtrateDamageFactor.formatted(digits: 2)), λ₀ = \(mud.filtrationCoefficient.formatted(digits: 0)) 1/m and c₀ = \(mud.finesConcentration.formatted(digits: 3)), the damage coefficient that matches the test is β = \(beta.formatted(digits: 0)).")
                    applyButton { mud.damageCoefficient = beta }
                } else {
                    Text("The measured ratio is above F, or no fines are captured, so fines damage cannot explain it. Measure F with a solids-free test first, or check λ₀ and c₀.")
                        .foregroundStyle(.orange)
                }
                Text("Linear core, constant λ: σ(x) = λ c₀ U e^{−λx}; harmonic averaging of k = F k₀ / (1 + βσ) over the core gives k_ret/k₀ = F L / (L + β c₀ U (1 − e^{−λL})).")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Fit F from a solids-free test first, then β from a whole-mud test on a sister plug.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .onChange(of: t) { applied = false }
    }

    private func applyButton(_ action: @escaping () -> Void) -> some View {
        Button(applied ? "Applied" : "Apply to Study") {
            action()
            applied = true
        }
        .disabled(applied)
    }

    private func number(_ value: Binding<Double>, _ unit: String) -> some View {
        HStack(spacing: 4) {
            TextField("", value: value, format: .number).frame(width: 70).multilineTextAlignment(.trailing)
            Text(unit).font(.caption).foregroundStyle(.secondary)
        }
    }
}
