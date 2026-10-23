import AppKit
import FlowCore
import FlowGPU
import MetalKit
import SwiftUI
import UniformTypeIdentifiers

/// State shared between the 3D pane's SwiftUI controls and its Metal renderer.
@MainActor
@Observable
final class Invasion3DController {
    enum RenderMode: Int, CaseIterable, Identifiable {
        case cutaway, front, volume

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .cutaway: "Cutaway"
            case .front: "Front"
            case .volume: "Volume"
            }
        }

        var help: String {
            switch self {
            case .cutaway: "Solid rock with a quarter cut away, coloured by the field, with the filtrate front drawn as a line"
            case .front: "The filtrate front (saturation 0.5) as a surface inside transparent rock, coloured by the field"
            case .volume: "Volume rendering of the field through the rock, with the cutaway removed"
            }
        }
    }

    enum Field: Int, CaseIterable, Identifiable {
        case filtrate, damage, permeability, retained, suspended, pressure

        var id: Int { rawValue }
        var shaderIndex: Int { rawValue }

        var title: String {
            switch self {
            case .filtrate: "Filtrate saturation"
            case .damage: "Damage 1 − k/k₀"
            case .permeability: "Permeability"
            case .retained: "Retained fines σ/σmax"
            case .suspended: "Suspended fines c/c₀"
            case .pressure: "Overpressure"
            }
        }

        func legend(overbalance: Double, permeability: Double, units: UnitSystem) -> (low: String, high: String) {
            switch self {
            case .filtrate: return ("0", "1")
            case .damage: return ("0 (k = k₀)", "1")
            case .permeability:
                let q = Quantity.permeability
                return (q.format(permeability * 0.01, digits: 2, in: units), q.format(permeability * 100, digits: 0, in: units))
            case .retained, .suspended: return ("0", "1")
            case .pressure: return ("0", Quantity.pressure.format(overbalance, digits: 0, in: units))
            }
        }

        /// Swift copy of the shader colour map, for the legend.
        func colour(_ t: Double) -> Color {
            let c = Colormaps.colour(self, t)
            return Color(red: c.x, green: c.y, blue: c.z)
        }
    }

    struct Camera {
        var azimuth = -0.85
        var elevation = 0.42
        var distance = 3.4
        var targetHeight = 0.0
    }

    var isPlaying = true
    /// Seconds of screen time for the whole exposure.
    var playbackSeconds: Double = 60
    var field: Field = .filtrate
    var mode: RenderMode = .cutaway
    var camera = Camera()
    /// Height of the cutaway floor, as a fraction of the half interval (−1 bottom, 1 top).
    var cutawayHeight: Float = 0
    /// Depth rings on cut faces are drawn at round metric spacings instead of round inch spacings.
    var metricRings = false

    /// Spacing of the depth rings on cut faces, m: the smallest round step that keeps about eight rings across the rock.
    var ringSpacing: Double {
        guard let setup else { return 0 }
        let depth = setup.domainRadius - setup.wellboreRadius
        let steps = metricRings ? [0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.5] : [0.5, 1, 2, 3, 6, 12, 24].map { $0 * 0.0254 }
        return steps.first { depth / $0 <= 8 } ?? steps.last!
    }

    /// The ring spacing as text, such as "2 in" or "5 cm".
    var ringSpacingLabel: String {
        let step = ringSpacing
        if metricRings { return step < 0.01 ? "\((step * 1000).formatted()) mm" : "\((step * 100).formatted()) cm" }
        return "\((step / 0.0254).formatted()) in"
    }

    var volumeOpacity: Double = 1.6
    var backgroundTop: (r: Double, g: Double, b: Double) = (0.97, 0.97, 0.98)
    var backgroundBottom: (r: Double, g: Double, b: Double) = (0.86, 0.87, 0.89)

    private(set) var stats = Invasion3DStats()
    private(set) var history: [Invasion3DStats] = []
    private(set) var isFinished = false
    private(set) var errorMessage: String?
    private(set) var setup: Invasion3DSetup?
    private(set) var skin: Double?
    private(set) var isComputingSkin = false
    var isPreparing = false

    @ObservationIgnored private(set) var renderer: Invasion3DRenderer?

    var exposureHours: Double { (setup?.exposureTime ?? 0) / 3600 }
    /// Top of the cake colour scale, mm.
    var cakeScale: Double { max(stats.cakeMax, 0.05) }

    func attach(_ renderer: Invasion3DRenderer) {
        self.renderer = renderer
        renderer.controller = self
        if let setup { start(setup) }
    }

    func configure(_ setup: Invasion3DSetup) {
        self.setup = setup
        start(setup)
    }

    func restart() {
        if let setup { start(setup) }
    }

    func fail(_ message: String) {
        errorMessage = message
        Invasion3DSnapshotRegistry.shared.lastError = message
    }

    func receive(stats: Invasion3DStats, finished: Bool, record: Bool) {
        self.stats = stats
        if record { history.append(stats) }
        if finished && !isFinished {
            isPlaying = false
            computeSkin()
        }
        isFinished = finished
    }

    func orbit(dx: Double, dy: Double) {
        camera.azimuth -= dx * 0.008
        camera.elevation = min(max(camera.elevation + dy * 0.008, -1.45), 1.45)
    }

    func zoom(_ amount: Double) {
        camera.distance = min(max(camera.distance * (1 - amount), 1.2), 9)
    }

    func resetCamera() {
        camera = Camera()
    }

    func computeSkin() {
        guard let solver = renderer?.solver, !isComputingSkin else { return }
        isComputingSkin = true
        Task { @MainActor in
            // Let the spinner draw before the blocking GPU solves.
            try? await Task.sleep(for: .milliseconds(60))
            let value = solver.computeSkin()
            skin = value.isFinite ? value : nil
            isComputingSkin = false
        }
    }

    /// The current fields in double precision, for export.
    func snapshot() -> Invasion3DSnapshot? {
        renderer?.solver?.snapshot()
    }

    private func start(_ setup: Invasion3DSetup) {
        guard let renderer else { return }
        do {
            try renderer.reset(setup: setup)
            errorMessage = nil
            stats = Invasion3DStats()
            history = []
            skin = nil
            isFinished = false
            isPlaying = true
        } catch {
            fail(String(describing: error))
        }
    }
}

