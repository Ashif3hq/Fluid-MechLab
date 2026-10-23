# 3D near-wellbore invasion model

This document describes the equations, units, numerical methods, verification and limits of the 3D Invasion model (`Sources/FlowCore/Invasion3D`, `Sources/FlowGPU/Invasion3D*`). It is meant to be cited in reports and theses that use the model. Every run can be reproduced from its JSON run record (Export ▸ Run record), which stores the inputs, grid, numerical settings, random seed and results.

## 1. Problem

The model covers a length *L* of vertical borehole of radius *r_w*, filled with mud at overbalance Δ*p*, and the rock around it out to radius *R*. Mud filtrate enters the rock through an external filter cake that builds on the wall. During the spurt period, before the cake bridges, fine solids enter with the filtrate. These fines are captured in the pore space by deep-bed filtration. Both the filtrate and the captured fines reduce permeability.

The model resolves all three directions: radial *r*, angular *θ*, and axial *z* (along the well). This lets it represent:

- layered and laminated rock, with permeability correlated more strongly along the bedding than across it;
- vertical anisotropy *k_v/k_h*;
- an uneven cake and uneven invasion around and along the well, including fingering into high-permeability streaks;
- the 3D distribution of damage, and the skin that results from it.

## 2. Equations

All variables are in SI units inside the solver. Pressures are normalised: *p̂* = (*p* − *p_pore*)/Δ*p*, so *p̂* = 1 in the borehole and *p̂* = 0 at the outer boundary. Permeabilities are written relative to the formation's horizontal permeability *k̄*.

| Symbol | Meaning | Units |
|---|---|---|
| *k̄* | horizontal formation permeability | m² (input md) |
| *k₀(x)* | undamaged permeability relative to *k̄* | – |
| *k_v/k_h* | anisotropy | – |
| φ | porosity | – |
| ΔS = 1 − S_wi − S_or | displaceable pore fraction | – |
| μ | filtrate viscosity | Pa·s (input cp) |
| Δ*p* | overbalance | Pa (input psi) |
| *s* | filtrate saturation (fraction of displaceable pore volume) | – |
| *c* | suspended fines, volume fraction of filtrate | – |
| σ | retained fines, volume per bulk volume | – |
| *h* | external cake thickness, per wall position | m |

**Flow.** The flow is incompressible Darcy flow with a tensor mobility:

∇·(λ **K** ∇*p̂*) = 0, where **K** = diag(1, 1, *k_v/k_h*) and λ = *k₀(x)* · *F_s* / (1 + βσ).

The filtrate factor is *F_s* = 1 − (1 − *F*) *s*. It interpolates between unflushed rock (*s* = 0) and fully flushed rock (*s* = 1, where k is multiplied by *F*). *F* lumps clay swelling, water blocking and relative-permeability effects.

The Darcy velocity is **u** = −(*k̄* Δ*p*/μ) λ **K** ∇*p̂*.

**Boundary conditions.**

- At the wall (*r* = *r_w*), the cake is a radial resistance in series with the rock: ln(*r_w*/(*r_w* − *h*)) / κ_c, where κ_c = *k_c*/*k̄*.
- At the outer radius *R*, the rock between *R* and the radius of the 1D model, *r_b*, is a resistance ln(*r_b*/*R*) at mean permeability. *p̂* = 0 at *r_b*.
- The top and bottom of the interval are sealed.

**Cake.** The cake grows from the solids in the filtrate, separately at each wall position:

d*h*/d*t* = α *u_n* (1 − *h*/*h_eq*), with α = *f_s* / ((1 − φ_c)(1 − *f_s*)).

Here *u_n* is the local filtration flux. *h_eq* is the equilibrium thickness under circulation; setting it to 0 gives static filtration.

**Filtrate.** φ ΔS ∂*s*/∂*t* + ∇·(**u** *s*) = 0, with *s* = 1 in the incoming filtrate.

**Fines (Iwasaki 1937; Herzig, Leclerc and Le Goff 1970):**

φ ∂*c*/∂*t* + ∇·(**u** *c*) = −λ_f |**u**| *c*

∂σ/∂*t* = λ_f |**u**| *c*

λ_f = λ₀ (1 − σ/σ_max)

The inlet concentration is *c₀* (1 − *h*/*h_b*)⁺, so fines stop entering once the cake reaches the bridging thickness *h_b*.

**Rock.** The rock is log-normal: *k₀* = exp(σ_ln *g* − σ_ln²/2), so its mean is 1. Here *g* is a unit Gaussian random field built from 64 random Fourier modes. Their wavenumbers have magnitude 2π/ℓ, with ℓ_h along the bedding and ℓ_v across it. A seed makes each realisation reproducible.

**Skin.** The skin is computed with the cake removed, from two steady 3D solves: one with the undamaged permeability, giving *Q₀*, and one with the damaged permeability, giving *Q_d*. Then

S = (*Q₀*/*Q_d* − 1) ln(*r_b*/*r_w*).

For purely radial damage this equals the discrete Hawkins sum Σ(*k₀*/*k* − 1) ln(*r*₊/*r*₋) exactly. A unit test checks this.

## 3. Discretisation

**Grid.** The grid is cylindrical (*n_r* × *n_θ* × *n_z*).

- Radial faces are spaced geometrically from *r_w* to *R*, so the cells are finest at the wall, where the flow converges and the fronts start. Every cell has the same width in ln *r*.
- Cell centres sit at the geometric mean of their faces.
- *n_θ* is even, which the red-black solver needs.

| Preset | *n_r* × *n_θ* × *n_z* | Cells |
|---|---|---|
| Preview | 40 × 48 × 24 | 46 k |
| Standard | 64 × 96 × 48 | 295 k |
| Fine | 96 × 144 × 72 | 995 k |
| Research | 128 × 192 × 96 | 2.36 M |

**Finite volumes.** Two-point flux approximation with exact geometric half-cell resistances:

- radial: ln(*r_face*/*r_c*) / (Δθ Δ*z* λ)
- angular: (Δθ/2) / (Δ*z* ln(*r₊*/*r₋*) λ)
- axial: (Δ*z*/2) / (*A* λ *k_v/k_h*), where *A* is the cell's horizontal cross-section

Face transmissibilities are harmonic combinations of the two half-cells. Because the radial resistances are exact logarithms, steady radial flow is reproduced exactly on any grid (verification case V1). Layered flow without cross-flow is also exact (V2).

**Pressure–transport coupling (IMPES).** The pressure is solved implicitly. The face flow rates are then frozen, and the transport equations are advanced explicitly for several steps.

The interval between pressure solves is limited in two ways:

- **Cake coupling.** Within one pressure solve the filtration rate of any column (the inverse of its series resistance: cake, rock and outer ring) may change by at most a fraction ε (default 0.01). The resulting coupling error is about 0.25 ε (verification case V5). Measuring the change against the whole column, not the wall face alone, lets the first seconds, when a cake a few nanometres thick already dominates the wall face but not the rock, pass in a few hundred pressure solves instead of thousands.
- **Step count.** At most 8 transport steps are taken per solve.

**Transport.** The default scheme is second-order MUSCL reconstruction with the van Leer limiter, with two-stage strong-stability-preserving Runge–Kutta time stepping (SSP-RK2) at Courant number 0.4. First-order upwind with forward Euler at Courant number 0.8 is also available.

The step limit counts both the outflow from each cell and the capture rate, λ₀ |**u**| / φ. The scheme is conservative, so the filtrate mass balance closes to round-off: about 10⁻¹⁴ on the CPU and 10⁻⁶ to 10⁻⁵ on the GPU in single precision. The run reports this error live.

**Pressure solvers.**

- **CPU reference (double precision):** conjugate gradients, preconditioned with exact tridiagonal solves along each radial line, run to a relative residual of 10⁻¹⁰.
- **GPU (Metal, single precision):** red-black line SOR (ω = 1.85), with one thread per radial line solving its line exactly by the Thomas algorithm. Every 8 sweeps the solver checks two things: the largest local correction must be below 2·10⁻⁶, and wall inflow must balance outer outflow to within the chosen tolerance (default 2·10⁻⁵).
- **Fast math:** off, so the Kahan-summed outflow accumulators and the thin-cake series stay accurate.

Because the two solvers use different algorithms, their agreement is an independent check (verification G1, `testGPUMatchesCPUReference`).

## 4. Verification

Open the Verify sheet in the 3D Invasion pane to run the suite. The unit tests (`Invasion3DTests`) run it on every CI build. Observed orders are computed from the two finest grids as *p* = ln(*e₁*/*e₂*)/ln 2.

| Case | Reference solution | Metric | Expected |
|---|---|---|---|
| V1 Steady radial flow | *p̂* = 1 − ln(*r/r_w*)/ln(*R/r_w*) | max pressure error | round-off |
| V2 Layered, anisotropic | *q* = Σ 2π Δ*z k_l* / ln(*R/r_w*) | inflow error | round-off |
| V3 Deep-bed filtration | Iwasaki/Herzig radial σ(*r*, *t*) at constant rate and λ | L1 error of σ | order > 1 (TVD), about 1 (upwind) |
| V4 Filtrate front | *r_f*² = *r_w*² + 2 *r_w u_w t* / (φΔS) | L1 error of *s* | about ⅔ (TVD), about ½ (upwind), the limits for a discontinuity |
| V5 Cake-controlled filtration | RK4 solution of the series cake + rock model | cumulative filtrate | first order in ε |
| V6 Mass balance | injected = stored + outflow | relative error | round-off |
| V7 Symmetry | uniform rock gives a circular front | front spread / mean | round-off |
| G1 GPU vs CPU | double-precision CPU reference | filtrate, pressure | < 1 %, < 10⁻³ |

The Python prototype that preceded the Swift code gave σ errors falling at an observed order of about 1.3 (TVD) and 1.0 (upwind) on grids of 16 to 128 radial cells, and cake-coupling errors of about 0.2 ε.

## 5. Calibration with laboratory data

The parameters λ₀, β, σ_max, *F*, *k_c*, *h_b* and the cake porosity are specific to each rock and mud. Literature defaults are illustrative only. Fit them with the Calibrate sheet as follows.

1. **Filter press (API RP 13B-1 or HPHT).** Fit *V/A* = *V_spurt* + *m*√*t* by least squares. The sheet reports 95 % confidence intervals and R².
   - Static cake filtration gives *m*² = 2 *k_c* Δ*p* / (μ α), which yields *k_c*.
   - If the final cake thickness was measured, α is taken from it. Otherwise α comes from the mud solids fraction and the cake porosity.
   - The bridging thickness is *h_b* = α *V_spurt*: the cake the spurt volume builds.
2. **Return permeability, solids-free filtrate.** This test gives *F* = *k_return*/*k₀* directly.
3. **Return permeability, whole mud.** For a linear core at constant λ, σ(*x*) = λ *c₀ U* e^{−λ*x*}. Harmonic averaging over the core then gives:

   *k_ret*/*k₀* = *F L* / (*L* + β *c₀ U* (1 − e^{−λ*L*}))

   This is solved for β.
4. **Particle-size distributions and effluent concentrations** from the coreflood can constrain λ₀ and *c₀* separately. That step is not automated yet.

**Validation** means comparing predictions with measurements that were not used in the fit. Examples are invasion depth from CT scans or resistivity profiles, return permeability at another overbalance, and filtrate volumes from dynamic filtration. Validation needs such data from the laboratory (for example the UPPA coreflood programme). The front-map export (angle, height, front depth, cake) is laid out for comparison with CT slices.

## 6. Exports

| Export | Content |
|---|---|
| VTK (legacy binary structured grid) | Cell corners in metres. Cell data: filtrate saturation, k/k₀, permeability (md), initial permeability, retained and suspended fines, overpressure (psi), cake thickness. Opens in ParaView and VisIt. |
| Radial profile CSV | Mean, minimum and maximum of each field over θ and z, against radius. |
| Front map CSV | Front depth and cake thickness for every wall column (θ, z). |
| History CSV | Every summary number over time, including mass balance and solver diagnostics. |
| Run record JSON | Inputs, options (including the seed), grid, solver, device, final stats, skin and history. |

## 7. Assumptions and limits

These assumptions are worth stating in any publication that uses the model.

- **Single-phase, incompressible flow.** The filtrate displaces the displaceable oil as a piston with mobility ratio 1. Viscous fingering from unequal viscosities and capillary effects are not modelled. Instead, *F* scales the permeability of flushed rock.
- **No internal filter cake.** Fines capture is the classical deep-bed model with constant σ_max and linear damage 1/(1 + βσ). Other options would be straining by size exclusion, or a damage law of the form k/k₀ = (1 − σ/φ)^n.
- **Vertical borehole, no stress.** Bedding is horizontal and the borehole axis is vertical. Deviated wells, and rock stress and mechanics (breakouts, induced fractures), are not modelled.
- **Simplified cake.** Cake permeability is constant (an incompressible cake). Dynamic erosion is represented only by *h_eq*.
- **Single precision on the GPU.** The GPU works in single precision. The CPU reference shows the effect of this is below 10⁻³ in pressure and below 1 % in integrated results on the test cases.
