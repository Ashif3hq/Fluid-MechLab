import Foundation

/// Grid, rock and mud parameters for the live 2D invasion model: a horizontal slice through the
/// formation around the borehole, on a square grid.
///
/// Equations (the same physics as `MudInvasionSimulator`, but in 2D so heterogeneity shows):
/// - Incompressible Darcy flow ∇·(k∇p) = 0, mud pressure in the borehole, pore pressure at the edge.
///   The external cake is a resistance h/kc on each borehole face, and the ring between the grid edge
///   and the 1D model radius is a resistance on each edge face, so rates match the 1D model.
/// - Cake growth dh/dt = α uₙ (1 − h/h_eq) on every wall cell.
/// - Filtrate saturation: φ ΔS ∂s/∂t + ∇·(u s) = 0, s = 1 entering from the borehole.
/// - Fines: φ ∂c/∂t + ∇·(u c) = −λ|u|c, ∂σ/∂t = λ|u|c, λ = λ₀(1 − σ/σmax), inlet c falls to 0 as the cake bridges.
/// - Permeability k = k₀(x) · (1 − (1 − F) s) / (1 + βσ).
///
/// Pressures are normalised (1 in the borehole, 0 at the edge) and permeabilities are relative to the
/// mean, so the GPU can work in single precision.
public struct LiveInvasionSetup: Sendable {
    public enum Cell: UInt8, Sendable {
        case rock = 0
        case mud = 1
        case outer = 2
    }

    /// Staircase correction: a square-cell circle has 4/π times the real perimeter.
    public static let wallFactor = Double.pi / 4

    public let size: Int
    /// Cell edge, m.
    public let cellSize: Double
    /// Borehole radius, m.
    public let wellboreRadius: Double
    /// Radius of the simulated rock disc, m.
    public let domainRadius: Double
    /// Exposure time to simulate, s.
    public let exposureTime: Double
    /// k̄·Δp/μ, m²/s. A normalised pressure difference divided by a resistance (m) gives a Darcy velocity.
    public let velocityScale: Double
    public let porosity: Double
    /// Porosity times the displaceable fraction: the pore volume the filtrate fills.
    public let displaceablePorosity: Double
    /// Cake volume per filtrate volume.
    public let cakeGrowth: Double
    /// Equilibrium cake thickness, m (0 = static filtration).
    public let equilibriumCake: Double
    /// Cake thickness that stops fines entering, m.
    public let bridgingCake: Double
    /// Cake permeability relative to the mean rock permeability.
    public let cakeMobility: Double
    public let finesInlet: Double
    /// λ₀, 1/m.
    public let filtrationCoefficient: Double
    public let damageCoefficient: Double
    public let maxRetention: Double
    public let filtrateDamageFactor: Double
    /// Resistance of the ring between the grid edge and the 1D model radius, m.
    public let outerResistance: Double
    public let cells: [Cell]
    /// Undamaged permeability relative to the mean, per cell.
    public let k0: [Float]

