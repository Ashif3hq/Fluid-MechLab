import XCTest
@testable import FlowCore

final class NodalTests: XCTestCase {
    func testFrictionFactor() {
        XCTAssertEqual(Numerics.moodyFrictionFactor(reynolds: 1000, relativeRoughness: 0), 0.064, accuracy: 1e-9)
        // Smooth pipe, Re = 1e5: Moody chart gives ≈ 0.018.
        XCTAssertEqual(Numerics.moodyFrictionFactor(reynolds: 1e5, relativeRoughness: 1e-6), 0.018, accuracy: 0.001)
    }

    func testIPRAboveAndBelowBubblePoint() {
        let inflow = InflowModel(reservoir: Reservoir(), fluid: BlackOilFluid())
        XCTAssertEqual(inflow.productivityIndex, 2.838, accuracy: 0.03)
        XCTAssertEqual(inflow.rate(pwf: inflow.reservoir.pressure), 0, accuracy: 1e-9)
        XCTAssertEqual(inflow.absoluteOpenFlow, 8318, accuracy: 100)
        let q = inflow.rate(pwf: 3000)
        XCTAssertEqual(inflow.pwf(rate: q) ?? -1, 3000, accuracy: 0.01)
    }

    func testSkinReducesProductivity() {
        var r = Reservoir()
        let clean = InflowModel(reservoir: r, fluid: BlackOilFluid()).productivityIndex
        r.skin = 5
        let damaged = InflowModel(reservoir: r, fluid: BlackOilFluid()).productivityIndex
        XCTAssertLessThan(damaged, clean * 0.65)
    }

    func testStaticGradientIsHydrostatic() {
        let s = PipeFlowState(vsl: 0, vsg: 0, liquidDensity: 62.4, gasDensity: 0, liquidViscosity: 1, gasViscosity: 0.01, surfaceTension: 70)
        let g = BeggsBrill.gradient(s, diameter: 0.25, roughness: 5e-5, inclination: .pi / 2)
        XCTAssertEqual(g.totalGradient, 0.4333, accuracy: 1e-3)
    }

    func testTraverseIncreasesWithDepth() {
        let model = WellboreFlowModel(well: Well(), fluid: BlackOilFluid(), reservoirTemperature: 200)
        let pts = model.traverse(rates: ProductionRates(liquidRate: 2000))
        XCTAssertEqual(pts.first?.pressure ?? 0, 250, accuracy: 1e-9)
        for (a, b) in zip(pts, pts.dropFirst()) { XCTAssertGreaterThan(b.pressure, a.pressure) }
        XCTAssertEqual(pts.last?.pressure ?? 0, 2131, accuracy: 60)
    }

    func testOperatingPoint() {
        let result = NodalAnalysis.solve(NodalCase())
        let op = try! XCTUnwrap(result.operatingPoint)
        XCTAssert((3800...4600).contains(op.rate), "rate \(op.rate)")
        XCTAssert((2350...2750).contains(op.pressure), "pwf \(op.pressure)")
    }

    func testNoNaturalFlowWhenReservoirPressureTooLow() {
        var c = NodalCase()
        c.reservoir.pressure = 1500
        c.waterCut = 0.9
        XCTAssertNil(NodalAnalysis.solve(c).operatingPoint)
    }
}
