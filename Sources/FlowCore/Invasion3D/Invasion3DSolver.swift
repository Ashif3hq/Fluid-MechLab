import Foundation

/// Summary of the 3D model state.
public struct Invasion3DStats: Equatable, Codable, Sendable {
    /// Simulated time, hours.
    public var time: Double = 0
    /// Depth of a cylinder holding the same filtrate volume, inches.
    public var filtrateDepth: Double = 0
    /// Front depth (s = 0.5) over the columns of the grid, inches.
    public var frontMin: Double = 0
    public var frontMax: Double = 0
    public var frontMean: Double = 0
    /// Standard deviation of the front depth over the columns, inches. Rises with fingering.
    public var frontSpread: Double = 0
    /// External cake thickness over the wall, mm.
    public var cakeMean: Double = 0
    public var cakeMin: Double = 0
    public var cakeMax: Double = 0
    /// Filtrate flux at the wall, cm/h.
    public var filtrationRate: Double = 0
    /// Filtrate that entered through the wall per unit wall area, cm.
    public var cumulativeFiltrate: Double = 0
    /// |stored + flowed out − injected| / injected for the filtrate.
    public var massBalanceError: Double = 0
    /// Lowest k/k₀ in the rock.
    public var minPermeabilityRatio: Double = 1
    /// Volume-weighted mean k/k₀ within the filtrate-invaded rock.
    public var meanInvadedPermeabilityRatio: Double = 1
    /// Number of pressure solves so far.
    public var pressureSolves: Int = 0
    /// Iterations of the last pressure solve.
    public var lastIterations: Int = 0
    /// Relative difference between wall inflow and outer outflow after the last pressure solve.
    public var lastImbalance: Double = 0
    /// Transport steps so far.
    public var transportSteps: Int = 0

    public init() {}
}

/// Reads stats from the model state. Shared by the CPU and GPU solvers.
public enum Invasion3DMetrics {
    public static func stats(
        setup: Invasion3DSetup, time: Double, wallInflow: Double, injected: Double, outflow: Double,
        saturation: (Int) -> Double, retained: (Int) -> Double, cake: (Int) -> Double
    ) -> Invasion3DStats {
        let inToM = 0.0254
        let rw = setup.wellboreRadius
        var stored = 0.0
        var minRatio = 1.0
        var invadedVolume = 0.0, invadedRatio = 0.0
        for k in 0..<setup.nz {
            for j in 0..<setup.nt {
                for i in 0..<setup.nr {
                    let a = setup.index(i, j, k)
                    let s = saturation(a)
                    let v = setup.volume[i]
                    stored += s * setup.displaceablePorosity * v
                    let ratio = setup.damageRatio(saturation: s, retained: retained(a))
                    minRatio = min(minRatio, ratio)
                    invadedVolume += s * v
                    invadedRatio += s * v * ratio
                }
            }
        }

        var fronts: [Double] = []
        fronts.reserveCapacity(setup.columnCount)
        var cakes: [Double] = []
        cakes.reserveCapacity(setup.columnCount)
        for k in 0..<setup.nz {
            for j in 0..<setup.nt {
                fronts.append(frontRadius(setup: setup, j: j, k: k, saturation: saturation) - rw)
                cakes.append(cake(setup.column(j, k)))
            }
        }
        let count = Double(max(fronts.count, 1))
        let mean = fronts.reduce(0, +) / count
        let variance = fronts.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / count

        var stats = Invasion3DStats()
        stats.time = time / 3600
        let equivalent = (rw * rw + invadedVolume / (.pi * setup.length)).squareRoot()
        stats.filtrateDepth = (equivalent - rw) / inToM
        stats.frontMin = (fronts.min() ?? 0) / inToM
        stats.frontMax = (fronts.max() ?? 0) / inToM
        stats.frontMean = mean / inToM
        stats.frontSpread = variance.squareRoot() / inToM
        stats.cakeMean = cakes.reduce(0, +) / Double(max(cakes.count, 1)) * 1e3
        stats.cakeMin = (cakes.min() ?? 0) * 1e3
        stats.cakeMax = (cakes.max() ?? 0) * 1e3
        stats.filtrationRate = wallInflow / setup.wallArea * 100 * 3600
        stats.cumulativeFiltrate = injected / setup.wallArea * 100
        stats.massBalanceError = injected > 0 ? abs(stored + outflow - injected) / injected : 0
        stats.minPermeabilityRatio = minRatio
        stats.meanInvadedPermeabilityRatio = invadedVolume > 0 ? invadedRatio / invadedVolume : 1
        return stats
    }

