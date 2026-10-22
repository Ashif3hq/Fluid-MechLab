import Foundation

/// Code verification of the 3D model: problems with known solutions, run on refined grids to measure the error
/// and its observed order of convergence. This shows that the equations are solved correctly; it does not show
/// that they describe a particular rock and mud (that is validation, which needs laboratory data).
public enum InvasionVerification {
    public struct Level: Sendable, Identifiable {
        public var id: String { label }
        public let label: String
        public let cells: Int
        public let error: Double
    }

    public struct Case: Sendable, Identifiable {
        public let id: String
        public let title: String
        /// The exact or reference solution compared against.
        public let reference: String
        /// What the error measures.
        public let metric: String
        public let levels: [Level]
        /// Observed order from the two finest levels, if the case is a refinement study.
        public let observedOrder: Double?
        /// What theory predicts.
        public let expected: String
        /// The case passes when the finest error is below this and, for refinement studies, the order is at least `minimumOrder`.
        public let tolerance: Double
        public let minimumOrder: Double?

        public var finestError: Double { levels.last?.error ?? .nan }
        public var passed: Bool {
            guard finestError.isFinite, finestError <= tolerance else { return false }
            if let minimumOrder, let observedOrder { return observedOrder >= minimumOrder }
            return true
        }
    }

    /// Observed order p from errors e₁, e₂ on grids refined by ratio r: p = ln(e₁/e₂)/ln r.
    public static func order(_ coarse: Double, _ fine: Double, ratio: Double = 2) -> Double {
        log(coarse / fine) / log(ratio)
    }

    /// Runs every case. `scheme` selects the transport scheme for the transient cases.
    public static func run(scheme: Invasion3DOptions.Scheme = .tvd) -> [Case] {
        [steadyRadial(), layered(), deepBedFiltration(scheme: scheme), filtrateFront(scheme: scheme),
         cakeFiltration(scheme: scheme), massBalance(scheme: scheme), symmetry(scheme: scheme)]
    }

    // MARK: Shared inputs

    /// A clean case: rock 100 md, φ 0.2, 500 psi, 1 cp, outer boundary at the grid edge, no damage feedback.
    static func baseCase() -> MudInvasionCase {
        var c = MudInvasionCase()
        c.permeability = 100
        c.porosity = 0.2
        c.displaceableFraction = 0.6
        c.wellboreRadius = 4.25
        c.overbalance = 500
        c.filtrateViscosity = 1
        c.modelRadius = 0
        c.filtrateDamageFactor = 1
        c.damageCoefficient = 0
        c.finesConcentration = 0
        c.mudSolidsFraction = 0
        c.equilibriumCakeThickness = 0
        return c
    }

    static func baseOptions(_ scheme: Invasion3DOptions.Scheme) -> Invasion3DOptions {
        var o = Invasion3DOptions()
        o.domainDepth = 9.5
        o.intervalLength = 6
        o.heterogeneity = 0
        o.anisotropy = 1
        o.scheme = scheme
        return o
    }

    static func uniform(_ dims: (Int, Int, Int)) -> [Float] {
        [Float](repeating: 1, count: dims.0 * dims.1 * dims.2)
    }

    // MARK: Cases

    /// Steady radial flow in uniform rock: p = 1 − ln(r/rw)/ln(R/rw). The log-centred grid reproduces it exactly.
    public static func steadyRadial() -> Case {
        let levels = [(8, 8, 2), (16, 8, 2), (32, 8, 2)].map { dims -> Level in
            let setup = Invasion3DSetup(baseCase(), options: baseOptions(.tvd), sizeOverride: dims, permeabilityField: uniform(dims))
            var p = [Double](repeating: 0.5, count: setup.cellCount)
            Invasion3DSolver.solvePressure(setup: setup, mobility: [Double](repeating: 1, count: setup.cellCount), cake: nil,
                                           pressure: &p, tolerance: 1e-13)
            let total = log(setup.domainRadius / setup.wellboreRadius)
            var worst = 0.0
            for k in 0..<setup.nz {
                for j in 0..<setup.nt {
                    for i in 0..<setup.nr {
                        let exact = 1 - log(setup.centres[i] / setup.wellboreRadius) / total
                        worst = max(worst, abs(p[setup.index(i, j, k)] - exact))
                    }
                }
            }
            return Level(label: "\(dims.0) × \(dims.1) × \(dims.2)", cells: setup.cellCount, error: worst)
        }
        return Case(id: "V1", title: "Steady radial flow", reference: "p = 1 − ln(r/rw) / ln(R/rw)",
                    metric: "Largest pressure error (fraction of overbalance)", levels: levels, observedOrder: nil,
                    expected: "Exact on any grid (round-off only)", tolerance: 1e-8, minimumOrder: nil)
    }

