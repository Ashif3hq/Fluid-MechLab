import FlowCore
import FlowGPU
import Metal
import XCTest

final class Invasion3DTests: XCTestCase {
    private func smallOptions(heterogeneity: Double = 0) -> Invasion3DOptions {
        var o = Invasion3DOptions()
        o.heterogeneity = heterogeneity
        o.horizontalCorrelation = 1.5
        o.verticalCorrelation = 0.4
        o.intervalLength = 6
        o.domainDepth = 4
        return o
    }

    func testGridGeometry() {
        let setup = Invasion3DSetup(MudInvasionCase(), options: smallOptions(), sizeOverride: (20, 15, 4))
        XCTAssertEqual(setup.nt, 16, "angular count is rounded up to even")
        XCTAssertEqual(setup.cellCount, 20 * 16 * 4)
        XCTAssertEqual(setup.faces.first!, setup.wellboreRadius, accuracy: 1e-12)
        XCTAssertEqual(setup.faces.last!, setup.domainRadius, accuracy: 1e-9)
        // Cell volumes add up to the annulus.
        let annulus = Double.pi * (setup.domainRadius * setup.domainRadius - setup.wellboreRadius * setup.wellboreRadius) * setup.length
        let total = setup.volume.reduce(0, +) * Double(setup.columnCount)
        XCTAssertEqual(total, annulus, accuracy: annulus * 1e-12)
        // Geometric spacing: every cell has the same ratio of outer to inner radius.
        let ratios = (0..<setup.nr).map { setup.faces[$0 + 1] / setup.faces[$0] }
        XCTAssertEqual(ratios.max()!, ratios.min()!, accuracy: 1e-12)
    }

    func testPermeabilityFieldIsLogNormalAndLayered() {
        var options = smallOptions(heterogeneity: 0.7)
        options.horizontalCorrelation = 3
        options.verticalCorrelation = 0.3
        options.intervalLength = 8
        let setup = Invasion3DSetup(MudInvasionCase(), options: options, sizeOverride: (24, 32, 24))
        let logs = setup.k0.map { log(Double($0)) }
        let mean = logs.reduce(0, +) / Double(logs.count)
        let sd = (logs.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(logs.count)).squareRoot()
        XCTAssertEqual(sd, 0.7, accuracy: 0.3)
        XCTAssertEqual(mean, -0.7 * 0.7 / 2, accuracy: 0.3)
        // Layering: ln k changes faster from one layer to the next than around the well.
        var vertical = 0.0, angular = 0.0
        for k in 0..<(setup.nz - 1) {
            for j in 0..<(setup.nt - 1) {
                for i in 0..<setup.nr {
                    let a = setup.index(i, j, k)
                    vertical += abs(logs[setup.index(i, j, k + 1)] - logs[a]) / setup.dz
                    angular += abs(logs[setup.index(i, j + 1, k)] - logs[a]) / (setup.centres[i] * setup.dTheta)
                }
            }
        }
        XCTAssertGreaterThan(vertical, angular * 2)
    }

    /// Every verification case: exact solutions to round-off, and the expected convergence orders.
    func testVerificationSuitePasses() {
        for c in InvasionVerification.run(scheme: .tvd) {
            let detail = c.levels.map { "\($0.label): \($0.error)" }.joined(separator: ", ")
            XCTAssertTrue(c.passed, "\(c.id) \(c.title) failed: \(detail), order \(c.observedOrder.map { "\($0)" } ?? "–")")
        }
    }

    func testFirstOrderSchemeConverges() {
        let c = InvasionVerification.deepBedFiltration(scheme: .upwind)
        XCTAssertTrue(c.passed, "upwind deep-bed errors \(c.levels.map(\.error)), order \(c.observedOrder ?? .nan)")
        let tvd = InvasionVerification.deepBedFiltration(scheme: .tvd)
        XCTAssertLessThan(tvd.finestError, c.finestError / 3, "second order should be clearly more accurate")
    }

