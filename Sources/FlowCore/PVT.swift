import Foundation

/// Black-oil fluid description in oilfield units.
///
/// Correlations: Standing (bubble point, Rs, Bo), Beggs-Robinson (oil viscosity),
/// Vasquez-Beggs (undersaturated viscosity), Sutton (gas pseudo-criticals),
/// Papay (Z-factor), Lee-Gonzalez-Eakin (gas viscosity).
public struct BlackOilFluid: Equatable, Codable, Sendable {
    /// Stock-tank oil gravity, °API.
    public var apiGravity: Double
    /// Gas specific gravity (air = 1).
    public var gasGravity: Double
    /// Solution gas-oil ratio at the bubble point, scf/STB.
    public var solutionGOR: Double
    /// Produced water specific gravity (fresh water = 1).
    public var waterGravity: Double
    /// Undersaturated oil compressibility, 1/psi.
    public var oilCompressibility: Double

    public init(
        apiGravity: Double = 32,
        gasGravity: Double = 0.75,
        solutionGOR: Double = 500,
        waterGravity: Double = 1.07,
        oilCompressibility: Double = 1.2e-5
    ) {
        self.apiGravity = apiGravity
        self.gasGravity = gasGravity
        self.solutionGOR = solutionGOR
        self.waterGravity = waterGravity
        self.oilCompressibility = oilCompressibility
    }

    /// Oil specific gravity (water = 1).
    public var oilGravity: Double { 141.5 / (131.5 + apiGravity) }

    // MARK: Oil

    /// Standing bubble-point pressure, psia, at temperature `t` (°F).
    public func bubblePoint(temperature t: Double) -> Double {
        let a = 0.00091 * t - 0.0125 * apiGravity
        return 18.2 * (pow(solutionGOR / gasGravity, 0.83) * pow(10, a) - 1.4)
    }

    /// Solution gas-oil ratio, scf/STB.
    public func solutionGasOilRatio(pressure p: Double, temperature t: Double) -> Double {
        let pb = bubblePoint(temperature: t)
        if p >= pb { return solutionGOR }
        let a = 0.0125 * apiGravity - 0.00091 * t
        let rs = gasGravity * pow((max(p, 14.7) / 18.2 + 1.4) * pow(10, a), 1.0 / 0.83)
        return min(max(rs, 0), solutionGOR)
    }

    /// Oil formation volume factor, rb/STB.
    public func oilFVF(pressure p: Double, temperature t: Double) -> Double {
        let pb = bubblePoint(temperature: t)
        let rs = solutionGasOilRatio(pressure: min(p, pb), temperature: t)
        let f = rs * (gasGravity / oilGravity).squareRoot() + 1.25 * t
        let bo = 0.9759 + 0.00012 * pow(f, 1.2)
        if p <= pb { return bo }
        return bo * exp(oilCompressibility * (pb - p))
    }

    /// Dead-oil viscosity, cp (Beggs-Robinson).
    public func deadOilViscosity(temperature t: Double) -> Double {
        let z = 3.0324 - 0.02023 * apiGravity
        let x = pow(10, z) * pow(t, -1.163)
        return pow(10, x) - 1
    }

    /// Live-oil viscosity, cp.
    public func oilViscosity(pressure p: Double, temperature t: Double) -> Double {
        let pb = bubblePoint(temperature: t)
        let rs = solutionGasOilRatio(pressure: min(p, pb), temperature: t)
        let muOD = deadOilViscosity(temperature: t)
        let a = 10.715 * pow(rs + 100, -0.515)
        let b = 5.44 * pow(rs + 150, -0.338)
        let muOB = a * pow(muOD, b)
        if p <= pb { return muOB }
        let m = 2.6 * pow(p, 1.187) * exp(-11.513 - 8.98e-5 * p)
        return muOB * pow(p / pb, m)
    }