    /// Stratified rock with no cross-flow: q = Σ 2π Δz kₗ / ln(R/rw). Checks the vertical coupling and harmonic averaging.
    public static func layered() -> Case {
        let layers: [Float] = [0.2, 1, 3, 0.5, 2, 0.1]
        let levels = [(8, 8, 6), (16, 8, 6), (32, 8, 6)].map { dims -> Level in
            var field = [Float](repeating: 1, count: dims.0 * dims.1 * dims.2)
            for k in 0..<dims.2 {
                for col in 0..<(dims.1) {
                    for i in 0..<dims.0 { field[(k * dims.1 + col) * dims.0 + i] = layers[k] }
                }
            }
            var options = baseOptions(.tvd)
            options.anisotropy = 0.3
            let setup = Invasion3DSetup(baseCase(), options: options, sizeOverride: dims, permeabilityField: field)
            let mobility = setup.k0.map(Double.init)
            var p = setup.radialPressure()
            Invasion3DSolver.solvePressure(setup: setup, mobility: mobility, cake: nil, pressure: &p, tolerance: 1e-13)
            let t = Invasion3DSolver.conductances(setup: setup, mobility: mobility, cake: nil)
            var q = 0.0
            for k in 0..<setup.nz {
                for j in 0..<setup.nt { q += t.wall[setup.column(j, k)] * (1 - p[setup.index(0, j, k)]) }
            }
            let exact = layers.reduce(0.0) { $0 + 2 * .pi * setup.dz * Double($1) / log(setup.domainRadius / setup.wellboreRadius) }
            return Level(label: "\(dims.0) × \(dims.1) × \(dims.2)", cells: setup.cellCount, error: abs(q / exact - 1))
        }
        return Case(id: "V2", title: "Layered rock, anisotropic", reference: "q = Σ 2π Δz kₗ / ln(R/rw)",
                    metric: "Relative error in total inflow", levels: levels, observedOrder: nil,
                    expected: "Exact on any grid (round-off only)", tolerance: 1e-8, minimumOrder: nil)
    }

    /// Setup for constant-rate radial injection of a fines suspension with constant filtration coefficient.
    struct Injection {
        let setup: Invasion3DSetup
        /// Wall Darcy velocity, m/s.
        let wallVelocity: Double
        let time: Double
    }

    static func injection(nr: Int, scheme: Invasion3DOptions.Scheme, porousFraction: Double) -> Injection {
        var c = baseCase()
        c.finesConcentration = 0.01
        c.filtrationCoefficient = 10
        c.maxRetention = 1e9
        c.bridgingThickness = 1e9
        let options = baseOptions(scheme)
        let dims = (nr, 4, 1)
        let probe = Invasion3DSetup(c, options: options, sizeOverride: dims, permeabilityField: uniform(dims))
        let rw = probe.wellboreRadius, radius = probe.domainRadius
        let uw = probe.velocityScale / (rw * log(radius / rw))
        // Run until the fines front has swept the given fraction of the rock volume.
        let time = porousFraction * probe.porosity * (radius * radius - rw * rw) / (2 * rw * uw)
        c.exposureTime = time / 3600
        let setup = Invasion3DSetup(c, options: options, sizeOverride: dims, permeabilityField: uniform(dims))
        return Injection(setup: setup, wallVelocity: uw, time: time)
    }

