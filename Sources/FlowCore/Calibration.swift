import Foundation

/// Static filter-press test (API RP 13B-1 low-pressure cell, or HPHT): cumulative filtrate against time.
public struct FilterPressTest: Codable, Equatable, Sendable {
    /// Elapsed times, minutes.
    public var times: [Double]
    /// Cumulative filtrate volumes, mL.
    public var volumes: [Double]
    /// Filtration area, cm². API low-pressure cell 45.8; HPHT cell about 22.6.
    public var area: Double = 45.8
    /// Differential pressure across the cake, psi.
    public var pressureDrop: Double = 100
    /// Filtrate viscosity at test temperature, cp.
    public var viscosity: Double = 1
    /// Mud solids volume fraction.
    public var mudSolidsFraction: Double = 0.1
    /// Cake porosity, fraction.
    public var cakePorosity: Double = 0.4
    /// Cake thickness measured at the end of the test, mm (optional).
    public var finalCakeThickness: Double?

    public init(times: [Double], volumes: [Double]) {
        self.times = times
        self.volumes = volumes
    }
}

/// Least-squares fit of V/A = V_spurt + m √t to a filter-press test, and the cake properties it implies.
public struct FilterPressFit: Equatable, Sendable {
    /// Spurt loss per unit area, cm (= mL/cm²).
    public let spurt: Double
    /// Static filtration slope, cm/√min.
    public let slope: Double
    /// Standard errors and 95 % confidence half-widths of the two coefficients.
    public let spurtError: Double
    public let slopeError: Double
    public let spurtConfidence: Double
    public let slopeConfidence: Double
    public let rSquared: Double
    /// Residuals of V/A, cm, one per point.
    public let residuals: [Double]
    /// API 30-minute fluid loss from the fit, mL, on the 45.8 cm² API area.
    public let apiFluidLoss: Double
    /// Cake volume per filtrate volume used for the permeability (from the measured cake if given, else from the solids).
    public let cakeGrowth: Double
    /// Cake permeability from m² = 2 kc Δp / (μ α), md.
    public let cakePermeability: Double
    /// Cake thickness at which fines stop entering, h_b = α V_spurt, mm (the model's interpretation of spurt).
    public let bridgingThickness: Double
}

public enum CalibrationError: Error, CustomStringConvertible, Equatable {
    case notEnoughPoints
    case invalidData(String)

    public var description: String {
        switch self {
        case .notEnoughPoints: "At least three points after time zero are needed."
        case .invalidData(let message): message
        }
    }
}

public enum Calibration {
    /// Fits the filter-press data. Points at t = 0 are ignored.
    public static func fit(_ test: FilterPressTest) throws -> FilterPressFit {
        guard test.times.count == test.volumes.count else { throw CalibrationError.invalidData("Times and volumes differ in length.") }
        guard test.area > 0, test.pressureDrop > 0, test.viscosity > 0 else {
            throw CalibrationError.invalidData("Area, pressure drop and viscosity must be positive.")
        }
        let points = zip(test.times, test.volumes).filter { $0.0 > 0 && $0.1.isFinite }
        guard points.count >= 3 else { throw CalibrationError.notEnoughPoints }
        let x = points.map { $0.0.squareRoot() }
        let y = points.map { $0.1 / test.area }
        let line = linearFit(x: x, y: y)

        let alphaSolids = test.mudSolidsFraction / ((1 - test.cakePorosity) * (1 - test.mudSolidsFraction))
        var alpha = alphaSolids
        let finalV = y.last! - line.intercept
        if let h = test.finalCakeThickness, h > 0, finalV > 0 {
            alpha = (h / 10) / finalV  // mm → cm over cm
        }
        // m in m/√s: cm/√min × 0.01 / √60.
        let mSI = line.slope * 0.01 / 60.0.squareRoot()
        let dp = test.pressureDrop * MudInvasionSimulator.psiToPa
        let mu = test.viscosity * MudInvasionSimulator.cpToPaS
        let kc = mSI * mSI * mu * alpha / (2 * dp) / MudInvasionSimulator.mdToM2
        let spurt = max(line.intercept, 0)

        let t95 = studentT95(points.count - 2)
        return FilterPressFit(
            spurt: line.intercept, slope: line.slope,
            spurtError: line.interceptError, slopeError: line.slopeError,
            spurtConfidence: t95 * line.interceptError, slopeConfidence: t95 * line.slopeError,
            rSquared: line.rSquared, residuals: line.residuals,
            apiFluidLoss: (line.intercept + line.slope * 30.0.squareRoot()) * 45.8,
            cakeGrowth: alpha, cakePermeability: kc,
            bridgingThickness: alpha * spurt * 10)
    }

