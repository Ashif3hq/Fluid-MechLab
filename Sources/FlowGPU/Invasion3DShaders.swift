/// Metal compute kernels for the 3D invasion model. They mirror `Invasion3DSolver` step for step, except that the
/// pressure equation is solved by red-black line SOR (one thread per radial line) instead of conjugate gradients.
/// The source is compiled at run time, with fast math off, so the package builds with plain `swift build`.
enum Invasion3DShaders {
    /// Indices into the parameter buffer.
    enum P: Int, CaseIterable {
        case nr, nt, nz, dTheta, dz, halfRadial, halfAngular, anisotropy, outerResistance, velocityScale
        case porosity, displaceablePorosity, cakeGrowth, equilibriumCake, bridgingCake, cakeMobility, finesInlet
        case filtrationCoefficient, damageCoefficient, maxRetention, filtrateDamageFactor, wellboreRadius
        case dt, weight, secondOrder, outflowWeight, omega, colour, noCake, field
    }

    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    #define P_NR 0
    #define P_NT 1
    #define P_NZ 2
    #define P_DTH 3
    #define P_DZ 4
    #define P_HR 5
    #define P_HT 6
    #define P_ANIS 7
    #define P_OUTER 8
    #define P_VSCALE 9
    #define P_PHI 10
    #define P_PHID 11
    #define P_ALPHA 12
    #define P_HEQ 13
    #define P_HBRIDGE 14
    #define P_KC 15
    #define P_FINES 16
    #define P_LAMBDA0 17
    #define P_BETA 18
    #define P_SIGMAMAX 19
    #define P_FD 20
    #define P_RW 21
    #define P_DT 22
    #define P_WEIGHT 23
    #define P_SECOND 24
    #define P_OUTW 25
    #define P_OMEGA 26
    #define P_COLOUR 27
    #define P_NOCAKE 28
    #define P_FIELD 29

    // state = (filtrate saturation s, suspended fines c, retained fines sigma, cake thickness h on the wall cell of each column)
    // flux  = (inner radial face, theta- face, z- face, outer radial face), m3/s, positive towards +r, +theta, +z

    struct Grid {
        uint nr, nt, nz;
        device const float *geo;
        float face(uint i) const { return geo[i]; }
        float area(uint i) const { return geo[nr + 1 + i]; }
        float volume(uint i) const { return geo[2 * nr + 1 + i]; }
        float halfAxial(uint i) const { return geo[3 * nr + 1 + i]; }
        uint index(uint i, uint j, uint k) const { return (k * nt + j) * nr + i; }
    };

    static Grid makeGrid(constant float *P, device const float *geo) {
        Grid g;
        g.nr = uint(P[P_NR]); g.nt = uint(P[P_NT]); g.nz = uint(P[P_NZ]); g.geo = geo;
        return g;
    }

    // ln(rw / (rw - h)) / (kc dTheta dz), with a series for thin cakes so single precision keeps its accuracy.
    static float cakeResistance(float h, constant float *P) {
        if (h <= 0.0f) { return 0.0f; }
        float rw = P[P_RW];
        float x = min(h / rw, 0.95f);
        float lg = x < 0.01f ? x * (1.0f + x * (0.5f + x * (1.0f / 3.0f + 0.25f * x))) : -log(1.0f - x);
        return lg / (P[P_KC] * P[P_DTH] * P[P_DZ]);
    }

    static float radialT(float a, float b, constant float *P) { return 1.0f / (P[P_HR] / a + P[P_HR] / b); }
    static float angularT(float a, float b, constant float *P) { return 1.0f / (P[P_HT] / a + P[P_HT] / b); }
    static float axialT(float hz, float a, float b, constant float *P) {
        float h = hz / P[P_ANIS];
        return 1.0f / (h / a + h / b);
    }
    static float wallT(float a, float cake, constant float *P) { return 1.0f / (P[P_HR] / a + cakeResistance(cake, P)); }
    static float outerT(float a, constant float *P) { return 1.0f / (P[P_HR] / a + P[P_OUTER]); }

    static uint3 cellOf(uint a, Grid g) {
        uint i = a % g.nr;
        uint col = a / g.nr;
        return uint3(i, col % g.nt, col / g.nt);
    }

