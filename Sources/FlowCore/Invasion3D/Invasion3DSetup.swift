import Foundation

/// User choices for the 3D invasion model. Stored with the study so a run can be reproduced.
public struct Invasion3DOptions: Equatable, Codable, Sendable {
    public enum Resolution: String, Codable, CaseIterable, Identifiable, Sendable {
        case preview, standard, fine, research

        public var id: String { rawValue }

        /// Radial, angular and axial cell counts. Angular counts are even, as the red-black line solver needs.
        public var dimensions: (radial: Int, angular: Int, axial: Int) {
            switch self {
            case .preview: (40, 48, 24)
            case .standard: (64, 96, 48)
            case .fine: (96, 144, 72)
            case .research: (128, 192, 96)
            }
        }

        public var title: String {
            switch self {
            case .preview: "Preview"
            case .standard: "Standard"
            case .fine: "Fine"
            case .research: "Research"
            }
        }

        public var cellCount: Int {
            let d = dimensions
            return d.radial * d.angular * d.axial
        }
    }

    public enum Scheme: String, Codable, CaseIterable, Identifiable, Sendable {
        /// First-order upwind with forward Euler.
        case upwind
        /// Second-order MUSCL reconstruction with the van Leer limiter, and two-stage SSP Runge-Kutta.
        case tvd

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .upwind: "First-order upwind"
            case .tvd: "Second-order TVD"
            }
        }

        /// Fraction of the stability limit used for each transport step.
        public var courant: Double {
            switch self {
            case .upwind: 0.8
            case .tvd: 0.4
            }
        }
    }

    public var resolution: Resolution = .standard
    /// Length of borehole simulated, inches.
    public var intervalLength: Double = 18
    /// Radial extent of rock beyond the borehole wall, inches. Nil sizes it from the 1D invasion depth.
    public var domainDepth: Double?
    /// Standard deviation of ln k.
    public var heterogeneity: Double = 0.5
    /// Correlation length of permeability along the bedding, inches.
    public var horizontalCorrelation: Double = 2
    /// Correlation length of permeability across the bedding, inches. Shorter than the horizontal length gives layering.
    public var verticalCorrelation: Double = 0.6
    /// Vertical to horizontal permeability ratio kv/kh.
    public var anisotropy: Double = 0.2
    /// Seed of the permeability field.
    public var seed: UInt64 = 7
    public var scheme: Scheme = .tvd
    /// Pressure solve stops when wall inflow and outer outflow agree to this relative tolerance.
    public var pressureTolerance: Double = 2e-5
    /// Largest relative change of the wall conductance between pressure solves (the cake coupling error scales with it).
    public var cakeCoupling: Double = 0.01
    /// Most transport steps between pressure solves.
    public var maxStepsPerPressureSolve: Int = 8

    public init() {}
}

/// Geometry, rock and mud parameters of the 3D model: a length of vertical borehole and the rock around it,
/// on a cylindrical grid (r, θ, z).
///
/// Radial faces are spaced geometrically from the wall, so cells are finest where the flow converges and every
/// cell has the same shape in ln r. Cell centres sit at the geometric mean of their faces. With radial half-cell
/// resistances ln(r₊/r₋)/(Δθ Δz k), steady radial flow is reproduced exactly on any grid.
///
/// Pressures are normalised (1 in the borehole, 0 at the outer boundary) and permeabilities are relative to the
/// formation's horizontal permeability, so the GPU can work in single precision.
public struct Invasion3DSetup: Sendable {
    public let nr: Int
    public let nt: Int
    public let nz: Int
    /// Borehole radius, m.
    public let wellboreRadius: Double
    /// Outer radius of the grid, m.
    public let domainRadius: Double
    /// Interval length, m.
    public let length: Double
    /// Radius of the 1D model's outer boundary, m. The ring between the grid and this radius is a resistance on each outer face.
    public let boundaryRadius: Double
    /// Exposure time, s.
    public let exposureTime: Double

    /// Radial faces, m (nr + 1 values).
    public let faces: [Double]
    /// Radial cell centres, m.
    public let centres: [Double]
    /// Cell cross-section in the r-θ plane per radial index, m².
    public let area: [Double]
    /// Cell volume per radial index, m³.
    public let volume: [Double]
    public let dTheta: Double
    public let dz: Double
    /// Geometric half-cell resistances (divide by mobility): radial, angular, and axial per radial index. Units 1/m.
    public let halfRadial: Double
    public let halfAngular: Double
    public let halfAxial: [Double]
    /// Resistance of the outer ring per face, 1/m (formation at mean permeability).
    public let outerResistance: Double

