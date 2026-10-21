import FlowCore
import SwiftUI

private struct UnitSystemKey: EnvironmentKey {
    static let defaultValue: UnitSystem = .field
}

extension EnvironmentValues {
    var unitSystem: UnitSystem {
        get { self[UnitSystemKey.self] }
        set { self[UnitSystemKey.self] = newValue }
    }
}

extension Quantity {
    /// Fraction digits for display: one more when SI shrinks the number, one fewer when it grows it.
    func digits(_ fieldDigits: Int, in system: UnitSystem) -> Int {
        guard system == .si else { return fieldDigits }
        let ratio = abs(display(1000, in: .si) - display(0, in: .si)) / 1000
        if ratio < 0.5 { return fieldDigits + 1 }
        if ratio > 5 { return max(fieldDigits - 1, 0) }
        return fieldDigits
    }

    /// "1,234 psi" in the given system.
    func format(_ value: Double, digits: Int, in system: UnitSystem) -> String {
        let v = display(value, in: system)
        let text = v.formatted(.number.precision(.fractionLength(self.digits(digits, in: system))))
        let unit = symbol(system)
        return unit.isEmpty ? text : "\(text) \(unit)"
    }

    /// Axis title such as "Pressure (bar)".
    func axisLabel(_ name: String, in system: UnitSystem) -> String {
        let unit = symbol(system)
        return unit.isEmpty ? name : "\(name) (\(unit))"
    }
}

extension Double {
    func formatted(digits: Int) -> String {
        formatted(.number.precision(.fractionLength(digits)))
    }
}

/// Casing and tubing sizes are spoken in fractions: 9.625 → 9⅝″.
func pipeSizeLabel(_ inches: Double) -> String {
    let whole = Int(inches)
    let fraction = inches - Double(whole)
    let eighths = Int((fraction * 8).rounded())
    let glyphs = ["", "⅛", "¼", "⅜", "½", "⅝", "¾", "⅞", ""]
    let wholePart = eighths == 8 ? whole + 1 : whole
    if abs(fraction * 8 - Double(eighths)) > 0.05 {
        return "\(inches.formatted(digits: 3))″"
    }
    return "\(wholePart)\(glyphs[eighths])″"
}
