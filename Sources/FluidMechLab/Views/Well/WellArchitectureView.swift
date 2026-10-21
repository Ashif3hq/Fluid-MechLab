import Charts
import FlowCore
import SwiftUI

/// Well construction editor: schematic on the left, editable tables on the right.
struct WellArchitectureView: View {
    @Binding var study: StudyCase
    var openPresets: () -> Void

    @Environment(SimulationModel.self) private var sim
    @Environment(\.unitSystem) private var units
    @State private var tab: Tab = .casing
    @State private var selectedCasing: CasingString.ID?
    @State private var selectedPerforation: PerforationInterval.ID?

    enum Tab: String, CaseIterable, Identifiable {
        case casing = "Casing Program"
        case completion = "Completion"
        case trajectory = "Trajectory"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            if study.basedOn == nil && study.title == "Untitled Study" {
                PresetBanner(openPresets: openPresets)
            }
            HSplitView {
                ChartCard(title: study.well.name, subtitle: "Schematic, not to radial scale") {
                    WellSchematic(well: study.well, damage: sim.damage, highlightedCasing: selectedCasing)
                        .frame(minHeight: 480)
                }
                .padding(16)
                .frame(minWidth: 380, idealWidth: 460, maxWidth: 620)

                VStack(alignment: .leading, spacing: 12) {
                    Picker("Section", selection: $tab) {
                        ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 420)

                    switch tab {
                    case .casing: casingEditor
                    case .completion: completionEditor
                    case .trajectory: trajectoryPanel
                    }

                    ValidationList(messages: study.well.validationMessages)
                }
                .padding(16)
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    // MARK: Casing

    private var casingEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Table(study.well.casings, selection: $selectedCasing) {
                TableColumn("String") { c in Text(c.name).fontWeight(c.id == selectedCasing ? .semibold : .regular) }
                    .width(min: 80, ideal: 100)
                TableColumn("OD") { c in Text(pipeSizeLabel(c.outerDiameter)).monospacedDigit() }
                    .width(44)
                TableColumn("ID (\(Quantity.diameter.symbol(units)))") { c in
                    Text(Quantity.diameter.display(c.innerDiameter, in: units).formatted(digits: units == .si ? 1 : 3)).monospacedDigit()
                }
                .width(62)
                TableColumn("Hole") { c in Text(pipeSizeLabel(c.holeSize)).monospacedDigit() }
                    .width(44)
                TableColumn("Top (\(Quantity.depth.symbol(units)))") { c in depthText(c.top) }
                    .width(min: 56, ideal: 64)
                TableColumn("Shoe (\(Quantity.depth.symbol(units)))") { c in depthText(c.shoe) }
                    .width(min: 56, ideal: 64)
                TableColumn("TOC (\(Quantity.depth.symbol(units)))") { c in depthText(c.topOfCement) }
                    .width(min: 56, ideal: 64)
            }
            .frame(minHeight: 150, maxHeight: 220)

            HStack(spacing: 0) {
                Button { addCasing() } label: { Image(systemName: "plus").frame(width: 22, height: 18) }
                    .help("Add a string inside the innermost one")
                Divider().frame(height: 16)
                Button { removeCasing() } label: { Image(systemName: "minus").frame(width: 22, height: 18) }
                    .disabled(selectedCasing == nil)
                    .help("Remove the selected string")
                Spacer()
                Text("Select a string to edit it.").font(.caption).foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)

            if let index = study.well.casings.firstIndex(where: { $0.id == selectedCasing }) {
                GroupBox {
                    Form {
                        TextField("Name", text: $study.well.casings[index].name)
                        ParameterRow(title: "Outer diameter", value: $study.well.casings[index].outerDiameter, range: 4...36, quantity: .diameter, digits: 3)
                        ParameterRow(title: "Inner diameter", value: $study.well.casings[index].innerDiameter, range: 3...35, quantity: .diameter, digits: 3)
                        ParameterRow(title: "Hole size", value: $study.well.casings[index].holeSize, range: 4...42, quantity: .diameter, digits: 3)
                        ParameterRow(title: "Top (liner hanger)", value: $study.well.casings[index].top, range: 0...25000, quantity: .depth, digits: 0)
                        ParameterRow(title: "Shoe depth", value: $study.well.casings[index].shoe, range: 50...25000, quantity: .depth, digits: 0)
                        ParameterRow(title: "Top of cement", value: $study.well.casings[index].topOfCement, range: 0...25000, quantity: .depth, digits: 0)
                    }
                    .formStyle(.columns)
                } label: {
                    Label("\(study.well.casings[index].name) string", systemImage: "cylinder.split.1x2")
                }
            }
        }
    }

