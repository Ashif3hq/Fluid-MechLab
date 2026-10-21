import Foundation

/// Small numerical helpers shared by the solvers.
public enum Numerics {
    /// Finds a root of `f` in [lo, hi] by bisection. Returns nil if the bracket has no sign change.
    public static func bisect(
        _ lo: Double, _ hi: Double,
        tolerance: Double = 1e-6,
        maxIterations: Int = 200,
        _ f: (Double) -> Double
    ) -> Double? {
        var a = lo, b = hi
        var fa = f(a)
        let fb = f(b)
        if fa == 0 { return a }
        if fb == 0 { return b }
        guard fa.sign != fb.sign, fa.isFinite, fb.isFinite else { return nil }
        for _ in 0..<maxIterations {
            let m = 0.5 * (a + b)
            let fm = f(m)
            if fm == 0 || 0.5 * (b - a) < tolerance { return m }
            if fm.sign == fa.sign {
                a = m
                fa = fm
            } else {
                b = m
            }
        }
        return 0.5 * (a + b)
    }

    /// Evenly spaced values from `start` to `end` inclusive.
    public static func linspace(_ start: Double, _ end: Double, count: Int) -> [Double] {
        guard count > 1 else { return [start] }
        let step = (end - start) / Double(count - 1)
        return (0..<count).map { start + Double($0) * step }
    }

    /// Trapezoidal integral of y over x.
    public static func trapezoid(x: [Double], y: [Double]) -> Double {
        precondition(x.count == y.count)
        guard x.count > 1 else { return 0 }
        var sum = 0.0
        for i in 1..<x.count {
            sum += 0.5 * (y[i] + y[i - 1]) * (x[i] - x[i - 1])
        }
        return sum
    }

    /// Darcy-Weisbach (Moody) friction factor from the explicit Chen (1979) equation,
    /// laminar 64/Re below Re = 2000.
    public static func moodyFrictionFactor(reynolds re: Double, relativeRoughness eps: Double) -> Double {
        guard re > 0 else { return 0 }
        if re < 2000 { return 64.0 / re }
        let a = eps / 3.7065
        let b = 5.0452 / re * log10(pow(eps, 1.1098) / 2.8257 + 5.8506 / pow(re, 0.8981))
        let invSqrt = -2.0 * log10(a - b)
        return 1.0 / (invSqrt * invSqrt)
    }
}
