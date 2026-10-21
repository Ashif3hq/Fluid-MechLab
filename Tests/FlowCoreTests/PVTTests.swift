import XCTest
@testable import FlowCore

final class PVTTests: XCTestCase {
    let fluid = BlackOilFluid()

    func testBubblePointMatchesStanding() {
        // 32 °API, γg 0.75, Rsb 500 scf/STB, 200 °F → about 2406 psia (Standing).
        XCTAssertEqual(fluid.bubblePoint(temperature: 200), 2406, accuracy: 5)
    }

    func testSolutionGORIsContinuousAtBubblePoint() {
        let pb = fluid.bubblePoint(temperature: 200)
        XCTAssertEqual(fluid.solutionGasOilRatio(pressure: pb - 0.01, temperature: 200), fluid.solutionGOR, accuracy: 0.5)
        XCTAssertEqual(fluid.solutionGasOilRatio(pressure: pb + 100, temperature: 200), fluid.solutionGOR)
    }

    func testOilPropertiesInPlausibleRange() {
        let bo = fluid.oilFVF(pressure: 4000, temperature: 200)
        XCTAssertEqual(bo, 1.271, accuracy: 0.01)
        let mu = fluid.oilViscosity(pressure: 4000, temperature: 200)
        XCTAssertEqual(mu, 0.775, accuracy: 0.02)
        let rho = fluid.oilDensity(pressure: 2000, temperature: 200)
        XCTAssert((40...55).contains(rho), "oil density \(rho)")
    }

    func testGasProperties() {
        XCTAssertEqual(fluid.gasZ(pressure: 2000, temperature: 200), 0.871, accuracy: 0.01)
        XCTAssertEqual(fluid.gasViscosity(pressure: 2000, temperature: 200), 0.0170, accuracy: 0.001)
        XCTAssertEqual(fluid.gasZ(pressure: 14.7, temperature: 60), 1.0, accuracy: 0.01)
    }

    func testBoIncreasesWithPressureBelowBubblePoint() {
        let a = fluid.oilFVF(pressure: 1000, temperature: 200)
        let b = fluid.oilFVF(pressure: 2000, temperature: 200)
        XCTAssertLessThan(a, b)
    }
}