    /// Ordinary least squares y = a + b x with standard errors.
    public static func linearFit(x: [Double], y: [Double]) -> (intercept: Double, slope: Double, interceptError: Double,
                                                                 slopeError: Double, rSquared: Double, residuals: [Double]) {
        let n = Double(x.count)
        let mx = x.reduce(0, +) / n, my = y.reduce(0, +) / n
        var sxx = 0.0, sxy = 0.0, syy = 0.0
        for (a, b) in zip(x, y) {
            sxx += (a - mx) * (a - mx)
            sxy += (a - mx) * (b - my)
            syy += (b - my) * (b - my)
        }
        let slope = sxx > 0 ? sxy / sxx : 0
        let intercept = my - slope * mx
        let residuals = zip(x, y).map { $0.1 - (intercept + slope * $0.0) }
        let ssr = residuals.reduce(0) { $0 + $1 * $1 }
        let variance = n > 2 ? ssr / (n - 2) : 0
        let slopeError = sxx > 0 ? (variance / sxx).squareRoot() : 0
        let interceptError = sxx > 0 ? (variance * (1 / n + mx * mx / sxx)).squareRoot() : 0
        let r2 = syy > 0 ? 1 - ssr / syy : 1
        return (intercept, slope, interceptError, slopeError, r2, residuals)
    }

    /// Two-sided 95 % Student-t quantile.
    public static func studentT95(_ dof: Int) -> Double {
        let table: [Double] = [12.706, 4.303, 3.182, 2.776, 2.571, 2.447, 2.365, 2.306, 2.262, 2.228,
                               2.201, 2.179, 2.160, 2.145, 2.131, 2.120, 2.110, 2.101, 2.093, 2.086,
                               2.080, 2.074, 2.069, 2.064, 2.060, 2.056, 2.052, 2.048, 2.045, 2.042]
        guard dof >= 1 else { return .infinity }
        if dof <= table.count { return table[dof - 1] }
        return 1.96 + 2.4 / Double(dof)
    }

    /// Reads two numeric columns from CSV, TSV or semicolon-separated text, skipping header and blank lines.
    public static func parseTwoColumns(_ text: String) -> [(Double, Double)] {
        var rows: [(Double, Double)] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let separators = CharacterSet(charactersIn: ",;\t ")
            let fields = raw.components(separatedBy: separators).filter { !$0.isEmpty }
            guard fields.count >= 2, let a = Double(fields[0]), let b = Double(fields[1]) else { continue }
            rows.append((a, b))
        }
        return rows
    }
}

/// Return-permeability coreflood: permeability to oil before and after mud exposure.
public struct ReturnPermeabilityTest: Codable, Equatable, Sendable {
    public var initialPermeability: Double
    public var returnPermeability: Double
    /// Core length, cm.
    public var coreLength: Double = 5
    /// Mud filtrate injected per unit core face area during the exposure, cm.
    public var injectedPerArea: Double = 2
    /// True when the test used solids-free filtrate, so only the filtrate damage factor F can be fitted.
    public var solidsFree: Bool = false

    public init(initialPermeability: Double, returnPermeability: Double) {
        self.initialPermeability = initialPermeability
        self.returnPermeability = returnPermeability
    }

    public var ratio: Double { returnPermeability / initialPermeability }

    /// Damage coefficient β that reproduces the measured ratio in a linear core, given F, λ₀ (1/m) and the fines
    /// concentration. With σ(x) = λ c₀ U e^{−λx} the harmonic mean over the core gives
    /// k_ret/k₀ = F L / (L + β c₀ U (1 − e^{−λL})), so β = (F L / ratio − L) / (c₀ U (1 − e^{−λL})).
    /// Returns nil when the data cannot be matched with β ≥ 0.
    public func damageCoefficient(filtrateFactor f: Double, filtrationCoefficient lambda: Double, finesConcentration c0: Double) -> Double? {
        let length = coreLength / 100, injected = injectedPerArea / 100
        let captured = c0 * injected * (1 - exp(-lambda * length))
        guard ratio > 0, captured > 0 else { return nil }
        let beta = (f * length / ratio - length) / captured
        return beta >= 0 ? beta : nil
    }
}
