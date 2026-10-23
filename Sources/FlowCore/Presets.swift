import Foundation

/// A named change to a study case. Field presets replace the whole case; the others adjust part of it.
public struct StudyPreset: Identifiable {
    public enum Category: String, CaseIterable, Identifiable, Sendable {
        case field = "Field Scenarios"
        case damage = "Formation Damage Studies"
        case mud = "Mud Systems"
        case rock = "Rock Types"

        public var id: String { rawValue }

        public var summary: String {
            switch self {
            case .field: "Complete reservoir, fluid and well setups. Replaces the current study."
            case .damage: "Rock, mud and drilling combinations for near-wellbore damage studies."
            case .mud: "Drilling-fluid systems. Changes mud, cake and filtrate properties only."
            case .rock: "Formation types. Changes permeability, porosity and fines behaviour only."
            }
        }
    }

    public let id: String
    public let category: Category
    public let name: String
    public let summary: String
    let change: (inout StudyCase) -> Void

    init(_ category: Category, _ name: String, _ summary: String, _ change: @escaping (inout StudyCase) -> Void) {
        self.id = "\(category.rawValue)/\(name)"
        self.category = category
        self.name = name
        self.summary = summary
        self.change = change
    }

    /// Returns `base` with this preset applied.
    public func applied(to base: StudyCase) -> StudyCase {
        var c = base
        change(&c)
        if category == .field { c.basedOn = name }
        return c
    }
}

extension StudyPreset {
    public static func presets(in category: Category) -> [StudyPreset] {
        all.filter { $0.category == category }
    }

    public static let all: [StudyPreset] = fieldScenarios + damageStudies + mudSystems + rockTypes

    // MARK: Field scenarios