/// Swift copies of the shader colour maps, so legends match the picture exactly.
enum Colormaps {
    static func poly(_ t: Double, _ c: [SIMD3<Double>]) -> SIMD3<Double> {
        let t = min(max(t, 0), 1)
        var v = c[6]
        for i in stride(from: 5, through: 0, by: -1) { v = c[i] + t * v }
        return v.clamped(lowerBound: SIMD3(repeating: 0), upperBound: SIMD3(repeating: 1))
    }

    static let viridis: [SIMD3<Double>] = [
        SIMD3(0.2777273272234177, 0.005407344544966578, 0.3340998053353061), SIMD3(0.1050930431085774, 1.404613529898575, 1.384590162594685),
        SIMD3(-0.3308618287255563, 0.214847559468213, 0.09509516302823659), SIMD3(-4.634230498983486, -5.799100973351585, -19.33244095627987),
        SIMD3(6.228269936347081, 14.17993336680509, 56.69055260068105), SIMD3(4.776384997670288, -13.74514537774601, -65.35303263337234),
        SIMD3(-5.435455855934631, 4.645852612178535, 26.3124352495832),
    ]
    static let inferno: [SIMD3<Double>] = [
        SIMD3(0.0002189403691192265, 0.001651004631001012, -0.01948089843709184), SIMD3(0.1065134194856116, 0.5639564367884091, 3.932712388889277),
        SIMD3(11.60249308247187, -3.972853965665698, -15.9423941062914), SIMD3(-41.70399613139459, 17.43639888205313, 44.35414519872813),
        SIMD3(77.162935699427, -33.40235894210092, -81.80730925738993), SIMD3(-71.31942824499214, 32.62606426397723, 73.20951985803202),
        SIMD3(25.13112622477341, -12.24266895238567, -23.07032500287172),
    ]
    static let magma: [SIMD3<Double>] = [
        SIMD3(-0.002136485053939582, -0.000749655052795221, -0.005386127855323933), SIMD3(0.2516605407371642, 0.6775232436837668, 2.494026599312351),
        SIMD3(8.353717279216625, -3.577719514958484, 0.3144679030132573), SIMD3(-27.66873308576866, 14.26473078096533, -13.64921318813922),
        SIMD3(52.17613981234068, -27.94360607168351, 12.94416944238394), SIMD3(-50.76852536473588, 29.04658282127291, 4.23415299384598),
        SIMD3(18.65570506591883, -11.48977351997711, -5.601961508734096),
    ]
    static let plasma: [SIMD3<Double>] = [
        SIMD3(0.05873234392399702, 0.02333670892565664, 0.5433401826748754), SIMD3(2.176514634195958, 0.2383834171260182, 0.7539604599784036),
        SIMD3(-2.689460476458034, -7.455851135738909, 3.110799939717086), SIMD3(6.130348345893603, 42.3461881477227, -28.51885465332158),
        SIMD3(-11.10743619062271, -82.66631109428045, 60.13984767418263), SIMD3(10.02306557647065, 71.41361770095349, -54.07218655560067),
        SIMD3(-3.658713842777788, -22.93153465461149, 18.19190778539828),
    ]

