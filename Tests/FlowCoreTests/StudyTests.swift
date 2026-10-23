import XCTest
@testable import FlowCore

final class TrajectoryTests: XCTestCase {
    func testVerticalWell() {
        let t = WellTrajectory()
        XCTAssertEqual(t.position(atMD: 5000).tvd, 5000, accuracy: 1e-9)
        XCTAssertEqual(t.position(atMD: 5000).displacement, 0, accuracy: 1e-9)
        XCTAssertEqual(t.inclination(atMD: 5000), 0)
    }

    func testBuildAndHold() {
        // KOP 2000 ft, 3°/100 ft to 45°: build length 1500 ft, radius 1909.86 ft.
        let t = WellTrajectory(kickoffDepth: 2000, buildRate: 3, holdInclination: 45)
        XCTAssertEqual(t.buildLength, 1500, accuracy: 1e-9)
        XCTAssertEqual(t.inclination(atMD: 2500), 15, accuracy: 1e-9)
        XCTAssertEqual(t.inclination(atMD: 6000), 45, accuracy: 1e-9)
        let radius = 18000 / (Double.pi * 3)
        let eob = t.position(atMD: 3500)
        XCTAssertEqual(eob.tvd, 2000 + radius * sin(.pi / 4), accuracy: 1e-6)
        XCTAssertEqual(eob.displacement, radius * (1 - cos(.pi / 4)), accuracy: 1e-6)
        let deeper = t.position(atMD: 4500)
        XCTAssertEqual(deeper.tvd - eob.tvd, 1000 * cos(.pi / 4), accuracy: 1e-6)
    }

    func testSurveyIsMonotonicAndEndsAtTD() {
        let survey = WellTrajectory(kickoffDepth: 1000, buildRate: 2, holdInclination: 30, azimuth: 90).survey(to: 9000, interval: 100)
        XCTAssertEqual(survey.last?.measuredDepth, 9000)
        for (a, b) in zip(survey, survey.dropFirst()) {
            XCTAssertGreaterThan(b.trueVerticalDepth, a.trueVerticalDepth)
            XCTAssertGreaterThanOrEqual(b.horizontalDisplacement, a.horizontalDisplacement)
        }
        // Azimuth 90° → displacement is all east.
        XCTAssertEqual(survey.last?.north ?? 1, 0, accuracy: 1e-6)
        XCTAssertGreaterThan(survey.last?.east ?? 0, 0)
    }

    func testMeasuredDepthAtTVDInvertsPosition() {
        var w = WellModel()
        w.trajectory = WellTrajectory(kickoffDepth: 1500, buildRate: 2.5, holdInclination: 40)
        let md = w.measuredDepth(atTVD: 7000)
        XCTAssertEqual(w.trajectory.position(atMD: md).tvd, 7000, accuracy: 0.05)
    }

    func testDeviatedWellNeedsLessBHPForSameRateThanItsMDSuggests() {
        // The same 8000 ft of tubing deviated 45° has a shorter hydrostatic column.
        let fluid = BlackOilFluid()
        let vertical = WellboreFlowModel(well: Well(), fluid: fluid, reservoirTemperature: 200)
        let deviated = WellboreFlowModel(well: Well(deviation: 45, kickoffDepth: 1000, buildRate: 3), fluid: fluid, reservoirTemperature: 200)
        let rates = ProductionRates(liquidRate: 1500)
        XCTAssertLessThan(deviated.bottomholePressure(rates: rates), vertical.bottomholePressure(rates: rates) - 200)
    }
}

final class StudyCaseTests: XCTestCase {
    func testDefaultWellArchitectureIsConsistent() {
        XCTAssertEqual(WellModel().validationMessages, [])
    }

    func testValidationCatchesBadTubing() {
        var w = WellModel()
        w.tubing.outerDiameter = 8
        XCTAssertFalse(w.validationMessages.isEmpty)
    }

    func testDamageCaseUsesReservoirRockAndBitSize() {
        var c = StudyCase()
        c.reservoir.permeability = 123
        c.reservoir.porosity = 0.17
        c.well.reservoirBitSize = 6.125
        let d = c.damageCase
        XCTAssertEqual(d.permeability, 123)
        XCTAssertEqual(d.porosity, 0.17)
        XCTAssertEqual(d.wellboreRadius, 3.0625)
    }

    func testDamageSkinFeedsInflowOnlyWhenEnabled() {
        var c = StudyCase()
        c.reservoir.skin = 1
        XCTAssertEqual(c.nodalCase(damageSkin: 2.5).reservoir.skin, 3.5, accuracy: 1e-12)
        c.includeDamageSkin = false
        XCTAssertEqual(c.nodalCase(damageSkin: 2.5).reservoir.skin, 1, accuracy: 1e-12)
    }

