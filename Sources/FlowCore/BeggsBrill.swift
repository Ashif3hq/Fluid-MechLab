import Foundation

/// Flow pattern predicted by Beggs-Brill for a horizontal pipe at the same rates.
public enum FlowPattern: String, CaseIterable, Codable, Sendable {
    case singlePhase = "Single phase"
    case segregated = "Segregated"
    case transition = "Transition"
    case intermittent = "Intermittent"
    case distributed = "Distributed"
}

/// In-situ conditions in one pipe segment, in oilfield units.
public struct PipeFlowState: Sendable {
    /// Superficial liquid velocity, ft/s.
    public var vsl: Double
    /// Superficial gas velocity, ft/s.
    public var vsg: Double
    /// Liquid density, lbm/ft³.
    public var liquidDensity: Double
    /// Gas density, lbm/ft³.
    public var gasDensity: Double
    /// Liquid viscosity, cp.
    public var liquidViscosity: Double
    /// Gas viscosity, cp.
    public var gasViscosity: Double
    /// Gas-liquid surface tension, dyne/cm.
    public var surfaceTension: Double

    public init(
        vsl: Double, vsg: Double,
        liquidDensity: Double, gasDensity: Double,
        liquidViscosity: Double, gasViscosity: Double,
        surfaceTension: Double
    ) {
        self.vsl = vsl
        self.vsg = vsg
        self.liquidDensity = liquidDensity
        self.gasDensity = gasDensity
        self.liquidViscosity = liquidViscosity
        self.gasViscosity = gasViscosity
        self.surfaceTension = surfaceTension
    }
}

/// Result of a Beggs-Brill gradient calculation.
public struct GradientResult: Sendable {
    public let pattern: FlowPattern
    /// In-situ liquid holdup (volume fraction of pipe occupied by liquid).
    public let holdup: Double
    /// No-slip liquid fraction λL.
    public let noSlipHoldup: Double
    /// Elevation (hydrostatic) gradient, psi/ft.
    public let elevationGradient: Double
    /// Friction gradient, psi/ft.
    public let frictionGradient: Double
    /// Total pressure gradient, psi/ft (positive = pressure increases going down/backwards).
    public var totalGradient: Double { elevationGradient + frictionGradient }
    /// Mixture velocity, ft/s.
    public let mixtureVelocity: Double
}

/// Beggs and Brill (1973) multiphase pressure-gradient correlation, with the
/// Payne et al. (1979) holdup corrections and Chen friction factor.
public enum BeggsBrill {
    static let g = 32.174

    /// - Parameters:
    ///   - diameter: pipe inner diameter, ft
    ///   - roughness: absolute roughness, ft
    ///   - inclination: angle from horizontal, radians (π/2 = vertical upward flow)
    public static func gradient(
        _ s: PipeFlowState,
        diameter d: Double,
        roughness: Double,
        inclination theta: Double
    ) -> GradientResult {
        let vm = s.vsl + s.vsg
        guard vm > 0 else {
            let elev = s.liquidDensity * sin(theta) / 144
            return GradientResult(
                pattern: .singlePhase, holdup: 1, noSlipHoldup: 1,
                elevationGradient: elev, frictionGradient: 0, mixtureVelocity: 0)
        }
        let lambda = s.vsl / vm
        let nfr = vm * vm / (g * d)

        var pattern: FlowPattern
        var holdup: Double

        if lambda >= 0.9999 || lambda <= 1e-4 {
            pattern = .singlePhase
            holdup = lambda >= 0.9999 ? 1 : 0
        } else {
            let l1 = 316 * pow(lambda, 0.302)
            let l2 = 0.0009252 * pow(lambda, -2.4684)
            let l3 = 0.10 * pow(lambda, -1.4516)
            let l4 = 0.5 * pow(lambda, -6.738)

            if (lambda < 0.01 && nfr < l1) || (lambda >= 0.01 && nfr < l2) {
                pattern = .segregated
            } else if lambda >= 0.01 && nfr >= l2 && nfr <= l3 {
                pattern = .transition
            } else if (lambda >= 0.01 && lambda < 0.4 && nfr > l3 && nfr <= l1)
                || (lambda >= 0.4 && nfr > l3 && nfr <= l4) {
                pattern = .intermittent
            } else {
                pattern = .distributed
            }

            let nlv = 1.938 * s.vsl * pow(s.liquidDensity / s.surfaceTension, 0.25)
            func inclinedHoldup(_ p: FlowPattern) -> Double {
                let coefficients: (Double, Double, Double)
                switch p {
                case .segregated: coefficients = (0.98, 0.4846, 0.0868)
                case .intermittent: coefficients = (0.845, 0.5351, 0.0173)
                default: coefficients = (1.065, 0.5824, 0.0609)
                }
                let (a, b, c) = coefficients
                let h0 = max(a * pow(lambda, b) / pow(nfr, c), lambda)

                var cc = 0.0
                if theta >= 0 {
                    switch p {
                    case .segregated:
                        cc = (1 - lambda) * log(0.011 * pow(lambda, -3.768) * pow(nlv, 3.539) * pow(nfr, -1.614))
                    case .intermittent:
                        cc = (1 - lambda) * log(2.96 * pow(lambda, 0.305) * pow(nlv, -0.4473) * pow(nfr, 0.0978))
                    default:
                        cc = 0
                    }
                } else {
                    cc = (1 - lambda) * log(4.70 * pow(lambda, -0.3692) * pow(nlv, 0.1244) * pow(nfr, -0.5056))
                }
                if !cc.isFinite { cc = 0 }
                cc = max(cc, 0)
                let s18 = sin(1.8 * theta)
                let psi = 1 + cc * (s18 - 0.333 * s18 * s18 * s18)
                // Payne et al. correction factors.
                let payne = theta > 0 ? 0.924 : (theta < 0 ? 0.685 : 1.0)
                return min(max(h0 * psi * payne, lambda), 1)
            }

            if pattern == .transition {
                let a = (l3 - nfr) / (l3 - l2)
                holdup = a * inclinedHoldup(.segregated) + (1 - a) * inclinedHoldup(.intermittent)
            } else {
                holdup = inclinedHoldup(pattern)
            }
        }

        let rhoS = s.liquidDensity * holdup + s.gasDensity * (1 - holdup)
        let rhoN = s.liquidDensity * lambda + s.gasDensity * (1 - lambda)
        let muN = s.liquidViscosity * lambda + s.gasViscosity * (1 - lambda)
        let re = 1488 * rhoN * vm * d / max(muN, 1e-6)
        let fn = Numerics.moodyFrictionFactor(reynolds: re, relativeRoughness: roughness / d)

        var factor = 1.0
        if pattern != .singlePhase {
            let y = lambda / (holdup * holdup)
            if y > 1 && y < 1.2 {
                factor = exp(log(2.2 * y - 1.2))
            } else {
                let ly = log(y)
                let sExp = ly / (-0.0523 + 3.182 * ly - 0.8725 * ly * ly + 0.01853 * pow(ly, 4))
                factor = exp(sExp.isFinite ? sExp : 0)
            }
        }
        let ftp = fn * factor

        let elevation = rhoS * sin(theta) / 144
        let friction = ftp * rhoN * vm * vm / (2 * g * d) / 144
        return GradientResult(
            pattern: pattern, holdup: holdup, noSlipHoldup: lambda,
            elevationGradient: elevation, frictionGradient: friction, mixtureVelocity: vm)
    }
}
