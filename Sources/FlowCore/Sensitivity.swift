import Foundation

/// Inputs a sensitivity study can sweep.
public enum SweepParameter: String, CaseIterable, Identifiable, Sendable {
    case overbalance = "Overbalance"
    case exposureTime = "Exposure time"
    case finesConcentration = "Fines concentration"
    case filtrationCoefficient = "Filtration coefficient λ₀"
    case damageCoefficient = "Damage coefficient β"
    case filtrateDamageFactor = "Filtrate k multiplier"
    case cakePermeability = "Mud-cake permeability"
    case permeability = "Formation permeability"

    public var id: String { rawValue }

    public var keyPath: WritableKeyPath<StudyCase, Double> {
        switch self {
        case .overbalance: \StudyCase.mud.overbalance
        case .exposureTime: \StudyCase.mud.exposureTime
        case .finesConcentration: \StudyCase.mud.finesConcentration
        case .filtrationCoefficient: \StudyCase.mud.filtrationCoefficient
        case .damageCoefficient: \StudyCase.mud.damageCoefficient
        case .filtrateDamageFactor: \StudyCase.mud.filtrateDamageFactor
        case .cakePermeability: \StudyCase.mud.cakePermeability
        case .permeability: \StudyCase.reservoir.permeability
        }
    }

    public var quantity: Quantity {
        switch self {
        case .overbalance: .pressure
        case .exposureTime: .hours
        case .finesConcentration, .filtrateDamageFactor: .fraction
        case .filtrationCoefficient: .perMetre
        case .damageCoefficient: .dimensionless
        case .cakePermeability, .permeability: .permeability
        }
    }

    /// Sweep spacing: logarithmic for parameters spanning decades.
    public var isLogarithmic: Bool {
        switch self {
        case .filtrationCoefficient, .damageCoefficient, .cakePermeability, .permeability: true
        default: false
        }
    }

    /// Sensible sweep range around the current value.
    public func defaultRange(around value: Double) -> ClosedRange<Double> {
        switch self {
        case .overbalance: return 100...3000
        case .exposureTime: return 2...168
        case .finesConcentration: return 0...0.04
        case .filtrateDamageFactor: return 0.1...1
        default:
            let v = max(value, 1e-9)
            return (v / 10)...(v * 10)
        }
    }

    public func values(in range: ClosedRange<Double>, count: Int) -> [Double] {
        if isLogarithmic, range.lowerBound > 0 {
            return Numerics.linspace(log10(range.lowerBound), log10(range.upperBound), count: count).map { pow(10, $0) }
        }
        return Numerics.linspace(range.lowerBound, range.upperBound, count: count)
    }
}

public struct SensitivityPoint: Identifiable, Sendable {
    public var id: Double { value }
    public let value: Double
    public let skin: Double
    public let productivityRatio: Double
    public let filtrateInvasionDepth: Double
    public let solidsInvasionDepth: Double
    /// Natural-flow operating rate with this damage skin, STB/d (nil = well does not flow).
    public let operatingRate: Double?
}

public enum SensitivityStudy {
    /// Runs the damage model (and the nodal model with the resulting skin) for each value.
    public static func run(
        _ base: StudyCase, parameter: SweepParameter, values: [Double]
    ) -> [SensitivityPoint] {
        values.map { v in
            var c = base
            c[keyPath: parameter.keyPath] = v
            let damage = MudInvasionSimulator.run(c.damageCase, historySamples: 10)
            var nodalInput = c
            nodalInput.includeDamageSkin = true
            let nodal = NodalAnalysis.solve(nodalInput.nodalCase(damageSkin: damage.skin), samples: 20)
            return SensitivityPoint(
                value: v,
                skin: damage.skin,
                productivityRatio: damage.productivityRatio,
                filtrateInvasionDepth: damage.filtrateInvasionDepth,
                solidsInvasionDepth: damage.solidsInvasionDepth,
                operatingRate: nodal.operatingPoint?.rate)
        }
    }
}
