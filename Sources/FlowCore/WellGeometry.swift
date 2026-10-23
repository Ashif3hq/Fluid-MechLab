import Foundation

// MARK: - Trajectory

/// Build-and-hold well path: vertical to the kick-off point, constant build rate, then a straight tangent.
public struct WellTrajectory: Equatable, Codable, Sendable {
    /// Kick-off point, ft MD.
    public var kickoffDepth: Double
    /// Build rate, degrees per 100 ft.
    public var buildRate: Double
    /// Tangent inclination from vertical, degrees.
    public var holdInclination: Double
    /// Azimuth of the tangent section, degrees from north.
    public var azimuth: Double

    public init(kickoffDepth: Double = 0, buildRate: Double = 2, holdInclination: Double = 0, azimuth: Double = 0) {
        self.kickoffDepth = kickoffDepth
        self.buildRate = buildRate
        self.holdInclination = holdInclination
        self.azimuth = azimuth
    }

    private var hold: Double { min(max(holdInclination, 0), 90) }

    /// Measured length of the build section, ft. Zero means the well steps straight to the hold angle.
    public var buildLength: Double {
        guard hold > 0, buildRate > 0 else { return 0 }
        return hold / buildRate * 100
    }

    /// Inclination from vertical at measured depth `md`, degrees.
    public func inclination(atMD md: Double) -> Double {
        guard hold > 0, md > kickoffDepth else { return 0 }
        guard buildLength > 0 else { return hold }
        return min((md - kickoffDepth) / 100 * buildRate, hold)
    }

    /// Position at measured depth `md`: true vertical depth and horizontal displacement (ft).
    public func position(atMD md: Double) -> (tvd: Double, displacement: Double) {
        guard hold > 0, md > kickoffDepth else { return (md, 0) }
        let kop = kickoffDepth
        if buildLength == 0 {
            let a = hold * .pi / 180
            return (kop + (md - kop) * cos(a), (md - kop) * sin(a))
        }
        let radius = 18000 / (.pi * buildRate)
        let lb = buildLength
        if md <= kop + lb {
            let theta = (md - kop) / radius
            return (kop + radius * sin(theta), radius * (1 - cos(theta)))
        }
        let a = hold * .pi / 180
        let tvdEOB = kop + radius * sin(a)
        let dispEOB = radius * (1 - cos(a))
        let tangent = md - kop - lb
        return (tvdEOB + tangent * cos(a), dispEOB + tangent * sin(a))
    }

    /// Survey stations at a fixed MD interval down to `totalDepth`.
    public func survey(to totalDepth: Double, interval: Double = 50) -> [SurveyStation] {
        let az = azimuth * .pi / 180
        var mds = Array(stride(from: 0, to: totalDepth, by: max(interval, 1)))
        mds.append(totalDepth)
        return mds.map { md in
            let p = position(atMD: md)
            return SurveyStation(
                measuredDepth: md,
                inclination: inclination(atMD: md),
                azimuth: azimuth,
                trueVerticalDepth: p.tvd,
                north: p.displacement * cos(az),
                east: p.displacement * sin(az))
        }
    }
}

public struct SurveyStation: Identifiable, Equatable, Sendable {
    public var id: Double { measuredDepth }
    public let measuredDepth: Double
    public let inclination: Double
    public let azimuth: Double
    public let trueVerticalDepth: Double
    public let north: Double
    public let east: Double

    public var horizontalDisplacement: Double { (north * north + east * east).squareRoot() }
}

// MARK: - Well architecture

/// A casing or liner string.
public struct CasingString: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    public var name: String
    /// Outer diameter, in.
    public var outerDiameter: Double
    /// Inner (drift) diameter, in.
    public var innerDiameter: Double
    /// Top of string, ft MD (0 for full casing, deeper for a liner).
    public var top: Double
    /// Shoe depth, ft MD.
    public var shoe: Double
    /// Bit size the hole was drilled with, in.
    public var holeSize: Double
    /// Top of cement, ft MD.
    public var topOfCement: Double

    public init(
        id: UUID = UUID(), name: String, outerDiameter: Double, innerDiameter: Double,
        top: Double = 0, shoe: Double, holeSize: Double, topOfCement: Double? = nil
    ) {
        self.id = id
        self.name = name
        self.outerDiameter = outerDiameter
        self.innerDiameter = innerDiameter
        self.top = top
        self.shoe = shoe
        self.holeSize = holeSize
        self.topOfCement = topOfCement ?? max(top, shoe - 1500)
    }

    public var isLiner: Bool { top > 0 }
}

public struct TubingString: Equatable, Codable, Sendable {
    /// Outer diameter, in.
    public var outerDiameter: Double
    /// Inner diameter, in.
    public var innerDiameter: Double
    /// Tubing shoe (end of tubing), ft MD.
    public var shoe: Double
    /// Absolute roughness, in.
    public var roughness: Double

    public init(outerDiameter: Double = 3.5, innerDiameter: Double = 2.992, shoe: Double = 7800, roughness: Double = 0.0006) {
        self.outerDiameter = outerDiameter
        self.innerDiameter = innerDiameter
        self.shoe = shoe
        self.roughness = roughness
    }
}

/// A perforated interval.
public struct PerforationInterval: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    /// Top, ft MD.
    public var top: Double
    /// Bottom, ft MD.
    public var bottom: Double
    /// Shots per foot.
    public var shotDensity: Double

    public init(id: UUID = UUID(), top: Double, bottom: Double, shotDensity: Double = 12) {
        self.id = id
        self.top = top
        self.bottom = bottom
        self.shotDensity = shotDensity
    }
}

