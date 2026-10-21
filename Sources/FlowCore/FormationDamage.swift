import Foundation

/// Inputs for near-wellbore formation damage caused by overbalanced drilling mud.
///
/// Values are in oilfield-friendly units at the interface and converted to SI internally.
public struct MudInvasionCase: Equatable, Codable, Sendable {
    // Rock
    /// Undamaged formation permeability, md.
    public var permeability: Double = 100
    /// Porosity, fraction.
    public var porosity: Double = 0.2
    /// Fraction of pore volume the filtrate can displace (1 − Swi − Sor), fraction.
    public var displaceableFraction: Double = 0.6
    /// Wellbore radius, inches.
    public var wellboreRadius: Double = 4.25
    /// Drainage radius used for skin and productivity ratio, ft.
    public var drainageRadius: Double = 1500

    // Mud and drilling
    /// Overbalance (mud pressure − pore pressure), psi.
    public var overbalance: Double = 500
    /// Filtrate viscosity, cp.
    public var filtrateViscosity: Double = 1.0
    /// Exposure time of the formation to mud, hours.
    public var exposureTime: Double = 24
    /// Mud solids volume fraction that builds the external cake.
    public var mudSolidsFraction: Double = 0.10
    /// Mud-cake permeability, md.
    public var cakePermeability: Double = 0.001
    /// Mud-cake porosity, fraction.
    public var cakePorosity: Double = 0.4
    /// Dynamic (circulating) filtration: cake erosion caps thickness at this value, mm. 0 = static.
    public var equilibriumCakeThickness: Double = 2.0
    /// Cake thickness at which fine particles stop passing into the rock, mm.
    public var bridgingThickness: Double = 0.5

    // Fines / deep-bed filtration
    /// Volume concentration of invading fine particles in the filtrate during spurt.
    public var finesConcentration: Double = 0.01
    /// Initial filtration coefficient λ₀, 1/m.
    public var filtrationCoefficient: Double = 50
    /// Formation damage coefficient β (k = k₀ / (1 + βσ)).
    public var damageCoefficient: Double = 500
    /// Maximum retained particle volume fraction σmax.
    public var maxRetention: Double = 0.03

    // Filtrate-rock interaction
    /// Permeability multiplier in the filtrate-invaded zone (clay swelling, water block), 0–1.
    public var filtrateDamageFactor: Double = 0.7

    // Numerics
    /// Radial extent of the simulated near-wellbore zone, ft.
    public var modelRadius: Double = 3
    /// Radial cells.
    public var cells: Int = 240

    public init() {}
}

/// Radial profile at the end of mud exposure.
public struct DamageProfilePoint: Identifiable, Sendable {
    public var id: Double { radius }
    /// Distance into the formation from the borehole wall, inches.
    public let depthIntoFormation: Double
    /// Radius from well centre, ft.
    public let radius: Double
    /// Permeability ratio k / k₀.
    public let permeabilityRatio: Double
    /// Retained fines volume fraction σ.
    public let retained: Double
    /// Suspended fines concentration c.
    public let suspended: Double
    /// True if the filtrate front has passed this point.
    public let filtrateInvaded: Bool
}

/// Time history of the invasion.
public struct InvasionHistoryPoint: Identifiable, Sendable {
    public var id: Double { time }
    /// Hours since exposure began.
    public let time: Double
    /// Filtrate flux at the borehole wall, cm/hr.
    public let filtrationRate: Double
    /// Cumulative filtrate volume per unit area of borehole wall, cm³/cm² (= cm).
    public let cumulativeFiltrate: Double
    /// External mud-cake thickness, mm.
    public let cakeThickness: Double
    /// Filtrate front depth into the formation, inches.
    public let filtrateFrontDepth: Double
}

