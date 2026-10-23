import Foundation

/// The 3D model fields at one moment, in double precision, for export.
public struct Invasion3DSnapshot: Sendable {
    public let setup: Invasion3DSetup
    /// Simulated time, s.
    public let time: Double
    /// Normalised pressure (0 pore, 1 mud).
    public let pressure: [Double]
    public let saturation: [Double]
    public let fines: [Double]
    public let retained: [Double]
    /// Cake thickness per column, m.
    public let cake: [Double]

    public init(setup: Invasion3DSetup, time: Double, pressure: [Double], saturation: [Double], fines: [Double],
                retained: [Double], cake: [Double]) {
        self.setup = setup
        self.time = time
        self.pressure = pressure
        self.saturation = saturation
        self.fines = fines
        self.retained = retained
        self.cake = cake
    }

    public func permeabilityRatio(_ a: Int) -> Double {
        setup.damageRatio(saturation: saturation[a], retained: retained[a])
    }
}

/// One row of the run history.
public struct Invasion3DHistoryPoint: Codable, Equatable, Sendable {
    public var stats: Invasion3DStats
    public init(stats: Invasion3DStats) { self.stats = stats }
}

/// Everything needed to reproduce a run: inputs, grid, numerical settings, and the results it gave.
public struct Invasion3DRunRecord: Codable, Sendable {
    public struct Grid: Codable, Sendable {
        public var radialCells: Int
        public var angularCells: Int
        public var axialCells: Int
        public var wellboreRadius_m: Double
        public var domainRadius_m: Double
        public var intervalLength_m: Double
        public var boundaryRadius_m: Double
        public var radialGrowthRatio: Double
        public var smallestRadialCell_m: Double
    }

    public var format = "FluidMechLab 3D invasion run record"
    public var formatVersion = 1
    public var application: String
    public var createdAt: Date
    public var study: String
    public var solver: String
    public var device: String
    public var mud: MudInvasionCase
    public var options: Invasion3DOptions
    public var grid: Grid
    public var equations = "docs/INVASION3D.md"
    public var finalStats: Invasion3DStats
    public var skin: Double?
    public var history: [Invasion3DStats]

    public init(application: String, study: String, solver: String, device: String, setup: Invasion3DSetup,
                finalStats: Invasion3DStats, skin: Double?, history: [Invasion3DStats], createdAt: Date = Date()) {
        self.application = application
        self.createdAt = createdAt
        self.study = study
        self.solver = solver
        self.device = device
        mud = setup.mud
        options = setup.options
        grid = Grid(
            radialCells: setup.nr, angularCells: setup.nt, axialCells: setup.nz,
            wellboreRadius_m: setup.wellboreRadius, domainRadius_m: setup.domainRadius, intervalLength_m: setup.length,
            boundaryRadius_m: setup.boundaryRadius, radialGrowthRatio: setup.faces[1] / setup.faces[0],
            smallestRadialCell_m: setup.faces[1] - setup.faces[0])
        self.finalStats = finalStats
        self.skin = skin
        self.history = history
    }

    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}

/// File formats for the 3D model.
public enum Invasion3DExport {
    /// Legacy VTK structured grid (binary, big-endian), readable by ParaView and VisIt.
    /// Points are the cell corners in metres (x, y across the well, z along it); fields are cell data.
    public static func vtk(_ snap: Invasion3DSnapshot, title: String = "FluidMechLab 3D invasion") -> Data {
        let s = snap.setup
        var data = Data()
        func line(_ text: String) { data.append(contentsOf: Array((text + "\n").utf8)) }
        func float(_ v: Double) {
            var bits = Float(v).bitPattern.bigEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }

        line("# vtk DataFile Version 3.0")
        line(String(title.prefix(200)).replacingOccurrences(of: "\n", with: " ") + String(format: ", t = %.6g h", snap.time / 3600))
        line("BINARY")
        line("DATASET STRUCTURED_GRID")
        line("DIMENSIONS \(s.nr + 1) \(s.nt + 1) \(s.nz + 1)")
        let pointCount = (s.nr + 1) * (s.nt + 1) * (s.nz + 1)
        line("POINTS \(pointCount) float")
        for k in 0...s.nz {
            let z = Double(k) * s.dz - 0.5 * s.length
            for j in 0...s.nt {
                let theta = Double(j) * s.dTheta
                let c = cos(theta), sn = sin(theta)
                for i in 0...s.nr {
                    float(s.faces[i] * c)
                    float(s.faces[i] * sn)
                    float(z)
                }
            }
        }
        line("")
        line("CELL_DATA \(s.cellCount)")
        func scalars(_ name: String, _ value: (Int) -> Double) {
            line("SCALARS \(name) float 1")
            line("LOOKUP_TABLE default")
            for a in 0..<s.cellCount { float(value(a)) }
            line("")
        }
        scalars("filtrate_saturation") { snap.saturation[$0] }
        scalars("k_over_k0") { snap.permeabilityRatio($0) }
        scalars("permeability_md") { Double(s.k0[$0]) * s.permeability * snap.permeabilityRatio($0) }
        scalars("initial_permeability_md") { Double(s.k0[$0]) * s.permeability }
        scalars("retained_fines_fraction") { snap.retained[$0] }
        scalars("suspended_fines_fraction") { snap.fines[$0] }
        scalars("overpressure_psi") { snap.pressure[$0] * s.overbalance }
        scalars("cake_thickness_mm") { a in snap.cake[a / s.nr] * 1e3 }
        return data
    }