    static func ramp(_ t: Double, _ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>) -> SIMD3<Double> {
        let t = min(max(t, 0), 1)
        return t < 0.5 ? a + (b - a) * (t * 2) : b + (c - b) * (t * 2 - 1)
    }

    static func colour(_ field: Invasion3DController.Field, _ t: Double) -> SIMD3<Double> {
        let rock = SIMD3(0.88, 0.83, 0.71)
        switch field {
        case .filtrate: return ramp(t, rock, SIMD3(0.36, 0.62, 0.86), SIMD3(0.04, 0.19, 0.45))
        case .damage: return poly(1 - 0.92 * t, inferno)
        case .permeability: return poly(t, viridis)
        case .retained: return poly(1 - 0.9 * t, magma)
        case .suspended: return ramp(t, rock, SIMD3(0.45, 0.74, 0.52), SIMD3(0.02, 0.36, 0.20))
        case .pressure: return poly(0.05 + 0.9 * t, plasma)
        }
    }
}

/// The 3D Invasion pane.
struct Invasion3DView: View {
    @Binding var study: StudyCase

    @Environment(SimulationModel.self) private var sim
    @Environment(\.unitSystem) private var units
    @Environment(\.colorScheme) private var colorScheme
    @State private var controller = Invasion3DController()
    @State private var showVerification = false
    @State private var showCalibration = false

    private struct Config: Equatable {
        let mud: MudInvasionCase
        let options: Invasion3DOptions
        let depth: Double?
    }

    private var config: Config {
        Config(mud: study.damageCase, options: study.invasionOptions,
               depth: sim.damage.map { ($0.filtrateInvasionDepth * 10).rounded() / 10 })
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Invasion3DMetalView(controller: controller)
                Invasion3DOverlays(controller: controller)
                if controller.isPreparing {
                    ProgressView("Building the \(study.invasionOptions.resolution.title.lowercased()) grid…")
                        .padding(16)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                if let error = controller.errorMessage {
                    ContentUnavailableView("3D view unavailable", systemImage: "exclamationmark.triangle", description: Text(error))
                        .background(.background)
                }
            }
            Divider()
            Invasion3DControlBar(controller: controller, study: study,
                                 showVerification: $showVerification, showCalibration: $showCalibration)
        }
        .task(id: config) {
            let c = config
            controller.isPreparing = true
            let setup = await Task.detached(priority: .userInitiated) {
                Invasion3DSetup(c.mud, options: c.options, invasionDepth: c.depth)
            }.value
            guard !Task.isCancelled else { return }
            controller.isPreparing = false
            controller.configure(setup)
        }
        .onAppear { updateAppearance() }
        .onChange(of: colorScheme) { updateAppearance() }
        .onChange(of: units) { updateAppearance() }
        .sheet(isPresented: $showVerification) { VerificationSheet() }
        .sheet(isPresented: $showCalibration) { CalibrationSheet(mud: $study.mud) }
    }

    private func updateAppearance() {
        if colorScheme == .dark {
            controller.backgroundTop = (0.16, 0.16, 0.18)
            controller.backgroundBottom = (0.07, 0.07, 0.08)
        } else {
            controller.backgroundTop = (0.97, 0.97, 0.98)
            controller.backgroundBottom = (0.84, 0.85, 0.88)
        }
        controller.metricRings = units == .si
    }
}

// MARK: - Overlays

private struct Invasion3DOverlays: View {
    let controller: Invasion3DController
    @Environment(\.unitSystem) private var units