public struct MudInvasionResult: Sendable {
    public let profile: [DamageProfilePoint]
    public let history: [InvasionHistoryPoint]
    /// Skin after the external cake is removed, from the internal damage profile (generalised Hawkins).
    public let skin: Double
    /// Productivity ratio J_damaged / J_undamaged.
    public let productivityRatio: Double
    /// Filtrate invasion depth, inches.
    public let filtrateInvasionDepth: Double
    /// Depth where retained fines fall below 5 % of their peak value, inches.
    public let solidsInvasionDepth: Double
    /// Spurt loss: filtrate volume per area before the cake bridged, cm.
    public let spurtLoss: Double
    public let finalCakeThickness: Double
    public let totalFiltrate: Double
}

/// Simulates radial mud filtrate invasion with external cake build-up and deep-bed filtration of fines.
///
/// Model (SI internally):
/// - Darcy flow in series through the cake and the radial invaded zone, driven by the overbalance:
///   q/L = 2π Δp / (μ [ln(rw/(rw−h))/kc + Σ ln(rᵢ₊₁/rᵢ)/kᵢ]).
/// - Cake growth: dh/dt = α u_w (1 − h/h_eq), α = fs / ((1 − φc)(1 − fs)) cake volume per filtrate volume.
/// - Fines transport and capture (Iwasaki / Herzig deep-bed filtration):
///   φ ∂c/∂t + u ∂c/∂r = −λ(σ) u c,   ∂σ/∂t = λ(σ) u c,   λ = λ₀ (1 − σ/σmax),
///   with u = u_w r_w / r and inlet concentration falling to zero as the cake bridges.
/// - Permeability: k = k₀ · F_filtrate / (1 + β σ).
/// - Skin: S = ∫ (k₀/k − 1) dr / r over the damaged zone.
public enum MudInvasionSimulator {
    static let mdToM2 = 9.869233e-16
    static let psiToPa = 6894.757
    static let cpToPaS = 1e-3
    static let ftToM = 0.3048
    static let inToM = 0.0254