    /// Radius where the filtrate saturation along one radial line falls through 0.5, m.
    /// The wall itself counts as saturation 1.
    public static func frontRadius(setup: Invasion3DSetup, j: Int, k: Int, saturation: (Int) -> Double) -> Double {
        var previousR = setup.wellboreRadius
        var previousS = 1.0
        for i in 0..<setup.nr {
            let s = saturation(setup.index(i, j, k))
            let r = setup.centres[i]
            if s < 0.5 {
                let f = (previousS - 0.5) / max(previousS - s, 1e-12)
                return previousR + f * (r - previousR)
            }
            previousR = r
            previousS = s
        }
        return setup.domainRadius
    }
}

/// Reference implementation of the 3D model in double precision on the CPU.
///
/// The Metal solver (`Invasion3DGPU`) runs the same transport steps; its pressure solve is a red-black line SOR,
/// while this one uses conjugate gradients with a radial-line preconditioner, so agreement between the two is an
/// independent check of the pressure field.
public final class Invasion3DSolver {
    public let setup: Invasion3DSetup
    public private(set) var time = 0.0
    public private(set) var pressure: [Double]
    public private(set) var saturation: [Double]
    public private(set) var fines: [Double]
    public private(set) var retained: [Double]
    /// External cake thickness per column, m.
    public private(set) var cake: [Double]
    public private(set) var mobility: [Double]
    /// Flow rates per cell, m³/s: (inner radial face, θ− face, z− face, outer radial face), positive towards +r, +θ, +z.
    public private(set) var flux: [SIMD4<Double>]
    /// Darcy speed at the cell centre, m/s.
    public private(set) var speed: [Double]
    /// Filtrate volume that entered through the wall, and that left through the outer boundary, m³.
    public private(set) var injected = 0.0
    public private(set) var outflow = 0.0
    public private(set) var pressureSolves = 0
    public private(set) var transportSteps = 0
    public private(set) var lastIterations = 0
    public private(set) var lastImbalance = 0.0
    /// Relative tolerance of the conjugate-gradient pressure solve.
    public var pressureTolerance = 1e-10

    public init(setup: Invasion3DSetup) {
        self.setup = setup
        let n = setup.cellCount
        pressure = setup.radialPressure()
        saturation = [Double](repeating: 0, count: n)
        fines = [Double](repeating: 0, count: n)
        retained = [Double](repeating: 0, count: n)
        cake = [Double](repeating: 0, count: setup.columnCount)
        mobility = setup.k0.map(Double.init)
        flux = [SIMD4<Double>](repeating: .zero, count: n)
        speed = [Double](repeating: 0, count: n)
    }

    public var isFinished: Bool { time >= setup.exposureTime * (1 - 1e-12) }

    /// Filtrate entering through the wall at the last pressure solve, m³/s.
    public var wallInflow: Double {
        var total = 0.0
        for k in 0..<setup.nz {
            for j in 0..<setup.nt { total += max(flux[setup.index(0, j, k)].x, 0) }
        }
        return total
    }

    public var stats: Invasion3DStats {
        var s = Invasion3DMetrics.stats(
            setup: setup, time: time, wallInflow: wallInflow, injected: injected, outflow: outflow,
            saturation: { self.saturation[$0] }, retained: { self.retained[$0] }, cake: { self.cake[$0] })
        s.pressureSolves = pressureSolves
        s.lastIterations = lastIterations
        s.lastImbalance = lastImbalance
        s.transportSteps = transportSteps
        return s
    }

    /// Advances by up to `target` seconds (stopping at the end of the exposure). Returns the time covered.
    @discardableResult
    public func advance(by target: Double, maxCycles: Int = .max) -> Double {
        let end = min(time + target, setup.exposureTime)
        let start = time
        var cycles = 0
        while time < end * (1 - 1e-12) && cycles < maxCycles {
            cycle(upTo: end)
            cycles += 1
        }
        return time - start
    }