    var body: some View {
        ZStack(alignment: .topLeading) {
            Invasion3DHUD(controller: controller)
                .padding(16)
            Invasion3DLegend(controller: controller)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .topTrailing)
            if let setup = controller.setup {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Grid \(setup.nr) × \(setup.nt) × \(setup.nz) (r × θ × z), \(setup.cellCount.formatted()) cells")
                    Text("Rock to \(Quantity.invasionDepth.format((setup.domainRadius - setup.wellboreRadius) / 0.0254, digits: 1, in: units)) from the wall, interval \(Quantity.invasionDepth.format(setup.length / 0.0254, digits: 0, in: units))")
                    if controller.mode == .cutaway {
                        Text("Rings every \(controller.ringSpacingLabel) into the formation")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
            HStack(spacing: 6) {
                Image(systemName: "hand.draw")
                Text("Drag to orbit, scroll or pinch to zoom")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
    }
}

private struct Invasion3DHUD: View {
    let controller: Invasion3DController
    @Environment(\.unitSystem) private var units

    var body: some View {
        let s = controller.stats
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(controller.isPlaying ? Color.green : (controller.isFinished ? Color.blue : Color.orange))
                    .frame(width: 8, height: 8)
                Text(controller.isFinished ? "Exposure complete" : (controller.isPlaying ? "Simulating on GPU" : "Paused"))
                    .font(.caption.weight(.semibold))
            }
            Text("\(s.time.formatted(digits: s.time < 1 ? 2 : 1)) h of \(controller.exposureHours.formatted(digits: 0)) h")
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                row("Filtrate front", Quantity.invasionDepth.format(s.frontMean, digits: 2, in: units))
                row("Front range", "\(Quantity.invasionDepth.format(s.frontMin, digits: 1, in: units)) – \(Quantity.invasionDepth.format(s.frontMax, digits: 1, in: units))")
                row("Front spread (1σ)", Quantity.invasionDepth.format(s.frontSpread, digits: 2, in: units))
                row("Mud cake", "\(s.cakeMean.formatted(digits: 2)) mm (\(s.cakeMin.formatted(digits: 2))–\(s.cakeMax.formatted(digits: 2)))")
                row("Fluid loss rate", "\(s.filtrationRate.formatted(digits: s.filtrationRate < 1 ? 3 : 1)) cm/h")
                row("Total filtrate", "\(s.cumulativeFiltrate.formatted(digits: 3)) cm")
                row("Lowest k/k₀", s.minPermeabilityRatio.formatted(digits: 3))
                row("Skin (cake off)", controller.isComputingSkin ? "computing…" : (controller.skin.map { $0.formatted(digits: 2) } ?? "–"))
            }
            .font(.caption)
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                row("Mass balance", s.massBalanceError > 0 ? String(format: "%.1e", s.massBalanceError) : "–")
                row("Pressure solve", "\(s.lastIterations) sweeps, imbalance \(String(format: "%.0e", s.lastImbalance))")
                row("Solves / steps", "\(s.pressureSolves) / \(s.transportSteps)")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 270, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).monospacedDigit().gridColumnAlignment(.trailing)
        }
    }
}

private struct Invasion3DLegend: View {
    let controller: Invasion3DController
    @Environment(\.unitSystem) private var units