    func testStudyRoundTripsThroughJSON() throws {
        let c = StudyPreset.all[0].applied(to: StudyCase())
        let data = try JSONEncoder().encode(c)
        XCTAssertEqual(try JSONDecoder().decode(StudyCase.self, from: data), c)
    }
}

final class PresetTests: XCTestCase {
    func testEveryCategoryHasPresets() {
        for category in StudyPreset.Category.allCases {
            XCTAssertFalse(StudyPreset.presets(in: category).isEmpty, category.rawValue)
        }
        XCTAssertEqual(Set(StudyPreset.all.map(\.id)).count, StudyPreset.all.count, "preset ids must be unique")
    }

    func testFieldScenariosBuildValidWellsAndRun() {
        for preset in StudyPreset.presets(in: .field) {
            let c = preset.applied(to: StudyCase())
            XCTAssertEqual(c.basedOn, preset.name)
            XCTAssertEqual(c.well.validationMessages, [], preset.name)
            let tvd = c.well.trajectory.position(atMD: c.well.midPerforationDepth).tvd
            XCTAssert(tvd > c.well.reservoirTop && tvd < c.well.reservoirBottom, "\(preset.name): perforations at \(tvd) ft TVD")
            let damage = MudInvasionSimulator.run(c.damageCase, historySamples: 10)
            XCTAssert(damage.skin.isFinite && damage.skin >= 0, "\(preset.name) skin \(damage.skin)")
            let nodal = NodalAnalysis.solve(c.nodalCase(damageSkin: damage.skin), samples: 20)
            XCTAssert(nodal.absoluteOpenFlow > 0, preset.name)
        }
    }

    func testWaterfloodPresetCannotFlowNaturally() {
        let preset = StudyPreset.all.first { $0.name == "Mature Onshore Waterflood" }!
        let c = preset.applied(to: StudyCase())
        let nodal = NodalAnalysis.solve(c.nodalCase(damageSkin: nil), samples: 20)
        XCTAssertNil(nodal.operatingPoint)
    }

    func testDrillInFluidDamagesLessThanFreshWaterMud() {
        func skin(_ name: String) -> Double {
            let c = StudyPreset.all.first { $0.name == name }!.applied(to: StudyCase())
            return MudInvasionSimulator.run(c.damageCase, historySamples: 10).skin
        }
        XCTAssertLessThan(skin("Optimised Drill-In Fluid"), skin("Clay Swelling by Fresh-Water Filtrate"))
    }

    func testPartialPresetsKeepTheWell() {
        var base = StudyCase()
        base.well.name = "Keep-Me"
        for preset in StudyPreset.all where preset.category != .field {
            XCTAssertEqual(preset.applied(to: base).well, base.well, preset.name)
        }
    }
}

final class UnitTests: XCTestCase {
    func testRoundTrip() {
        for q in [Quantity.pressure, .temperature, .depth, .diameter, .liquidRate, .gasOilRatio, .density, .productivityIndex] {
            XCTAssertEqual(q.engine(q.display(1234.5, in: .si), from: .si), 1234.5, accuracy: 1e-9)
        }
    }

    func testKnownConversions() {
        XCTAssertEqual(Quantity.pressure.display(14.5038, in: .si), 1.0, accuracy: 1e-4)
        XCTAssertEqual(Quantity.temperature.display(212, in: .si), 100, accuracy: 1e-9)
        XCTAssertEqual(Quantity.depth.display(1000, in: .si), 304.8, accuracy: 1e-9)
        XCTAssertEqual(Quantity.liquidRate.display(1, in: .si), 0.158987, accuracy: 1e-6)
        XCTAssertEqual(Quantity.pressure.display(500, in: .field), 500)
    }
}

final class SensitivityTests: XCTestCase {
    func testSkinGrowsWithFinesConcentration() {
        var base = StudyCase()
        base.mud.filtrateDamageFactor = 1
        let points = SensitivityStudy.run(base, parameter: .finesConcentration, values: [0, 0.01, 0.03])
        XCTAssertEqual(points.count, 3)
        XCTAssertEqual(points[0].skin, 0, accuracy: 1e-9)
        XCTAssertLessThan(points[1].skin, points[2].skin)
    }

    func testLogValues() {
        let v = SweepParameter.permeability.values(in: 1...100, count: 3)
        XCTAssertEqual(v[1], 10, accuracy: 1e-9)
    }
}