    /// Profile against radius, averaged over angle and height (with minimum and maximum over the ring).
    public static func radialProfileCSV(_ snap: Invasion3DSnapshot) -> String {
        let s = snap.setup
        var rows = ["radius_m,depth_into_formation_in,saturation_mean,saturation_min,saturation_max,k_over_k0_mean,k_over_k0_min,retained_fines_mean,suspended_fines_mean,overpressure_psi_mean"]
        let ring = Double(s.columnCount)
        for i in 0..<s.nr {
            var sSum = 0.0, sMin = 1.0, sMax = 0.0, kSum = 0.0, kMin = Double.infinity, sigma = 0.0, c = 0.0, p = 0.0
            for k in 0..<s.nz {
                for j in 0..<s.nt {
                    let a = s.index(i, j, k)
                    let sat = snap.saturation[a]
                    sSum += sat
                    sMin = min(sMin, sat)
                    sMax = max(sMax, sat)
                    let ratio = snap.permeabilityRatio(a)
                    kSum += ratio
                    kMin = min(kMin, ratio)
                    sigma += snap.retained[a]
                    c += snap.fines[a]
                    p += snap.pressure[a]
                }
            }
            let r = s.centres[i]
            let depth: Double = (r - s.wellboreRadius) / 0.0254
            let pressure: Double = p / ring * s.overbalance
            let values: [Double] = [r, depth, sSum / ring, sMin, sMax, kSum / ring, kMin, sigma / ring, c / ring, pressure]
            rows.append(row(values))
        }
        return rows.joined(separator: "\n") + "\n"
    }

    /// Filtrate front depth (s = 0.5) and cake thickness for every column of the wall: an unrolled map of the borehole.
    public static func frontMapCSV(_ snap: Invasion3DSnapshot) -> String {
        let s = snap.setup
        var rows = ["angle_deg,height_m,front_depth_in,cake_thickness_mm"]
        for k in 0..<s.nz {
            for j in 0..<s.nt {
                let r = Invasion3DMetrics.frontRadius(setup: s, j: j, k: k) { snap.saturation[$0] }
                let angle = (Double(j) + 0.5) * s.dTheta * 180 / .pi
                let z = (Double(k) + 0.5) * s.dz - 0.5 * s.length
                let depth: Double = (r - s.wellboreRadius) / 0.0254
                let cake: Double = snap.cake[s.column(j, k)] * 1e3
                rows.append(row([angle, z, depth, cake]))
            }
        }
        return rows.joined(separator: "\n") + "\n"
    }

    /// Time history of the summary numbers.
    public static func historyCSV(_ history: [Invasion3DStats]) -> String {
        var rows = ["time_h,filtrate_depth_in,front_mean_in,front_min_in,front_max_in,front_spread_in,cake_mean_mm,cake_min_mm,cake_max_mm,filtration_rate_cm_per_h,cumulative_filtrate_cm,min_k_over_k0,mean_invaded_k_over_k0,mass_balance_error,pressure_solves,last_pressure_sweeps,last_flow_imbalance"]
        for h in history {
            var values: [Double] = [h.time, h.filtrateDepth, h.frontMean, h.frontMin, h.frontMax, h.frontSpread]
            values += [h.cakeMean, h.cakeMin, h.cakeMax, h.filtrationRate, h.cumulativeFiltrate]
            values += [h.minPermeabilityRatio, h.meanInvadedPermeabilityRatio, h.massBalanceError]
            values += [Double(h.pressureSolves), Double(h.lastIterations), h.lastImbalance]
            rows.append(row(values))
        }
        return rows.joined(separator: "\n") + "\n"
    }

    static func row(_ values: [Double]) -> String {
        values.map { (v: Double) -> String in format(v) }.joined(separator: ",")
    }

    static func format(_ v: Double) -> String {
        guard v.isFinite else { return "" }
        return String(format: "%.8g", v)
    }
}