    kernel void mobility3D(device float *lam [[buffer(0)]],
                           device const float *k0 [[buffer(1)]],
                           device const float4 *state [[buffer(2)]],
                           constant float *P [[buffer(3)]],
                           uint a [[thread_position_in_grid]]) {
        uint n = uint(P[P_NR]) * uint(P[P_NT]) * uint(P[P_NZ]);
        if (a >= n) { return; }
        float4 st = state[a];
        lam[a] = k0[a] * (1.0f - (1.0f - P[P_FD]) * st.x) / (1.0f + P[P_BETA] * st.z);
    }

    // One colour of red-black line SOR: each thread solves its radial line exactly (Thomas algorithm), then over-relaxes.
    kernel void line3D(device float *p [[buffer(0)]],
                       device const float *lam [[buffer(1)]],
                       device const float4 *state [[buffer(2)]],
                       device float *cPrime [[buffer(3)]],
                       device float *dPrime [[buffer(4)]],
                       device const float *geo [[buffer(5)]],
                       constant float *P [[buffer(6)]],
                       uint2 gid [[thread_position_in_grid]]) {
        Grid g = makeGrid(P, geo);
        if (gid.x >= g.nt || gid.y >= g.nz) { return; }
        if (((gid.x + gid.y) & 1u) != uint(P[P_COLOUR])) { return; }
        uint j = gid.x, k = gid.y;
        uint jm = (j + g.nt - 1) % g.nt, jp = (j + 1) % g.nt;
        uint base = g.index(0, j, k);
        float cake = P[P_NOCAKE] > 0.5f ? 0.0f : state[base].w;
        float prevC = 0.0f, prevD = 0.0f;
        for (uint i = 0; i < g.nr; i++) {
            uint a = base + i;
            float la = lam[a];
            float tIn = i == 0 ? wallT(la, cake, P) : radialT(lam[a - 1], la, P);
            float tOut = i == g.nr - 1 ? outerT(la, P) : radialT(la, lam[a + 1], P);
            uint am = g.index(i, jm, k), ap = g.index(i, jp, k);
            float tm = angularT(la, lam[am], P), tp = angularT(la, lam[ap], P);
            float hz = g.halfAxial(i);
            float tzm = 0.0f, tzp = 0.0f, rhs = tm * p[am] + tp * p[ap];
            if (k > 0) { uint b = g.index(i, j, k - 1); tzm = axialT(hz, la, lam[b], P); rhs += tzm * p[b]; }
            if (k < g.nz - 1) { uint b = g.index(i, j, k + 1); tzp = axialT(hz, la, lam[b], P); rhs += tzp * p[b]; }
            float lower = 0.0f;
            if (i == 0) { rhs += tIn; } else { lower = tIn; }
            float d = tIn + tOut + tm + tp + tzm + tzp;
            float den = d - lower * prevC;
            float c = i < g.nr - 1 ? tOut / den : 0.0f;
            float dd = (rhs + lower * prevD) / den;
            cPrime[a] = c;
            dPrime[a] = dd;
            prevC = c;
            prevD = dd;
        }
        float omega = P[P_OMEGA];
        float x = 0.0f;
        for (int i = int(g.nr) - 1; i >= 0; i--) {
            uint a = base + uint(i);
            x = dPrime[a] + cPrime[a] * x;
            p[a] += omega * (x - p[a]);
        }
    }

