import Foundation

/// Display unit system. The engine always computes in oilfield units; SI is a presentation layer.
public enum UnitSystem: String, CaseIterable, Codable, Identifiable, Sendable {
    case field = "Field"
    case si = "SI"

    public var id: String { rawValue }
}

/// Physical quantities that appear in the user interface.
public enum Quantity: Sendable {
    case pressure          // psi ↔ bar
    case temperature       // °F ↔ °C
    case depth             // ft ↔ m
    case diameter          // in ↔ mm
    case invasionDepth     // in ↔ cm
    case permeability      // md ↔ mD
    case liquidRate        // STB/d ↔ m³/d
    case gasOilRatio       // scf/STB ↔ sm³/sm³
    case viscosity         // cp ↔ mPa·s
    case density           // lbm/ft³ ↔ kg/m³
    case productivityIndex // STB/d/psi ↔ m³/d/bar
    case buildRate         // °/100 ft ↔ °/30 m
    case fraction
    case dimensionless
    case angle
    case hours
    case millimetres
    case perMetre
    case formationVolumeFactor

    /// Multiplier and offset that convert an oilfield value to SI: si = field × scale + offset.
    private var toSI: (scale: Double, offset: Double) {
        switch self {
        case .pressure: (0.0689476, 0.0)
        case .temperature: (5.0 / 9.0, -32 * 5.0 / 9.0)
        case .depth: (0.3048, 0.0)
        case .diameter: (25.4, 0.0)
        case .invasionDepth: (2.54, 0.0)
        case .liquidRate: (0.158987, 0.0)
        case .gasOilRatio: (0.178108, 0.0)
        case .density: (16.0185, 0.0)
        case .productivityIndex: (0.158987 / 0.0689476, 0.0)
        case .buildRate: (0.3048 * 100 / 30, 0.0)
        default: (1.0, 0.0)
        }
    }

    public func symbol(_ system: UnitSystem) -> String {
        switch (self, system) {
        case (.pressure, .field): "psi"
        case (.pressure, .si): "bar"
        case (.temperature, .field): "°F"
        case (.temperature, .si): "°C"
        case (.depth, .field): "ft"
        case (.depth, .si): "m"
        case (.diameter, .field): "in"
        case (.diameter, .si): "mm"
        case (.invasionDepth, .field): "in"
        case (.invasionDepth, .si): "cm"
        case (.permeability, _): "mD"
        case (.liquidRate, .field): "STB/d"
        case (.liquidRate, .si): "m³/d"
        case (.gasOilRatio, .field): "scf/STB"
        case (.gasOilRatio, .si): "sm³/sm³"
        case (.viscosity, .field): "cp"
        case (.viscosity, .si): "mPa·s"
        case (.density, .field): "lbm/ft³"
        case (.density, .si): "kg/m³"
        case (.productivityIndex, .field): "STB/d/psi"
        case (.productivityIndex, .si): "m³/d/bar"
        case (.buildRate, .field): "°/100 ft"
        case (.buildRate, .si): "°/30 m"
        case (.fraction, _): ""
        case (.dimensionless, _): ""
        case (.angle, _): "°"
        case (.hours, _): "h"
        case (.millimetres, _): "mm"
        case (.perMetre, _): "1/m"
        case (.formationVolumeFactor, _): "rb/STB"
        }
    }

    /// Converts an engine (oilfield) value into the display system.
    public func display(_ value: Double, in system: UnitSystem) -> Double {
        guard system == .si else { return value }
        let c = toSI
        return value * c.scale + c.offset
    }

    /// Converts a value typed in the display system back into engine units.
    public func engine(_ value: Double, from system: UnitSystem) -> Double {
        guard system == .si else { return value }
        let c = toSI
        return (value - c.offset) / c.scale
    }
}
