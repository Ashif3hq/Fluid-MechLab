import FlowCore
import SwiftUI

/// Template-chooser style sheet for the industry presets.
struct PresetLibrary: View {
    @Binding var study: StudyCase
    @Environment(\.dismiss) private var dismiss
    @State private var category: StudyPreset.Category = .field
    @State private var selection: StudyPreset.ID?

    private var presets: [StudyPreset] { StudyPreset.presets(in: category) }
    private var selected: StudyPreset? { StudyPreset.all.first { $0.id == selection } }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Preset Library").font(.title2.weight(.semibold))
                Picker("Category", selection: $category) {
                    ForEach(StudyPreset.Category.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(category.summary).font(.callout).foregroundStyle(.secondary)
            }
            .padding(20)

            Divider()

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 14)], spacing: 14) {
                    ForEach(presets) { preset in
                        PresetCard(preset: preset, isSelected: preset.id == selection)
                            .onTapGesture(count: 2) { apply(preset) }
                            .onTapGesture { selection = preset.id }
                    }
                }
                .padding(20)
            }
            .background(.background.secondary)

            Divider()

            HStack {
                if let selected {
                    Text(selected.category == .field ? "Replaces the whole study." : "Changes only part of the study. Undo with ⌘Z.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") { if let selected { apply(selected) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected == nil)
            }
            .padding(16)
        }
        .frame(width: 820, height: 580)
        .onChange(of: category) { _, _ in selection = nil }
    }

    private func apply(_ preset: StudyPreset) {
        study = preset.applied(to: study)
        dismiss()
    }
}

private struct PresetCard: View {
    let preset: StudyPreset
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(gradient)
                Image(systemName: symbol)
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.white)
                    .shadow(radius: 2)
            }
            .frame(height: 64)
            Text(preset.name).font(.headline).lineLimit(2)
            Text(preset.summary).font(.caption).foregroundStyle(.secondary).lineLimit(4)
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(height: 190, alignment: .top)
        .background(.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: isSelected ? 3 : 1)
        )
        .contentShape(Rectangle())
    }

    private var symbol: String {
        if let specific = Self.symbols[preset.name] { return specific }
        return switch preset.category {
        case .field: "globe.europe.africa.fill"
        case .damage: "circle.dashed.inset.filled"
        case .mud: "drop.circle.fill"
        case .rock: "square.stack.3d.down.forward.fill"
        }
    }

    private static let symbols: [String: String] = [
        "Giant Carbonate, Light Oil": "sun.max.fill",
        "Deepwater Turbidite Sandstone": "water.waves",
        "North Sea Sandstone": "wind",
        "Mature Onshore Waterflood": "drop.triangle.fill",
        "Heavy Oil Sand": "thermometer.sun.fill",
        "Tight Sandstone": "square.grid.3x3.fill",
        "HPHT Deep Reservoir": "flame.fill",
        "Fines Plugging During Spurt": "aqi.medium",
        "Clay Swelling by Fresh-Water Filtrate": "humidity.fill",
        "Water Block in Tight Sand": "drop.degreesign.fill",
        "Optimised Drill-In Fluid": "checkmark.seal.fill",
        "High-Overbalance HPHT Exposure": "gauge.with.dots.needle.100percent",
        "Long Static Exposure (Rig Downtime)": "clock.fill",
        "Bentonite Water-Based Mud": "drop.fill",
        "Polymer WBM (XC/PAC)": "link",
        "Oil-Based Mud (Invert Emulsion)": "drop.halffull",
        "Reservoir Drill-In Fluid (Sized CaCO₃)": "circle.grid.cross.fill",
        "Fresh-Water Mud, Poor Fluid-Loss Control": "exclamationmark.triangle.fill",
        "Clean Sandstone (Berea-Type)": "circle.hexagongrid.fill",
        "Clay-Rich Sandstone": "square.3.layers.3d.down.right",
        "Tight Gas Sandstone": "circle.dotted",
        "Vuggy Carbonate": "bubbles.and.sparkles.fill",
        "Chalk": "cube.fill",
    ]

    private var gradient: LinearGradient {
        let colors: [Color]
        switch preset.category {
        case .field: colors = [Color(red: 0.10, green: 0.35, blue: 0.62), Color(red: 0.18, green: 0.62, blue: 0.70)]
        case .damage: colors = [Color(red: 0.70, green: 0.20, blue: 0.18), Color(red: 0.92, green: 0.55, blue: 0.25)]
        case .mud: colors = [Color(red: 0.38, green: 0.27, blue: 0.20), Color(red: 0.65, green: 0.50, blue: 0.35)]
        case .rock: colors = [Color(red: 0.62, green: 0.52, blue: 0.30), Color(red: 0.88, green: 0.76, blue: 0.48)]
        }
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
