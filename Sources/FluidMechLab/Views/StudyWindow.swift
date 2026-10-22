import FlowCore
import SwiftUI
import UniformTypeIdentifiers

/// One document window: sidebar, detail pane, inspector and toolbar.
struct StudyWindow: View {
    @Binding var document: StudyDocument

    @State private var sim = SimulationModel()
    @State private var section: StudySection? = .architecture
    @State private var showInspector = true
    @State private var showPresets = false
    @State private var isExporting = false
    @State private var exportDocument = CSVDocument()
    @AppStorage("unitSystem") private var unitSystem: UnitSystem = .field

    private var current: StudySection { section ?? .architecture }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
                .frame(minWidth: 640, minHeight: 520)
        }
        .navigationSubtitle(current.title)
        .inspector(isPresented: $showInspector) {
            InspectorView(section: current, study: $document.study)
                .inspectorColumnWidth(min: 320, ideal: 380, max: 480)
        }
        .toolbar { toolbarContent }
        .environment(\.unitSystem, unitSystem)
        .environment(sim)
        .task(id: document.study) {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            await sim.update(for: document.study)
        }
        .task {
            await SnapshotRunner.runIfRequested(
                select: { section = $0 },
                applyPreset: { name in
                    if let p = StudyPreset.all.first(where: { $0.name == name }) { document.study = p.applied(to: document.study) }
                },
                showPresets: { showPresets = $0 },
                units: { unitSystem = $0 })
        }
        .sheet(isPresented: $showPresets) {
            PresetLibrary(study: $document.study)
        }
        .fileExporter(isPresented: $isExporting, document: exportDocument, contentType: .commaSeparatedText,
                      defaultFilename: "\(document.study.title) – \(current.title).csv") { _ in }
        .focusedSceneValue(\.studyActions, actions)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $section) {
            Section("Model") {
                ForEach(StudySection.modelSections) { s in
                    NavigationLink(value: s) { Label(s.title, systemImage: s.systemImage) }
                }
            }
            Section("Simulation") {
                ForEach(StudySection.simulationSections) { s in
                    NavigationLink(value: s) { Label(s.title, systemImage: s.systemImage) }
                        .badge(badge(for: s))
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                Text(document.study.title).font(.caption.weight(.semibold)).lineLimit(1)
                Text(document.study.basedOn.map { "Based on \($0)" } ?? document.study.well.name)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
    }

    private func badge(for s: StudySection) -> Text? {
        switch s {
        case .damage:
            return sim.damage.map { Text("S \($0.skin.formatted(digits: 1))") }
        case .nodal:
            guard let nodal = sim.nodal else { return nil }
            guard let rate = nodal.operatingPoint?.rate else { return Text("no flow") }
            return Text(Quantity.liquidRate.display(rate, in: unitSystem).formatted(digits: 0))
        default:
            return nil
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        switch current {
        case .architecture:
            WellArchitectureView(study: $document.study, openPresets: { showPresets = true })
        case .model3D:
            Model3DPane(study: document.study)
        case .fluid:
            PVTView(study: document.study)
        case .damage:
            FormationDamageView(study: document.study)
        case .liveFlow:
            LiveFlowView(study: document.study)
        case .nodal:
            NodalView(study: document.study)
        case .sensitivity:
            SensitivityView(study: document.study)
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .status) {
            if sim.isRunning {
                ProgressView().controlSize(.small)
            } else {
                Text(sim.lastRunDuration > 0 ? "Solved in \(Int(sim.lastRunDuration * 1000)) ms" : "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                ForEach(StudyPreset.Category.allCases) { category in
                    Section(category.rawValue) {
                        ForEach(StudyPreset.presets(in: category)) { preset in
                            Button(preset.name) { document.study = preset.applied(to: document.study) }
                        }
                    }
                }
                Divider()
                Button("Preset Library…") { showPresets = true }
            } label: {
                Label("Presets", systemImage: "square.stack.3d.up")
            }
            .help("Load an industry preset")

            Picker("Units", selection: $unitSystem) {
                ForEach(UnitSystem.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .help("Display units")

            Button {
                if sim.hasReference { sim.clearReference() } else { keepReference() }
            } label: {
                Label(sim.hasReference ? "Clear Reference" : "Keep as Reference", systemImage: sim.hasReference ? "pin.slash" : "pin")
            }
            .help(sim.hasReference ? "Remove the dashed reference curves" : "Keep the current results as dashed reference curves to compare against")

            Button(action: exportCSV) {
                Label("Export CSV", systemImage: "square.and.arrow.up")
            }
            .help("Export the current section's results as CSV")

            Button { showInspector.toggle() } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .help("Show or hide the inspector")
        }
    }

    // MARK: Actions

    private var actions: StudyActions {
        StudyActions(
            select: { section = $0 },
            rerun: { Task { await sim.update(for: document.study, force: true) } },
            keepReference: keepReference,
            clearReference: { sim.clearReference() },
            showPresets: { showPresets = true },
            toggleInspector: { showInspector.toggle() },
            exportCSV: exportCSV,
            hasReference: sim.hasReference)
    }

    private func keepReference() {
        let label = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
        sim.keepAsReference(label: "\(document.study.title), \(label)")
    }

    private func exportCSV() {
        exportDocument = CSVDocument(text: ResultExporter.csv(for: current, study: document.study, sim: sim, units: unitSystem))
        isExporting = true
    }
}