    /// One pressure solve followed by the transport steps it allows.
    public func cycle(upTo end: Double) {
        updateMobility()
        let result = Invasion3DSolver.solvePressure(setup: setup, mobility: mobility, cake: cake, pressure: &pressure,
                                                    tolerance: pressureTolerance)
        lastIterations = result.iterations
        lastImbalance = result.imbalance
        pressureSolves += 1
        let limits = updateFluxes()
        let step = setup.courant / max(limits.maxRate, 1e-300)
        let cakeLimit = limits.maxCakeRate > 0 ? setup.options.cakeCoupling / limits.maxCakeRate : .infinity
        let span = min(cakeLimit, Double(setup.options.maxStepsPerPressureSolve) * step, end - time)
        guard span > 0 else { return }
        let count = max(1, Int((span / step - 1e-9).rounded(.up)))
        let dt = span / Double(count)
        let inflow = wallInflow
        for _ in 0..<count { transport(dt: dt) }
        injected += inflow * span
    }

    // MARK: Steps (mirrored by the Metal kernels)

    func updateMobility() {
        for a in mobility.indices {
            mobility[a] = Double(setup.k0[a]) * setup.damageRatio(saturation: saturation[a], retained: retained[a])
        }
    }

    /// Conductances (1/m) for a mobility field: radial to the next cell (outer boundary for the last cell),
    /// angular across the θ− face, axial across the z− face, and the wall face of each column.
    struct Conductances {
        var radial: [Double]
        var angular: [Double]
        var axial: [Double]
        var wall: [Double]
    }

    static func conductances(setup: Invasion3DSetup, mobility m: [Double], cake: [Double]?) -> Conductances {
        let n = setup.cellCount
        var radial = [Double](repeating: 0, count: n)
        var angular = [Double](repeating: 0, count: n)
        var axial = [Double](repeating: 0, count: n)
        var wall = [Double](repeating: 0, count: setup.columnCount)
        let hr = setup.halfRadial, ht = setup.halfAngular, anis = setup.anisotropy
        for k in 0..<setup.nz {
            for j in 0..<setup.nt {
                let jm = (j + setup.nt - 1) % setup.nt
                for i in 0..<setup.nr {
                    let a = setup.index(i, j, k)
                    if i < setup.nr - 1 {
                        radial[a] = 1 / (hr / m[a] + hr / m[a + 1])
                    } else {
                        radial[a] = 1 / (hr / m[a] + setup.outerResistance)
                    }
                    angular[a] = 1 / (ht / m[a] + ht / m[setup.index(i, jm, k)])
                    if k > 0 {
                        let hz = setup.halfAxial[i] / anis
                        axial[a] = 1 / (hz / m[a] + hz / m[setup.index(i, j, k - 1)])
                    }
                }
                let col = setup.column(j, k)
                let h = cake?[col] ?? 0
                wall[col] = 1 / (hr / m[setup.index(0, j, k)] + setup.cakeResistance(h))
            }
        }
        return Conductances(radial: radial, angular: angular, axial: axial, wall: wall)
    }