    /// Illustrative analogues built from typical published ranges, not data from any specific field.
    static let fieldScenarios: [StudyPreset] = [
        StudyPreset(.field, "Giant Carbonate, Light Oil",
                    "Middle East–type limestone: thick, high-permeability pay, 33 °API oil, vertical producer.") { c in
            c = StudyCase(
                title: "Giant Carbonate, Light Oil",
                well: StudyPreset.wellProgram(name: "Carbonate-1", mdTarget: 7100, payTVD: (7000, 7200), tubing: .t4_5, bit: 8.5,
                                  trajectory: WellTrajectory(), whp: 300, wht: 130),
                fluid: BlackOilFluid(apiGravity: 33, gasGravity: 0.80, solutionGOR: 550, waterGravity: 1.12),
                reservoir: Reservoir(pressure: 3300, temperature: 210, permeability: 250, thickness: 180, porosity: 0.21, drainageRadius: 2000),
                waterCut: 0.25, producingGOR: 600,
                mud: MudInvasionCase.with { $0.overbalance = 400; $0.exposureTime = 36 })
            StudyPreset.vuggyCarbonate(&c)
        },
        StudyPreset(.field, "Deepwater Turbidite Sandstone",
                    "West Africa–type subsea well: unconsolidated high-permeability sand, deviated 35°, high wellhead pressure.") { c in
            c = StudyCase(
                title: "Deepwater Turbidite Sandstone",
                well: StudyPreset.wellProgram(name: "Subsea-A1", mdTarget: 10400, payTVD: (9000, 9120), tubing: .t5_5, bit: 8.5,
                                  trajectory: WellTrajectory(kickoffDepth: 2500, buildRate: 2.5, holdInclination: 35, azimuth: 60),
                                  whp: 1500, wht: 95),
                fluid: BlackOilFluid(apiGravity: 30, gasGravity: 0.72, solutionGOR: 750, waterGravity: 1.06),
                reservoir: Reservoir(pressure: 5600, temperature: 175, permeability: 900, thickness: 90, porosity: 0.28, drainageRadius: 2500),
                waterCut: 0.10, producingGOR: 800,
                mud: MudInvasionCase.with { $0.overbalance = 600; $0.exposureTime = 48 })
            StudyPreset.cleanSandstone(&c)
            c.reservoir.permeability = 900
            c.reservoir.porosity = 0.28
        },
        StudyPreset(.field, "North Sea Sandstone",
                    "Brent-type deviated platform well: 38 °API oil, moderate water cut.") { c in
            c = StudyCase(
                title: "North Sea Sandstone",
                well: StudyPreset.wellProgram(name: "Platform-B7", mdTarget: 12600, payTVD: (10500, 10650), tubing: .t4_5, bit: 8.5,
                                  trajectory: WellTrajectory(kickoffDepth: 1500, buildRate: 3, holdInclination: 45, azimuth: 200),
                                  whp: 600, wht: 140),
                fluid: BlackOilFluid(apiGravity: 38, gasGravity: 0.78, solutionGOR: 850),
                reservoir: Reservoir(pressure: 4800, temperature: 220, permeability: 300, thickness: 110, porosity: 0.22, drainageRadius: 1800),
                waterCut: 0.40, producingGOR: 900,
                mud: MudInvasionCase.with { $0.overbalance = 500 })
            StudyPreset.cleanSandstone(&c)
            c.reservoir.permeability = 300
        },
        StudyPreset(.field, "Mature Onshore Waterflood",
                    "Shallow vertical well at 85 % water cut: shows when a well can no longer flow without artificial lift.") { c in
            c = StudyCase(
                title: "Mature Onshore Waterflood",
                well: StudyPreset.wellProgram(name: "Onshore-112", mdTarget: 5050, payTVD: (5000, 5100), tubing: .t2_875, bit: 7.875,
                                  trajectory: WellTrajectory(), whp: 120, wht: 90),
                fluid: BlackOilFluid(apiGravity: 35, gasGravity: 0.75, solutionGOR: 300, waterGravity: 1.05),
                reservoir: Reservoir(pressure: 2000, temperature: 150, permeability: 80, thickness: 40, porosity: 0.18, drainageRadius: 660),
                waterCut: 0.85, producingGOR: 300,
                mud: MudInvasionCase.with { $0.overbalance = 300; $0.exposureTime = 24 })
            StudyPreset.clayRichSandstone(&c)
            c.reservoir.permeability = 80
        },
        StudyPreset(.field, "Heavy Oil Sand",
                    "Shallow, very permeable sand with 14 °API viscous oil.") { c in
            c = StudyCase(
                title: "Heavy Oil Sand",
                well: StudyPreset.wellProgram(name: "Heavy-3", mdTarget: 2550, payTVD: (2500, 2600), tubing: .t3_5, bit: 8.5,
                                  trajectory: WellTrajectory(), whp: 100, wht: 85),
                fluid: BlackOilFluid(apiGravity: 14, gasGravity: 0.65, solutionGOR: 80, waterGravity: 1.03),
                reservoir: Reservoir(pressure: 1200, temperature: 110, permeability: 2500, thickness: 50, porosity: 0.32, drainageRadius: 660),
                waterCut: 0.20, producingGOR: 90,
                mud: MudInvasionCase.with { $0.overbalance = 200 })
            StudyPreset.cleanSandstone(&c)
            c.reservoir.permeability = 2500
            c.reservoir.porosity = 0.32
        },
        StudyPreset(.field, "Tight Sandstone",
                    "Low-permeability, high-GOR light oil: skin has an outsized effect on rate.") { c in
            c = StudyCase(
                title: "Tight Sandstone",
                well: StudyPreset.wellProgram(name: "Tight-9", mdTarget: 10050, payTVD: (10000, 10100), tubing: .t2_875, bit: 6.125,
                                  trajectory: WellTrajectory(), whp: 500, wht: 120),
                fluid: BlackOilFluid(apiGravity: 42, gasGravity: 0.80, solutionGOR: 1400),
                reservoir: Reservoir(pressure: 5200, temperature: 240, permeability: 0.8, thickness: 50, porosity: 0.10, drainageRadius: 1000),
                waterCut: 0.05, producingGOR: 1500,
                mud: MudInvasionCase.with { $0.overbalance = 800 })
            StudyPreset.tightGasSandstone(&c)
            c.reservoir.permeability = 0.8
        },
        StudyPreset(.field, "HPHT Deep Reservoir",
                    "High-pressure, high-temperature well at 16,000 ft with a large mud overbalance.") { c in
            c = StudyCase(
                title: "HPHT Deep Reservoir",
                well: StudyPreset.wellProgram(name: "HPHT-1", mdTarget: 16100, payTVD: (16000, 16200), tubing: .t3_5, bit: 6.0,
                                  trajectory: WellTrajectory(), whp: 3000, wht: 180),
                fluid: BlackOilFluid(apiGravity: 40, gasGravity: 0.75, solutionGOR: 1200),
                reservoir: Reservoir(pressure: 11500, temperature: 320, permeability: 20, thickness: 120, porosity: 0.15, drainageRadius: 1500),
                waterCut: 0.0, producingGOR: 1200,
                mud: MudInvasionCase.with { $0.overbalance = 1500; $0.exposureTime = 72 })
            StudyPreset.oilBasedMud(&c)
        },
    ]