    private func depthText(_ md: Double) -> some View {
        Text(Quantity.depth.display(md, in: units).formatted(digits: 0)).monospacedDigit()
    }

    private func addCasing() {
        let innermost = study.well.casings.min { $0.outerDiameter < $1.outerDiameter }
        let od = max((innermost?.innerDiameter ?? 8) - 1.5, 4.5)
        let new = CasingString(name: "Liner", outerDiameter: od, innerDiameter: od - 0.6,
                               top: max((innermost?.shoe ?? 0) - 300, 0), shoe: study.well.totalDepth,
                               holeSize: (innermost?.innerDiameter ?? od + 1.5) - 0.1)
        study.well.casings.append(new)
        selectedCasing = new.id
    }

    private func removeCasing() {
        study.well.casings.removeAll { $0.id == selectedCasing }
        selectedCasing = nil
    }

    // MARK: Completion

    private var completionEditor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                GroupBox {
                    Form {
                        ParameterRow(title: "Tubing OD", value: $study.well.tubing.outerDiameter, range: 1.5...7.5, quantity: .diameter, digits: 3,
                                     help: "Outer diameter of the production tubing.")
                        ParameterRow(title: "Tubing ID", value: $study.well.tubing.innerDiameter, range: 1...7, quantity: .diameter, digits: 3,
                                     help: "Flow diameter used by the multiphase outflow model.")
                        ParameterRow(title: "Tubing shoe", value: $study.well.tubing.shoe, range: 100...25000, quantity: .depth, digits: 0)
                        ParameterRow(title: "Roughness", value: $study.well.tubing.roughness, range: 0.00001...0.01, quantity: .diameter, digits: 5, logarithmic: true,
                                     help: "Absolute wall roughness. New steel ≈ 0.0006 in; scaled or corroded tubing is rougher.")
                        ParameterRow(title: "Packer depth", value: $study.well.packerDepth, range: 100...25000, quantity: .depth, digits: 0)
                    }
                    .formStyle(.columns)
                } label: {
                    Label("Tubing and packer", systemImage: "pipe.and.drop")
                }