    /// Solves ∇·(λ∇p) = 0 with p = 1 behind the wall (through the cake) and p = 0 beyond the outer ring,
    /// by conjugate gradients preconditioned with exact radial-line solves.
    /// - Parameter cake: cake thickness per column, or nil for no cake.
    /// - Returns: iterations, and the relative difference between wall inflow and outer outflow.
    @discardableResult
    public static func solvePressure(setup: Invasion3DSetup, mobility: [Double], cake: [Double]?, pressure x: inout [Double],
                                     tolerance: Double = 1e-10, maxIterations: Int = 20000) -> (iterations: Int, imbalance: Double) {
        let t = conductances(setup: setup, mobility: mobility, cake: cake)
        let n = setup.cellCount, nr = setup.nr, nt = setup.nt, nz = setup.nz
        var diag = [Double](repeating: 0, count: n)
        var b = [Double](repeating: 0, count: n)
        for k in 0..<nz {
            for j in 0..<nt {
                let jp = (j + 1) % nt
                for i in 0..<nr {
                    let a = setup.index(i, j, k)
                    var d = t.radial[a] + t.angular[a] + t.angular[setup.index(i, jp, k)] + t.axial[a]
                    if k < nz - 1 { d += t.axial[setup.index(i, j, k + 1)] }
                    if i > 0 { d += t.radial[a - 1] } else { d += t.wall[setup.column(j, k)] }
                    diag[a] = d
                }
                b[setup.index(0, j, k)] = t.wall[setup.column(j, k)]
            }
        }

        func apply(_ v: [Double], _ out: inout [Double]) {
            for k in 0..<nz {
                for j in 0..<nt {
                    let jp = (j + 1) % nt, jm = (j + nt - 1) % nt
                    for i in 0..<nr {
                        let a = setup.index(i, j, k)
                        var y = diag[a] * v[a]
                        if i > 0 { y -= t.radial[a - 1] * v[a - 1] }
                        if i < nr - 1 { y -= t.radial[a] * v[a + 1] }
                        y -= t.angular[a] * v[setup.index(i, jm, k)]
                        y -= t.angular[setup.index(i, jp, k)] * v[setup.index(i, jp, k)]
                        if k > 0 { y -= t.axial[a] * v[setup.index(i, j, k - 1)] }
                        if k < nz - 1 {
                            let up = setup.index(i, j, k + 1)
                            y -= t.axial[up] * v[up]
                        }
                        out[a] = y
                    }
                }
            }
        }

        // Thomas algorithm on each radial line.
        var cPrime = [Double](repeating: 0, count: nr)
        var dPrime = [Double](repeating: 0, count: nr)
        func preconditioner(_ r: [Double], _ z: inout [Double]) {
            for column in 0..<(nt * nz) {
                let base = column * nr
                cPrime[0] = -t.radial[base] / diag[base]
                dPrime[0] = r[base] / diag[base]
                for i in 1..<nr {
                    let lower = t.radial[base + i - 1]
                    let denominator = diag[base + i] - lower * cPrime[i - 1]
                    cPrime[i] = i < nr - 1 ? -t.radial[base + i] / denominator : 0
                    dPrime[i] = (r[base + i] + lower * dPrime[i - 1]) / denominator
                }
                z[base + nr - 1] = dPrime[nr - 1]
                for i in stride(from: nr - 2, through: 0, by: -1) {
                    z[base + i] = dPrime[i] - cPrime[i] * z[base + i + 1]
                }
            }
        }

        func imbalance(_ p: [Double]) -> Double {
            var inflow = 0.0, outflowSum = 0.0
            for k in 0..<nz {
                for j in 0..<nt {
                    inflow += t.wall[setup.column(j, k)] * (1 - p[setup.index(0, j, k)])
                    let last = setup.index(nr - 1, j, k)
                    outflowSum += t.radial[last] * p[last]
                }
            }
            return abs(inflow - outflowSum) / max(abs(inflow), 1e-300)
        }

        var ax = [Double](repeating: 0, count: n)
        apply(x, &ax)
        var r = [Double](repeating: 0, count: n)
        for a in 0..<n { r[a] = b[a] - ax[a] }
        var z = [Double](repeating: 0, count: n)
        preconditioner(r, &z)
        var p = z
        var rz = zip(r, z).reduce(0) { $0 + $1.0 * $1.1 }
        let bNorm = max(b.reduce(0) { $0 + $1 * $1 }.squareRoot(), 1e-300)
        var q = [Double](repeating: 0, count: n)
        var iterations = 0
        while iterations < maxIterations {
            let rNorm = r.reduce(0) { $0 + $1 * $1 }.squareRoot()
            if rNorm / bNorm < tolerance && imbalance(x) < tolerance * 10 { break }
            apply(p, &q)
            let pq = zip(p, q).reduce(0) { $0 + $1.0 * $1.1 }
            guard pq > 0 else { break }
            let alpha = rz / pq
            for a in 0..<n {
                x[a] += alpha * p[a]
                r[a] -= alpha * q[a]
            }
            preconditioner(r, &z)
            let rzNew = zip(r, z).reduce(0) { $0 + $1.0 * $1.1 }
            let beta = rzNew / rz
            rz = rzNew
            for a in 0..<n { p[a] = z[a] + beta * p[a] }
            iterations += 1
        }
        return (iterations, imbalance(x))
    }