    /// - Parameters:
    ///   - invasionDepth: expected filtrate depth in inches (from the 1D model); sizes the grid so the invaded zone fills the view.
    ///   - heterogeneity: standard deviation of ln k.
    ///   - correlationLength: size of permeability features, inches.
    public init(_ c: MudInvasionCase, size: Int = 256, invasionDepth: Double? = nil,
                heterogeneity: Double = 0.5, correlationLength: Double = 1.5, seed: UInt64 = 7) {
        let inToM = 0.0254
        let n = max(size, 24)
        let rw = c.wellboreRadius * inToM
        let depth = min(max(1.8 * (invasionDepth ?? 5), 3), 24) * inToM
        let radius = rw + depth
        // Two spare cells around the disc so every rock cell has four neighbours.
        let dx = 2 * radius / Double(n - 4)
        let kMean = c.permeability * MudInvasionSimulator.mdToM2

        self.size = n
        cellSize = dx
        wellboreRadius = rw
        domainRadius = radius
        exposureTime = c.exposureTime * 3600
        velocityScale = kMean * c.overbalance * MudInvasionSimulator.psiToPa / (c.filtrateViscosity * MudInvasionSimulator.cpToPaS)
        porosity = c.porosity
        displaceablePorosity = c.porosity * c.displaceableFraction
        cakeGrowth = c.mudSolidsFraction / ((1 - c.cakePorosity) * (1 - c.mudSolidsFraction))
        equilibriumCake = c.equilibriumCakeThickness * 1e-3
        bridgingCake = max(c.bridgingThickness * 1e-3, 1e-6)
        cakeMobility = c.cakePermeability / c.permeability
        finesInlet = c.finesConcentration
        filtrationCoefficient = c.filtrationCoefficient
        damageCoefficient = c.damageCoefficient
        maxRetention = c.maxRetention
        filtrateDamageFactor = c.filtrateDamageFactor
        let modelRadius = max(c.modelRadius * MudInvasionSimulator.ftToM, rw * 1.5)
        outerResistance = modelRadius > radius ? radius * log(modelRadius / radius) : 0

        // Gaussian random field from random Fourier modes, for log-normal permeability.
        var rng = SplitMix64(seed: seed)
        let modes = 48
        let kappa = 2 * Double.pi / max(correlationLength * inToM, dx)
        let waves: [(kx: Double, ky: Double, phase: Double)] = (0..<modes).map { _ in
            let angle = rng.unit() * 2 * .pi
            let magnitude = kappa * (0.5 + rng.unit())
            return (magnitude * cos(angle), magnitude * sin(angle), rng.unit() * 2 * .pi)
        }
        let amplitude = (2.0 / Double(modes)).squareRoot()
        let half = Double(n) / 2

        var cells = [Cell](repeating: .rock, count: n * n)
        var k0 = [Float](repeating: 1, count: n * n)
        for j in 0..<n {
            for i in 0..<n {
                let x = (Double(i) + 0.5 - half) * dx
                let y = (Double(j) + 0.5 - half) * dx
                let r = (x * x + y * y).squareRoot()
                let index = j * n + i
                if r < rw {
                    cells[index] = .mud
                } else if r > radius {
                    cells[index] = .outer
                } else if heterogeneity > 0 {
                    var g = 0.0
                    for w in waves { g += cos(w.kx * x + w.ky * y + w.phase) }
                    g *= amplitude
                    k0[index] = Float(exp(heterogeneity * g - heterogeneity * heterogeneity / 2))
                }
            }
        }
        self.cells = cells
        self.k0 = k0
    }

    /// Centre of cell (i, j) relative to the well axis, m.
    public func position(_ i: Int, _ j: Int) -> (x: Double, y: Double) {
        let half = Double(size) / 2
        return ((Double(i) + 0.5 - half) * cellSize, (Double(j) + 0.5 - half) * cellSize)
    }

    /// Initial pressure guess: the steady radial profile without a cake.
    public func radialPressure() -> [Float] {
        let n = size
        var p = [Float](repeating: 0, count: n * n)
        let outer = log(domainRadius / wellboreRadius) + outerResistance / domainRadius
        for j in 0..<n {
            for i in 0..<n {
                let index = j * n + i
                switch cells[index] {
                case .mud: p[index] = 1
                case .outer: p[index] = 0
                case .rock:
                    let (x, y) = position(i, j)
                    let r = max((x * x + y * y).squareRoot(), wellboreRadius)
                    p[index] = Float(1 - log(r / wellboreRadius) / outer)
                }
            }
        }
        return p
    }

    /// Rock cells that touch the borehole.
    public var wallCells: [Int] {
        let n = size
        return (0..<(n * n)).filter { index in
            cells[index] == .rock && [index - 1, index + 1, index - n, index + n].contains { cells[$0] == .mud }
        }
    }

