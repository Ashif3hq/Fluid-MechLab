/// Metal compute kernels for the live invasion model. They mirror `LiveInvasionSolver` step for step.
/// The source is compiled at run time so the package builds with plain `swift build`.
enum LiveInvasionShaders {
    /// Indices into the parameter buffer.
    enum P: Int, CaseIterable {
        case size, dx, velocityScale, porosity, displaceablePorosity, cakeGrowth, equilibriumCake, bridgingCake
        case cakeMobility, finesInlet, filtrationCoefficient, damageCoefficient, maxRetention, filtrateDamageFactor
        case outerResistance, wallFactor, dt, omega, colour, wellboreRadius, domainRadius, particleStep, frame, maxSpeed
    }

    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    #define P_SIZE 0
    #define P_DX 1
    #define P_VSCALE 2
    #define P_PHI 3
    #define P_PHID 4
    #define P_ALPHA 5
    #define P_HEQ 6
    #define P_HBRIDGE 7
    #define P_KC 8
    #define P_FINES 9
    #define P_LAMBDA0 10
    #define P_BETA 11
    #define P_SIGMAMAX 12
    #define P_FD 13
    #define P_OUTER 14
    #define P_WALL 15
    #define P_DT 16
    #define P_OMEGA 17
    #define P_COLOUR 18
    #define P_RW 19
    #define P_R 20
    #define P_PSTEP 21
    #define P_FRAME 22
    #define P_MAXSPEED 23

    #define ROCK 0
    #define MUD 1
    #define OUTER 2

    // state = (filtrate saturation s, suspended fines c, retained fines sigma, cake thickness h)

    static float conductance(uint a, uint b, constant float *P, device const float *lam,
                             device const uchar *cell, device const float4 *state) {
        float dx = P[P_DX];
        float halfA = dx / (2.0f * lam[a]);
        uchar kind = cell[b];
        if (kind == ROCK) { return 1.0f / (halfA + dx / (2.0f * lam[b])); }
        if (kind == MUD) { return P[P_WALL] / (halfA + state[a].w / P[P_KC]); }
        return P[P_WALL] / (halfA + P[P_OUTER]);
    }

    kernel void mobilityKernel(device float *lam [[buffer(0)]],
                               device const float *k0 [[buffer(1)]],
                               device const uchar *cell [[buffer(2)]],
                               device const float4 *state [[buffer(3)]],
                               constant float *P [[buffer(4)]],
                               uint2 gid [[thread_position_in_grid]]) {
        uint n = uint(P[P_SIZE]);
        if (gid.x >= n || gid.y >= n) { return; }
        uint a = gid.y * n + gid.x;
        if (cell[a] != ROCK) { lam[a] = 1.0f; return; }
        float4 st = state[a];
        lam[a] = k0[a] * (1.0f - (1.0f - P[P_FD]) * st.x) / (1.0f + P[P_BETA] * st.z);
    }

    kernel void pressureKernel(device float *p [[buffer(0)]],
                               device const float *lam [[buffer(1)]],
                               device const uchar *cell [[buffer(2)]],
                               device const float4 *state [[buffer(3)]],
                               constant float *P [[buffer(4)]],
                               uint2 gid [[thread_position_in_grid]]) {
        uint n = uint(P[P_SIZE]);
        if (gid.x < 1 || gid.y < 1 || gid.x >= n - 1 || gid.y >= n - 1) { return; }
        if (((gid.x + gid.y) & 1u) != uint(P[P_COLOUR])) { return; }
        uint a = gid.y * n + gid.x;
        if (cell[a] != ROCK) { return; }
        uint nb[4] = { a - 1, a + 1, a - n, a + n };
        float sum = 0.0f, weight = 0.0f;
        for (int k = 0; k < 4; k++) {
            float t = conductance(a, nb[k], P, lam, cell, state);
            sum += t * p[nb[k]];
            weight += t;
        }
        p[a] += P[P_OMEGA] * (sum / weight - p[a]);
    }

    kernel void velocityKernel(device float4 *vel [[buffer(0)]],
                               device const float *p [[buffer(1)]],
                               device const float *lam [[buffer(2)]],
                               device const uchar *cell [[buffer(3)]],
                               device const float4 *state [[buffer(4)]],
                               constant float *P [[buffer(5)]],
                               uint2 gid [[thread_position_in_grid]]) {
        uint n = uint(P[P_SIZE]);
        if (gid.x >= n || gid.y >= n) { return; }
        uint a = gid.y * n + gid.x;
        if (cell[a] != ROCK) { vel[a] = float4(0.0f); return; }
        uint nb[4] = { a + 1, a - 1, a + n, a - n };
        float f[4];
        float largest = 0.0f;
        for (int k = 0; k < 4; k++) {
            f[k] = P[P_VSCALE] * conductance(a, nb[k], P, lam, cell, state) * (p[a] - p[nb[k]]);
            largest = max(largest, fabs(f[k]));
        }
        vel[a] = float4(0.5f * (f[0] - f[1]), 0.5f * (f[2] - f[3]), largest, 0.0f);
    }