    // MARK: Formation damage studies

    static let damageStudies: [StudyPreset] = [
        StudyPreset(.damage, "Fines Plugging During Spurt",
                    "Clean sandstone drilled with bentonite water-based mud: fines invade before the cake bridges.") { c in
            StudyPreset.cleanSandstone(&c); StudyPreset.bentoniteWBM(&c)
            c.mud.finesConcentration = 0.02
            c.mud.bridgingThickness = 1.0
            c.mud.overbalance = 500; c.mud.exposureTime = 24
        },
        StudyPreset(.damage, "Clay Swelling by Fresh-Water Filtrate",
                    "Smectite-rich sandstone exposed to a fresh-water mud: deep filtrate-zone impairment.") { c in
            StudyPreset.clayRichSandstone(&c); StudyPreset.freshWaterMud(&c)
            c.mud.filtrateDamageFactor = 0.3
            c.mud.overbalance = 500; c.mud.exposureTime = 48
        },
        StudyPreset(.damage, "Water Block in Tight Sand",
                    "Low-permeability sand where trapped filtrate cuts the oil permeability sharply.") { c in
            StudyPreset.tightGasSandstone(&c); StudyPreset.polymerWBM(&c)
            c.mud.filtrateDamageFactor = 0.2
            c.mud.displaceableFraction = 0.35
            c.mud.overbalance = 800; c.mud.exposureTime = 36
        },
        StudyPreset(.damage, "Optimised Drill-In Fluid",
                    "Sized-carbonate reservoir drill-in fluid that bridges fast: the low-damage reference case.") { c in
            StudyPreset.cleanSandstone(&c); StudyPreset.drillInFluid(&c)
            c.mud.overbalance = 300; c.mud.exposureTime = 24
        },
        StudyPreset(.damage, "High-Overbalance HPHT Exposure",
                    "2,500 psi overbalance for three days with oil-based mud.") { c in
            StudyPreset.cleanSandstone(&c); StudyPreset.oilBasedMud(&c)
            c.reservoir.permeability = 50
            c.mud.overbalance = 2500; c.mud.exposureTime = 72
        },
        StudyPreset(.damage, "Long Static Exposure (Rig Downtime)",
                    "No circulation for five days: static cake keeps growing while filtrate invades deeper.") { c in
            StudyPreset.cleanSandstone(&c); StudyPreset.bentoniteWBM(&c)
            c.mud.equilibriumCakeThickness = 0
            c.mud.overbalance = 500; c.mud.exposureTime = 120
        },
    ]

    // MARK: Mud systems

    static let mudSystems: [StudyPreset] = [
        StudyPreset(.mud, "Bentonite Water-Based Mud", "Conventional WBM with clay solids and moderate fluid loss.", StudyPreset.bentoniteWBM),
        StudyPreset(.mud, "Polymer WBM (XC/PAC)", "Low-solids polymer mud: viscous filtrate, polymer adsorption.", StudyPreset.polymerWBM),
        StudyPreset(.mud, "Oil-Based Mud (Invert Emulsion)", "Tight cake and no clay swelling, but emulsion and wettability effects.", StudyPreset.oilBasedMud),
        StudyPreset(.mud, "Reservoir Drill-In Fluid (Sized CaCO₃)", "Bridging particles sized to the pore throats: fast, thin, removable cake.", StudyPreset.drillInFluid),
        StudyPreset(.mud, "Fresh-Water Mud, Poor Fluid-Loss Control", "Unweighted mud with a leaky cake and reactive filtrate.", StudyPreset.freshWaterMud),
    ]