    public static func run(_ c: MudInvasionCase, historySamples: Int = 200) -> MudInvasionResult {
        let k0 = c.permeability * mdToM2
        let kc = c.cakePermeability * mdToM2
        let dp = c.overbalance * psiToPa
        let mu = c.filtrateViscosity * cpToPaS
        let rw = c.wellboreRadius * inToM
        let rOuter = max(c.modelRadius * ftToM, rw * 1.5)
        let tEnd = c.exposureTime * 3600
        let phi = c.porosity
        let alpha = c.mudSolidsFraction / ((1 - c.cakePorosity) * (1 - c.mudSolidsFraction))
        let hEq = c.equilibriumCakeThickness * 1e-3
        let hBridge = max(c.bridgingThickness * 1e-3, 1e-6)
        let n = max(c.cells, 20)

        // Radial grid: geometric spacing so cells are finest at the borehole wall.
        let growth = pow(rOuter / rw, 1.0 / Double(n))
        var faces = [Double](repeating: 0, count: n + 1)
        for i in 0...n { faces[i] = rw * pow(growth, Double(i)) }
        let centres = (0..<n).map { 0.5 * (faces[$0] + faces[$0 + 1]) }
        let dr = (0..<n).map { faces[$0 + 1] - faces[$0] }
        let logRatio = (0..<n).map { log(faces[$0 + 1] / faces[$0]) }

        var conc = [Double](repeating: 0, count: n)
        var sigma = [Double](repeating: 0, count: n)
        var cake = 0.0
        var filtrate = 0.0  // m³ per m² of borehole wall
        var spurt: Double? = nil
        let displaceable = phi * c.displaceableFraction

        func frontRadius() -> Double {
            // Volume balance per unit well length: 2π rw V = π (rf² − rw²) φ ΔS
            (rw * rw + 2 * rw * filtrate / displaceable).squareRoot()
        }

        func permeability(_ i: Int, front: Double) -> Double {
            let f = centres[i] <= front ? c.filtrateDamageFactor : 1
            return k0 * f / (1 + c.damageCoefficient * sigma[i])
        }

        func wallFlux() -> Double {
            let front = frontRadius()
            var resistance = cake > 0 ? log(rw / max(rw - cake, rw * 0.05)) / kc : 0
            for i in 0..<n { resistance += logRatio[i] / permeability(i, front: front) }
            return dp / (mu * rw * resistance)
        }

        var history: [InvasionHistoryPoint] = []
        let sampleTimes = (0...historySamples).map { tEnd * pow(Double($0) / Double(historySamples), 2) }
        var nextSample = 0
        var t = 0.0

        func record(_ u: Double, at time: Double) {
            history.append(InvasionHistoryPoint(
                time: time / 3600,
                filtrationRate: u * 100 * 3600,
                cumulativeFiltrate: filtrate * 100,
                cakeThickness: cake * 1e3,
                filtrateFrontDepth: (frontRadius() - rw) / inToM))
        }

        while t < tEnd {
            let uw = wallFlux()
            while nextSample < sampleTimes.count && sampleTimes[nextSample] <= t {
                record(uw, at: sampleTimes[nextSample])
                nextSample += 1
            }

            // Explicit upwind CFL limit, fastest at the wall.
            var dt = 0.4 * phi * dr[0] / max(uw, 1e-30)
            dt = min(dt, 120, tEnd - t)
            if nextSample < sampleTimes.count { dt = min(dt, max(sampleTimes[nextSample] - t, 1e-3)) }

            let inlet = c.finesConcentration * max(0, 1 - cake / hBridge)
            if inlet == 0 && spurt == nil { spurt = filtrate }

            var newConc = conc
            for i in 0..<n {
                let u = uw * rw / centres[i]
                let upstream = i == 0 ? inlet : conc[i - 1]
                let lam = c.filtrationCoefficient * max(0, 1 - sigma[i] / c.maxRetention)
                let capture = lam * u * conc[i]
                newConc[i] = conc[i] + dt / phi * (-u * (conc[i] - upstream) / dr[i] - capture)
                newConc[i] = max(newConc[i], 0)
                sigma[i] = min(sigma[i] + dt * capture, c.maxRetention)
            }
            conc = newConc

            var dh = alpha * uw * dt
            if hEq > 0 { dh *= max(0, 1 - cake / hEq) }
            cake = min(cake + dh, rw * 0.9)
            filtrate += uw * dt
            t += dt
        }
        let uEnd = wallFlux()
        while nextSample < sampleTimes.count {
            record(uEnd, at: sampleTimes[nextSample])
            nextSample += 1
        }

        let front = frontRadius()
        var profile: [DamageProfilePoint] = []
        var skinIntegrand: [Double] = []
        for i in 0..<n {
            let ratio = permeability(i, front: front) / k0
            profile.append(DamageProfilePoint(
                depthIntoFormation: (centres[i] - rw) / inToM,
                radius: centres[i] / ftToM,
                permeabilityRatio: ratio,
                retained: sigma[i],
                suspended: conc[i],
                filtrateInvaded: centres[i] <= front))
            skinIntegrand.append((1 / ratio - 1) * logRatio[i])
        }
        let skin = skinIntegrand.reduce(0, +)

        let re = c.drainageRadius * ftToM
        let base = log(re / rw) - 0.75
        let peakRetention = sigma.max() ?? 0
        let threshold = 0.05 * peakRetention
        let solidsDepth = peakRetention <= 0 ? 0 : profile.last(where: { $0.retained > threshold })?.depthIntoFormation ?? 0

        return MudInvasionResult(
            profile: profile,
            history: history,
            skin: skin,
            productivityRatio: base / max(base + skin, 0.05),
            filtrateInvasionDepth: (front - rw) / inToM,
            solidsInvasionDepth: solidsDepth,
            spurtLoss: (spurt ?? filtrate) * 100,
            finalCakeThickness: cake * 1e3,
            totalFiltrate: filtrate * 100)
    }
}
