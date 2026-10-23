import Charts
import FlowCore
import SwiftUI

struct FormationDamageView: View {
    let study: StudyCase
    @Environment(SimulationModel.self) private var sim
    @Environment(\.unitSystem) private var units

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PaneHeader(section: .damage, trailing: sim.isRunning ? "Simulating…" : nil)
                if let result = sim.damage {
                    DamageResults(study: study, result: result, reference: sim.damageReference)
                } else {
                    ProgressView("Simulating mud invasion…")
                        .frame(maxWidth: .infinity, minHeight: 300)
                }
            }
            .padding(20)
        }
    }
}

private struct DamageResults: View {
    let study: StudyCase
    let result: MudInvasionResult
    let reference: ReferenceRun<MudInvasionResult>?

    @Environment(\.unitSystem) private var units

    /// Profile extent: a little beyond the deepest damage.
    private var extent: Double {
        max(result.filtrateInvasionDepth, result.solidsInvasionDepth, reference?.result.filtrateInvasionDepth ?? 0) * 1.3 + 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StatGrid {
                StatTile(title: "Damage skin", value: result.skin.formatted(digits: 2),
                         detail: reference.map { "reference \($0.result.skin.formatted(digits: 2))" } ?? "after mud-cake lift-off",
                         systemImage: "gauge.with.dots.needle.67percent", tint: result.skin > 2 ? .red : .orange)
                StatTile(title: "Productivity ratio", value: "\((result.productivityRatio * 100).formatted(digits: 1)) %",
                         detail: "damaged ÷ undamaged productivity", systemImage: "arrow.down.right")
                StatTile(title: "Filtrate invasion", value: Quantity.invasionDepth.format(result.filtrateInvasionDepth, digits: 1, in: units),
                         detail: "beyond the borehole wall", systemImage: "drop.triangle")
                StatTile(title: "Solids invasion", value: Quantity.invasionDepth.format(result.solidsInvasionDepth, digits: 2, in: units),
                         detail: "internal filter cake", systemImage: "circle.grid.3x3")
                StatTile(title: "Mud cake", value: "\(result.finalCakeThickness.formatted(digits: 2)) mm",
                         detail: "spurt loss \(result.spurtLoss.formatted(digits: 3)) cm³/cm²", systemImage: "square.3.layers.3d.down.right")
                StatTile(title: "Fluid loss", value: "\(result.totalFiltrate.formatted(digits: 1)) cm³/cm²",
                         detail: "over \(study.mud.exposureTime.formatted(digits: 0)) h of exposure", systemImage: "timer")
            }

            if let reference {
                ReferenceBadge(label: reference.label)
            }

            HStack(alignment: .top, spacing: 16) {
                ChartCard(title: "Permeability impairment", subtitle: "k/k₀ with distance from the borehole wall") {
                    Chart {
                        ForEach(result.profile.filter { $0.depthIntoFormation <= extent }) { p in
                            AreaMark(x: .value("Depth", Quantity.invasionDepth.display(p.depthIntoFormation, in: units)),
                                     yStart: .value("k/k₀", p.permeabilityRatio), yEnd: .value("Clean", 1.0))
                                .foregroundStyle(.red.opacity(0.15))
                            LineMark(x: .value("Depth", Quantity.invasionDepth.display(p.depthIntoFormation, in: units)),
                                     y: .value("k/k₀", p.permeabilityRatio), series: .value("Run", "Current"))
                                .foregroundStyle(.red)
                        }
                        if let reference {
                            ForEach(reference.result.profile.filter { $0.depthIntoFormation <= extent }) { p in
                                LineMark(x: .value("Depth", Quantity.invasionDepth.display(p.depthIntoFormation, in: units)),
                                         y: .value("k/k₀", p.permeabilityRatio), series: .value("Run", "Reference"))
                                    .foregroundStyle(.secondary)
                                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                            }
                        }
                    }
                    .chartYScale(domain: 0...1.05)
                    .chartXAxisLabel(Quantity.invasionDepth.axisLabel("Depth into formation", in: units))
                    .chartYAxisLabel("k / k₀")
                    .frame(height: 260)
                }
                ChartCard(title: "Radial damage map", subtitle: "Plan view around the borehole, coloured by k/k₀") {
                    RadialDamageMap(result: result, wellboreRadiusInches: study.damageCase.wellboreRadius, extentInches: extent)
                        .frame(height: 260)
                }
                .frame(maxWidth: 360)
            }

            HStack(alignment: .top, spacing: 16) {
                ChartCard(title: "Retained fines", subtitle: "Deposited particle volume fraction σ") {
                    Chart(result.profile.filter { $0.depthIntoFormation <= max(result.solidsInvasionDepth * 2, 0.5) }) { p in
                        AreaMark(x: .value("Depth", Quantity.invasionDepth.display(p.depthIntoFormation, in: units)), y: .value("σ", p.retained))
                            .foregroundStyle(.brown.opacity(0.55))
                    }
                    .chartXAxisLabel(Quantity.invasionDepth.axisLabel("Depth into formation", in: units))
                    .chartYAxisLabel("σ (volume fraction)")
                    .frame(height: 220)
                }
                ChartCard(title: "Fluid loss", subtitle: "Cumulative filtrate per unit area of borehole wall") {
                    Chart {
                        ForEach(result.history) { h in
                            LineMark(x: .value("Time", h.time), y: .value("Filtrate", h.cumulativeFiltrate), series: .value("Run", "Current"))
                                .foregroundStyle(.blue)
                        }
                        if let reference {
                            ForEach(reference.result.history) { h in
                                LineMark(x: .value("Time", h.time), y: .value("Filtrate", h.cumulativeFiltrate), series: .value("Run", "Reference"))
                                    .foregroundStyle(.secondary)
                                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                            }
                        }
                    }
                    .chartXAxisLabel("Time (h)")
                    .chartYAxisLabel("Filtrate (cm³/cm²)")
                    .frame(height: 220)
                }
                ChartCard(title: "Invasion front and mud cake", subtitle: "Filtrate front depth and external cake thickness") {
                    Chart {
                        ForEach(result.history) { h in
                            LineMark(x: .value("Time", h.time), y: .value("Value", Quantity.invasionDepth.display(h.filtrateFrontDepth, in: units)),
                                     series: .value("Series", "front"))
                                .foregroundStyle(by: .value("Series", "Filtrate front (\(Quantity.invasionDepth.symbol(units)))"))
                        }
                        ForEach(result.history) { h in
                            LineMark(x: .value("Time", h.time), y: .value("Value", h.cakeThickness), series: .value("Series", "cake"))
                                .foregroundStyle(by: .value("Series", "Cake thickness (mm)"))
                        }
                    }
                    .chartXAxisLabel("Time (h)")
                    .frame(height: 220)
                }
            }

            GroupBox {
                Text("Darcy flow in series through the mud cake and the radial invaded zone; cake growth with an erosion limit (dynamic filtration); Iwasaki deep-bed filtration of fines with k = k₀·F/(1 + βσ); skin from the generalised Hawkins integral. The skin is an open-hole equivalent. Calibrate λ₀, β, σmax and F against coreflood return-permeability tests for the formation you are studying.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Label("Model", systemImage: "function")
            }
        }
    }
}

