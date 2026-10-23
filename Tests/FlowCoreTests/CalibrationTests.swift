import FlowCore
import XCTest

final class CalibrationTests: XCTestCase {
    func testFilterPressFitRecoversSpurtAndSlope() throws {
        let times: [Double] = [0, 1, 2, 4, 7.5, 10, 15, 20, 25, 30]
        let spurt = 0.04, slope = 0.06  // cm and cm/√min
        let area = 45.8
        var test = FilterPressTest(times: times, volumes: times.map { (spurt + slope * $0.squareRoot()) * area })
        test.pressureDrop = 100
        let fit = try Calibration.fit(test)
        XCTAssertEqual(fit.spurt, spurt, accuracy: 1e-10)
        XCTAssertEqual(fit.slope, slope, accuracy: 1e-10)
        XCTAssertEqual(fit.rSquared, 1, accuracy: 1e-12)
        XCTAssertEqual(fit.apiFluidLoss, (spurt + slope * 30.0.squareRoot()) * 45.8, accuracy: 1e-8)

        // Forward check: the fitted cake permeability, used in V² = 2 kc Δp t / (μ α), gives the slope back.
        let kc = fit.cakePermeability * 9.869233e-16
        let m = (2 * kc * 100 * 6894.757 / (1e-3 * fit.cakeGrowth)).squareRoot()  // m/√s
        XCTAssertEqual(m * 100 * 60.0.squareRoot(), slope, accuracy: slope * 1e-9)
        XCTAssertEqual(fit.bridgingThickness, fit.cakeGrowth * spurt * 10, accuracy: 1e-12)
    }

    func testFitReportsUncertaintyForNoisyData() throws {
        let times: [Double] = [1, 2, 4, 7.5, 10, 15, 20, 25, 30]
        let noise: [Double] = [0.004, -0.003, 0.002, -0.004, 0.003, 0.001, -0.002, 0.003, -0.002]
        let test = FilterPressTest(times: times, volumes: zip(times, noise).map { (0.03 + 0.05 * $0.0.squareRoot() + $0.1) * 45.8 })
        let fit = try Calibration.fit(test)
        XCTAssertEqual(fit.slope, 0.05, accuracy: fit.slopeConfidence)
        XCTAssertEqual(fit.spurt, 0.03, accuracy: fit.spurtConfidence)
        XCTAssertGreaterThan(fit.slopeConfidence, 0)
        XCTAssertLessThan(fit.rSquared, 1)
        XCTAssertEqual(fit.residuals.count, times.count)
    }

    func testMeasuredCakeOverridesSolidsEstimate() throws {
        let times: [Double] = [1, 4, 9, 16, 25, 30]
        var test = FilterPressTest(times: times, volumes: times.map { (0.02 + 0.05 * $0.squareRoot()) * 45.8 })
        test.finalCakeThickness = 2
        let fit = try Calibration.fit(test)
        let filtrate = 0.05 * 30.0.squareRoot()
        XCTAssertEqual(fit.cakeGrowth, 0.2 / filtrate, accuracy: 1e-9)
    }

    func testTooFewPointsIsAnError() {
        XCTAssertThrowsError(try Calibration.fit(FilterPressTest(times: [0, 1, 2], volumes: [0, 1, 2])))
    }

    func testParsesCommonCSVLayouts() {
        let text = "time (min), volume (mL)\n1, 2.5\n2;3.1\n4\t4.0\n\n7.5 5.2\nnote,abc\n"
        let rows = Calibration.parseTwoColumns(text)
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows[3].0, 7.5)
        XCTAssertEqual(rows[3].1, 5.2)
    }

    func testReturnPermeabilityRoundTrip() {
        let f = 0.8, lambda = 40.0, c0 = 0.01, beta = 300.0
        var test = ReturnPermeabilityTest(initialPermeability: 150, returnPermeability: 0)
        test.coreLength = 5
        test.injectedPerArea = 3
        let length = 0.05, injected = 0.03
        let ratio = f * length / (length + beta * c0 * injected * (1 - exp(-lambda * length)))
        test.returnPermeability = 150 * ratio
        let fitted = test.damageCoefficient(filtrateFactor: f, filtrationCoefficient: lambda, finesConcentration: c0)
        XCTAssertEqual(fitted ?? 0, beta, accuracy: 1e-6)
        // A return permeability above F·k₀ cannot be explained by fines.
        test.returnPermeability = 150 * 0.95
        XCTAssertNil(test.damageCoefficient(filtrateFactor: f, filtrationCoefficient: lambda, finesConcentration: c0))
    }
}