    /// Chooses the substeps for one frame. Returns the number of substeps and their length, s.
    public func substeps(target: Double, maxFaceFlux: Double, maxSubsteps: Int) -> (count: Int, dt: Double) {
        guard target > 0 else { return (0, 0) }
        let cfl = 0.2 * displaceablePorosity * cellSize / max(maxFaceFlux, 1e-30)
        if target <= cfl * Double(maxSubsteps) {
            let count = max(1, Int((target / cfl).rounded(.up)))
            return (count, target / Double(count))
        }
        return (maxSubsteps, cfl)
    }
}

/// Summary numbers from the live model.
public struct LiveInvasionStats: Equatable, Sendable {
    /// Simulated time, hours.
    public var time: Double = 0
    /// Depth of a circle with the same invaded area, inches.
    public var filtrateDepth: Double = 0
    /// Deepest invaded cell, inches.
    public var maxFiltrateDepth: Double = 0
    /// Mean external cake thickness, mm.
    public var cakeThickness: Double = 0
    /// Filtrate flux at the borehole wall, cm/hr.
    public var filtrationRate: Double = 0
    /// Cumulative filtrate per unit wall area, cm.
    public var cumulativeFiltrate: Double = 0
    /// Lowest k/k₀ in the rock.
    public var minPermeabilityRatio: Double = 1

    public init() {}
}

/// Reads stats from the model state. Shared by the CPU solver and the GPU solver, whose buffers live in
/// unified memory and can be read directly.
public enum LiveInvasionMetrics {
    public static func stats(
        setup: LiveInvasionSetup, wallCells: [Int], time: Double, cumulativeFiltrate: Double,
        pressure: UnsafeBufferPointer<Float>, saturation: (Int) -> Float, retained: (Int) -> Float,
        cake: (Int) -> Float, mobility: UnsafeBufferPointer<Float>
    ) -> LiveInvasionStats {
        let n = setup.size
        let inToM = 0.0254
        var invadedArea = 0.0
        var maxDepth = 0.0
        var minRatio = 1.0
        let cellArea = setup.cellSize * setup.cellSize
        for j in 0..<n {
            for i in 0..<n {
                let index = j * n + i
                guard setup.cells[index] == .rock else { continue }
                let s = Double(saturation(index))
                if s > 0.5 {
                    invadedArea += cellArea
                    let (x, y) = setup.position(i, j)
                    maxDepth = max(maxDepth, (x * x + y * y).squareRoot() - setup.wellboreRadius)
                }
                let ratio = (1 - (1 - setup.filtrateDamageFactor) * s) / (1 + setup.damageCoefficient * Double(retained(index)))
                minRatio = min(minRatio, ratio)
            }
        }
        let rw = setup.wellboreRadius
        var stats = LiveInvasionStats()
        stats.time = time / 3600
        stats.filtrateDepth = ((rw * rw + invadedArea / .pi).squareRoot() - rw) / inToM
        stats.maxFiltrateDepth = maxDepth / inToM
        stats.cakeThickness = wallCells.isEmpty ? 0 : wallCells.reduce(0) { $0 + Double(cake($1)) } / Double(wallCells.count) * 1e3
        let inflow = wallInflow(setup: setup, wallCells: wallCells, pressure: pressure, cake: cake, mobility: mobility)
        stats.filtrationRate = inflow / (2 * .pi * rw) * 100 * 3600
        stats.cumulativeFiltrate = cumulativeFiltrate / (2 * .pi * rw) * 100
        stats.minPermeabilityRatio = minRatio
        return stats
    }

    /// Filtrate entering the rock per metre of well, m²/s.
    public static func wallInflow(
        setup: LiveInvasionSetup, wallCells: [Int], pressure: UnsafeBufferPointer<Float>,
        cake: (Int) -> Float, mobility: UnsafeBufferPointer<Float>
    ) -> Double {
        let n = setup.size
        var total = 0.0
        for a in wallCells {
            for b in [a - 1, a + 1, a - n, a + n] where setup.cells[b] == .mud {
                let resistance = setup.cellSize / (2 * Double(mobility[a])) + Double(cake(a)) / setup.cakeMobility
                total += setup.velocityScale * LiveInvasionSetup.wallFactor / resistance * Double(1 - pressure[a]) * setup.cellSize
            }
        }
        return total
    }
}