    /// Computes face flow rates and cell speeds from the pressure field.
    /// Returns the largest transport rate (1/s, for the step limit) and the largest relative rate of change of a wall conductance (1/s).
    func updateFluxes() -> (maxRate: Double, maxCakeRate: Double) {
        let t = Invasion3DSolver.conductances(setup: setup, mobility: mobility, cake: cake)
        let nr = setup.nr, nt = setup.nt, nz = setup.nz
        let vs = setup.velocityScale
        let p = pressure
        for k in 0..<nz {
            for j in 0..<nt {
                let jm = (j + nt - 1) % nt
                for i in 0..<nr {
                    let a = setup.index(i, j, k)
                    let inner = i > 0 ? t.radial[a - 1] * (p[a - 1] - p[a]) : t.wall[setup.column(j, k)] * (1 - p[a])
                    let angular = t.angular[a] * (p[setup.index(i, jm, k)] - p[a])
                    let axial = k > 0 ? t.axial[a] * (p[setup.index(i, j, k - 1)] - p[a]) : 0
                    let outer = i < nr - 1 ? t.radial[a] * (p[a] - p[a + 1]) : t.radial[a] * p[a]
                    flux[a] = SIMD4(inner, angular, axial, outer) * vs
                }
            }
        }
        var maxRate = 0.0, maxCakeRate = 0.0
        for k in 0..<nz {
            for j in 0..<nt {
                let jp = (j + 1) % nt
                for i in 0..<nr {
                    let a = setup.index(i, j, k)
                    let f = flux[a]
                    let angularPlus = flux[setup.index(i, jp, k)].y
                    let axialPlus = k < nz - 1 ? flux[setup.index(i, j, k + 1)].z : 0
                    let ur = 0.5 * (f.x / (setup.faces[i] * setup.dTheta * setup.dz) + f.w / (setup.faces[i + 1] * setup.dTheta * setup.dz))
                    let ut = 0.5 * (f.y + angularPlus) / ((setup.faces[i + 1] - setup.faces[i]) * setup.dz)
                    let uz = 0.5 * (f.z + axialPlus) / setup.area[i]
                    let u = (ur * ur + ut * ut + uz * uz).squareRoot()
                    speed[a] = u
                    let out = max(-f.x, 0) + max(f.w, 0) + max(-f.y, 0) + max(angularPlus, 0) + max(-f.z, 0) + max(axialPlus, 0)
                    let rate = out / (setup.displaceablePorosity * setup.volume[i]) + setup.filtrationCoefficient * u / setup.porosity
                    maxRate = max(maxRate, rate)
                }
                let col = setup.column(j, k)
                let wallFlux = max(flux[setup.index(0, j, k)].x, 0)
                var growth = setup.cakeGrowth * wallFlux / setup.wallFaceArea
                if setup.equilibriumCake > 0 { growth *= max(0, 1 - cake[col] / setup.equilibriumCake) }
                let inner = max(setup.wellboreRadius - cake[col], 0.05 * setup.wellboreRadius)
                let resistanceRate = growth / (inner * setup.cakeMobility * setup.dTheta * setup.dz)
                maxCakeRate = max(maxCakeRate, resistanceRate * t.wall[col])
            }
        }
        return (maxRate, maxCakeRate)
    }

    /// Value on a face from the upwind cell U, the cell behind it UU and the downwind cell D.
    /// Second order uses the van Leer limiter: U + ΔuΔd/(Δu + Δd) when the slopes agree in sign.
    @inline(__always) static func faceValue(_ u: Double, _ uu: Double, _ d: Double, secondOrder: Bool) -> Double {
        guard secondOrder else { return u }
        let du = u - uu, dd = d - u
        return du * dd > 0 ? u + du * dd / (du + dd) : u
    }

