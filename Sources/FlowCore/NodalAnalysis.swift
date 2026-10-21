import Foundation

/// Inputs for a bottomhole nodal analysis.
public struct NodalCase: Equatable, Codable, Sendable {
    public var fluid: BlackOilFluid
    public var reservoir: Reservoir
    public var well: Well
    public var waterCut: Double
    public var producingGOR: Double

    public init(
        fluid: BlackOilFluid = BlackOilFluid(),
        reservoir: Reservoir = Reservoir(),
        well: Well = Well(),
        waterCut: Double = 0.2,
        producingGOR: Double = 600
    ) {
        self.fluid = fluid
        self.reservoir = reservoir
        self.well = well
        self.waterCut = waterCut
        self.producingGOR = producingGOR
    }
}

public struct CurvePoint: Identifiable, Sendable {
    public var id: Double { rate }
    public let rate: Double
    public let pressure: Double
}

public struct NodalResult: Sendable {
    public let ipr: [CurvePoint]
    public let vlp: [CurvePoint]
    /// Operating point (liquid rate STB/d, flowing bottomhole pressure psia), nil if the well cannot flow naturally.
    public let operatingPoint: CurvePoint?
    /// Pressure traverse at the operating point (or at a nominal rate if there is none).
    public let traverse: [TraversePoint]
    public let productivityIndex: Double
    public let absoluteOpenFlow: Double
    public let bubblePoint: Double
}

/// Finds where reservoir inflow (IPR) meets tubing outflow (VLP) at the bottomhole node.
public enum NodalAnalysis {
    public static func solve(_ c: NodalCase, samples: Int = 30) -> NodalResult {
        let inflow = InflowModel(reservoir: c.reservoir, fluid: c.fluid)
        let outflow = WellboreFlowModel(well: c.well, fluid: c.fluid, reservoirTemperature: c.reservoir.temperature)
        let aof = inflow.absoluteOpenFlow

        func rates(_ q: Double) -> ProductionRates {
            ProductionRates(liquidRate: q, waterCut: c.waterCut, producingGOR: c.producingGOR)
        }

        let ipr = inflow.curve(points: samples).map { CurvePoint(rate: $0.rate, pressure: $0.pwf) }
        let qs = Numerics.linspace(aof * 0.01, aof, count: samples)
        let vlp = qs.map { CurvePoint(rate: $0, pressure: outflow.bottomholePressure(rates: rates($0))) }

        // f(q) = VLP − IPR. The stable operating point is the rightmost crossing where f goes
        // from negative (reservoir pressure to spare) to positive (tubing needs more than it gets).
        func mismatch(_ q: Double) -> Double {
            outflow.bottomholePressure(rates: rates(q)) - (inflow.pwf(rate: q) ?? 0)
        }
        var operating: CurvePoint?
        let values = qs.map(mismatch)
        if let i = (1..<values.count).reversed().first(where: { values[$0 - 1] < 0 && values[$0] >= 0 }) {
            if let q = Numerics.bisect(qs[i - 1], qs[i], tolerance: 0.05, mismatch) {
                operating = CurvePoint(rate: q, pressure: inflow.pwf(rate: q) ?? 0)
            }
        }

        let traverseRate = operating?.rate ?? aof * 0.3
        return NodalResult(
            ipr: ipr,
            vlp: vlp,
            operatingPoint: operating,
            traverse: outflow.traverse(rates: rates(traverseRate)),
            productivityIndex: inflow.productivityIndex,
            absoluteOpenFlow: aof,
            bubblePoint: inflow.bubblePoint
        )
    }
}
