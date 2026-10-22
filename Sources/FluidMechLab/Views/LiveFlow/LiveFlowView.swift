import FlowCore
import FlowGPU
import MetalKit
import SwiftUI

/// State shared between the live view's SwiftUI controls and its Metal renderer.
@MainActor
@Observable
final class LiveFlowController {
    var isPlaying = true
    /// Seconds of screen time for the whole mud exposure.
    var playbackSeconds: Double = 30
    var field: LiveField = .filtrate
    var showParticles = true
    var showReference = true
    var background: (r: Double, g: Double, b: Double) = (0.95, 0.95, 0.96)
    private(set) var stats = LiveInvasionStats()
    private(set) var isFinished = false
    private(set) var errorMessage: String?
    private(set) var setup: LiveInvasionSetup?

    @ObservationIgnored private var history: [InvasionHistoryPoint] = []
    @ObservationIgnored private(set) var renderer: LiveFlowRenderer?

    /// The external cake is millimetres thick on a borehole inches across, so it is drawn enlarged.
    static let cakeExaggeration = 8.0

    /// Half-width of the visible area, m.
    static func viewExtent(_ setup: LiveInvasionSetup) -> Double { setup.domainRadius * 1.06 }

    var exposureHours: Double { (setup?.exposureTime ?? 0) / 3600 }

    func attach(_ renderer: LiveFlowRenderer) {
        self.renderer = renderer
        renderer.controller = self
        if let setup { start(setup) }
    }

    func configure(_ setup: LiveInvasionSetup, history: [InvasionHistoryPoint]) {
        self.setup = setup
        self.history = history
        start(setup)
    }

    func restart() {
        if let setup { start(setup) }
    }

    func fail(_ message: String) {
        errorMessage = message
        LiveFlowSnapshotRegistry.shared.lastError = message
    }

    func receive(stats: LiveInvasionStats, finished: Bool) {
        self.stats = stats
        if finished && !isFinished { isPlaying = false }
        isFinished = finished
    }

    /// Filtrate front depth from the 1D model at the given time, inches.
    func referenceFrontDepth(atHours t: Double) -> Double? {
        guard showReference, let first = history.first, history.count > 1 else { return nil }
        if t <= first.time { return first.filtrateFrontDepth }
        for (a, b) in zip(history, history.dropFirst()) where t <= b.time {
            let f = (t - a.time) / max(b.time - a.time, 1e-12)
            return a.filtrateFrontDepth + f * (b.filtrateFrontDepth - a.filtrateFrontDepth)
        }
        return history.last?.filtrateFrontDepth
    }

    private func start(_ setup: LiveInvasionSetup) {
        guard let renderer else { return }
        do {
            try renderer.reset(setup: setup)
            errorMessage = nil
            stats = LiveInvasionStats()
            isFinished = false
            isPlaying = true
        } catch {
            fail(String(describing: error))
        }
    }
}

/// Lets the screenshot runner capture the Metal view, which window snapshots cannot see.
@MainActor
final class LiveFlowSnapshotRegistry {
    static let shared = LiveFlowSnapshotRegistry()
    weak var view: MTKView?
    weak var controller: LiveFlowController?
    var lastError: String?

    func snapshot() -> CGImage? {
        guard let view, let renderer = controller?.renderer else { return nil }
        return renderer.snapshot(size: view.drawableSize)
    }
}

/// The MTKView that shows the simulation.
struct LiveFlowMetalView: NSViewRepresentable {
    let controller: LiveFlowController

    final class Coordinator {
        // MTKView holds its delegate weakly.
        var renderer: LiveFlowRenderer?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.colorPixelFormat = .bgra8Unorm
        view.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        view.preferredFramesPerSecond = 120
        guard let device = MTLCreateSystemDefaultDevice() else {
            controller.fail("This Mac has no Metal device.")
            return view
        }
        view.device = device
        do {
            let renderer = try LiveFlowRenderer(device: device)
            context.coordinator.renderer = renderer
            view.delegate = renderer
            controller.attach(renderer)
            LiveFlowSnapshotRegistry.shared.view = view
            LiveFlowSnapshotRegistry.shared.controller = controller
        } catch {
            controller.fail("The Metal shaders did not compile: \(error.localizedDescription)")
        }
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {}
}

/// The Live Flow pane: a real-time GPU simulation of mud invasion around the borehole.
struct LiveFlowView: View {
    let study: StudyCase

    @Environment(SimulationModel.self) private var sim
    @Environment(\.unitSystem) private var units
    @Environment(\.colorScheme) private var colorScheme
    @State private var controller = LiveFlowController()
    @AppStorage("liveHeterogeneity") private var heterogeneity = 0.6
    @AppStorage("liveResolution") private var resolution = 256

    private struct Config: Equatable {
        let mud: MudInvasionCase
        let depth: Double?
        let heterogeneity: Double
        let resolution: Int
    }

    private var config: Config {
        Config(mud: study.damageCase, depth: sim.damage.map { ($0.filtrateInvasionDepth * 10).rounded() / 10 },
               heterogeneity: heterogeneity, resolution: resolution)
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                LiveFlowMetalView(controller: controller)
                overlays
                if let error = controller.errorMessage {
                    ContentUnavailableView("Live view unavailable", systemImage: "exclamationmark.triangle", description: Text(error))
                        .background(.background)
                }
            }
            Divider()
            LiveFlowControlBar(controller: controller, heterogeneity: $heterogeneity)
        }
        .task(id: config) {
            let c = config
            let setup = await Task.detached(priority: .userInitiated) {
                LiveInvasionSetup(c.mud, size: c.resolution, invasionDepth: c.depth, heterogeneity: c.heterogeneity)
            }.value
            guard !Task.isCancelled else { return }
            controller.configure(setup, history: sim.damage?.history ?? [])
        }
        .onAppear { updateBackground() }
        .onChange(of: colorScheme) { updateBackground() }
    }

    private func updateBackground() {
        controller.background = colorScheme == .dark ? (0.11, 0.11, 0.12) : (0.95, 0.95, 0.96)
    }

    private var overlays: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                LiveFlowHUD(controller: controller)
                    .padding(16)
                LiveFlowLegend(controller: controller)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .topTrailing)
                if let setup = controller.setup {
                    ScaleBar(pointsPerMetre: min(geometry.size.width, geometry.size.height) / 2 / LiveFlowController.viewExtent(setup))
                        .padding(16)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
            }
        }
    }
}

