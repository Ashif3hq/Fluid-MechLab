import Foundation

/// Everything one study document holds: the well, the reservoir and fluid, and the drilling-mud exposure.
///
/// Rock properties and wellbore size live in one place (reservoir and well) and are copied into the
/// formation damage and nodal inputs, so the modules always describe the same well.
public struct StudyCase: Equatable, Codable, Sendable {
    public var formatVersion: Int = 1
    public var title: String
    public var notes: String
    public var well: WellModel
    public var fluid: BlackOilFluid
    /// Reservoir. Its `skin` is the completion (mechanical) skin, excluding mud damage.
    public var reservoir: Reservoir
    public var waterCut: Double
    public var producingGOR: Double
    /// Mud, drilling and rock-fluid interaction parameters.
    public var mud: MudInvasionCase
    /// Add the simulated mud-damage skin to the completion skin in the inflow model.
    public var includeDamageSkin: Bool
    /// Name of the preset this case was built from, if any.
    public var basedOn: String?
    /// Settings of the 3D invasion model. Nil in studies saved before it existed.
    public var invasion3D: Invasion3DOptions?

    /// 3D model settings, with defaults when the study has none.
    public var invasionOptions: Invasion3DOptions {
        get { invasion3D ?? Invasion3DOptions() }
        set { invasion3D = newValue }
    }

    public init(
        title: String = "Untitled Study",
        notes: String = "",
        well: WellModel = WellModel(),
        fluid: BlackOilFluid = BlackOilFluid(),
        reservoir: Reservoir = Reservoir(),
        waterCut: Double = 0.2,
        producingGOR: Double = 600,
        mud: MudInvasionCase = MudInvasionCase(),
        includeDamageSkin: Bool = true,
        basedOn: String? = nil,
        invasion3D: Invasion3DOptions? = nil
    ) {
        self.title = title
        self.notes = notes
        self.well = well
        self.fluid = fluid
        self.reservoir = reservoir
        self.waterCut = waterCut
        self.producingGOR = producingGOR
        self.mud = mud
        self.includeDamageSkin = includeDamageSkin
        self.basedOn = basedOn
        self.invasion3D = invasion3D
    }

    /// Formation damage inputs with rock and geometry taken from the reservoir and well.
    public var damageCase: MudInvasionCase {
        var m = mud
        m.permeability = reservoir.permeability
        m.porosity = reservoir.porosity
        m.wellboreRadius = well.reservoirBitSize / 2
        m.drainageRadius = reservoir.drainageRadius
        return m
    }

    /// Nodal inputs. `damageSkin` is the latest formation damage result, if one exists.
    public func nodalCase(damageSkin: Double?) -> NodalCase {
        var r = reservoir
        r.wellboreRadius = well.wellboreRadius
        if includeDamageSkin, let damageSkin { r.skin += damageSkin }
        return NodalCase(fluid: fluid, reservoir: r, well: well.flowWell, waterCut: waterCut, producingGOR: producingGOR)
    }

    /// Reservoir pressure gradient implied by the inputs, psi/ft, for sanity hints.
    public var reservoirPressureGradient: Double {
        let tvd = well.trajectory.position(atMD: well.midPerforationDepth).tvd
        return tvd > 0 ? reservoir.pressure / tvd : 0
    }
}
