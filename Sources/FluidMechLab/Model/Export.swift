import FlowCore
import Foundation

/// CSV tables for the current section, in the chosen display units.
enum ResultExporter {
    @MainActor
    static func csv(for section: StudySection, study: StudyCase, sim: SimulationModel, units: UnitSystem) -> String {
        var rows: [[String]] = []
        func n(_ v: Double, _ digits: Int = 4) -> String { v.formatted(.number.precision(.fractionLength(digits)).grouping(.never)) }
        func h(_ name: String, _ q: Quantity) -> String { q.axisLabel(name, in: units) }

        switch section {
        case .architecture, .model3D:
            rows.append([h("MD", .depth), "Inclination (deg)", "Azimuth (deg)", h("TVD", .depth), h("North", .depth), h("East", .depth)])
            for s in study.well.survey(interval: 100) {
                rows.append([n(Quantity.depth.display(s.measuredDepth, in: units), 1), n(s.inclination, 2), n(s.azimuth, 1),
                             n(Quantity.depth.display(s.trueVerticalDepth, in: units), 1),
                             n(Quantity.depth.display(s.north, in: units), 1), n(Quantity.depth.display(s.east, in: units), 1)])
            }
        case .fluid:
            rows.append([h("Pressure", .pressure), h("Rs", .gasOilRatio), "Bo (rb/STB)", h("Oil viscosity", .viscosity),
                         h("Oil density", .density), "Z", h("Gas viscosity", .viscosity)])
            let pb = study.fluid.bubblePoint(temperature: study.reservoir.temperature)
            for p in study.fluid.table(temperature: study.reservoir.temperature, maxPressure: max(study.reservoir.pressure, pb) * 1.2) {
                rows.append([n(Quantity.pressure.display(p.pressure, in: units), 1), n(Quantity.gasOilRatio.display(p.rs, in: units), 2),
                             n(p.bo), n(p.oilViscosity), n(Quantity.density.display(p.oilDensity, in: units), 3), n(p.z), n(p.gasViscosity, 5)])
            }
        case .damage, .liveFlow, .sensitivity:
            guard let d = sim.damage else { break }
            rows.append([h("Depth into formation", .invasionDepth), h("Radius", .depth), "k/k0", "Retained fines sigma", "Suspended fines c", "Filtrate invaded"])
            for p in d.profile {
                rows.append([n(Quantity.invasionDepth.display(p.depthIntoFormation, in: units)), n(Quantity.depth.display(p.radius, in: units)),
                             n(p.permeabilityRatio), n(p.retained, 6), n(p.suspended, 6), p.filtrateInvaded ? "yes" : "no"])
            }
            rows.append([])
            rows.append(["Time (h)", "Filtration rate (cm/h)", "Cumulative filtrate (cm3/cm2)", "Cake thickness (mm)", h("Filtrate front", .invasionDepth)])
            for p in d.history {
                rows.append([n(p.time), n(p.filtrationRate), n(p.cumulativeFiltrate), n(p.cakeThickness), n(Quantity.invasionDepth.display(p.filtrateFrontDepth, in: units))])
            }
            rows.append([])
            rows.append(["Skin", n(d.skin)])
            rows.append(["Productivity ratio", n(d.productivityRatio)])
        case .nodal:
            guard let r = sim.nodal else { break }
            rows.append([h("Liquid rate", .liquidRate), h("IPR pressure", .pressure), h("VLP rate", .liquidRate), h("VLP pressure", .pressure)])
            for i in 0..<max(r.ipr.count, r.vlp.count) {
                let a = i < r.ipr.count ? r.ipr[i] : nil
                let b = i < r.vlp.count ? r.vlp[i] : nil
                rows.append([a.map { n(Quantity.liquidRate.display($0.rate, in: units), 1) } ?? "",
                             a.map { n(Quantity.pressure.display($0.pressure, in: units), 1) } ?? "",
                             b.map { n(Quantity.liquidRate.display($0.rate, in: units), 1) } ?? "",
                             b.map { n(Quantity.pressure.display($0.pressure, in: units), 1) } ?? ""])
            }
            rows.append([])
            rows.append([h("MD", .depth), h("Pressure", .pressure), h("Temperature", .temperature), "Holdup", "Flow pattern", "Mixture velocity (ft/s)"])
            for p in r.traverse {
                rows.append([n(Quantity.depth.display(p.depth, in: units), 1), n(Quantity.pressure.display(p.pressure, in: units), 1),
                             n(Quantity.temperature.display(p.temperature, in: units), 1), n(p.holdup), p.pattern.rawValue, n(p.mixtureVelocity, 3)])
            }
            if let op = r.operatingPoint {
                rows.append([])
                rows.append(["Operating rate", n(Quantity.liquidRate.display(op.rate, in: units), 1)])
                rows.append(["Operating pressure", n(Quantity.pressure.display(op.pressure, in: units), 1)])
            }
        }
        return rows.map { $0.map(escape).joined(separator: ",") }.joined(separator: "\n") + "\n"
    }

    private static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