    // Largest local correction |p_jacobi - p| over the grid, into maxima[2] (as float bits).
    kernel void residual3D(device const float *p [[buffer(0)]],
                           device const float *lam [[buffer(1)]],
                           device const float4 *state [[buffer(2)]],
                           device atomic_uint *maxima [[buffer(3)]],
                           device const float *geo [[buffer(4)]],
                           constant float *P [[buffer(5)]],
                           uint a [[thread_position_in_grid]]) {
        Grid g = makeGrid(P, geo);
        if (a >= g.nr * g.nt * g.nz) { return; }
        uint3 c = cellOf(a, g);
        uint i = c.x, j = c.y, k = c.z;
        float la = lam[a];
        float cake = P[P_NOCAKE] > 0.5f ? 0.0f : state[g.index(0, j, k)].w;
        float sum = 0.0f, weight = 0.0f, t;
        if (i == 0) { t = wallT(la, cake, P); sum += t; weight += t; }
        else { t = radialT(lam[a - 1], la, P); sum += t * p[a - 1]; weight += t; }
        if (i == g.nr - 1) { t = outerT(la, P); weight += t; }
        else { t = radialT(la, lam[a + 1], P); sum += t * p[a + 1]; weight += t; }
        uint am = g.index(i, (j + g.nt - 1) % g.nt, k), ap = g.index(i, (j + 1) % g.nt, k);
        t = angularT(la, lam[am], P); sum += t * p[am]; weight += t;
        t = angularT(la, lam[ap], P); sum += t * p[ap]; weight += t;
        float hz = g.halfAxial(i);
        if (k > 0) { uint b = g.index(i, j, k - 1); t = axialT(hz, la, lam[b], P); sum += t * p[b]; weight += t; }
        if (k < g.nz - 1) { uint b = g.index(i, j, k + 1); t = axialT(hz, la, lam[b], P); sum += t * p[b]; weight += t; }
        float correction = fabs(sum / weight - p[a]);
        atomic_fetch_max_explicit(&maxima[2], as_type<uint>(correction), memory_order_relaxed);
    }

    // Face flow rates and cell speeds; the largest transport rate goes to maxima[0] and the largest relative
    // rate of change of a wall conductance to maxima[1].
    kernel void flux3D(device float4 *flux [[buffer(0)]],
                       device float *speed [[buffer(1)]],
                       device const float *p [[buffer(2)]],
                       device const float *lam [[buffer(3)]],
                       device const float4 *state [[buffer(4)]],
                       device atomic_uint *maxima [[buffer(5)]],
                       device const float *geo [[buffer(6)]],
                       constant float *P [[buffer(7)]],
                       uint a [[thread_position_in_grid]]) {
        Grid g = makeGrid(P, geo);
        if (a >= g.nr * g.nt * g.nz) { return; }
        uint3 c = cellOf(a, g);
        uint i = c.x, j = c.y, k = c.z;
        float vs = P[P_VSCALE];
        float la = lam[a];
        float cake = state[g.index(0, j, k)].w;
        float tw = 0.0f;

        float inner;
        if (i == 0) { tw = wallT(la, cake, P); inner = tw * (1.0f - p[a]); }
        else { inner = radialT(lam[a - 1], la, P) * (p[a - 1] - p[a]); }
        float outer = i == g.nr - 1 ? outerT(la, P) * p[a] : radialT(la, lam[a + 1], P) * (p[a] - p[a + 1]);
        uint am = g.index(i, (j + g.nt - 1) % g.nt, k), ap = g.index(i, (j + 1) % g.nt, k);
        float angular = angularT(la, lam[am], P) * (p[am] - p[a]);
        float angularPlus = angularT(la, lam[ap], P) * (p[a] - p[ap]);
        float hz = g.halfAxial(i);
        float axial = 0.0f, axialPlus = 0.0f;
        if (k > 0) { uint b = g.index(i, j, k - 1); axial = axialT(hz, la, lam[b], P) * (p[b] - p[a]); }
        if (k < g.nz - 1) { uint b = g.index(i, j, k + 1); axialPlus = axialT(hz, la, lam[b], P) * (p[a] - p[b]); }
        float4 f = float4(inner, angular, axial, outer) * vs;
        angularPlus *= vs;
        axialPlus *= vs;
        flux[a] = f;

        float dth = P[P_DTH], dz = P[P_DZ];
        float ur = 0.5f * (f.x / (g.face(i) * dth * dz) + f.w / (g.face(i + 1) * dth * dz));
        float ut = 0.5f * (f.y + angularPlus) / ((g.face(i + 1) - g.face(i)) * dz);
        float uz = 0.5f * (f.z + axialPlus) / g.area(i);
        float u = sqrt(ur * ur + ut * ut + uz * uz);
        speed[a] = u;
        float out = max(-f.x, 0.0f) + max(f.w, 0.0f) + max(-f.y, 0.0f) + max(angularPlus, 0.0f) + max(-f.z, 0.0f) + max(axialPlus, 0.0f);
        float rate = out / (P[P_PHID] * g.volume(i)) + P[P_LAMBDA0] * u / P[P_PHI];
        atomic_fetch_max_explicit(&maxima[0], as_type<uint>(rate), memory_order_relaxed);

        if (i == 0) {
            float rw = P[P_RW];
            float growth = P[P_ALPHA] * max(f.x, 0.0f) / (rw * dth * dz);
            if (P[P_HEQ] > 0.0f) { growth *= max(0.0f, 1.0f - cake / P[P_HEQ]); }
            float innerRadius = max(rw - cake, 0.05f * rw);
            float cakeRate = growth / (innerRadius * P[P_KC] * dth * dz) * tw;
            atomic_fetch_max_explicit(&maxima[1], as_type<uint>(cakeRate), memory_order_relaxed);
        }
    }