    /// For purely radial damage the 3D skin must equal the discrete Hawkins sum Σ (k₀/k − 1) ln(r₊/r₋).
    func testSkinMatchesHawkinsForRadialDamage() {
        let dims = (24, 6, 2)
        var options = smallOptions()
        options.domainDepth = 6
        var c = MudInvasionCase()
        c.modelRadius = 0
        let setup = Invasion3DSetup(c, options: options, sizeOverride: dims, permeabilityField: [Float](repeating: 1, count: 24 * 6 * 2))
        let profile = (0..<setup.nr).map { i in 0.15 + 0.85 * (1 - exp(-Double(i) / 5)) }
        var damaged = [Double](repeating: 1, count: setup.cellCount)
        for a in 0..<setup.cellCount { damaged[a] = profile[a % setup.nr] }
        let skin = Invasion3DSolver.skin(setup: setup, damaged: damaged, undamaged: [Double](repeating: 1, count: setup.cellCount))
        let hawkins = (0..<setup.nr).reduce(0.0) { $0 + (1 / profile[$1] - 1) * log(setup.faces[$1 + 1] / setup.faces[$1]) }
        XCTAssertEqual(skin, hawkins, accuracy: abs(hawkins) * 1e-8)
    }

    /// Uniform rock: the 3D model and the radial 1D model describe the same physics on different grids and schemes.
    func testHomogeneousCaseMatchesOneDimensionalModel() {
        var c = MudInvasionCase()
        c.exposureTime = 1
        let reference = MudInvasionSimulator.run(c)
        var options = smallOptions()
        options.domainDepth = nil
        let setup = Invasion3DSetup(c, options: options, invasionDepth: reference.filtrateInvasionDepth, sizeOverride: (48, 8, 2),
                                    permeabilityField: [Float](repeating: 1, count: 48 * 8 * 2))
        let solver = Invasion3DSolver(setup: setup)
        solver.advance(by: setup.exposureTime)
        let stats = solver.stats
        XCTAssertEqual(stats.time, 1, accuracy: 1e-9)
        XCTAssertEqual(stats.cumulativeFiltrate, reference.totalFiltrate, accuracy: reference.totalFiltrate * 0.1)
        XCTAssertEqual(stats.cakeMean, reference.finalCakeThickness, accuracy: reference.finalCakeThickness * 0.1)
        XCTAssertEqual(stats.filtrateDepth, reference.filtrateInvasionDepth, accuracy: max(reference.filtrateInvasionDepth * 0.15, 0.2))
        XCTAssertLessThan(stats.massBalanceError, 1e-8)
        XCTAssertLessThan(stats.minPermeabilityRatio, 1)
        let skin = solver.skin()
        XCTAssertEqual(skin, reference.skin, accuracy: max(abs(reference.skin) * 0.25, 0.3))
    }

    func testFiltrateInvadesHighPermeabilityLayersFurther() {
        var c = MudInvasionCase()
        c.exposureTime = 0.5
        let dims = (24, 8, 6)
        var field = [Float](repeating: 1, count: 24 * 8 * 6)
        let layers: [Float] = [0.3, 3, 0.3, 3, 0.3, 3]
        for a in field.indices { field[a] = layers[a / (24 * 8)] }
        var options = smallOptions()
        options.domainDepth = 8
        options.anisotropy = 0.05
        // A thin, leaky cake, so the rock and not the cake sets the rate in each layer.
        c.cakePermeability = 5
        let setup = Invasion3DSetup(c, options: options, sizeOverride: dims, permeabilityField: field)
        let solver = Invasion3DSolver(setup: setup)
        func depth(_ k: Int) -> Double {
            Invasion3DMetrics.frontRadius(setup: setup, j: 0, k: k) { solver.saturation[$0] } - setup.wellboreRadius
        }
        // Stop while the fast layers' front is still inside the model, so neither front is clipped by the outer edge.
        let room = setup.domainRadius - setup.wellboreRadius
        while depth(1) < 0.45 * room && solver.time < setup.exposureTime * (1 - 1e-12) {
            solver.advance(by: setup.exposureTime / 400)
        }
        XCTAssertLessThan(depth(1), 0.8 * room, "front reached the edge of the model")
        XCTAssertGreaterThan(depth(1), depth(0) * 1.3)
        XCTAssertGreaterThan(depth(3), depth(2) * 1.3)
        XCTAssertGreaterThan(solver.stats.frontSpread, 0)
    }