    static func bentoniteWBM(_ c: inout StudyCase) {
        c.mud.mudSolidsFraction = 0.08; c.mud.cakePermeability = 0.001; c.mud.cakePorosity = 0.45
        c.mud.equilibriumCakeThickness = 2.5; c.mud.bridgingThickness = 0.5
        c.mud.finesConcentration = 0.012; c.mud.filtrateViscosity = 1.0; c.mud.filtrateDamageFactor = 0.7
    }

    static func polymerWBM(_ c: inout StudyCase) {
        c.mud.mudSolidsFraction = 0.04; c.mud.cakePermeability = 0.0005; c.mud.cakePorosity = 0.40
        c.mud.equilibriumCakeThickness = 1.5; c.mud.bridgingThickness = 0.8
        c.mud.finesConcentration = 0.006; c.mud.filtrateViscosity = 2.5; c.mud.filtrateDamageFactor = 0.6
    }

    static func oilBasedMud(_ c: inout StudyCase) {
        c.mud.mudSolidsFraction = 0.10; c.mud.cakePermeability = 0.0002; c.mud.cakePorosity = 0.35
        c.mud.equilibriumCakeThickness = 1.5; c.mud.bridgingThickness = 0.3
        c.mud.finesConcentration = 0.004; c.mud.filtrateViscosity = 3.0; c.mud.filtrateDamageFactor = 0.85
    }

    static func drillInFluid(_ c: inout StudyCase) {
        c.mud.mudSolidsFraction = 0.06; c.mud.cakePermeability = 0.0003; c.mud.cakePorosity = 0.30
        c.mud.equilibriumCakeThickness = 1.0; c.mud.bridgingThickness = 0.1
        c.mud.finesConcentration = 0.002; c.mud.filtrateViscosity = 1.5; c.mud.filtrateDamageFactor = 0.9
    }

    static func freshWaterMud(_ c: inout StudyCase) {
        c.mud.mudSolidsFraction = 0.03; c.mud.cakePermeability = 0.05; c.mud.cakePorosity = 0.50
        c.mud.equilibriumCakeThickness = 3.0; c.mud.bridgingThickness = 2.0
        c.mud.finesConcentration = 0.02; c.mud.filtrateViscosity = 1.0; c.mud.filtrateDamageFactor = 0.5
    }

    // MARK: Rock types

    static let rockTypes: [StudyPreset] = [
        StudyPreset(.rock, "Clean Sandstone (Berea-Type)", "Well-sorted quartz sandstone, few reactive clays.", StudyPreset.cleanSandstone),
        StudyPreset(.rock, "Clay-Rich Sandstone", "Smectite/illite-bearing sand, sensitive to fresh filtrate and fines.", StudyPreset.clayRichSandstone),
        StudyPreset(.rock, "Tight Gas Sandstone", "Small pore throats: strong capture of fines and water blocking.", StudyPreset.tightGasSandstone),
        StudyPreset(.rock, "Vuggy Carbonate", "Large vugs and fractures: deep but weak solids invasion.", StudyPreset.vuggyCarbonate),
        StudyPreset(.rock, "Chalk", "High porosity, very low permeability, fine-grained.", StudyPreset.chalk),
    ]

    static func cleanSandstone(_ c: inout StudyCase) {
        c.reservoir.permeability = 300; c.reservoir.porosity = 0.22
        c.mud.filtrationCoefficient = 30; c.mud.damageCoefficient = 300; c.mud.maxRetention = 0.03; c.mud.displaceableFraction = 0.6
    }

    static func clayRichSandstone(_ c: inout StudyCase) {
        c.reservoir.permeability = 50; c.reservoir.porosity = 0.18
        c.mud.filtrationCoefficient = 80; c.mud.damageCoefficient = 800; c.mud.maxRetention = 0.02; c.mud.displaceableFraction = 0.5
    }