    /// Radial deep-bed filtration (Iwasaki 1937; Herzig, Leclerc and Le Goff 1970) at constant rate and λ:
    /// c = c₀ e^{−λ(r−rw)} and σ = λ c₀ e^{−λ(r−rw)} u(r) (t − τ(r)) behind the front, τ = φ (r² − rw²) / (2 rw u_w).
    public static func deepBedFiltration(scheme: Invasion3DOptions.Scheme) -> Case {
        let levels = [16, 32, 64].map { nr -> Level in
            let run = injection(nr: nr, scheme: scheme, porousFraction: 0.5)
            let s = run.setup
            let solver = Invasion3DSolver(setup: s)
            solver.advance(by: run.time)
            var errorSum = 0.0, normSum = 0.0
            for i in 0..<s.nr {
                let r = s.centres[i]
                let tau = s.porosity * (r * r - s.wellboreRadius * s.wellboreRadius) / (2 * s.wellboreRadius * run.wallVelocity)
                let exact = run.time > tau
                    ? s.filtrationCoefficient * s.finesInlet * exp(-s.filtrationCoefficient * (r - s.wellboreRadius))
                        * run.wallVelocity * s.wellboreRadius / r * (run.time - tau)
                    : 0
                var mean = 0.0
                for col in 0..<s.columnCount { mean += solver.retained[col * s.nr + i] }
                mean /= Double(s.columnCount)
                errorSum += abs(mean - exact) * s.volume[i]
                normSum += exact * s.volume[i]
            }
            return Level(label: "nr = \(nr)", cells: s.cellCount, error: errorSum / max(normSum, 1e-300))
        }
        return Case(id: "V3", title: "Deep-bed filtration of fines", reference: "Iwasaki / Herzig radial solution for σ(r, t)",
                    metric: "Relative L1 error in retained fines σ", levels: levels,
                    observedOrder: order(levels[1].error, levels[2].error),
                    expected: scheme == .tvd ? "Above 1 (σ has a kink at the front)" : "About 1",
                    tolerance: scheme == .tvd ? 0.01 : 0.05, minimumOrder: 0.85)
    }

    /// Piston-like filtrate front from volume balance: rf² = rw² + 2 rw u_w t / (φ ΔS). The exact cell averages of the
    /// step are compared with the computed saturation. A moving discontinuity limits first-order schemes to order ½.
    public static func filtrateFront(scheme: Invasion3DOptions.Scheme) -> Case {
        let levels = [16, 32, 64].map { nr -> Level in
            let run = injection(nr: nr, scheme: scheme, porousFraction: 0.3)
            let s = run.setup
            let solver = Invasion3DSolver(setup: s)
            solver.advance(by: run.time)
            let rw = s.wellboreRadius
            let front = (rw * rw + 2 * rw * run.wallVelocity * run.time / s.displaceablePorosity).squareRoot()
            var errorSum = 0.0, normSum = 0.0
            for i in 0..<s.nr {
                let inner = s.faces[i], outer = s.faces[i + 1]
                let filled = min(max((min(front, outer) * min(front, outer) - inner * inner) / (outer * outer - inner * inner), 0), 1)
                var mean = 0.0
                for col in 0..<s.columnCount { mean += solver.saturation[col * s.nr + i] }
                mean /= Double(s.columnCount)
                errorSum += abs(mean - filled) * s.volume[i]
                normSum += filled * s.volume[i]
            }
            return Level(label: "nr = \(nr)", cells: s.cellCount, error: errorSum / max(normSum, 1e-300))
        }
        return Case(id: "V4", title: "Filtrate front", reference: "Volume balance: rf² = rw² + 2 rw u_w t / (φ ΔS)",
                    metric: "Relative L1 error in filtrate saturation", levels: levels,
                    observedOrder: order(levels[1].error, levels[2].error),
                    expected: scheme == .tvd ? "About ⅔ for a discontinuity" : "About ½ for a discontinuity",
                    tolerance: scheme == .tvd ? 0.06 : 0.12, minimumOrder: 0.4)
    }