/// Reference implementation of the live model on the CPU. The Metal solver runs the same steps on the GPU;
/// tests compare the two and check this one against the 1D model.
public final class LiveInvasionSolver {
    public let setup: LiveInvasionSetup
    public private(set) var time = 0.0
    /// Filtrate entered per metre of well, m².
    public private(set) var cumulativeFiltrate = 0.0
    public private(set) var pressure: [Float]
    public private(set) var saturation: [Float]
    public private(set) var fines: [Float]
    public private(set) var retained: [Float]
    public private(set) var cake: [Float]
    public private(set) var mobility: [Float]
    /// Cell velocity (x, y) and the largest face flux, m/s.
    public private(set) var velocity: [SIMD3<Float>]
    public let wallCells: [Int]
    public var overRelaxation: Float = 1.85

    public init(setup: LiveInvasionSetup) {
        self.setup = setup
        let count = setup.size * setup.size
        pressure = setup.radialPressure()
        saturation = [Float](repeating: 0, count: count)
        fines = [Float](repeating: 0, count: count)
        retained = [Float](repeating: 0, count: count)
        cake = [Float](repeating: 0, count: count)
        mobility = setup.k0
        velocity = [SIMD3<Float>](repeating: .zero, count: count)
        wallCells = setup.wallCells
    }

    public var isFinished: Bool { time >= setup.exposureTime }

    /// Advances by up to `target` seconds. Returns the simulated time actually covered.
    @discardableResult
    public func advance(by target: Double, pressureIterations: Int = 60, maxSubsteps: Int = 64) -> Double {
        let target = min(target, setup.exposureTime - time)
        guard target > 0 else { return 0 }
        updateMobility()
        solvePressure(iterations: pressureIterations)
        let maxFlux = updateVelocity()
        let steps = setup.substeps(target: target, maxFaceFlux: maxFlux, maxSubsteps: maxSubsteps)
        for _ in 0..<steps.count { transport(dt: steps.dt) }
        return Double(steps.count) * steps.dt
    }

    public var stats: LiveInvasionStats {
        pressure.withUnsafeBufferPointer { p in
            mobility.withUnsafeBufferPointer { m in
                LiveInvasionMetrics.stats(
                    setup: setup, wallCells: wallCells, time: time, cumulativeFiltrate: cumulativeFiltrate,
                    pressure: p, saturation: { self.saturation[$0] }, retained: { self.retained[$0] },
                    cake: { self.cake[$0] }, mobility: m)
            }
        }
    }

    // MARK: Steps (mirrored by the Metal kernels)

    func updateMobility() {
        let fd = Float(setup.filtrateDamageFactor)
        let beta = Float(setup.damageCoefficient)
        for index in mobility.indices where setup.cells[index] == .rock {
            mobility[index] = setup.k0[index] * (1 - (1 - fd) * saturation[index]) / (1 + beta * retained[index])
        }
    }

    /// Face conductance from rock cell `a` to neighbour `b`, 1/m.
    private func conductance(_ a: Int, _ b: Int) -> Float {
        let dx = Float(setup.cellSize)
        let halfA = dx / (2 * mobility[a])
        switch setup.cells[b] {
        case .rock: return 1 / (halfA + dx / (2 * mobility[b]))
        case .mud: return Float(LiveInvasionSetup.wallFactor) / (halfA + cake[a] / Float(setup.cakeMobility))
        case .outer: return Float(LiveInvasionSetup.wallFactor) / (halfA + Float(setup.outerResistance))
        }
    }