/// Full well architecture: what the schematic and 3D views draw, and what the flow model uses.
public struct WellModel: Equatable, Codable, Sendable {
    public var name: String
    public var trajectory: WellTrajectory
    public var casings: [CasingString]
    public var tubing: TubingString
    /// Production packer depth, ft MD.
    public var packerDepth: Double
    public var perforations: [PerforationInterval]
    /// Total depth of the well, ft MD.
    public var totalDepth: Double
    /// Bit size across the reservoir section, in. Sets the wellbore radius for inflow and damage.
    public var reservoirBitSize: Double
    /// Top and bottom of the reservoir, ft TVD.
    public var reservoirTop: Double
    public var reservoirBottom: Double
    /// Flowing wellhead pressure, psia.
    public var wellheadPressure: Double
    /// Flowing wellhead temperature, °F.
    public var wellheadTemperature: Double

    public init(
        name: String = "Producer-1",
        trajectory: WellTrajectory = WellTrajectory(),
        casings: [CasingString] = WellModel.defaultCasings,
        tubing: TubingString = TubingString(),
        packerDepth: Double = 7750,
        perforations: [PerforationInterval] = [PerforationInterval(top: 7970, bottom: 8030)],
        totalDepth: Double = 8200,
        reservoirBitSize: Double = 8.5,
        reservoirTop: Double = 7950,
        reservoirBottom: Double = 8050,
        wellheadPressure: Double = 250,
        wellheadTemperature: Double = 120
    ) {
        self.name = name
        self.trajectory = trajectory
        self.casings = casings
        self.tubing = tubing
        self.packerDepth = packerDepth
        self.perforations = perforations
        self.totalDepth = totalDepth
        self.reservoirBitSize = reservoirBitSize
        self.reservoirTop = reservoirTop
        self.reservoirBottom = reservoirBottom
        self.wellheadPressure = wellheadPressure
        self.wellheadTemperature = wellheadTemperature
    }

    public static let defaultCasings: [CasingString] = [
        CasingString(name: "Conductor", outerDiameter: 20, innerDiameter: 19.124, shoe: 300, holeSize: 26, topOfCement: 0),
        CasingString(name: "Surface", outerDiameter: 13.375, innerDiameter: 12.415, shoe: 2500, holeSize: 17.5, topOfCement: 0),
        CasingString(name: "Intermediate", outerDiameter: 9.625, innerDiameter: 8.681, shoe: 5500, holeSize: 12.25, topOfCement: 1500),
        CasingString(name: "Production", outerDiameter: 7, innerDiameter: 6.184, shoe: 8200, holeSize: 8.5, topOfCement: 6500),
    ]

    /// Mid-point of the perforated interval(s), ft MD.
    public var midPerforationDepth: Double {
        guard let top = perforations.map(\.top).min(), let bottom = perforations.map(\.bottom).max() else {
            return totalDepth
        }
        return 0.5 * (top + bottom)
    }

    /// Total perforated length, ft MD.
    public var perforatedLength: Double {
        perforations.reduce(0) { $0 + max($1.bottom - $1.top, 0) }
    }

    /// Wellbore radius across the reservoir, ft.
    public var wellboreRadius: Double { reservoirBitSize / 24 }

    public func survey(interval: Double = 50) -> [SurveyStation] {
        trajectory.survey(to: totalDepth, interval: interval)
    }

    /// Converts a TVD to MD along this trajectory (bisection; MD is monotonic in TVD while inclination < 90°).
    public func measuredDepth(atTVD tvd: Double) -> Double {
        Numerics.bisect(0, max(totalDepth, tvd) * 4, tolerance: 0.01) { trajectory.position(atMD: $0).tvd - tvd } ?? tvd
    }

    /// Flow path for the outflow model. Flow runs up the tubing from mid-perforations.
    public var flowWell: Well {
        Well(
            measuredDepth: midPerforationDepth,
            deviation: trajectory.holdInclination,
            kickoffDepth: trajectory.kickoffDepth,
            buildRate: trajectory.buildRate,
            tubingID: tubing.innerDiameter,
            roughness: tubing.roughness,
            wellheadPressure: wellheadPressure,
            wellheadTemperature: wellheadTemperature)
    }

    /// Basic engineering checks shown to the user next to the schematic.
    public var validationMessages: [String] {
        var messages: [String] = []
        let sorted = casings.sorted { $0.outerDiameter > $1.outerDiameter }
        for (outer, inner) in zip(sorted, sorted.dropFirst()) where inner.outerDiameter >= outer.innerDiameter {
            messages.append("\(inner.name) (\(inner.outerDiameter)\" OD) does not fit inside \(outer.name) (\(outer.innerDiameter)\" ID).")
        }
        for c in casings where c.holeSize <= c.outerDiameter {
            messages.append("\(c.name): hole size must be larger than the casing OD.")
        }
        for c in casings where c.innerDiameter >= c.outerDiameter {
            messages.append("\(c.name): ID must be smaller than OD.")
        }
        if let prod = sorted.last, tubing.outerDiameter >= prod.innerDiameter {
            messages.append("Tubing OD is larger than the \(prod.name) ID.")
        }
        if tubing.innerDiameter >= tubing.outerDiameter {
            messages.append("Tubing ID must be smaller than its OD.")
        }
        if packerDepth > midPerforationDepth {
            messages.append("Packer is set below the perforations.")
        }
        if tubing.shoe > (perforations.map(\.top).min() ?? totalDepth) {
            messages.append("Tubing shoe is inside the perforated interval.")
        }
        for p in perforations where p.bottom > totalDepth || p.top >= p.bottom {
            messages.append("Perforation \(Int(p.top))–\(Int(p.bottom)) ft is outside the well or has zero length.")
        }
        return messages
    }
}