                GroupBox {
                    VStack(alignment: .leading) {
                        Table(study.well.perforations, selection: $selectedPerforation) {
                            TableColumn("Top") { p in Text(Quantity.depth.format(p.top, digits: 0, in: units)).monospacedDigit() }
                            TableColumn("Bottom") { p in Text(Quantity.depth.format(p.bottom, digits: 0, in: units)).monospacedDigit() }
                            TableColumn("Length") { p in Text(Quantity.depth.format(p.bottom - p.top, digits: 0, in: units)).monospacedDigit() }
                            TableColumn("Shots/ft") { p in Text(p.shotDensity.formatted(digits: 0)).monospacedDigit() }
                        }
                        .frame(height: 110)
                        HStack(spacing: 0) {
                            Button { addPerforation() } label: { Image(systemName: "plus").frame(width: 22, height: 18) }
                            Divider().frame(height: 16)
                            Button {
                                study.well.perforations.removeAll { $0.id == selectedPerforation }
                                selectedPerforation = nil
                            } label: { Image(systemName: "minus").frame(width: 22, height: 18) }
                                .disabled(selectedPerforation == nil)
                            Spacer()
                        }
                        .buttonStyle(.borderless)
                        if let i = study.well.perforations.firstIndex(where: { $0.id == selectedPerforation }) {
                            Form {
                                ParameterRow(title: "Top", value: $study.well.perforations[i].top, range: 0...25000, quantity: .depth, digits: 0)
                                ParameterRow(title: "Bottom", value: $study.well.perforations[i].bottom, range: 0...25000, quantity: .depth, digits: 0)
                                ParameterRow(title: "Shot density", value: $study.well.perforations[i].shotDensity, range: 1...24, quantity: .dimensionless, digits: 0)
                            }
                            .formStyle(.columns)
                        }
                    }
                } label: {
                    Label("Perforated intervals", systemImage: "dot.radiowaves.left.and.right")
                }
            }
        }
    }

    private func addPerforation() {
        let top = study.well.measuredDepth(atTVD: study.well.reservoirTop) + 5
        let bottom = study.well.measuredDepth(atTVD: study.well.reservoirBottom) - 5
        let new = PerforationInterval(top: top, bottom: max(bottom, top + 10))
        study.well.perforations.append(new)
        selectedPerforation = new.id
    }

    // MARK: Trajectory

    private var trajectoryPanel: some View {
        let survey = study.well.survey(interval: 100)
        return VStack(alignment: .leading, spacing: 12) {
            ChartCard(title: "Vertical section", subtitle: "True vertical depth against horizontal displacement") {
                Chart {
                    ForEach(survey) { s in
                        LineMark(x: .value("Displacement", Quantity.depth.display(s.horizontalDisplacement, in: units)),
                                 y: .value("TVD", Quantity.depth.display(s.trueVerticalDepth, in: units)))
                            .foregroundStyle(.blue)
                    }
                    RectangleMark(xStart: .value("Start", 0.0),
                                  xEnd: .value("End", Quantity.depth.display(max(survey.map(\.horizontalDisplacement).max() ?? 0, 300), in: units)),
                                  yStart: .value("Top", Quantity.depth.display(study.well.reservoirTop, in: units)),
                                  yEnd: .value("Bottom", Quantity.depth.display(study.well.reservoirBottom, in: units)))
                        .foregroundStyle(.yellow.opacity(0.3))
                }
                .chartYScale(domain: .automatic(includesZero: true, reversed: true))
                .chartXAxisLabel(Quantity.depth.axisLabel("Horizontal displacement", in: units))
                .chartYAxisLabel(Quantity.depth.axisLabel("TVD", in: units))
                .frame(height: 220)
            }
            Table(survey) {
                TableColumn("MD") { s in Text(Quantity.depth.format(s.measuredDepth, digits: 0, in: units)).monospacedDigit() }
                TableColumn("Inclination") { s in Text("\(s.inclination.formatted(digits: 1))°").monospacedDigit() }
                TableColumn("Azimuth") { s in Text("\(s.azimuth.formatted(digits: 0))°").monospacedDigit() }
                TableColumn("TVD") { s in Text(Quantity.depth.format(s.trueVerticalDepth, digits: 0, in: units)).monospacedDigit() }
                TableColumn("North") { s in Text(Quantity.depth.format(s.north, digits: 0, in: units)).monospacedDigit() }
                TableColumn("East") { s in Text(Quantity.depth.format(s.east, digits: 0, in: units)).monospacedDigit() }
            }
            .frame(minHeight: 160)
            Text("Edit the kick-off point, build rate and hold angle in the inspector.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Shown on brand-new studies to point at the preset library.
struct PresetBanner: View {
    var openPresets: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Start from an industry preset").font(.headline)
                Text("Field scenarios, mud systems, rock types and formation damage studies.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Browse Presets…", action: openPresets)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.tint.opacity(0.08))
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// Engineering checks on the well architecture.
struct ValidationList: View {
    let messages: [String]

    var body: some View {
        if messages.isEmpty {
            Label("Well architecture is consistent.", systemImage: "checkmark.seal.fill")
                .font(.caption)
                .foregroundStyle(.green)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(messages, id: \.self) { m in
                    Label(m, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }
}