    /// Time derivatives of (s, c, σ) per cell and of the cake per column, and the filtrate outflow rate at the outer boundary.
    func rates(s: [Double], c: [Double], sigma: [Double], h: [Double],
               ds: inout [Double], dc: inout [Double], dsigma: inout [Double], dh: inout [Double]) -> Double {
        let nr = setup.nr, nt = setup.nt, nz = setup.nz
        let second = setup.options.scheme == .tvd
        var outflowRate = 0.0
        for k in 0..<nz {
            for j in 0..<nt {
                let col = setup.column(j, k)
                let inlet = setup.finesInlet * max(0, 1 - h[col] / setup.bridgingCake)
                let jm = (j + nt - 1) % nt, jp = (j + 1) % nt
                let jmm = (j + nt - 2) % nt, jpp = (j + 2) % nt
                let km = max(k - 1, 0), kp = min(k + 1, nz - 1), kmm = max(k - 2, 0), kpp = min(k + 2, nz - 1)
                for i in 0..<nr {
                    let a = setup.index(i, j, k)
                    let f = flux[a]
                    let angularPlus = flux[setup.index(i, jp, k)].y
                    let axialPlus = k < nz - 1 ? flux[setup.index(i, j, k + 1)].z : 0

                    // Radial neighbours with ghost cells: mud inside the wall, unflushed rock beyond the outer boundary.
                    func radial(_ q: [Double], _ ii: Int, wall: Double) -> Double {
                        ii < 0 ? wall : (ii >= nr ? 0 : q[setup.index(ii, j, k)])
                    }
                    func net(_ q: [Double], wall: Double) -> (Double, Double) {
                        let here = q[a]
                        var total = 0.0
                        // Inner radial face.
                        if f.x > 0 {
                            total += f.x * Invasion3DSolver.faceValue(radial(q, i - 1, wall: wall), radial(q, i - 2, wall: wall), here, secondOrder: second)
                        } else {
                            total += f.x * Invasion3DSolver.faceValue(here, radial(q, i + 1, wall: wall), radial(q, i - 1, wall: wall), secondOrder: second)
                        }
                        // Outer radial face.
                        var out = 0.0
                        if f.w > 0 {
                            out = f.w * Invasion3DSolver.faceValue(here, radial(q, i - 1, wall: wall), radial(q, i + 1, wall: wall), secondOrder: second)
                        } else {
                            out = f.w * Invasion3DSolver.faceValue(radial(q, i + 1, wall: wall), radial(q, i + 2, wall: wall), here, secondOrder: second)
                        }
                        total -= out
                        // Angular faces (periodic).
                        let qm = q[setup.index(i, jm, k)], qmm = q[setup.index(i, jmm, k)]
                        let qp = q[setup.index(i, jp, k)], qpp = q[setup.index(i, jpp, k)]
                        total += f.y > 0 ? f.y * Invasion3DSolver.faceValue(qm, qmm, here, secondOrder: second)
                                         : f.y * Invasion3DSolver.faceValue(here, qp, qm, secondOrder: second)
                        total -= angularPlus > 0 ? angularPlus * Invasion3DSolver.faceValue(here, qm, qp, secondOrder: second)
                                                 : angularPlus * Invasion3DSolver.faceValue(qp, qpp, here, secondOrder: second)
                        // Axial faces (sealed top and bottom; clamped neighbours only feed the limiter).
                        let zm = q[setup.index(i, j, km)], zmm = q[setup.index(i, j, kmm)]
                        let zp = q[setup.index(i, j, kp)], zpp = q[setup.index(i, j, kpp)]
                        total += f.z > 0 ? f.z * Invasion3DSolver.faceValue(zm, zmm, here, secondOrder: second)
                                         : f.z * Invasion3DSolver.faceValue(here, zp, zm, secondOrder: second)
                        total -= axialPlus > 0 ? axialPlus * Invasion3DSolver.faceValue(here, zm, zp, secondOrder: second)
                                               : axialPlus * Invasion3DSolver.faceValue(zp, zpp, here, secondOrder: second)
                        return (total, i == nr - 1 ? max(out, 0) : 0)
                    }

                    let (sNet, sOut) = net(s, wall: 1)
                    let (cNet, _) = net(c, wall: inlet)
                    outflowRate += sOut
                    let v = setup.volume[i]
                    let lambda = setup.filtrationCoefficient * max(0, 1 - sigma[a] / setup.maxRetention)
                    let capture = lambda * speed[a] * c[a]
                    ds[a] = sNet / (setup.displaceablePorosity * v)
                    dc[a] = (cNet / v - capture) / setup.porosity
                    dsigma[a] = capture
                }
                var growth = setup.cakeGrowth * max(flux[setup.index(0, j, k)].x, 0) / setup.wallFaceArea
                if setup.equilibriumCake > 0 { growth *= max(0, 1 - h[col] / setup.equilibriumCake) }
                dh[col] = growth
            }
        }
        return outflowRate
    }

