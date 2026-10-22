import FlowCore
import FlowGPU
import Metal
import XCTest

final class LiveInvasionTests: XCTestCase {
    /// A short exposure keeps the CPU reference fast enough for unit tests.
    private func testCase(hours: Double = 1) -> MudInvasionCase {
        var c = MudInvasionCase()
        c.exposureTime = hours
        return c
    }

    private func run(_ solver: LiveInvasionSolver, frames: Int) {
        let target = solver.setup.exposureTime / Double(frames)
        var guardCount = 0
        while !solver.isFinished && guardCount < frames * 20 {
            solver.advance(by: target, pressureIterations: 60)
            guardCount += 1
        }
    }

    func testSetupGeometry() {
        let c = testCase()
        let setup = LiveInvasionSetup(c, size: 64, invasionDepth: 4, heterogeneity: 0)
        XCTAssertEqual(setup.cells.count, 64 * 64)
        XCTAssertGreaterThan(setup.domainRadius, setup.wellboreRadius)
        // Corners lie outside the disc, the centre is inside the borehole.
        XCTAssertEqual(setup.cells[0], .outer)
        XCTAssertEqual(setup.cells[32 * 64 + 32], .mud)
        XCTAssertFalse(setup.wallCells.isEmpty)
        XCTAssertTrue(setup.k0.allSatisfy { $0 == 1 })
    }

    func testHeterogeneousFieldIsLogNormalAroundOne() {
        let setup = LiveInvasionSetup(testCase(), size: 96, heterogeneity: 0.6, correlationLength: 1)
        let rock = zip(setup.cells, setup.k0).filter { $0.0 == .rock }.map { Double($0.1) }
        let logs = rock.map { log($0) }
        let mean = logs.reduce(0, +) / Double(logs.count)
        let sd = (logs.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(logs.count)).squareRoot()
        XCTAssertEqual(sd, 0.6, accuracy: 0.25)
        XCTAssertGreaterThan(rock.max()!, 1.5)
        XCTAssertLessThan(rock.min()!, 0.67)
    }

    func testHomogeneousCaseMatchesOneDimensionalModel() {
        let c = testCase(hours: 1)
        let reference = MudInvasionSimulator.run(c)
        let setup = LiveInvasionSetup(c, size: 56, invasionDepth: reference.filtrateInvasionDepth, heterogeneity: 0)
        let solver = LiveInvasionSolver(setup: setup)
        run(solver, frames: 240)
        let stats = solver.stats

        XCTAssertEqual(stats.time, 1, accuracy: 1e-6)
        XCTAssertEqual(stats.cumulativeFiltrate, reference.totalFiltrate, accuracy: reference.totalFiltrate * 0.3)
        XCTAssertEqual(stats.cakeThickness, reference.finalCakeThickness, accuracy: reference.finalCakeThickness * 0.3)
        XCTAssertEqual(stats.filtrateDepth, reference.filtrateInvasionDepth, accuracy: max(reference.filtrateInvasionDepth * 0.35, 0.4))
        // Radially symmetric: the deepest invaded cell is close to the mean front.
        XCTAssertLessThan(stats.maxFiltrateDepth, stats.filtrateDepth * 1.5 + 0.5)
        XCTAssertLessThan(stats.minPermeabilityRatio, 1)
    }

    func testFiltrationSlowsAsCakeBuilds() {
        let c = testCase(hours: 0.5)
        let setup = LiveInvasionSetup(c, size: 48, invasionDepth: 3, heterogeneity: 0)
        let solver = LiveInvasionSolver(setup: setup)
        // The cake forms within seconds, so compare a rate soon after it forms with one at the end.
        var guardCount = 0
        while solver.time < 30 && guardCount < 5000 {
            solver.advance(by: 30 - solver.time)
            guardCount += 1
        }
        let early = solver.stats.filtrationRate
        run(solver, frames: 120)
        let late = solver.stats
        XCTAssertGreaterThan(early, late.filtrationRate * 2)
        XCTAssertGreaterThan(late.cakeThickness, 0.1)
    }

    func testFiltrateInvadesHighPermeabilityRockFirst() {
        let c = testCase(hours: 0.5)
        let setup = LiveInvasionSetup(c, size: 56, invasionDepth: 3, heterogeneity: 1.0, correlationLength: 1)
        let solver = LiveInvasionSolver(setup: setup)
        run(solver, frames: 120)
        let reach = setup.wellboreRadius + 2 * solver.stats.filtrateDepth * 0.0254
        var high: [Float] = [], low: [Float] = []
        for j in 0..<setup.size {
            for i in 0..<setup.size {
                let index = j * setup.size + i
                guard setup.cells[index] == .rock else { continue }
                let (x, y) = setup.position(i, j)
                guard (x * x + y * y).squareRoot() < reach else { continue }
                if setup.k0[index] > 1.5 { high.append(solver.saturation[index]) }
                if setup.k0[index] < 0.67 { low.append(solver.saturation[index]) }
            }
        }
        XCTAssertFalse(high.isEmpty)
        XCTAssertFalse(low.isEmpty)
        let meanHigh = high.reduce(0, +) / Float(high.count)
        let meanLow = low.reduce(0, +) / Float(low.count)
        XCTAssertGreaterThan(meanHigh, meanLow + 0.05)
    }

    /// The Metal kernels must reproduce the CPU reference. Skipped where no Metal device exists.
    func testGPUMatchesCPUReference() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let c = testCase(hours: 0.25)
        let setup = LiveInvasionSetup(c, size: 48, invasionDepth: 3, heterogeneity: 0.7, correlationLength: 1)
        let cpu = LiveInvasionSolver(setup: setup)
        let gpu = try LiveInvasionGPU(setup: setup, device: device, particleCount: 256)
        gpu.pressureIterations = 60
        let target = setup.exposureTime / 60
        for _ in 0..<40 {
            cpu.advance(by: target, pressureIterations: 60)
            gpu.advance(by: target)
        }
        gpu.waitUntilIdle()
        XCTAssertEqual(gpu.time, cpu.time, accuracy: cpu.time * 0.02)

        let a = cpu.stats, b = gpu.stats
        XCTAssertEqual(b.cumulativeFiltrate, a.cumulativeFiltrate, accuracy: a.cumulativeFiltrate * 0.05)
        XCTAssertEqual(b.cakeThickness, a.cakeThickness, accuracy: a.cakeThickness * 0.05)
        XCTAssertEqual(b.filtrateDepth, a.filtrateDepth, accuracy: max(a.filtrateDepth * 0.1, 0.1))

        let gpuPressure = gpu.readPressure()
        var worst: Float = 0
        for i in gpuPressure.indices { worst = max(worst, abs(gpuPressure[i] - cpu.pressure[i])) }
        XCTAssertLessThan(worst, 0.02)
    }

    func testSubstepsRespectCFLAndTarget() {
        let setup = LiveInvasionSetup(testCase(), size: 48, heterogeneity: 0)
        let small = setup.substeps(target: 1e-6, maxFaceFlux: 1e-3, maxSubsteps: 64)
        XCTAssertEqual(small.count, 1)
        XCTAssertEqual(small.dt, 1e-6, accuracy: 1e-12)
        let large = setup.substeps(target: 1e6, maxFaceFlux: 1e-3, maxSubsteps: 64)
        XCTAssertEqual(large.count, 64)
        XCTAssertLessThan(large.dt * 64, 1e6)
        XCTAssertEqual(setup.substeps(target: 0, maxFaceFlux: 1, maxSubsteps: 8).count, 0)
    }
}
