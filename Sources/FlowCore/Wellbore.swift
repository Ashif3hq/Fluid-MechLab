import Foundation

/// Hydraulic description of the flow path used by the outflow model: tubing plus a build-and-hold trajectory.
public struct Well: Equatable, Codable, Sendable {
    /// Measured depth from wellhead to mid-perforation, ft.
    public var measuredDepth: Double
    /// Hold (tangent) inclination from vertical, degrees (0 = vertical well).
    public var deviation: Double
    /// Kick-off point, ft MD.
    public var kickoffDepth: Double
    /// Build rate, degrees per 100 ft.
    public var buildRate: Double
    /// Tubing inner diameter, inches.
    public var tubingID: Double
    /// Absolute pipe roughness, inches.
    public var roughness: Double
    /// Flowing wellhead pressure, psia.
    public var wellheadPressure: Double
    /// Wellhead flowing temperature, °F.
    public var wellheadTemperature: Double

    public init(
        measuredDepth: Double = 8000,
        deviation: Double = 0,
        kickoffDepth: Double = 0,
        buildRate: Double = 2,
        tubingID: Double = 2.992,
        roughness: Double = 0.0006,
        wellheadPressure: Double = 250,
        wellheadTemperature: Double = 120
    ) {
        self.measuredDepth = measuredDepth
        self.deviation = deviation
        self.kickoffDepth = kickoffDepth
        self.buildRate = buildRate
        self.tubingID = tubingID
        self.roughness = roughness
        self.wellheadPressure = wellheadPressure
        self.wellheadTemperature = wellheadTemperature
    }

    var trajectory: WellTrajectory {
        WellTrajectory(kickoffDepth: kickoffDepth, buildRate: buildRate, holdInclination: deviation, azimuth: 0)
    }

    /// Inclination from vertical at a measured depth, degrees.
    public func inclination(atMD md: Double) -> Double { trajectory.inclination(atMD: md) }

    /// True vertical depth at a measured depth, ft.
    public func trueVerticalDepth(atMD md: Double) -> Double { trajectory.position(atMD: md).tvd }

    public var trueVerticalDepth: Double { trueVerticalDepth(atMD: measuredDepth) }
}

/// Surface production rates and ratios.
public struct ProductionRates: Equatable, Codable, Sendable {
    /// Total liquid rate (oil + water), STB/d.
    public var liquidRate: Double
    /// Water cut, fraction of liquid.
    public var waterCut: Double
    /// Producing gas-oil ratio, scf/STB.
    public var producingGOR: Double

    public init(liquidRate: Double, waterCut: Double = 0.2, producingGOR: Double = 600) {
        self.liquidRate = liquidRate
        self.waterCut = waterCut
        self.producingGOR = producingGOR
    }
}

/// One station of a pressure traverse.
public struct TraversePoint: Identifiable, Sendable {
    public var id: Double { depth }
    /// Measured depth, ft.
    public let depth: Double
    public let pressure: Double
    public let temperature: Double
    public let holdup: Double
    public let pattern: FlowPattern
    public let mixtureVelocity: Double
    public let elevationGradient: Double
    public let frictionGradient: Double
}

/// Vertical lift performance: pressure traverse down the tubing from the wellhead.
public struct WellboreFlowModel: Sendable {
    public let well: Well
    public let fluid: BlackOilFluid
    public let reservoirTemperature: Double
    /// Segment length for the marching scheme, ft.
    public var stepLength: Double = 100

    public init(well: Well, fluid: BlackOilFluid, reservoirTemperature: Double) {
        self.well = well
        self.fluid = fluid
        self.reservoirTemperature = reservoirTemperature
    }

    /// Linear geothermal profile in true vertical depth between wellhead and perforations.
    func temperature(atDepth md: Double) -> Double {
        let total = well.trueVerticalDepth
        let f = total > 0 ? well.trueVerticalDepth(atMD: md) / total : 0
        return well.wellheadTemperature + f * (reservoirTemperature - well.wellheadTemperature)
    }

    /// In-situ phase velocities and properties at (p, T) for the given surface rates.
    public func flowState(pressure p: Double, temperature t: Double, rates: ProductionRates) -> PipeFlowState {
        let d = well.tubingID / 12
        let area = Double.pi * d * d / 4
        let qo = rates.liquidRate * (1 - rates.waterCut)
        let qw = rates.liquidRate * rates.waterCut

        let rs = fluid.solutionGasOilRatio(pressure: p, temperature: t)
        let bo = fluid.oilFVF(pressure: p, temperature: t)
        let bw = fluid.waterFVF(pressure: p, temperature: t)
        let bg = fluid.gasFVF(pressure: p, temperature: t)

        let qoInSitu = qo * bo * 5.615 / 86400
        let qwInSitu = qw * bw * 5.615 / 86400
        let qgInSitu = qo * max(rates.producingGOR - rs, 0) * bg / 86400
        let ql = qoInSitu + qwInSitu

        let rhoO = fluid.oilDensity(pressure: p, temperature: t)
        let rhoW = fluid.waterDensity(pressure: p, temperature: t)
        let muO = fluid.oilViscosity(pressure: p, temperature: t)
        let muW = fluid.waterViscosity(temperature: t)
        let fo = ql > 0 ? qoInSitu / ql : 1
        let fw = 1 - fo

        return PipeFlowState(
            vsl: ql / area,
            vsg: qgInSitu / area,
            liquidDensity: rhoO * fo + rhoW * fw,
            gasDensity: fluid.gasDensity(pressure: p, temperature: t),
            liquidViscosity: muO * fo + muW * fw,
            gasViscosity: fluid.gasViscosity(pressure: p, temperature: t),
            surfaceTension: 30 * fo + 60 * fw
        )
    }

    private func gradient(pressure p: Double, depth md: Double, rates: ProductionRates) -> GradientResult {
        let t = temperature(atDepth: md)
        let state = flowState(pressure: max(p, 14.7), temperature: t, rates: rates)
        let theta = (90 - well.inclination(atMD: md)) * .pi / 180
        return BeggsBrill.gradient(
            state, diameter: well.tubingID / 12, roughness: well.roughness / 12, inclination: theta)
    }

    /// Marches from the wellhead to the perforations with a predictor-corrector (Heun) step.
    public func traverse(rates: ProductionRates) -> [TraversePoint] {
        var points: [TraversePoint] = []
        var md = 0.0
        var p = well.wellheadPressure
        let total = well.measuredDepth
        var g = gradient(pressure: p, depth: md, rates: rates)
        points.append(point(md, p, g))
        while md < total - 1e-9 {
            let h = min(stepLength, total - md)
            let pPred = p + g.totalGradient * h
            let gPred = gradient(pressure: pPred, depth: md + h, rates: rates)
            p += 0.5 * (g.totalGradient + gPred.totalGradient) * h
            md += h
            g = gradient(pressure: p, depth: md, rates: rates)
            points.append(point(md, p, g))
        }
        return points
    }

    private func point(_ md: Double, _ p: Double, _ g: GradientResult) -> TraversePoint {
        TraversePoint(
            depth: md, pressure: p, temperature: temperature(atDepth: md),
            holdup: g.holdup, pattern: g.pattern, mixtureVelocity: g.mixtureVelocity,
            elevationGradient: g.elevationGradient, frictionGradient: g.frictionGradient)
    }

    /// Required flowing bottomhole pressure (psia) to lift `rates` to surface.
    public func bottomholePressure(rates: ProductionRates) -> Double {
        traverse(rates: rates).last?.pressure ?? well.wellheadPressure
    }
}