    func transport(dt: Double) {
        let n = setup.cellCount
        var ds = [Double](repeating: 0, count: n), dc = ds, dsigma = ds
        var dh = [Double](repeating: 0, count: setup.columnCount)
        let smax = setup.maxRetention

        func step(_ s: [Double], _ c: [Double], _ sigma: [Double], _ h: [Double], weight: Double,
                  base: ([Double], [Double], [Double], [Double])?) -> ([Double], [Double], [Double], [Double], Double) {
            let out = rates(s: s, c: c, sigma: sigma, h: h, ds: &ds, dc: &dc, dsigma: &dsigma, dh: &dh)
            var ns = s, nc = c, nsigma = sigma, nh = h
            for a in 0..<n {
                var vs = s[a] + dt * ds[a], vc = c[a] + dt * dc[a], vsig = sigma[a] + dt * dsigma[a]
                if let base {
                    vs = weight * base.0[a] + (1 - weight) * vs
                    vc = weight * base.1[a] + (1 - weight) * vc
                    vsig = weight * base.2[a] + (1 - weight) * vsig
                }
                ns[a] = min(max(vs, 0), 1)
                nc[a] = max(vc, 0)
                nsigma[a] = min(vsig, smax)
            }
            for col in 0..<setup.columnCount {
                var vh = h[col] + dt * dh[col]
                if let base { vh = weight * base.3[col] + (1 - weight) * vh }
                nh[col] = vh
            }
            return (ns, nc, nsigma, nh, out)
        }

        if setup.options.scheme == .tvd {
            let first = step(saturation, fines, retained, cake, weight: 0, base: nil)
            let second = step(first.0, first.1, first.2, first.3, weight: 0.5, base: (saturation, fines, retained, cake))
            outflow += 0.5 * dt * (first.4 + second.4)
            (saturation, fines, retained, cake) = (second.0, second.1, second.2, second.3)
        } else {
            let first = step(saturation, fines, retained, cake, weight: 0, base: nil)
            outflow += dt * first.4
            (saturation, fines, retained, cake) = (first.0, first.1, first.2, first.3)
        }
        time += dt
        transportSteps += 1
    }

    // MARK: Skin

    /// Skin of the damaged zone after the external cake is removed: S = (Q₀/Q_d − 1) ln(r_b/r_w),
    /// from steady solves with the undamaged and damaged permeability (r_b is the outer boundary radius).
    public func skin() -> Double {
        updateMobility()
        let undamaged = setup.k0.map(Double.init)
        return Invasion3DSolver.skin(setup: setup, damaged: mobility, undamaged: undamaged)
    }

    public var snapshot: Invasion3DSnapshot {
        Invasion3DSnapshot(setup: setup, time: time, pressure: pressure, saturation: saturation, fines: fines,
                           retained: retained, cake: cake)
    }

    public static func skin(setup: Invasion3DSetup, damaged: [Double], undamaged: [Double], tolerance: Double = 1e-10) -> Double {
        func rate(_ m: [Double]) -> Double {
            var p = setup.radialPressure()
            solvePressure(setup: setup, mobility: m, cake: nil, pressure: &p, tolerance: tolerance)
            let t = conductances(setup: setup, mobility: m, cake: nil)
            var q = 0.0
            for k in 0..<setup.nz {
                for j in 0..<setup.nt { q += t.wall[setup.column(j, k)] * (1 - p[setup.index(0, j, k)]) }
            }
            return q
        }
        let q0 = rate(undamaged), qd = rate(damaged)
        return (q0 / max(qd, 1e-300) - 1) * log(setup.boundaryRadius / setup.wellboreRadius)
    }
}
