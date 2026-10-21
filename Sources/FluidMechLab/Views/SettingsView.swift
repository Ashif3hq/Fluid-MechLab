import FlowCore
import SwiftUI

/// Fluid MechLab ▸ Settings (⌘,).
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            DisplaySettings()
                .tabItem { Label("3D Model", systemImage: "cube.transparent") }
        }
        .frame(width: 460)
        .padding(20)
    }
}

private struct GeneralSettings: View {
    @AppStorage("unitSystem") private var unitSystem: UnitSystem = .field
    @AppStorage("showInspectorSliders") private var showSliders = true

    var body: some View {
        Form {
            Picker("Units:", selection: $unitSystem) {
                Text("Field (psi, ft, STB/d, °F)").tag(UnitSystem.field)
                Text("SI (bar, m, m³/d, °C)").tag(UnitSystem.si)
            }
            .pickerStyle(.radioGroup)
            Toggle("Show sliders under inspector values", isOn: $showSliders)
            Text("Calculations always run in oilfield units; SI only changes what you see and type.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct DisplaySettings: View {
    @AppStorage("radialExaggeration") private var exaggeration = 150.0

    var body: some View {
        Form {
            Slider(value: $exaggeration, in: 20...400) {
                Text("Radial exaggeration:")
            } minimumValueLabel: {
                Text("×20")
            } maximumValueLabel: {
                Text("×400")
            }
            Text("Pipe and damage radii are enlarged so they are visible against thousands of feet of depth.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