// MARK: - Overlays

private struct LiveFlowHUD: View {
    let controller: LiveFlowController
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
                row("Filtrate front", Quantity.invasionDepth.format(s.filtrateDepth, digits: 1, in: units))
                row("Deepest finger", Quantity.invasionDepth.format(s.maxFiltrateDepth, digits: 1, in: units))
                row("Mud cake", "\(s.cakeThickness.formatted(digits: 2)) mm")
                row("Fluid loss rate", "\(s.filtrationRate.formatted(digits: s.filtrationRate < 1 ? 3 : 1)) cm/h")
                row("Total filtrate", "\(s.cumulativeFiltrate.formatted(digits: 2)) cm")
                row("Lowest k/k₀", s.minPermeabilityRatio.formatted(digits: 2))
            }
            .font(.caption)
        }
        .padding(12)
        .frame(width: 230, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).monospacedDigit().gridColumnAlignment(.trailing)
        }
    }
}

private struct LiveFlowLegend: View {
    let controller: LiveFlowController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(controller.field.title).font(.caption.weight(.semibold))
            LinearGradient(colors: controller.field.swatches, startPoint: .leading, endPoint: .trailing)
                .frame(width: 180, height: 10)
                .clipShape(RoundedRectangle(cornerRadius: 3))
            HStack {
                Text(controller.field.legend.low)
                Spacer()
                Text(controller.field.legend.high)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            if controller.showParticles {
                Label("Tracers follow the filtrate flow", systemImage: "circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if controller.showReference {
                Label("Dashed ring: 1D model front", systemImage: "circle.dashed")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Label("Mud cake drawn ×\(Int(LiveFlowController.cakeExaggeration))", systemImage: "circle.circle")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 204, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct ScaleBar: View {
    let pointsPerMetre: Double
    @Environment(\.unitSystem) private var units

    var body: some View {
        let unitLength = units == .si ? 0.01 : 0.0254
        let unitName = units == .si ? "cm" : "in"
        let target = 120 / pointsPerMetre / unitLength
        let length = [0.5, 1, 2, 3, 5, 10, 20].last { $0 <= target } ?? 0.5
        VStack(alignment: .leading, spacing: 3) {
            Rectangle()
                .frame(width: length * unitLength * pointsPerMetre, height: 3)
                .overlay(alignment: .leading) { Rectangle().frame(width: 1.5, height: 9) }
                .overlay(alignment: .trailing) { Rectangle().frame(width: 1.5, height: 9) }
            Text("\(length.formatted(digits: length < 1 ? 1 : 0)) \(unitName)").font(.caption2.monospacedDigit())
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct LiveFlowControlBar: View {
    @Bindable var controller: LiveFlowController
    @Binding var heterogeneity: Double

    var body: some View {
        HStack(spacing: 14) {
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
                .frame(minWidth: 80, maxWidth: 220)

            Picker("Show", selection: $controller.field) {
                ForEach(LiveField.allCases) { Text($0.title).tag($0) }
            }
            .fixedSize()

            Picker("Duration", selection: $controller.playbackSeconds) {
                Text("15 s").tag(15.0)
                Text("30 s").tag(30.0)
                Text("1 min").tag(60.0)
                Text("2 min").tag(120.0)
                Text("5 min").tag(300.0)
            }
            .fixedSize()
            .help("Screen time for the whole exposure")

            Toggle("Tracers", isOn: $controller.showParticles)
            Toggle("1D front", isOn: $controller.showReference)

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                Text("Heterogeneity").font(.caption).foregroundStyle(.secondary)
                Slider(value: $heterogeneity, in: 0...1.2).frame(width: 110).controlSize(.small)
            }
            .help("Spread of permeability in the rock (standard deviation of ln k). Changing it restarts the run.")
        }
        .toggleStyle(.checkbox)
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

extension LiveField {
    /// Swift copies of the shader colour ramps, for the legend.
    var swatches: [Color] {
        let sand = Color(red: 0.87, green: 0.80, blue: 0.64)
        switch self {
        case .filtrate: return [sand, Color(red: 0.30, green: 0.60, blue: 0.92), Color(red: 0.06, green: 0.20, blue: 0.62)]
        case .damage: return [sand, Color(red: 0.96, green: 0.56, blue: 0.18), Color(red: 0.55, green: 0.05, blue: 0.08)]
        case .permeability: return [Color(red: 0.27, green: 0, blue: 0.33), Color(red: 0.13, green: 0.57, blue: 0.55), Color(red: 0.99, green: 0.91, blue: 0.14)]
        case .fines: return [sand, Color(red: 0.70, green: 0.45, blue: 0.80), Color(red: 0.32, green: 0.10, blue: 0.45)]
        case .pressure: return [Color(red: 0.12, green: 0.22, blue: 0.55), Color(red: 0.20, green: 0.72, blue: 0.62), Color(red: 0.98, green: 0.84, blue: 0.25)]
        }
    }
}
