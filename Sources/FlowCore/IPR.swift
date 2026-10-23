import Foundation

/// Reservoir description used to compute inflow performance.
public struct Reservoir: Equatable, Codable, Sendable {
    /// Average reservoir pressure, psia.
    public var pressure: Double
    /// Reservoir temperature, °F.
    public var temperature: Double
    /// Horizontal permeability, md.
    public var permeability: Double
    /// Net pay thickness, ft.
    public var thickness: Double
    /// Porosity, fraction.
    public var porosity: Double
    /// Drainage radius, ft.
    public var drainageRadius: Double
    /// Wellbore radius, ft.
    public var wellboreRadius: Double
    /// Total skin factor (formation damage + completion), dimensionless.
    public var skin: Double

    public init(
        pressure: Double = 4000,
        temperature: Double = 200,
        permeability: Double = 50,
        thickness: Double = 60,
        porosity: Double = 0.2,
        drainageRadius: Double = 1500,
        wellboreRadius: Double = 0.354,
        skin: Double = 0
    ) {
        self.pressure = pressure
        self.temperature = temperature
        self.permeability = permeability
        self.thickness = thickness
        self.porosity = porosity
        self.drainageRadius = drainageRadius
        self.wellboreRadius = wellboreRadius
        self.skin = skin
    }
}

/// Inflow performance relationship: liquid rate the reservoir delivers at a flowing bottomhole pressure.
///
/// Darcy pseudo-steady-state productivity index above the bubble point, and the
/// composite Vogel curve below it.
public struct InflowModel: Sendable {
    public let reservoir: Reservoir
    public let fluid: BlackOilFluid

    public init(reservoir: Reservoir, fluid: BlackOilFluid) {
        self.reservoir = reservoir
        self.fluid = fluid
    }

    public var bubblePoint: Double { fluid.bubblePoint(temperature: reservoir.temperature) }

    /// Darcy productivity index, STB/d/psi, with skin:
    /// J = k h / (141.2 Bo μo [ln(re/rw) − 0.75 + S]).
    public var productivityIndex: Double {
        let r = reservoir
        let pRef = max(r.pressure, bubblePoint)
        let bo = fluid.oilFVF(pressure: pRef, temperature: r.temperature)
        let mu = fluid.oilViscosity(pressure: pRef, temperature: r.temperature)
        let denom = log(r.drainageRadius / r.wellboreRadius) - 0.75 + r.skin
        return r.permeability * r.thickness / (141.2 * bo * mu * max(denom, 0.05))
    }

    /// Liquid rate (STB/d) at flowing bottomhole pressure `pwf` (psia).
    public func rate(pwf: Double) -> Double {
        let pr = reservoir.pressure
        let pb = bubblePoint
        let j = productivityIndex
        let p = min(max(pwf, 0), pr)
        if pr <= pb {
            let qmax = j * pr / 1.8
            let x = p / pr
            return qmax * (1 - 0.2 * x - 0.8 * x * x)
        }
        if p >= pb { return j * (pr - p) }
        let qb = j * (pr - pb)
        let x = p / pb
        return qb + j * pb / 1.8 * (1 - 0.2 * x - 0.8 * x * x)
    }

    /// Absolute open flow potential (rate at pwf = 0), STB/d.
    public var absoluteOpenFlow: Double { rate(pwf: 0) }

    /// Flowing bottomhole pressure (psia) that delivers liquid rate `q`, or nil if q exceeds AOF.
    public func pwf(rate q: Double) -> Double? {
        if q <= 0 { return reservoir.pressure }
        if q > absoluteOpenFlow { return nil }
        return Numerics.bisect(0, reservoir.pressure, tolerance: 1e-4) { rate(pwf: $0) - q }
    }

    /// IPR curve sampled from pwf = pr down to 0.
    public func curve(points: Int = 50) -> [(pwf: Double, rate: Double)] {
        Numerics.linspace(reservoir.pressure, 0, count: points).map { ($0, rate(pwf: $0)) }
    }
}