    /// Filtration through a growing static cake in series with the rock, against a fine Runge-Kutta solution of
    /// dV/dt = (k̄Δp/μ) / (rw [ln(rw/(rw − αV))/κc + ln(R/rw)]). Refines the cake-coupling tolerance ε.
    public static func cakeFiltration(scheme: Invasion3DOptions.Scheme) -> Case {
        var c = baseCase()
        c.mudSolidsFraction = 0.1
        c.cakePermeability = 0.001
        c.cakePorosity = 0.4
        c.exposureTime = 1
        let levels = [0.04, 0.02, 0.01].map { epsilon -> Level in
            var options = baseOptions(scheme)
            options.cakeCoupling = epsilon
            let dims = (12, 4, 1)
            let setup = Invasion3DSetup(c, options: options, sizeOverride: dims, permeabilityField: uniform(dims))
            let solver = Invasion3DSolver(setup: setup)
            solver.advance(by: setup.exposureTime)
            let computed = solver.injected / setup.wallArea
            let exact = cakeODE(setup: setup, time: setup.exposureTime)
            return Level(label: "ε = \(epsilon)", cells: setup.cellCount, error: abs(computed / exact - 1))
        }
        return Case(id: "V5", title: "Cake-controlled filtration", reference: "Series cake + rock resistance (RK4 reference)",
                    metric: "Relative error in cumulative filtrate after 1 h", levels: levels,
                    observedOrder: order(levels[1].error, levels[2].error),
                    expected: "About 1 in the coupling tolerance ε", tolerance: 0.01, minimumOrder: 0.8)
    }

    /// Cumulative filtrate per wall area (m) for the cake-in-series model, by RK4 on a time grid refined towards t = 0.
    public static func cakeODE(setup s: Invasion3DSetup, time: Double, steps: Int = 40000) -> Double {
        let rw = s.wellboreRadius
        let rock = log(s.domainRadius / rw) + s.outerResistance * s.dTheta * s.dz
        func rate(_ v: Double) -> Double {
            let h = s.cakeGrowth * v
            let cake = h > 0 ? log(rw / max(rw - h, 0.05 * rw)) / s.cakeMobility : 0
            return s.velocityScale / (rw * (cake + rock))
        }
        var v = 0.0
        var previous = 0.0
        for n in 1...steps {
            let t = time * pow(Double(n) / Double(steps), 2)
            let h = t - previous
            let k1 = rate(v), k2 = rate(v + 0.5 * h * k1), k3 = rate(v + 0.5 * h * k2), k4 = rate(v + h * k3)
            v += h / 6 * (k1 + 2 * k2 + 2 * k3 + k4)
            previous = t
        }
        return v
    }

    /// Full physics in heterogeneous, layered rock: the filtrate stored plus the filtrate that left must equal the filtrate injected.
    public static func massBalance(scheme: Invasion3DOptions.Scheme) -> Case {
        var c = MudInvasionCase()
        c.exposureTime = 0.5
        var options = Invasion3DOptions()
        options.scheme = scheme
        options.heterogeneity = 0.8
        options.horizontalCorrelation = 1.5
        options.verticalCorrelation = 0.4
        options.anisotropy = 0.2
        options.intervalLength = 6
        options.domainDepth = 4
        let setup = Invasion3DSetup(c, options: options, sizeOverride: (16, 16, 6))
        let solver = Invasion3DSolver(setup: setup)
        solver.advance(by: setup.exposureTime)
        let level = Level(label: "16 × 16 × 6", cells: setup.cellCount, error: solver.stats.massBalanceError)
        return Case(id: "V6", title: "Filtrate mass balance", reference: "Injected = stored + outflow",
                    metric: "Relative mass-balance error, heterogeneous rock with cake and fines", levels: [level],
                    observedOrder: nil, expected: "Round-off only (the scheme is conservative)", tolerance: 1e-7, minimumOrder: nil)
    }

    /// Full physics in uniform rock must stay axisymmetric: the front depth may not vary around the well.
    public static func symmetry(scheme: Invasion3DOptions.Scheme) -> Case {
        var c = MudInvasionCase()
        c.exposureTime = 0.5
        var options = Invasion3DOptions()
        options.scheme = scheme
        options.heterogeneity = 0
        options.intervalLength = 6
        options.domainDepth = 4
        let dims = (16, 12, 4)
        let setup = Invasion3DSetup(c, options: options, sizeOverride: dims, permeabilityField: uniform(dims))
        let solver = Invasion3DSolver(setup: setup)
        solver.advance(by: setup.exposureTime)
        let stats = solver.stats
        let level = Level(label: "16 × 12 × 4", cells: setup.cellCount, error: stats.frontSpread / max(stats.frontMean, 1e-12))
        return Case(id: "V7", title: "Axial symmetry", reference: "Uniform rock gives a circular front",
                    metric: "Front depth spread / mean front depth", levels: [level], observedOrder: nil,
                    expected: "Round-off only", tolerance: 1e-9, minimumOrder: nil)
    }
}
