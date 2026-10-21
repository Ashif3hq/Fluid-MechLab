# Fluid MechLab

An offline, native macOS app for studying fluid flow in oil wells, with a focus on near-wellbore formation damage caused by drilling mud. It is written in Swift and SwiftUI for Apple Silicon Macs and needs no internet connection.

## What it does today (milestone 1)

| Workspace | What you can study |
|---|---|
| **Nodal Analysis** | Where reservoir inflow (IPR) meets tubing outflow (VLP). Live sliders for reservoir pressure, permeability, skin, fluid gravity, GOR, water cut, tubing size and wellhead pressure. Shows the operating rate and pressure, the pressure traverse coloured by multiphase flow pattern, and liquid holdup along the tubing. |
| **Formation Damage** | Radial invasion of mud filtrate and fine solids into the rock while drilling overbalanced: external mud-cake growth (static or dynamic), spurt loss, deep-bed filtration of fines, filtrate damage (clay swelling or water block), the resulting permeability profile, skin and productivity ratio. One click carries the skin into Nodal Analysis. |
| **Fluid PVT** | Black-oil properties (Rs, Bo, oil viscosity and density, gas Z-factor and viscosity) against pressure. |

The equations, correlations and references are in [docs/MODELS.md](docs/MODELS.md).

## Running it on your Mac

Requirements: macOS 14 (Sonoma) or newer and Xcode 16 or newer (free from the Mac App Store).

**With Xcode:** open the folder (or `Package.swift`) in Xcode, choose the **FluidMechLab** scheme and **My Mac**, then press ⌘R.

**From Terminal:**

```sh
git clone https://github.com/Ashif3hq/Fluid-MechLab.git
cd Fluid-MechLab
swift run -c release FluidMechLab
```

Run the physics tests with `swift test`.

## Project layout

```
Sources/FlowCore/        Physics engine (pure Swift, no UI)
  PVT.swift              Black-oil fluid correlations
  IPR.swift              Reservoir inflow (Darcy PI with skin, Vogel)
  BeggsBrill.swift       Multiphase pressure gradient and flow pattern
  Wellbore.swift         Tubing pressure traverse
  NodalAnalysis.swift    IPR/VLP operating point
  FormationDamage.swift  Mud cake, filtrate and fines invasion, skin
Sources/FluidMechLab/    SwiftUI app
Tests/FlowCoreTests/     Unit tests for the engine
```

## Roadmap

1. Wellbore nodal analysis and mud-induced formation damage (this milestone).
2. Calibration against coreflood data: fit λ₀, β and the filtrate factor to return-permeability tests, and import lab data from CSV.
3. 2D/3D reservoir pressure and saturation solver on the GPU with Metal compute, with heatmaps of the damaged zone during clean-up and production.
4. Fines migration during production, acid stimulation and skin removal.
5. Pipelines and surface gathering networks.

## Accuracy

The correlations are standard textbook methods meant for study and screening. They are not a replacement for validated commercial simulators, so check results against field or lab data before relying on them.
