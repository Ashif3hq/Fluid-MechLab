import XCTest
@testable import FlowCore

final class FormationDamageTests: XCTestCase {
    func testDefaultCase() {
        let r = MudInvasionSimulator.run(MudInvasionCase())
        XCTAssertEqual(r.filtrateInvasionDepth, 17.0, accuracy: 1.5)
        XCTAssertEqual(r.finalCakeThickness, 2.0, accuracy: 0.05)
        XCTAssertEqual(r.skin, 0.77, accuracy: 0.1)
        XCTAssertGreaterThan(r.solidsInvasionDepth, 0.2)
        XCTAssertLessThan(r.solidsInvasionDepth, r.filtrateInvasionDepth)
        XCTAssertLessThan(r.productivityRatio, 1)
        XCTAssertEqual(r.history.count, 201)
    }

    func testNoDamageMechanismsGivesZeroSkin() {
        var c = MudInvasionCase()
        c.finesConcentration = 0
        c.filtrateDamageFactor = 1
        let r = MudInvasionSimulator.run(c)
        XCTAssertEqual(r.skin, 0, accuracy: 1e-9)
        XCTAssertEqual(r.productivityRatio, 1, accuracy: 1e-9)
    }

    func testHigherOverbalanceInvadesDeeper() {
        var c = MudInvasionCase()
        let base = MudInvasionSimulator.run(c)
        c.overbalance = 1000
        let high = MudInvasionSimulator.run(c)
        XCTAssertGreaterThan(high.filtrateInvasionDepth, base.filtrateInvasionDepth * 1.2)
        XCTAssertGreaterThan(high.totalFiltrate, base.totalFiltrate * 1.5)
    }

    func testStaticFiltrationGrowsThickerCakeAndLessFiltrate() {
        var c = MudInvasionCase()
        let dynamic = MudInvasionSimulator.run(c)
        c.equilibriumCakeThickness = 0
        let staticRun = MudInvasionSimulator.run(c)
        XCTAssertGreaterThan(staticRun.finalCakeThickness, dynamic.finalCakeThickness)
        XCTAssertLessThan(staticRun.totalFiltrate, dynamic.totalFiltrate)
    }

    func testPermeabilityNeverExceedsOriginal() {
        let r = MudInvasionSimulator.run(MudInvasionCase())
        for p in r.profile { XCTAssertLessThanOrEqual(p.permeabilityRatio, 1 + 1e-12) }
    }
}