    static func tightGasSandstone(_ c: inout StudyCase) {
        c.reservoir.permeability = 0.5; c.reservoir.porosity = 0.08
        c.mud.filtrationCoefficient = 150; c.mud.damageCoefficient = 1500; c.mud.maxRetention = 0.01; c.mud.displaceableFraction = 0.4
    }

    static func vuggyCarbonate(_ c: inout StudyCase) {
        c.reservoir.permeability = 500; c.reservoir.porosity = 0.15
        c.mud.filtrationCoefficient = 10; c.mud.damageCoefficient = 150; c.mud.maxRetention = 0.05; c.mud.displaceableFraction = 0.7
    }

    static func chalk(_ c: inout StudyCase) {
        c.reservoir.permeability = 3; c.reservoir.porosity = 0.35
        c.mud.filtrationCoefficient = 120; c.mud.damageCoefficient = 1000; c.mud.maxRetention = 0.015; c.mud.displaceableFraction = 0.6
    }

    // MARK: Well program builder

    enum TubingSize {
        case t2_875, t3_5, t4_5, t5_5

        var string: TubingString {
            switch self {
            case .t2_875: TubingString(outerDiameter: 2.875, innerDiameter: 2.441)
            case .t3_5: TubingString(outerDiameter: 3.5, innerDiameter: 2.992)
            case .t4_5: TubingString(outerDiameter: 4.5, innerDiameter: 3.958)
            case .t5_5: TubingString(outerDiameter: 5.5, innerDiameter: 4.892)
            }
        }
    }

    /// Builds a conventional casing program for a well whose pay sits at `payTVD`.
    static func wellProgram(
        name: String, mdTarget: Double, payTVD: (top: Double, bottom: Double), tubing: TubingSize, bit: Double,
        trajectory: WellTrajectory, whp: Double, wht: Double
    ) -> WellModel {
        var w = WellModel(name: name, trajectory: trajectory)
        w.reservoirTop = payTVD.top
        w.reservoirBottom = payTVD.bottom
        let mdTop = w.measuredDepth(atTVD: payTVD.top)
        let mdBottom = w.measuredDepth(atTVD: payTVD.bottom)
        let td = mdBottom + 150
        w.totalDepth = td

        // Casing program sized from the reservoir bit: production string across the pay, two strings above.
        let program: [(name: String, od: Double, id: Double, hole: Double)]
        if bit >= 8.5 {
            program = [("Surface", 13.375, 12.415, 17.5), ("Intermediate", 9.625, 8.681, 12.25), ("Production", 7, 6.184, bit)]
        } else if bit >= 7.5 {
            program = [("Surface", 11.75, 10.88, 14.75), ("Intermediate", 8.625, 7.921, 11), ("Production", 5.5, 4.892, bit)]
        } else {
            program = [("Surface", 9.625, 8.681, 12.25), ("Intermediate", 7, 6.184, 8.5), ("Production", 5, 4.276, bit)]
        }
        let intermediateShoe = min(max(mdTop * 0.6, 1500), mdTop - 800)
        let surfaceShoe = min(max(mdTop * 0.15, 500), intermediateShoe - 500)
        let shoes = [surfaceShoe, intermediateShoe, td]
        let cementTops = [0, 0, max(mdTop - 1500, 0)]
        let strings = (0..<3).map { i in
            CasingString(name: program[i].name, outerDiameter: program[i].od, innerDiameter: program[i].id,
                         shoe: shoes[i], holeSize: program[i].hole, topOfCement: cementTops[i])
        }
        w.casings = strings
        w.reservoirBitSize = bit

        var t = tubing.string
        t.shoe = mdTop - 200
        w.tubing = t
        w.packerDepth = mdTop - 250
        w.perforations = [PerforationInterval(top: mdTop + 10, bottom: mdBottom - 10)]
        w.wellheadPressure = whp
        w.wellheadTemperature = wht
        return w
    }
}

extension MudInvasionCase {
    /// Default mud case with a few fields changed.
    public static func with(_ change: (inout MudInvasionCase) -> Void) -> MudInvasionCase {
        var m = MudInvasionCase()
        change(&m)
        return m
    }
}
