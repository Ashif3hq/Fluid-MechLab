# Fluid MechLab

An offline, native macOS app for studying fluid flow in oil wells, with a focus on near-wellbore formation damage caused by drilling mud. It is written in Swift and SwiftUI for Apple Silicon Macs and needs no internet connection.

## What it does

Each study is a document (`.fmlab`) with a sidebar of sections, an inspector on the right for inputs, and results that recompute as you type. It supports light and dark mode, Field and SI units, undo, and standard Mac shortcuts.

| Section | What you can study |
|---|---|
| **Well Architecture** | A built-in well model editor: trajectory (kickoff, build rate, hold angle), casing program, tubing, packer and perforations, drawn as a live well schematic with a survey table and validation of the design. |
| **3D Model** | An orbitable 3D view of the well path, casing strings, rock layers, reservoir and the invaded zone around the hole. |
| **Fluid PVT** | Black-oil properties (Rs, Bo, oil viscosity and density, gas Z-factor and viscosity) against pressure. |
| **Formation Damage** | Radial invasion of mud filtrate and fine solids while drilling overbalanced: mud-cake growth, spurt loss, deep-bed filtration of fines, filtrate damage (clay swelling or water block), the permeability profile, a radial damage map, skin and productivity ratio. |
| **Live Flow** | A real-time simulation of mud invasion around the borehole, computed and drawn on the Mac's GPU with Metal. Watch the cake build, the filtrate and fines move into heterogeneous rock, and permeability fall, with tracer particles showing the flow. Choose which field to show, play or pause, change the playback speed and the rock heterogeneity, and compare with the 1D model's front. |
| **3D Invasion** | A research-grade 3D model of a length of borehole and the layered, anisotropic rock around it, solved on the GPU on a cylindrical grid of up to 2.4 million cells. Ray-marched cutaway, front-isosurface and volume views of filtrate, damage, fines and pressure. Built-in verification against analytical solutions with observed convergence orders, live mass-balance and solver diagnostics, lab calibration from filter-press and return-permeability tests, and ParaView (VTK), CSV and JSON run-record exports. See [docs/INVASION3D.md](docs/INVASION3D.md). |
| **Nodal Analysis** | Inflow (Darcy + Vogel) against tubing outflow (Beggs-Brill along the deviated path), with the damage skin carried in. Shows the operating point, pressure traverse by flow pattern, holdup and the gradient split. |
| **Sensitivity** | Sweeps one input (overbalance, exposure time, fines, λ₀, β, cake permeability, rock permeability) and plots skin, invasion depth and rate. |

**Presets.** The Preset Library (⇧⌘L) has 23 templates relevant to the study: field scenarios (giant carbonate, deepwater turbidite, North Sea, mature waterflood, heavy oil, tight sand, HPHT), formation damage studies, mud systems (bentonite WBM, polymer WBM, OBM, sized-CaCO₃ drill-in fluid, fresh-water mud) and rock types. Mud and rock presets change only their part of the study.

**Compare.** Keep as Reference (⌘K) pins the current results as dashed curves so you can see what a change does. Export CSV (⇧⌘E) saves the current section's results.

The equations, correlations and references are in [docs/MODELS.md](docs/MODELS.md).

| | |
|---|---|
| ![Well architecture](https://github.com/Ashif3hq/Fluid-MechLab/blob/ci-screenshots/light-1-architecture.png?raw=true) | ![Formation damage](https://github.com/Ashif3hq/Fluid-MechLab/blob/ci-screenshots/light-4-damage.png?raw=true) |
| ![Nodal analysis](https://github.com/Ashif3hq/Fluid-MechLab/blob/ci-screenshots/dark-5-nodal.png?raw=true) | ![Preset library](https://github.com/Ashif3hq/Fluid-MechLab/blob/ci-screenshots/preset-library.png?raw=true) |

Screenshots are produced by CI on every push and stored on the `ci-screenshots` branch.

## Running it on your Mac

Requirements: macOS 14 (Sonoma) or newer and Xcode 16 or newer (free from the Mac App Store).

**With Xcode:** open the folder (or `Package.swift`) in Xcode, choose the **FluidMechLab** scheme and **My Mac**, then press ⌘R.

**From Terminal:**

```sh
git clone https://github.com/Ashif3hq/Fluid-MechLab.git
cd Fluid-MechLab
swift run -c release FluidMechLab
```

To build a double-clickable app, run `scripts/build-app.sh`. It creates `build/Fluid MechLab.app`, which you can drag to Applications.

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
  WellGeometry.swift     Trajectory, casing, tubing, perforations
  StudyCase.swift        The document model
  Presets.swift          Industry presets
  Sensitivity.swift      One-parameter sweeps
  Units.swift            Field and SI display units
Sources/FluidMechLab/    SwiftUI app (App, Model, Views)
scripts/build-app.sh     Builds the .app bundle
Tests/FlowCoreTests/     Unit tests for the engine
```

## Roadmap

1. Wellbore nodal analysis, mud-induced formation damage, well model editor, 3D view and presets (done).
2. Calibration against coreflood data: fit λ₀, β and the filtrate factor to return-permeability tests, and import lab data from CSV.
3. 2D/3D reservoir pressure and saturation solver on the GPU with Metal compute, with heatmaps of the damaged zone during clean-up and production.
4. Fines migration during production, acid stimulation and skin removal.
5. Pipelines and surface gathering networks.

## Accuracy

The correlations are standard textbook methods meant for study and screening. They are not a replacement for validated commercial simulators, so check results against field or lab data before relying on them.