    // Face value from the upwind cell u, the cell behind it uu and the downwind cell d (van Leer limiter when second order).
    static float2 faceValue(float2 u, float2 uu, float2 d, bool second) {
        if (!second) { return u; }
        float2 du = u - uu, dd = d - u;
        float2 prod = du * dd;
        float2 limited = u + prod / (du + dd);
        return select(u, limited, prod > 0.0f);
    }

    static float2 radialValue(device const float4 *q, uint base, int ii, uint nr, float2 wall) {
        if (ii < 0) { return wall; }
        if (ii >= int(nr)) { return float2(0.0f); }
        return q[base + uint(ii)].xy;
    }

    // One transport stage: out = w * baseState + (1 - w) * (in + dt * L(in)).
    kernel void transport3D(device float4 *outState [[buffer(0)]],
                            device const float4 *q [[buffer(1)]],
                            device const float4 *baseState [[buffer(2)]],
                            device const float4 *flux [[buffer(3)]],
                            device const float *speed [[buffer(4)]],
                            device float2 *outflow [[buffer(5)]],
                            device const float *geo [[buffer(6)]],
                            constant float *P [[buffer(7)]],
                            uint a [[thread_position_in_grid]]) {
        Grid g = makeGrid(P, geo);
        if (a >= g.nr * g.nt * g.nz) { return; }
        uint3 c = cellOf(a, g);
        uint i = c.x, j = c.y, k = c.z;
        bool second = P[P_SECOND] > 0.5f;
        float dt = P[P_DT];
        uint base = g.index(0, j, k);
        float h = q[base].w;
        float2 wall = float2(1.0f, P[P_FINES] * max(0.0f, 1.0f - h / P[P_HBRIDGE]));
        float4 st = q[a];
        float2 here = st.xy;

        float4 f = flux[a];
        uint jm = (j + g.nt - 1) % g.nt, jp = (j + 1) % g.nt;
        uint jmm = (j + g.nt - 2) % g.nt, jpp = (j + 2) % g.nt;
        float angularPlus = flux[g.index(i, jp, k)].y;
        float axialPlus = k < g.nz - 1 ? flux[g.index(i, j, k + 1)].z : 0.0f;

        int ii = int(i);
        float2 total = float2(0.0f);
        // Radial faces.
        if (f.x > 0.0f) { total += f.x * faceValue(radialValue(q, base, ii - 1, g.nr, wall), radialValue(q, base, ii - 2, g.nr, wall), here, second); }
        else { total += f.x * faceValue(here, radialValue(q, base, ii + 1, g.nr, wall), radialValue(q, base, ii - 1, g.nr, wall), second); }
        float2 out;
        if (f.w > 0.0f) { out = f.w * faceValue(here, radialValue(q, base, ii - 1, g.nr, wall), radialValue(q, base, ii + 1, g.nr, wall), second); }
        else { out = f.w * faceValue(radialValue(q, base, ii + 1, g.nr, wall), radialValue(q, base, ii + 2, g.nr, wall), here, second); }
        total -= out;
        // Angular faces (periodic).
        float2 qm = q[g.index(i, jm, k)].xy, qmm = q[g.index(i, jmm, k)].xy;
        float2 qp = q[g.index(i, jp, k)].xy, qpp = q[g.index(i, jpp, k)].xy;
        total += f.y > 0.0f ? f.y * faceValue(qm, qmm, here, second) : f.y * faceValue(here, qp, qm, second);
        total -= angularPlus > 0.0f ? angularPlus * faceValue(here, qm, qp, second) : angularPlus * faceValue(qp, qpp, here, second);
        // Axial faces (sealed top and bottom).
        uint km = k > 0 ? k - 1 : 0, kmm = k > 1 ? k - 2 : 0;
        uint kp = min(k + 1, g.nz - 1), kpp = min(k + 2, g.nz - 1);
        float2 zm = q[g.index(i, j, km)].xy, zmm = q[g.index(i, j, kmm)].xy;
        float2 zp = q[g.index(i, j, kp)].xy, zpp = q[g.index(i, j, kpp)].xy;
        total += f.z > 0.0f ? f.z * faceValue(zm, zmm, here, second) : f.z * faceValue(here, zp, zm, second);
        total -= axialPlus > 0.0f ? axialPlus * faceValue(here, zm, zp, second) : axialPlus * faceValue(zp, zpp, here, second);

        float v = g.volume(i);
        float lambda = P[P_LAMBDA0] * max(0.0f, 1.0f - st.z / P[P_SIGMAMAX]);
        float capture = lambda * speed[a] * st.y;
        float4 next;
        next.x = st.x + dt * total.x / (P[P_PHID] * v);
        next.y = st.y + dt * (total.y / v - capture) / P[P_PHI];
        next.z = st.z + dt * capture;
        next.w = 0.0f;
        if (i == 0) {
            float growth = P[P_ALPHA] * max(f.x, 0.0f) / (P[P_RW] * P[P_DTH] * P[P_DZ]);
            if (P[P_HEQ] > 0.0f) { growth *= max(0.0f, 1.0f - h / P[P_HEQ]); }
            next.w = h + dt * growth;
        }
        float w = P[P_WEIGHT];
        next = w * baseState[a] + (1.0f - w) * next;
        next.x = clamp(next.x, 0.0f, 1.0f);
        next.y = max(next.y, 0.0f);
        next.z = min(next.z, P[P_SIGMAMAX]);
        outState[a] = next;

        if (i == g.nr - 1 && out.x > 0.0f) {
            // Kahan sum per column of the filtrate leaving through the outer boundary.
            uint col = k * g.nt + j;
            float2 acc = outflow[col];
            float y = P[P_OUTW] * dt * out.x - acc.y;
            float t = acc.x + y;
            acc.y = (t - acc.x) - y;
            acc.x = t;
            outflow[col] = acc;
        }
    }