    // Physics, as in `LiveInvasionSetup`.
    /// k̄·Δp/μ, m²/s. Multiplies a conductance (m) and a normalised pressure difference to give a flow rate, m³/s.
    public let velocityScale: Double
    public let porosity: Double
    public let displaceablePorosity: Double
    public let cakeGrowth: Double
    public let equilibriumCake: Double
    public let bridgingCake: Double
    /// Cake permeability relative to the formation's horizontal permeability.
    public let cakeMobility: Double
    public let finesInlet: Double
    public let filtrationCoefficient: Double
    public let damageCoefficient: Double
    public let maxRetention: Double
    public let filtrateDamageFactor: Double
    /// kv/kh.
    public let anisotropy: Double
    /// Overbalance (mud minus pore pressure), psi. Normalised pressure 1 is this much above pore pressure.
    public let overbalance: Double
    /// Horizontal formation permeability, md. Relative permeabilities are multiples of this.
    public let permeability: Double
    /// The inputs this setup was built from.
    public let mud: MudInvasionCase

    public let options: Invasion3DOptions
    /// Undamaged horizontal permeability relative to the mean, per cell.
    public let k0: [Float]

    public var cellCount: Int { nr * nt * nz }
    public var columnCount: Int { nt * nz }

    @inline(__always) public func index(_ i: Int, _ j: Int, _ k: Int) -> Int { (k * nt + j) * nr + i }
    @inline(__always) public func column(_ j: Int, _ k: Int) -> Int { k * nt + j }

    /// - Parameters:
    ///   - invasionDepth: expected filtrate depth in inches (from the 1D model), used when the options leave the domain size automatic.
    ///   - sizeOverride: radial, angular and axial counts, for tests and verification.
    ///   - permeabilityField: k₀ per cell relative to the formation permeability, replacing the random field.
    public init(_ c: MudInvasionCase, options: Invasion3DOptions = Invasion3DOptions(), invasionDepth: Double? = nil,
                sizeOverride: (Int, Int, Int)? = nil, permeabilityField: [Float]? = nil) {
        let inToM = 0.0254
        let preset = options.resolution.dimensions
        let dims: (Int, Int, Int) = sizeOverride ?? (preset.radial, preset.angular, preset.axial)
        let nr = max(dims.0, 4)
        let nt = max(dims.1 + dims.1 % 2, 2)
        let nz = max(dims.2, 1)
        self.nr = nr
        self.nt = nt
        self.nz = nz
        let rw = c.wellboreRadius * inToM
        let depth = options.domainDepth ?? min(max(1.4 * (invasionDepth ?? 5), 3), 24)
        let radius = rw + max(depth, 0.5) * inToM
        let length = max(options.intervalLength, 0.5) * inToM
        let boundary = max(c.modelRadius * MudInvasionSimulator.ftToM, radius)
        wellboreRadius = rw
        domainRadius = radius
        self.length = length
        boundaryRadius = boundary
        exposureTime = c.exposureTime * 3600
        self.options = options

        let growth = pow(radius / rw, 1 / Double(nr))
        let logGrowth = log(growth)
        let faces: [Double] = (0...nr).map { (i: Int) -> Double in rw * pow(growth, Double(i)) }
        let centres: [Double] = (0..<nr).map { (i: Int) -> Double in rw * pow(growth, Double(i) + 0.5) }
        let dTheta = 2 * Double.pi / Double(nt)
        let dz = length / Double(nz)
        var area = [Double](repeating: 0, count: nr)
        for i in 0..<nr {
            let outer: Double = faces[i + 1] * faces[i + 1]
            let inner: Double = faces[i] * faces[i]
            area[i] = 0.5 * (outer - inner) * dTheta
        }
        self.faces = faces
        self.centres = centres
        self.dTheta = dTheta
        self.dz = dz
        self.area = area
        volume = area.map { (a: Double) -> Double in a * dz }
        halfRadial = 0.5 * logGrowth / (dTheta * dz)
        halfAngular = 0.5 * dTheta / (dz * logGrowth)
        halfAxial = area.map { (a: Double) -> Double in 0.5 * dz / a }
        outerResistance = boundary > radius ? log(boundary / radius) / (dTheta * dz) : 0

        velocityScale = c.permeability * MudInvasionSimulator.mdToM2 * c.overbalance * MudInvasionSimulator.psiToPa
            / (c.filtrateViscosity * MudInvasionSimulator.cpToPaS)
        porosity = c.porosity
        displaceablePorosity = c.porosity * c.displaceableFraction
        cakeGrowth = c.mudSolidsFraction / ((1 - c.cakePorosity) * (1 - c.mudSolidsFraction))
        equilibriumCake = c.equilibriumCakeThickness * 1e-3
        bridgingCake = max(c.bridgingThickness * 1e-3, 1e-9)
        cakeMobility = c.cakePermeability / c.permeability
        finesInlet = c.finesConcentration
        filtrationCoefficient = c.filtrationCoefficient
        damageCoefficient = c.damageCoefficient
        maxRetention = max(c.maxRetention, 1e-12)
        filtrateDamageFactor = c.filtrateDamageFactor
        anisotropy = max(options.anisotropy, 1e-6)
        overbalance = c.overbalance
        permeability = c.permeability
        mud = c

        if let permeabilityField {
            precondition(permeabilityField.count == nr * nt * nz)
            k0 = permeabilityField
        } else {
            k0 = Invasion3DSetup.permeabilityField(
                nr: nr, nt: nt, nz: nz, centres: centres, dTheta: dTheta, dz: dz, length: length,
                sigma: options.heterogeneity, horizontal: options.horizontalCorrelation * inToM,
                vertical: options.verticalCorrelation * inToM, seed: options.seed)
        }
    }