    /// The Metal kernels must reproduce the CPU reference. Skipped where no Metal device exists.
    func testGPUMatchesCPUReference() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        var c = MudInvasionCase()
        c.exposureTime = 0.25
        let setup = Invasion3DSetup(c, options: smallOptions(heterogeneity: 0.7), sizeOverride: (16, 16, 6))
        let cpu = Invasion3DSolver(setup: setup)
        let gpu = try Invasion3DGPU(setup: setup, device: device)
        cpu.advance(by: setup.exposureTime)
        gpu.advance(by: setup.exposureTime)
        gpu.waitUntilIdle()
        XCTAssertEqual(gpu.time, cpu.time, accuracy: cpu.time * 1e-9)

        let a = cpu.stats, b = gpu.stats
        XCTAssertEqual(b.cumulativeFiltrate, a.cumulativeFiltrate, accuracy: a.cumulativeFiltrate * 0.01)
        XCTAssertEqual(b.cakeMean, a.cakeMean, accuracy: a.cakeMean * 0.01)
        XCTAssertEqual(b.filtrateDepth, a.filtrateDepth, accuracy: max(a.filtrateDepth * 0.02, 0.02))
        XCTAssertEqual(b.frontMax, a.frontMax, accuracy: max(a.frontMax * 0.05, 0.05))
        XCTAssertEqual(b.minPermeabilityRatio, a.minPermeabilityRatio, accuracy: 0.02)
        XCTAssertLessThan(b.massBalanceError, 2e-3)

        let p = gpu.readPressure()
        var worst = 0.0
        for i in p.indices { worst = max(worst, abs(Double(p[i]) - cpu.pressure[i])) }
        XCTAssertLessThan(worst, 1e-3)

        let gpuSkin = gpu.computeSkin(), cpuSkin = cpu.skin()
        XCTAssertEqual(gpuSkin, cpuSkin, accuracy: max(abs(cpuSkin) * 0.02, 0.02))
    }

    func testExports() throws {
        var c = MudInvasionCase()
        c.exposureTime = 0.05
        let dims = (8, 6, 3)
        let setup = Invasion3DSetup(c, options: smallOptions(heterogeneity: 0.4), sizeOverride: dims)
        let solver = Invasion3DSolver(setup: setup)
        solver.advance(by: setup.exposureTime)
        let snap = solver.snapshot

        let vtk = Invasion3DExport.vtk(snap)
        let text = String(decoding: vtk.prefix(300), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("# vtk DataFile Version 3.0"))
        XCTAssertTrue(text.contains("DIMENSIONS 9 7 4"))
        let points = 9 * 7 * 4
        XCTAssertGreaterThan(vtk.count, points * 12 + 8 * setup.cellCount * 4)

        let profile = Invasion3DExport.radialProfileCSV(snap).split(separator: "\n")
        XCTAssertEqual(profile.count, setup.nr + 1)
        let map = Invasion3DExport.frontMapCSV(snap).split(separator: "\n")
        XCTAssertEqual(map.count, setup.columnCount + 1)
        let history = Invasion3DExport.historyCSV([solver.stats]).split(separator: "\n")
        XCTAssertEqual(history.count, 2)

        let record = Invasion3DRunRecord(application: "test", study: "unit", solver: "CPU", device: "none", setup: setup,
                                         finalStats: solver.stats, skin: solver.skin(), history: [solver.stats])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let back = try decoder.decode(Invasion3DRunRecord.self, from: record.json())
        XCTAssertEqual(back.options, setup.options)
        XCTAssertEqual(back.mud, c)
        XCTAssertEqual(back.grid.radialCells, 8)
        XCTAssertEqual(back.finalStats, solver.stats)
    }
}