    /// In-situ oil density, lbm/ft³.
    public func oilDensity(pressure p: Double, temperature t: Double) -> Double {
        let rs = solutionGasOilRatio(pressure: p, temperature: t)
        return (62.4 * oilGravity + 0.0136 * rs * gasGravity) / oilFVF(pressure: p, temperature: t)
    }

    // MARK: Gas

    /// Pseudo-critical pressure (psia) and temperature (°R), Sutton.
    public var gasPseudoCritical: (p: Double, t: Double) {
        let g = gasGravity
        return (756.8 - 131.0 * g - 3.6 * g * g, 169.2 + 349.5 * g - 74.0 * g * g)
    }

    /// Gas compressibility factor (Papay).
    public func gasZ(pressure p: Double, temperature t: Double) -> Double {
        let pc = gasPseudoCritical
        let ppr = p / pc.p
        let tpr = (t + 459.67) / pc.t
        let z = 1 - 3.53 * ppr / pow(10, 0.9813 * tpr) + 0.274 * ppr * ppr / pow(10, 0.8157 * tpr)
        return max(z, 0.25)
    }

    /// Gas formation volume factor, ft³/scf.
    public func gasFVF(pressure p: Double, temperature t: Double) -> Double {
        0.02827 * gasZ(pressure: p, temperature: t) * (t + 459.67) / p
    }

    /// Gas density, lbm/ft³.
    public func gasDensity(pressure p: Double, temperature t: Double) -> Double {
        2.7 * gasGravity * p / (gasZ(pressure: p, temperature: t) * (t + 459.67))
    }

    /// Gas viscosity, cp (Lee-Gonzalez-Eakin).
    public func gasViscosity(pressure p: Double, temperature t: Double) -> Double {
        let tr = t + 459.67
        let m = 28.97 * gasGravity
        let k = (9.4 + 0.02 * m) * pow(tr, 1.5) / (209 + 19 * m + tr)
        let x = 3.5 + 986 / tr + 0.01 * m
        let y = 2.4 - 0.2 * x
        let rho = gasDensity(pressure: p, temperature: t) / 62.428
        return 1e-4 * k * exp(x * pow(rho, y))
    }

    // MARK: Water

    /// Water formation volume factor, rb/STB (weak function; held near unity).
    public func waterFVF(pressure p: Double, temperature t: Double) -> Double {
        1.0 + 1.2e-4 * (t - 60) + 1.0e-6 * (t - 60) * (t - 60) - 3.0e-6 * (p - 14.7) * 0.1
    }

    /// Water density, lbm/ft³.
    public func waterDensity(pressure p: Double, temperature t: Double) -> Double {
        62.4 * waterGravity / waterFVF(pressure: p, temperature: t)
    }

    /// Water viscosity, cp (temperature-only fit).
    public func waterViscosity(temperature t: Double) -> Double {
        exp(1.003 - 1.479e-2 * t + 1.982e-5 * t * t)
    }
}

/// One evaluated PVT state, handy for tables and charts.
public struct PVTPoint: Identifiable, Sendable {
    public var id: Double { pressure }
    public let pressure: Double
    public let rs: Double
    public let bo: Double
    public let oilViscosity: Double
    public let oilDensity: Double
    public let z: Double
    public let bg: Double
    public let gasViscosity: Double
}

extension BlackOilFluid {
    public func table(temperature t: Double, maxPressure: Double, points: Int = 60) -> [PVTPoint] {
        Numerics.linspace(50, maxPressure, count: points).map { p in
            PVTPoint(
                pressure: p,
                rs: solutionGasOilRatio(pressure: p, temperature: t),
                bo: oilFVF(pressure: p, temperature: t),
                oilViscosity: oilViscosity(pressure: p, temperature: t),
                oilDensity: oilDensity(pressure: p, temperature: t),
                z: gasZ(pressure: p, temperature: t),
                bg: gasFVF(pressure: p, temperature: t),
                gasViscosity: gasViscosity(pressure: p, temperature: t)
            )
        }
    }
}