    /// Log-normal permeability k = exp(σ g − σ²/2), mean 1, where g is a unit Gaussian random field made from
    /// random Fourier modes with separate horizontal and vertical correlation lengths.
    static func permeabilityField(nr: Int, nt: Int, nz: Int, centres: [Double], dTheta: Double, dz: Double, length: Double,
                                  sigma: Double, horizontal: Double, vertical: Double, seed: UInt64) -> [Float] {
        let count = nr * nt * nz
        guard sigma > 0 else { return [Float](repeating: 1, count: count) }
        var rng = SplitMix64(seed: seed)
        let modes = 64
        let kh = 2 * Double.pi / max(horizontal, 1e-4)
        let kv = 2 * Double.pi / max(vertical, 1e-4)
        struct Wave { var x: Double; var y: Double; var z: Double; var phase: Double }
        let waves: [Wave] = (0..<modes).map { _ in
            // Direction uniform on the sphere, then stretched by the two correlation lengths.
            let azimuth = rng.unit() * 2 * .pi
            let cosine = 2 * rng.unit() - 1
            let sine = (1 - cosine * cosine).squareRoot()
            let magnitude = 0.5 + rng.unit()
            return Wave(x: kh * magnitude * sine * cos(azimuth), y: kh * magnitude * sine * sin(azimuth),
                        z: kv * magnitude * cosine, phase: rng.unit() * 2 * .pi)
        }
        let amplitude = (2.0 / Double(modes)).squareRoot()
        var field = [Float](repeating: 1, count: count)
        for k in 0..<nz {
            let z = (Double(k) + 0.5) * dz - 0.5 * length
            for j in 0..<nt {
                let theta = (Double(j) + 0.5) * dTheta
                let ct = cos(theta), st = sin(theta)
                for i in 0..<nr {
                    let x = centres[i] * ct, y = centres[i] * st
                    var g = 0.0
                    for w in waves { g += cos(w.x * x + w.y * y + w.z * z + w.phase) }
                    g *= amplitude
                    field[(k * nt + j) * nr + i] = Float(exp(sigma * g - sigma * sigma / 2))
                }
            }
        }
        return field
    }

    /// Steady radial pressure without a cake, the initial guess for the first solve.
    public func radialPressure() -> [Double] {
        let total = log(domainRadius / wellboreRadius) + outerResistance * dTheta * dz
        var p = [Double](repeating: 0, count: cellCount)
        for k in 0..<nz {
            for j in 0..<nt {
                for i in 0..<nr {
                    p[index(i, j, k)] = 1 - log(centres[i] / wellboreRadius) / total
                }
            }
        }
        return p
    }

    /// Wall area of one column (r = rw), m².
    public var wallFaceArea: Double { wellboreRadius * dTheta * dz }
    /// Total borehole wall area, m².
    public var wallArea: Double { 2 * .pi * wellboreRadius * length }

    /// Cake resistance on one wall face, 1/m.
    @inline(__always) public func cakeResistance(_ h: Double) -> Double {
        guard h > 0 else { return 0 }
        let inner = max(wellboreRadius - h, 0.05 * wellboreRadius)
        return log(wellboreRadius / inner) / (cakeMobility * dTheta * dz)
    }

    /// Permeability ratio k/k₀ from filtrate saturation and retained fines.
    @inline(__always) public func damageRatio(saturation s: Double, retained sigma: Double) -> Double {
        (1 - (1 - filtrateDamageFactor) * s) / (1 + damageCoefficient * sigma)
    }

    /// The Courant fraction used per transport step.
    public var courant: Double { options.scheme.courant }
}
