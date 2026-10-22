# Models and equations

All engine code lives in `Sources/FlowCore`. Nodal analysis uses oilfield units (psia, °F, ft, STB/d, cp, md). The formation damage solver works in SI internally and reports oilfield-friendly units.

## Fluid properties (`PVT.swift`)

| Property | Correlation |
|---|---|
| Bubble point, solution GOR Rs, oil FVF Bo (saturated) | Standing (1947) |
| Bo above bubble point | Bo = Bob · exp(co (pb − p)) |
| Dead and live oil viscosity | Beggs and Robinson (1975) |
| Undersaturated oil viscosity | Vasquez and Beggs (1980) |
| Gas pseudo-critical properties | Sutton (1985) |
| Gas Z-factor | Papay (1968) |
| Gas viscosity | Lee, Gonzalez and Eakin (1966) |
| Water viscosity | Temperature fit |

## Inflow performance (`IPR.swift`)

Pseudo-steady-state Darcy productivity index with skin:

J = k h / (141.2 Bo μo [ln(re/rw) − 0.75 + S])

Above the bubble point q = J (pr − pwf). Below it the composite Vogel curve applies:

q = J (pr − pb) + (J pb / 1.8) [1 − 0.2 (pwf/pb) − 0.8 (pwf/pb)²]

## Tubing outflow (`BeggsBrill.swift`, `Wellbore.swift`)

Beggs and Brill (1973) with the Payne et al. (1979) holdup corrections:

1. Flow pattern (segregated, transition, intermittent, distributed) from the no-slip liquid fraction λL and the Froude number.
2. Horizontal holdup HL(0) = a λL^b / NFr^c, corrected for inclination with the C and ψ terms.
3. Two-phase friction factor ftp = fn · e^S, with fn from the Chen (1979) explicit Moody equation.
4. Gradient dp/dL = ρs sinθ + ftp ρn vm² / (2 g d). Acceleration is neglected.

The traverse marches from the wellhead to mid-perforations in 100 ft steps with a predictor-corrector (Heun) scheme. Temperature varies linearly from the wellhead to the reservoir.

The operating point is the rightmost rate where VLP − IPR changes from negative to positive, which is the stable intersection. It is refined by bisection.

## Near-wellbore formation damage from drilling mud (`FormationDamage.swift`)

The model covers the formation around an overbalanced well during mud exposure, in radial geometry from the borehole wall rw outward.

**Filtration flux.** Darcy flow in series through the external cake (thickness h, permeability kc) and the radial invaded zone gives the flux at the wall:

u_w = Δp / ( μ rw [ ln(rw/(rw − h))/kc + Σ ln(r_{i+1}/r_i)/k_i ] )

**External cake.** The cake grows from the mud solids carried by the filtrate:

dh/dt = α u_w (1 − h/h_eq),  α = fs / ((1 − φc)(1 − fs))

Here h_eq is the equilibrium thickness set by erosion under circulation (dynamic filtration). Setting h_eq = 0 gives static filtration, where the cake grows without limit and cumulative loss follows roughly √t.

**Spurt and fines invasion.** Before the cake bridges, fine particles at volume concentration c0 enter the rock. The inlet concentration falls linearly to zero as h approaches the bridging thickness. Fines transport and capture follow the classical deep-bed filtration model (Iwasaki 1937; Herzig, Leclerc and Le Goff 1970):

φ ∂c/∂t + u ∂c/∂r = −λ(σ) u c
∂σ/∂t = λ(σ) u c,  λ(σ) = λ0 (1 − σ/σmax),  u = u_w rw / r

This is solved with explicit first-order upwinding on a geometric radial grid that is finest at the wall, with a CFL-limited time step.

**Filtrate front.** From volume balance, π (rf² − rw²) φ (1 − Swi − Sor) = 2π rw V, where V is the cumulative filtrate per unit wall area. Inside rf the permeability is multiplied by F, which lumps clay swelling, water blocking and relative-permeability effects.

**Permeability and skin.** k(r) = k0 · F(r) / (1 + β σ(r)). The skin after cake lift-off comes from the generalised Hawkins integral:

S = ∫ (k0/k(r) − 1) dr/r

The productivity ratio is PR = (ln(re/rw) − 0.75) / (ln(re/rw) − 0.75 + S).

**Calibration.** λ0, β, σmax and F are rock-and-mud specific. They should be fitted to laboratory coreflood tests (dynamic filtration cell plus return-permeability measurement) for the formation being studied.

## Live 2D invasion on the GPU (`LiveInvasion.swift`, `FlowGPU`)

The Live Flow screen solves the same physics as the 1D damage model, on a horizontal slice of rock around the borehole, so that permeability heterogeneity and uneven invasion can be seen as they develop.

- **Grid.** A square grid (128² to 512²) covering the rock out to about 1.8 times the 1D invasion depth. Cells inside the bit radius hold mud; cells outside the disc are at pore pressure.
- **Rock.** Log-normal permeability k₀(x) = k̄ exp(σ g(x) − σ²/2), where g is a Gaussian random field made from 48 random Fourier modes with a set correlation length. σ is the Heterogeneity slider; σ = 0 gives a uniform rock.
- **Pressure.** ∇·(k∇p) = 0 by red-black successive over-relaxation (ω = 1.85), warm-started every frame. Face conductances use the harmonic mean of the two cells. Each borehole face adds the cake resistance h/k_c. Each outer face adds the resistance of the ring out to the 1D model radius, so total rates match the 1D model. Borehole and outer faces are scaled by π/4 to correct for the staircase outline of a circle drawn in square cells.
- **Transport.** Explicit first-order upwind, with substeps limited to 0.2 of the CFL limit:
  - filtrate saturation: φΔS ∂s/∂t + ∇·(u s) = 0
  - fines: φ ∂c/∂t + ∇·(u c) = −λ|u|c and ∂σ/∂t = λ|u|c
  - cake growth on each wall cell: dh/dt = α uₙ (1 − h/h_eq)
  - permeability: k = k₀ (1 − (1 − F)s)/(1 + βσ)
- **GPU.** Every step is a Metal compute kernel: mobility, pressure (one pass per colour), velocity, transport (ping-pong buffers) and tracer particles. The buffers use shared storage, so on Apple Silicon the CPU reads the statistics straight from unified memory. `LiveInvasionSolver` is a CPU copy of the same steps. Tests check it against the 1D model for a uniform rock, and check that the GPU reproduces it.
- **Tracers.** These are particles carried by the Darcy velocity. Their screen speed is scaled to the fastest cell, so they show direction and relative speed rather than true displacement.

The live model is for insight. The 1D model remains the quantitative reference, and the live view draws its filtrate front as a dashed ring for comparison.

### References

- Bedrikovetsky, P. et al. (2001). Characterisation of deep bed filtration system from laboratory pressure drop measurements. *J. Pet. Sci. Eng.* 32, 167–177.
- Civan, F. (2015). *Reservoir Formation Damage*, 3rd ed. Gulf Professional Publishing.
- Herzig, J.P., Leclerc, D.M., Le Goff, P. (1970). Flow of suspensions through porous media. *Ind. Eng. Chem.* 62(5), 8–35.
- Outmans, H.D. (1963). Mechanics of static and dynamic filtration in the borehole. *SPE J.* 3(3), 236–244.
- Beggs, H.D., Brill, J.P. (1973). A study of two-phase flow in inclined pipes. *JPT* 25(5), 607–617.
- Vogel, J.V. (1968). Inflow performance relationships for solution-gas drive wells. *JPT* 20(1), 83–92.