    kernel void transportKernel(device float4 *outState [[buffer(0)]],
                                device const float4 *state [[buffer(1)]],
                                device const float *p [[buffer(2)]],
                                device const float *lam [[buffer(3)]],
                                device const uchar *cell [[buffer(4)]],
                                device const float4 *vel [[buffer(5)]],
                                constant float *P [[buffer(6)]],
                                uint2 gid [[thread_position_in_grid]]) {
        uint n = uint(P[P_SIZE]);
        if (gid.x >= n || gid.y >= n) { return; }
        uint a = gid.y * n + gid.x;
        float4 st = state[a];
        if (cell[a] != ROCK) { outState[a] = st; return; }
        float dt = P[P_DT];
        float dx = P[P_DX];
        float inlet = P[P_FINES] * max(0.0f, 1.0f - st.w / P[P_HBRIDGE]);
        uint nb[4] = { a - 1, a + 1, a - n, a + n };
        float sOut = 0.0f, cOut = 0.0f, mudIn = 0.0f, mudFaces = 0.0f;
        for (int k = 0; k < 4; k++) {
            uint b = nb[k];
            float f = P[P_VSCALE] * conductance(a, b, P, lam, cell, state) * (p[a] - p[b]);
            if (f > 0.0f) {
                sOut += f * st.x;
                cOut += f * st.y;
            } else if (cell[b] == ROCK) {
                float4 other = state[b];
                sOut += f * other.x;
                cOut += f * other.y;
            } else if (cell[b] == MUD) {
                sOut += f;
                cOut += f * inlet;
                mudIn -= f;
                mudFaces += 1.0f;
            }
        }
        float4 result;
        result.x = clamp(st.x - dt / (P[P_PHID] * dx) * sOut, 0.0f, 1.0f);
        float speed = length(vel[a].xy);
        float lambda = P[P_LAMBDA0] * max(0.0f, 1.0f - st.z / P[P_SIGMAMAX]);
        float capture = lambda * speed * st.y;
        result.y = max(st.y + dt / P[P_PHI] * (-cOut / dx - capture), 0.0f);
        result.z = min(st.z + dt * capture, P[P_SIGMAMAX]);
        result.w = st.w;
        if (mudFaces > 0.0f) {
            float un = mudIn / mudFaces / P[P_WALL];
            float dh = P[P_ALPHA] * un * dt;
            if (P[P_HEQ] > 0.0f) { dh *= max(0.0f, 1.0f - st.w / P[P_HEQ]); }
            result.w = st.w + dh;
        }
        outState[a] = result;
    }

    static float hash(uint x) {
        x ^= x >> 16; x *= 0x7feb352du; x ^= x >> 15; x *= 0x846ca68bu; x ^= x >> 16;
        return float(x) / 4294967295.0f;
    }

    static float2 sampleVelocity(float2 pos, uint n, float dx, device const float4 *vel) {
        float centre = float(n) * 0.5f;
        float2 g = pos / dx + centre - 0.5f;
        int2 i0 = int2(floor(g));
        float2 t = g - float2(i0);
        i0 = clamp(i0, int2(0), int2(int(n) - 2));
        float2 v00 = vel[uint(i0.y) * n + uint(i0.x)].xy;
        float2 v10 = vel[uint(i0.y) * n + uint(i0.x + 1)].xy;
        float2 v01 = vel[uint(i0.y + 1) * n + uint(i0.x)].xy;
        float2 v11 = vel[uint(i0.y + 1) * n + uint(i0.x + 1)].xy;
        return mix(mix(v00, v10, t.x), mix(v01, v11, t.x), t.y);
    }

    // particle = (x, y, age, lifetime); positions in metres from the well axis.
    kernel void particleKernel(device float4 *particles [[buffer(0)]],
                               device const float4 *vel [[buffer(1)]],
                               constant float *P [[buffer(2)]],
                               uint id [[thread_position_in_grid]]) {
        uint n = uint(P[P_SIZE]);
        float4 q = particles[id];
        float rw = P[P_RW];
        float R = P[P_R];
        float2 v = sampleVelocity(q.xy, n, P[P_DX], vel);
        float maxSpeed = max(P[P_MAXSPEED], 1e-30f);
        q.xy += v / maxSpeed * P[P_PSTEP];
        q.z += 1.0f;
        float r = length(q.xy);
        if (r > R || r < rw * 0.98f || q.z > q.w) {
            uint seed = id * 9781u + uint(P[P_FRAME]) * 6271u;
            float angle = hash(seed) * 6.2831853f;
            float start = rw + P[P_DX] * (0.6f + 2.0f * hash(seed + 1u));
            q = float4(start * cos(angle), start * sin(angle), 0.0f, 90.0f + 240.0f * hash(seed + 2u));
        }
        particles[id] = q;
    }
    """
}