/// Plan view of the near-wellbore region: concentric rings coloured by permeability ratio.
struct RadialDamageMap: View {
    let result: MudInvasionResult
    let wellboreRadiusInches: Double
    let extentInches: Double

    @Environment(\.unitSystem) private var units

    var body: some View {
        Canvas { context, size in
            let maxR = min(size.width, size.height) / 2 - 18
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)
            let outerInches = wellboreRadiusInches + extentInches
            func r(_ depthIntoFormation: Double) -> CGFloat {
                CGFloat((wellboreRadiusInches + depthIntoFormation) / outerInches) * maxR
            }

            // Undamaged rock background disc.
            context.fill(Path(ellipseIn: CGRect(x: centre.x - maxR, y: centre.y - maxR, width: 2 * maxR, height: 2 * maxR)),
                         with: .color(Color(red: 0.93, green: 0.82, blue: 0.55)))

            // Rings from outside in so inner rings paint over outer ones.
            let points = result.profile.filter { $0.depthIntoFormation <= extentInches }
            for p in points.reversed() {
                let radius = r(p.depthIntoFormation)
                let damage = 1 - p.permeabilityRatio
                let color = Color(red: 0.93 - 0.25 * damage, green: 0.82 - 0.7 * damage, blue: 0.55 - 0.45 * damage)
                context.fill(Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius, width: 2 * radius, height: 2 * radius)),
                             with: .color(color))
            }

            // Mud cake (removed at flowback, drawn for reference) and borehole.
            let rw = r(0)
            let cakeInches = result.finalCakeThickness / 25.4
            let rc = max(rw - CGFloat(cakeInches / outerInches) * maxR, rw * 0.6)
            context.fill(Path(ellipseIn: CGRect(x: centre.x - rw, y: centre.y - rw, width: 2 * rw, height: 2 * rw)),
                         with: .color(Color(red: 0.45, green: 0.32, blue: 0.22)))
            context.fill(Path(ellipseIn: CGRect(x: centre.x - rc, y: centre.y - rc, width: 2 * rc, height: 2 * rc)),
                         with: .color(Color(red: 0.12, green: 0.14, blue: 0.18)))

            // Filtrate front.
            let rf = r(result.filtrateInvasionDepth)
            context.stroke(Path(ellipseIn: CGRect(x: centre.x - rf, y: centre.y - rf, width: 2 * rf, height: 2 * rf)),
                           with: .color(.blue), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
            context.draw(Text("filtrate front").font(.caption2).foregroundColor(.blue),
                         at: CGPoint(x: centre.x, y: centre.y - rf - 3), anchor: .bottom)

            // Scale bar.
            let barInches = niceStep(outerInches / 3)
            let barLength = CGFloat(barInches / outerInches) * maxR
            var bar = Path()
            bar.move(to: CGPoint(x: 10, y: size.height - 10))
            bar.addLine(to: CGPoint(x: 10 + barLength, y: size.height - 10))
            context.stroke(bar, with: .color(.primary), lineWidth: 2)
            context.draw(Text(Quantity.invasionDepth.format(barInches, digits: 0, in: units)).font(.caption2),
                         at: CGPoint(x: 10 + barLength / 2, y: size.height - 14), anchor: .bottom)
        }
        .overlay(alignment: .topTrailing) {
            VStack(alignment: .trailing, spacing: 2) {
                LinearGradient(colors: [Color(red: 0.68, green: 0.12, blue: 0.10), Color(red: 0.93, green: 0.82, blue: 0.55)],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: 90, height: 8)
                    .clipShape(Capsule())
                HStack {
                    Text("0")
                    Spacer()
                    Text("k/k₀ = 1")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 90)
            }
        }
    }
}