    // Writes the display texture: (field value 0-1, filtrate saturation, k/k0, retained fines / sigma max),
    // and the cake texture (thickness in mm) for the wall.
    kernel void display3D(texture3d<half, access::write> volume [[texture(0)]],
                          texture2d<half, access::write> cakeTexture [[texture(1)]],
                          device const float4 *state [[buffer(0)]],
                          device const float *p [[buffer(1)]],
                          device const float *k0 [[buffer(2)]],
                          constant float *P [[buffer(3)]],
                          uint3 gid [[thread_position_in_grid]]) {
        uint nr = uint(P[P_NR]), nt = uint(P[P_NT]), nz = uint(P[P_NZ]);
        if (gid.x >= nr || gid.y >= nt || gid.z >= nz) { return; }
        uint a = (gid.z * nt + gid.y) * nr + gid.x;
        float4 st = state[a];
        float ratio = (1.0f - (1.0f - P[P_FD]) * st.x) / (1.0f + P[P_BETA] * st.z);
        float sigma = st.z / P[P_SIGMAMAX];
        float value;
        switch (int(P[P_FIELD])) {
            case 0: value = st.x; break;
            case 1: value = 1.0f - ratio; break;
            case 2: value = clamp(0.5f + 0.25f * log10(max(k0[a] * ratio, 1e-6f)), 0.0f, 1.0f); break;
            case 3: value = sigma; break;
            case 4: value = P[P_FINES] > 0.0f ? clamp(st.y / P[P_FINES], 0.0f, 1.0f) : 0.0f; break;
            default: value = p[a]; break;
        }
        volume.write(half4(half(value), half(st.x), half(ratio), half(sigma)), gid);
        if (gid.x == 0) { cakeTexture.write(half4(half(st.w * 1000.0f), 0.0h, 0.0h, 1.0h), uint2(gid.y, gid.z)); }
    }
    """
}