    var body: some View {
        let field = controller.field
        let labels = field.legend(overbalance: controller.setup?.overbalance ?? 0, permeability: controller.setup?.permeability ?? 0, units: units)
        VStack(alignment: .leading, spacing: 6) {
            Text(field.title).font(.caption.weight(.semibold))
            LinearGradient(colors: (0...16).map { field.colour(Double($0) / 16) }, startPoint: .leading, endPoint: .trailing)
                .frame(width: 190, height: 12)
                .clipShape(RoundedRectangle(cornerRadius: 3))
            HStack {
                Text(labels.low)
                Spacer()
                Text(labels.high)
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            switch controller.mode {
            case .cutaway:
                Label("Line: filtrate front (s = 0.5)", systemImage: "line.diagonal").font(.caption2).foregroundStyle(.secondary)
            case .front:
                Label("Surface: filtrate front (s = 0.5)", systemImage: "circle.hexagongrid").font(.caption2).foregroundStyle(.secondary)
            case .volume:
                Label("Opacity rises with the value", systemImage: "cube.transparent").font(.caption2).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                LinearGradient(colors: [Colormaps.cakeSwatch(0), Colormaps.cakeSwatch(1)], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 40, height: 8)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                Text("Borehole wall: cake 0–\(controller.cakeScale.formatted(digits: 2)) mm")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 214, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

extension Colormaps {
    static func cakeSwatch(_ t: Double) -> Color {
        let a = SIMD3(0.42, 0.36, 0.30), b = SIMD3(0.28, 0.17, 0.08)
        let c = a + (b - a) * t
        return Color(red: c.x, green: c.y, blue: c.z)
    }
}

// MARK: - Controls

private struct Invasion3DControlBar: View {
    @Bindable var controller: Invasion3DController
    let study: StudyCase
    @Binding var showVerification: Bool
    @Binding var showCalibration: Bool

    var body: some View {
        HStack(spacing: 10) {
            Button {
                if controller.isFinished { controller.restart() } else { controller.isPlaying.toggle() }
            } label: {
                Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill").frame(width: 18)
            }
            .keyboardShortcut(.space, modifiers: [])
            .help(controller.isPlaying ? "Pause" : "Play")

            Button { controller.restart() } label: { Image(systemName: "backward.end.fill") }
                .help("Restart the exposure")

            ProgressView(value: min(controller.stats.time, controller.exposureHours), total: max(controller.exposureHours, 1e-9))
                .frame(minWidth: 36, maxWidth: 160)

            Picker("View", selection: $controller.mode) {
                ForEach(Invasion3DController.RenderMode.allCases) { Text($0.title).tag($0).help($0.help) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Picker("Show", selection: $controller.field) {
                ForEach(Invasion3DController.Field.allCases) { Text($0.title).tag($0) }
            }
            .fixedSize()

            Picker(selection: $controller.playbackSeconds) {
                Text("30 s").tag(30.0)
                Text("1 min").tag(60.0)
                Text("2 min").tag(120.0)
                Text("5 min").tag(300.0)
                Text("10 min").tag(600.0)
            } label: {
                Image(systemName: "timer")
            }
            .fixedSize()
            .help("Screen time for the whole exposure. The solver never takes larger steps than its accuracy limits allow; on fine grids it may run slower than this.")

            Spacer(minLength: 0)

            Button { controller.resetCamera() } label: { Image(systemName: "camera.metering.center.weighted") }
                .help("Reset the view")

            Button { controller.computeSkin() } label: { Label("Skin", systemImage: "function") }
                .disabled(controller.isComputingSkin)
                .help("Compute the skin of the damaged zone with the cake removed (two steady 3D solves)")

            Menu {
                Button("ParaView / VisIt (VTK)…") { export(.vtk) }
                Button("Radial profile (CSV)…") { export(.profile) }
                Button("Front and cake map (CSV)…") { export(.frontMap) }
                Button("Time history (CSV)…") { export(.history) }
                Divider()
                Button("Run record (JSON)…") { export(.record) }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .fixedSize()
            .help("Export the current 3D state for analysis and reproducibility")

            Button { showVerification = true } label: { Label("Verify", systemImage: "checkmark.seal") }
                .help("Run the verification suite against analytical solutions")
            Button { showCalibration = true } label: { Label("Calibrate", systemImage: "testtube.2") }
                .help("Fit cake and damage parameters to laboratory data")
        }
        .labelStyle(.iconOnly)
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private enum ExportKind { case vtk, profile, frontMap, history, record }

    private func export(_ kind: ExportKind) {
        let wasPlaying = controller.isPlaying
        controller.isPlaying = false
        defer { controller.isPlaying = wasPlaying }
        guard let snap = controller.snapshot() else { return }
        let hours = String(format: "%.2fh", snap.time / 3600)
        let base = "\(study.title) – 3D \(hours)"
        let data: Data
        let name: String
        let type: UTType
        switch kind {
        case .vtk:
            data = Invasion3DExport.vtk(snap, title: "\(study.title), \(study.well.name)")
            name = "\(base).vtk"
            type = UTType(filenameExtension: "vtk") ?? .data
        case .profile:
            data = Data(Invasion3DExport.radialProfileCSV(snap).utf8)
            name = "\(base) radial profile.csv"
            type = .commaSeparatedText
        case .frontMap:
            data = Data(Invasion3DExport.frontMapCSV(snap).utf8)
            name = "\(base) front map.csv"
            type = .commaSeparatedText
        case .history:
            data = Data(Invasion3DExport.historyCSV(controller.history).utf8)
            name = "\(study.title) – 3D history.csv"
            type = .commaSeparatedText
        case .record:
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
            let device = controller.renderer?.device.name ?? "unknown"
            let record = Invasion3DRunRecord(
                application: "Fluid MechLab \(version)", study: study.title, solver: "Metal GPU, red-black line SOR + \(snap.setup.options.scheme.title)",
                device: device, setup: snap.setup, finalStats: controller.stats, skin: controller.skin, history: controller.history)
            guard let json = try? record.json() else { return }
            data = json
            name = "\(base) run record.json"
            type = .json
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url)
    }
}

// MARK: - Inspector

/// Inspector section for the 3D model's rock structure and numerics.
struct Invasion3DInspector: View {
    @Binding var options: Invasion3DOptions

    private var autoDepth: Binding<Bool> {
        Binding(get: { options.domainDepth == nil }, set: { options.domainDepth = $0 ? nil : 8 })
    }

    private var depth: Binding<Double> {
        Binding(get: { options.domainDepth ?? 8 }, set: { options.domainDepth = $0 })
    }

    var body: some View {
        Section {
            ParameterRow(title: "Heterogeneity σ ln k", value: $options.heterogeneity, range: 0...1.5, digits: 2,
                         help: "Standard deviation of ln k. 0 gives uniform rock.")
            ParameterRow(title: "Bedding correlation", value: $options.horizontalCorrelation, range: 0.2...12, quantity: .invasionDepth, digits: 1,
                         help: "Size of permeability features along the bedding.")
            ParameterRow(title: "Layer correlation", value: $options.verticalCorrelation, range: 0.05...12, quantity: .invasionDepth, digits: 2,
                         help: "Size of features across the bedding. Shorter than the bedding correlation gives laminated rock.")
            ParameterRow(title: "kv/kh", value: $options.anisotropy, range: 0.01...1, digits: 3, logarithmic: true,
                         help: "Vertical to horizontal permeability ratio.")
            ParameterRow(title: "Interval length", value: $options.intervalLength, range: 2...48, quantity: .invasionDepth, digits: 1,
                         help: "Length of borehole simulated. Top and bottom are sealed.")
            Toggle("Size rock from 1D invasion depth", isOn: autoDepth)
            if options.domainDepth != nil {
                ParameterRow(title: "Rock beyond wall", value: depth, range: 1...36, quantity: .invasionDepth, digits: 1)
            }
            Stepper("Field seed: \(options.seed)", value: Binding(get: { Int(options.seed) }, set: { options.seed = UInt64(max($0, 0)) }), in: 0...9999)
        } header: {
            Text("3D rock structure")
        } footer: {
            Text("Changing these rebuilds the grid and restarts the run. The seed makes a permeability realisation reproducible.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section {
            Picker("Grid", selection: $options.resolution) {
                ForEach(Invasion3DOptions.Resolution.allCases) { r in
                    let d = r.dimensions
                    Text("\(r.title) – \(d.radial)×\(d.angular)×\(d.axial)").tag(r)
                }
            }
            Picker("Transport", selection: $options.scheme) {
                ForEach(Invasion3DOptions.Scheme.allCases) { Text($0.title).tag($0) }
            }
            Picker("Cake coupling ε", selection: $options.cakeCoupling) {
                Text("0.04 (fast)").tag(0.04)
                Text("0.02").tag(0.02)
                Text("0.01").tag(0.01)
                Text("0.005 (precise)").tag(0.005)
            }
            .help("Largest relative change of a wall conductance between pressure solves. The cake coupling error is proportional to it (about 0.2 ε).")
            Picker("Pressure tolerance", selection: $options.pressureTolerance) {
                Text("1e-4").tag(1e-4)
                Text("2e-5").tag(2e-5)
                Text("5e-6").tag(5e-6)
            }
            .help("Relative balance of wall inflow and outer outflow at which the pressure solve stops (single precision limits this to about 1e-6).")
        } header: {
            Text("3D numerics")
        } footer: {
            Text("Research grids hold 2.4 million cells and run best on Apple silicon with 16 GB or more. Use Verify to check accuracy.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