    func solvePressure(iterations: Int) {
        let n = setup.size
        let offsets = [-1, 1, -n, n]
        for _ in 0..<iterations {
            for colour in 0..<2 {
                for j in 1..<(n - 1) {
                    var i = 1 + (j + colour + 1) % 2
                    while i < n - 1 {
                        let a = j * n + i
                        if setup.cells[a] == .rock {
                            var sum: Float = 0, weight: Float = 0
                            for o in offsets {
                                let b = a + o
                                let t = conductance(a, b)
                                sum += t * pressure[b]
                                weight += t
                            }
                            pressure[a] += overRelaxation * (sum / weight - pressure[a])
                        }
                        i += 2
                    }
                }
            }
        }
    }

    /// Returns the largest face flux, m/s.
    func updateVelocity() -> Double {
        let n = setup.size
        let scale = Float(setup.velocityScale)
        var maxFlux: Float = 0
        func flux(_ a: Int, _ b: Int) -> Float { scale * conductance(a, b) * (pressure[a] - pressure[b]) }
        for a in velocity.indices where setup.cells[a] == .rock {
            let east = flux(a, a + 1), west = flux(a, a - 1), north = flux(a, a + n), south = flux(a, a - n)
            let largest = max(abs(east), abs(west), abs(north), abs(south))
            velocity[a] = SIMD3(0.5 * (east - west), 0.5 * (north - south), largest)
            maxFlux = max(maxFlux, largest)
        }
        return Double(maxFlux)
    }

    func transport(dt: Double) {
        let n = setup.size
        let scale = Float(setup.velocityScale)
        let dx = Float(setup.cellSize)
        let dtf = Float(dt)
        let phi = Float(setup.porosity), phiD = Float(setup.displaceablePorosity)
        let wall = Float(LiveInvasionSetup.wallFactor)
        var newS = saturation, newC = fines, newSigma = retained, newCake = cake
        var inflow: Float = 0
        let offsets = [-1, 1, -n, n]
        for a in saturation.indices where setup.cells[a] == .rock {
            let inlet = Float(setup.finesInlet) * max(0, 1 - cake[a] / Float(setup.bridgingCake))
            var sOut: Float = 0, cOut: Float = 0, mudIn: Float = 0, mudFaces: Float = 0
            for o in offsets {
                let b = a + o
                let f = scale * conductance(a, b) * (pressure[a] - pressure[b])
                if f > 0 {
                    sOut += f * saturation[a]
                    cOut += f * fines[a]
                } else {
                    switch setup.cells[b] {
                    case .rock:
                        sOut += f * saturation[b]
                        cOut += f * fines[b]
                    case .mud:
                        sOut += f
                        cOut += f * inlet
                        mudIn -= f
                        mudFaces += 1
                    case .outer:
                        break
                    }
                }
            }
            newS[a] = min(max(saturation[a] - dtf / (phiD * dx) * sOut, 0), 1)
            let v = velocity[a]
            let speed = (v.x * v.x + v.y * v.y).squareRoot()
            let lambda = Float(setup.filtrationCoefficient) * max(0, 1 - retained[a] / Float(setup.maxRetention))
            let capture = lambda * speed * fines[a]
            newC[a] = max(fines[a] + dtf / phi * (-cOut / dx - capture), 0)
            newSigma[a] = min(retained[a] + dtf * capture, Float(setup.maxRetention))
            if mudFaces > 0 {
                let un = mudIn / mudFaces / wall
                var dh = Float(setup.cakeGrowth) * un * dtf
                if setup.equilibriumCake > 0 { dh *= max(0, 1 - cake[a] / Float(setup.equilibriumCake)) }
                newCake[a] = cake[a] + dh
                inflow += mudIn
            }
        }
        saturation = newS
        fines = newC
        retained = newSigma
        cake = newCake
        cumulativeFiltrate += Double(inflow) * setup.cellSize * dt
        time += dt
    }
}

/// Small deterministic generator so the permeability field is reproducible.
struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}
