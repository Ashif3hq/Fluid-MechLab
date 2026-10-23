import FlowCore
import FlowGPU
import MetalKit
import QuartzCore
import simd
import SwiftUI

/// Layout shared with the shader's `Uniforms`.
struct Invasion3DUniforms {
    var inverseViewProjection = simd_float4x4(1)
    /// xyz camera position, m.
    var camera = SIMD4<Float>(repeating: 0)
    /// rw, R, L, ln(R/rw).
    var geometry = SIMD4<Float>(repeating: 0)
    /// nr, nt, nz, cake value at the top of the cake colour scale (mm).
    var grid = SIMD4<Float>(repeating: 0)
    /// Normals of the two half-planes that bound the cutaway wedge.
    var cut = SIMD4<Float>(repeating: 0)
    /// mode, field, cut height (m), ring spacing (m).
    var options = SIMD4<Float>(repeating: 0)
    var backgroundTop = SIMD4<Float>(repeating: 0)
    var backgroundBottom = SIMD4<Float>(repeating: 0)
    /// width, height, frame counter, volume opacity.
    var viewport = SIMD4<Float>(repeating: 0)
}

/// Draws the 3D model by ray marching the GPU state, and steps the simulation while playing.
@MainActor
final class Invasion3DRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let pipeline: MTLRenderPipelineState
    private(set) var solver: Invasion3DGPU?
    private var volumeTexture: MTLTexture?
    private var cakeTexture: MTLTexture?
    private var lastFrame: CFTimeInterval = 0
    private var lastStats: CFTimeInterval = 0
    private var lastHistory = -1.0
    private var frame: Float = 0
    weak var controller: Invasion3DController?

    init(device: MTLDevice) throws {
        self.device = device
        let library = try device.makeLibrary(source: Invasion3DRenderer.shaderSource, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "rayVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "rayFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        super.init()
    }

    func reset(setup: Invasion3DSetup) throws {
        let solver = try Invasion3DGPU(setup: setup, device: device)
        let volume = MTLTextureDescriptor()
        volume.textureType = .type3D
        volume.pixelFormat = .rgba16Float
        volume.width = setup.nr
        volume.height = setup.nt
        volume.depth = setup.nz
        volume.usage = [.shaderRead, .shaderWrite]
        volume.storageMode = .private
        let cake = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: setup.nt, height: setup.nz, mipmapped: false)
        cake.usage = [.shaderRead, .shaderWrite]
        cake.storageMode = .private
        guard let volumeTexture = device.makeTexture(descriptor: volume), let cakeTexture = device.makeTexture(descriptor: cake) else {
            throw LiveInvasionGPUError.allocation
        }
        self.solver = solver
        self.volumeTexture = volumeTexture
        self.cakeTexture = cakeTexture
        lastFrame = 0
        lastHistory = -1
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let solver, let controller else { return }
        let now = CACurrentMediaTime()
        let elapsed = lastFrame == 0 ? 1.0 / 60 : min(now - lastFrame, 1.0 / 20)
        lastFrame = now

        if controller.isPlaying && !solver.isFinished {
            solver.advance(by: solver.setup.exposureTime / controller.playbackSeconds * elapsed, budget: 0.014)
        }
        let finished = solver.isFinished
        if now - lastStats > 0.25 || finished != controller.isFinished {
            lastStats = now
            let stats = solver.stats
            let record = stats.time - lastHistory >= solver.setup.exposureTime / 3600 / 200 || (finished && stats.time > lastHistory)
            if record { lastHistory = stats.time }
            controller.receive(stats: stats, finished: finished, record: record)
        }

        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let buffer = solver.queue.makeCommandBuffer() else { return }
        encode(into: buffer, pass: pass, size: view.drawableSize, solver: solver, controller: controller)
        buffer.present(drawable)
        buffer.commit()
    }

    /// Renders one frame offscreen and returns it as an image (for screenshots).
    func snapshot(size: CGSize) -> CGImage? {
        guard let solver, let controller, size.width > 0, size.height > 0 else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: Int(size.width), height: Int(size.height), mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor), let buffer = solver.queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        encode(into: buffer, pass: pass, size: size, solver: solver, controller: controller)
        buffer.commit()
        buffer.waitUntilCompleted()

        let width = texture.width, height = texture.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info, provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    // MARK: Encoding

    private func encode(into buffer: MTLCommandBuffer, pass: MTLRenderPassDescriptor, size: CGSize,
                        solver: Invasion3DGPU, controller: Invasion3DController) {
        guard let volumeTexture, let cakeTexture else { return }
        if let compute = buffer.makeComputeCommandEncoder() {
            solver.encodeDisplay(compute, volume: volumeTexture, cake: cakeTexture, field: controller.field.shaderIndex)
            compute.endEncoding()
        }
        frame += 1
        var uniforms = makeUniforms(setup: solver.setup, size: size, controller: controller)
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Invasion3DUniforms>.stride, index: 0)
        encoder.setFragmentTexture(volumeTexture, index: 0)
        encoder.setFragmentTexture(cakeTexture, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    private func makeUniforms(setup: Invasion3DSetup, size: CGSize, controller: Invasion3DController) -> Invasion3DUniforms {
        let camera = controller.camera
        let extent = Float(max(setup.domainRadius, setup.length * 0.5))
        let distance = extent * Float(camera.distance)
        let elevation = Float(camera.elevation), azimuth = Float(camera.azimuth)
        let eye = SIMD3<Float>(distance * cos(elevation) * cos(azimuth), distance * cos(elevation) * sin(azimuth), distance * sin(elevation))
        let view = Invasion3DRenderer.lookAt(eye: eye, target: SIMD3(0, 0, Float(camera.targetHeight) * Float(setup.length) * 0.5), up: SIMD3(0, 0, 1))
        let aspect = Float(max(size.width, 1) / max(size.height, 1))
        let projection = Invasion3DRenderer.perspective(fovY: 28 * .pi / 180, aspect: aspect, near: distance * 0.05, far: distance * 4)

        var u = Invasion3DUniforms()
        u.inverseViewProjection = (projection * view).inverse
        u.camera = SIMD4(eye, 1)
        u.geometry = SIMD4(Float(setup.wellboreRadius), Float(setup.domainRadius), Float(setup.length),
                           Float(log(setup.domainRadius / setup.wellboreRadius)))
        u.grid = SIMD4(Float(setup.nr), Float(setup.nt), Float(setup.nz), Float(max(controller.cakeScale, 0.05)))
        // Cutaway wedge: the quarter facing the camera, bounded by angles a and a + 90°.
        let start = azimuth - .pi / 4
        let end = start + .pi / 2
        u.cut = SIMD4(-sin(start), cos(start), sin(end), -cos(end))
        u.options = SIMD4(Float(controller.mode.rawValue), Float(controller.field.shaderIndex),
                          controller.cutawayHeight * Float(setup.length) * 0.5, Float(controller.ringSpacing))
        let top = controller.backgroundTop, bottom = controller.backgroundBottom
        u.backgroundTop = SIMD4(Float(top.r), Float(top.g), Float(top.b), 1)
        u.backgroundBottom = SIMD4(Float(bottom.r), Float(bottom.g), Float(bottom.b), 1)
        u.viewport = SIMD4(Float(size.width), Float(size.height), frame, Float(controller.volumeOpacity))
        return u
    }

    static func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let f = simd_normalize(target - eye)
        let s = simd_normalize(simd_cross(f, up))
        let u = simd_cross(s, f)
        return simd_float4x4(columns: (
            SIMD4(s.x, u.x, -f.x, 0),
            SIMD4(s.y, u.y, -f.y, 0),
            SIMD4(s.z, u.z, -f.z, 0),
            SIMD4(-simd_dot(s, eye), -simd_dot(u, eye), simd_dot(f, eye), 1)))
    }

    /// Right-handed perspective with Metal's 0…1 depth range.
    static func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let y = 1 / tan(fovY * 0.5)
        let x = y / aspect
        let z = far / (near - far)
        return simd_float4x4(columns: (
            SIMD4(x, 0, 0, 0),
            SIMD4(0, y, 0, 0),
            SIMD4(0, 0, z, -1),
            SIMD4(0, 0, z * near, 0)))
    }

    // MARK: Shaders

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float4x4 inverseViewProjection;
        float4 camera;
        float4 geometry;   // rw, R, L, ln(R/rw)
        float4 grid;       // nr, nt, nz, cake scale mm
        float4 cut;        // half-plane normals of the cutaway wedge
        float4 options;    // mode, field, cut height, ring spacing
        float4 backgroundTop;
        float4 backgroundBottom;
        float4 viewport;   // width, height, frame, volume opacity
    };

    constexpr sampler fieldSampler(filter::linear, s_address::clamp_to_edge, t_address::repeat, r_address::clamp_to_edge);
    constexpr sampler cakeSampler(filter::linear, s_address::repeat, t_address::clamp_to_edge);

    #define TAU 6.28318530718f

    struct VOut { float4 position [[position]]; };

    vertex VOut rayVertex(uint vid [[vertex_id]]) {
        float2 corners[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
        VOut out;
        out.position = float4(corners[vid], 0.0, 1.0);
        return out;
    }

    // Polynomial fits of the matplotlib colour maps (Matt Zucker, CC0).
    static float3 poly(float t, float3 c0, float3 c1, float3 c2, float3 c3, float3 c4, float3 c5, float3 c6) {
        t = clamp(t, 0.0f, 1.0f);
        return clamp(c0 + t * (c1 + t * (c2 + t * (c3 + t * (c4 + t * (c5 + t * c6))))), 0.0f, 1.0f);
    }
    static float3 viridis(float t) {
        return poly(t, float3(0.2777273272234177, 0.005407344544966578, 0.3340998053353061),
                       float3(0.1050930431085774, 1.404613529898575, 1.384590162594685),
                       float3(-0.3308618287255563, 0.214847559468213, 0.09509516302823659),
                       float3(-4.634230498983486, -5.799100973351585, -19.33244095627987),
                       float3(6.228269936347081, 14.17993336680509, 56.69055260068105),
                       float3(4.776384997670288, -13.74514537774601, -65.35303263337234),
                       float3(-5.435455855934631, 4.645852612178535, 26.3124352495832));
    }
    static float3 inferno(float t) {
        return poly(t, float3(0.0002189403691192265, 0.001651004631001012, -0.01948089843709184),
                       float3(0.1065134194856116, 0.5639564367884091, 3.932712388889277),
                       float3(11.60249308247187, -3.972853965665698, -15.9423941062914),
                       float3(-41.70399613139459, 17.43639888205313, 44.35414519872813),
                       float3(77.162935699427, -33.40235894210092, -81.80730925738993),
                       float3(-71.31942824499214, 32.62606426397723, 73.20951985803202),
                       float3(25.13112622477341, -12.24266895238567, -23.07032500287172));
    }
    static float3 magma(float t) {
        return poly(t, float3(-0.002136485053939582, -0.000749655052795221, -0.005386127855323933),
                       float3(0.2516605407371642, 0.6775232436837668, 2.494026599312351),
                       float3(8.353717279216625, -3.577719514958484, 0.3144679030132573),
                       float3(-27.66873308576866, 14.26473078096533, -13.64921318813922),
                       float3(52.17613981234068, -27.94360607168351, 12.94416944238394),
                       float3(-50.76852536473588, 29.04658282127291, 4.23415299384598),
                       float3(18.65570506591883, -11.48977351997711, -5.601961508734096));
    }
    static float3 plasma(float t) {
        return poly(t, float3(0.05873234392399702, 0.02333670892565664, 0.5433401826748754),
                       float3(2.176514634195958, 0.2383834171260182, 0.7539604599784036),
                       float3(-2.689460476458034, -7.455851135738909, 3.110799939717086),
                       float3(6.130348345893603, 42.3461881477227, -28.51885465332158),
                       float3(-11.10743619062271, -82.66631109428045, 60.13984767418263),
                       float3(10.02306557647065, 71.41361770095349, -54.07218655560067),
                       float3(-3.658713842777788, -22.93153465461149, 18.19190778539828));
    }
    static float3 ramp3(float t, float3 a, float3 b, float3 c) {
        t = clamp(t, 0.0f, 1.0f);
        return t < 0.5f ? mix(a, b, t * 2.0f) : mix(b, c, t * 2.0f - 1.0f);
    }

    // Field colour. Fields: 0 filtrate, 1 damage (1 - k/k0), 2 permeability, 3 retained fines, 4 suspended fines, 5 pressure.
    static float3 colourMap(int field, float t) {
        float3 rock = float3(0.88, 0.83, 0.71);
        switch (field) {
            case 0: return ramp3(t, rock, float3(0.36, 0.62, 0.86), float3(0.04, 0.19, 0.45));
            case 1: return inferno(1.0f - 0.92f * t);
            case 2: return viridis(t);
            case 3: return magma(1.0f - 0.9f * t);
            case 4: return ramp3(t, rock, float3(0.45, 0.74, 0.52), float3(0.02, 0.36, 0.20));
            default: return plasma(0.05f + 0.9f * t);
        }
    }

    static float3 cakeColour(float t) {
        return mix(float3(0.42, 0.36, 0.30), float3(0.28, 0.17, 0.08), clamp(t, 0.0f, 1.0f));
    }

    static float4 sampleField(float3 p, constant Uniforms &U, texture3d<float> tex) {
        float rw = U.geometry.x;
        float r = max(length(p.xy), rw);
        float th = atan2(p.y, p.x);
        if (th < 0.0f) { th += TAU; }
        float3 uvw = float3(log(r / rw) / U.geometry.w, th / TAU, p.z / U.geometry.z + 0.5f);
        return tex.sample(fieldSampler, uvw);
    }

    static float sampleCake(float3 p, constant Uniforms &U, texture2d<float> cake) {
        float th = atan2(p.y, p.x);
        if (th < 0.0f) { th += TAU; }
        return cake.sample(cakeSampler, float2(th / TAU, p.z / U.geometry.z + 0.5f)).x;
    }

    // Signed distance (lower bound) to the rock annulus, optionally with the cutaway wedge removed above the cut height.
    static float solidDistance(float3 p, constant Uniforms &U, bool cutaway) {
        float r = length(p.xy);
        float d = max(max(r - U.geometry.y, U.geometry.x - r), fabs(p.z) - 0.5f * U.geometry.z);
        if (cutaway) {
            float d1 = dot(p.xy, U.cut.xy), d2 = dot(p.xy, U.cut.zw);
            d = max(d, min(min(d1, d2), p.z - U.options.z));
        }
        return d;
    }

    static float3 solidNormal(float3 p, constant Uniforms &U, bool cutaway, float h) {
        float2 e = float2(h, 0.0f);
        return normalize(float3(solidDistance(p + e.xyy, U, cutaway) - solidDistance(p - e.xyy, U, cutaway),
                                solidDistance(p + e.yxy, U, cutaway) - solidDistance(p - e.yxy, U, cutaway),
                                solidDistance(p + e.yyx, U, cutaway) - solidDistance(p - e.yyx, U, cutaway)));
    }

    // Entry and exit of the ray through the cylinder r <= radius, |z| <= L/2. Returns false on a miss.
    static bool cylinderSpan(float3 o, float3 d, float radius, float halfLength, thread float &t0, thread float &t1) {
        float a = dot(d.xy, d.xy), b = dot(o.xy, d.xy), c = dot(o.xy, o.xy) - radius * radius;
        float lo = -1e30f, hi = 1e30f;
        if (a > 1e-12f) {
            float disc = b * b - a * c;
            if (disc < 0.0f) { return false; }
            float s = sqrt(disc);
            lo = (-b - s) / a; hi = (-b + s) / a;
        } else if (c > 0.0f) { return false; }
        if (fabs(d.z) > 1e-12f) {
            float za = (-halfLength - o.z) / d.z, zb = (halfLength - o.z) / d.z;
            lo = max(lo, min(za, zb)); hi = min(hi, max(za, zb));
        } else if (fabs(o.z) > halfLength) { return false; }
        t0 = max(lo, 0.0f); t1 = hi;
        return t1 > t0;
    }

    // First entry of the ray into the borehole r < rw within the interval, or a large value.
    static float boreholeEntry(float3 o, float3 d, constant Uniforms &U) {
        float t0, t1;
        if (cylinderSpan(o, d, U.geometry.x, 0.5f * U.geometry.z, t0, t1)) { return t0; }
        return 1e30f;
    }

    // Marching step: about half of the local cell, whose size grows with radius on the geometric grid.
    static float localStep(float3 p, constant Uniforms &U) {
        float r = max(length(p.xy), U.geometry.x);
        float g = exp(U.geometry.w / U.grid.x) - 1.0f;
        float cell = min(min(r * g, r * TAU / U.grid.y), U.geometry.z / U.grid.z);
        return max(0.5f * cell, 1e-5f);
    }

    static float3 shade(float3 base, float3 n, float3 v, float ambient) {
        float3 key = normalize(float3(0.45f, -0.55f, 0.75f));
        float3 fill = normalize(float3(-0.6f, 0.4f, 0.25f));
        float diffuse = max(dot(n, key), 0.0f) * 0.62f + max(dot(n, fill), 0.0f) * 0.22f;
        float3 h = normalize(key + v);
        float specular = pow(max(dot(n, h), 0.0f), 48.0f) * 0.18f;
        return base * (ambient + diffuse) + specular;
    }

    static float hash(float2 p, float frame) {
        return fract(sin(dot(p + frame * 0.618f, float2(12.9898f, 78.233f))) * 43758.5453f);
    }

    // Wall of the borehole, coloured by external cake thickness.
    static float3 boreholeWall(float3 p, float3 v, constant Uniforms &U, texture2d<float> cake) {
        float3 n = normalize(float3(-p.x, -p.y, 0.0f));
        float t = sampleCake(p, U, cake) / U.grid.w;
        float stripe = 0.5f + 0.5f * sin(p.z / U.geometry.z * 120.0f);
        float3 base = cakeColour(t) * (0.92f + 0.08f * stripe);
        return shade(base, n, v, 0.45f);
    }

    fragment float4 rayFragment(VOut in [[stage_in]],
                                constant Uniforms &U [[buffer(0)]],
                                texture3d<float> field [[texture(0)]],
                                texture2d<float> cake [[texture(1)]]) {
        float2 size = U.viewport.xy;
        float2 ndc = float2(in.position.x / size.x * 2.0f - 1.0f, 1.0f - in.position.y / size.y * 2.0f);
        float4 nearPoint = U.inverseViewProjection * float4(ndc, 0.0f, 1.0f);
        float4 farPoint = U.inverseViewProjection * float4(ndc, 1.0f, 1.0f);
        float3 o = U.camera.xyz;
        float3 d = normalize(farPoint.xyz / farPoint.w - nearPoint.xyz / nearPoint.w);
        float3 v = -d;

        float3 background = mix(U.backgroundBottom.rgb, U.backgroundTop.rgb, in.position.y < 0 ? 1.0f : 1.0f - in.position.y / size.y);
        int mode = int(U.options.x);
        int fieldIndex = int(U.options.y);
        float rw = U.geometry.x, R = U.geometry.y, L = U.geometry.z;

        float t0, t1;
        if (!cylinderSpan(o, d, R * 1.0005f, 0.5f * L * 1.0005f, t0, t1)) { return float4(background, 1.0); }

        if (mode == 0) {
            // Cutaway solid: sphere-trace the rock with a quarter removed above the cut height.
            float t = t0;
            float eps = 2e-5f * R;
            bool hit = false;
            for (int i = 0; i < 256 && t < t1; i++) {
                float dist = solidDistance(o + t * d, U, true);
                if (dist < eps) { hit = true; break; }
                t += max(dist, eps * 0.5f);
            }
            if (!hit) { return float4(background, 1.0); }
            float3 p = o + t * d;
            float3 n = solidNormal(p, U, true, 4e-5f * R);
            float r = length(p.xy);
            if (r < rw * 1.0005f && dot(n.xy, p.xy) < 0.0f) {
                return float4(boreholeWall(p, v, U, cake), 1.0);
            }
            float4 s = sampleField(p - n * 1e-4f * R, U, field);
            float3 base = colourMap(fieldIndex, s.x);
            // Filtrate front (s = 0.5) as a crisp line on every cut surface.
            float width = max(fwidth(s.y), 1e-4f);
            float front = 1.0f - smoothstep(0.6f, 1.6f, fabs(s.y - 0.5f) / width);
            // Graduated rings at fixed depths into the formation, on the flat faces.
            float spacing = U.options.w;
            bool flat = fabs(n.z) > 0.5f || fabs(dot(n.xy, normalize(p.xy))) < 0.5f;
            if (spacing > 0.0f && flat) {
                float q = (r - rw) / spacing;
                float ring = 1.0f - smoothstep(0.5f, 1.5f, fabs(q - round(q)) / max(fwidth(q), 1e-5f));
                base = mix(base, base * 0.55f, 0.55f * ring);
            }
            float3 colour = shade(base, n, v, 0.42f);
            colour = mix(colour, float3(1.0f), 0.85f * front * (fieldIndex == 0 ? 0.0f : 1.0f));
            colour = mix(colour, float3(0.02f, 0.10f, 0.30f), 0.9f * front * (fieldIndex == 0 ? 1.0f : 0.0f));
            return float4(colour, 1.0);
        }

        float tWall = boreholeEntry(o, d, U);
        float tEnd = min(t1, tWall);
        float jitter = hash(in.position.xy, U.viewport.z);

        // Glass shell of the rock domain.
        float3 entry = o + t0 * d;
        float3 shellNormal = fabs(fabs(entry.z) - 0.5f * L) < 1e-3f * L ? float3(0.0f, 0.0f, sign(entry.z)) : normalize(float3(entry.xy, 0.0f));
        float fresnel = pow(1.0f - fabs(dot(shellNormal, v)), 4.0f);

        if (mode == 1) {
            // Filtrate front as an isosurface of s = 0.5, refined by bisection.
            float t = t0;
            float4 previous = sampleField(o + t * d, U, field);
            if (previous.y >= 0.5f) {
                // The front reaches the cap or edge of the domain here: show the cut face.
                float3 colour = fieldIndex == 0 ? float3(0.20f, 0.48f, 0.85f) : colourMap(fieldIndex, previous.x);
                return float4(shade(colour, shellNormal, v, 0.5f), 1.0);
            }
            bool hit = false;
            float tHit = 0.0f;
            float tPrev = t;
            t += localStep(o + t * d, U) * (0.5f + jitter);
            for (int i = 0; i < 900 && t < tEnd; i++) {
                float4 s = sampleField(o + t * d, U, field);
                if (s.y >= 0.5f) {
                    float a = tPrev, b = t;
                    for (int k = 0; k < 10; k++) {
                        float m = 0.5f * (a + b);
                        if (sampleField(o + m * d, U, field).y >= 0.5f) { b = m; } else { a = m; }
                    }
                    tHit = 0.5f * (a + b);
                    hit = true;
                    break;
                }
                tPrev = t;
                t += localStep(o + t * d, U);
            }
            float3 colour;
            if (hit) {
                float3 p = o + tHit * d;
                float h = localStep(p, U) * 0.8f;
                float3 grad = float3(sampleField(p + float3(h, 0, 0), U, field).y - sampleField(p - float3(h, 0, 0), U, field).y,
                                     sampleField(p + float3(0, h, 0), U, field).y - sampleField(p - float3(0, h, 0), U, field).y,
                                     sampleField(p + float3(0, 0, h), U, field).y - sampleField(p - float3(0, 0, h), U, field).y);
                float3 n = length(grad) > 1e-6f ? -normalize(grad) : -d;
                if (dot(n, v) < 0.0f) { n = -n; }
                float4 s = sampleField(p, U, field);
                float3 base = fieldIndex == 0 ? float3(0.20f, 0.48f, 0.85f) : colourMap(fieldIndex, s.x);
                colour = shade(base, n, v, 0.38f);
            } else if (tWall < t1) {
                colour = boreholeWall(o + tWall * d, v, U, cake);
            } else {
                colour = background;
            }
            colour = mix(colour, float3(1.0f), 0.35f * fresnel);
            return float4(colour, 1.0);
        }

        // Volume rendering (emission-absorption) of the selected field, with the cutaway removed.
        float3 accumulated = float3(0.0f);
        float transmittance = 1.0f;
        float density = U.viewport.w / (0.05f * R);
        float t = t0 + localStep(o + t0 * d, U) * jitter;
        for (int i = 0; i < 900 && t < tEnd && transmittance > 0.02f; i++) {
            float3 p = o + t * d;
            float step = localStep(p, U);
            if (solidDistance(p, U, true) <= 0.0f) {
                float4 s = sampleField(p, U, field);
                float value = fieldIndex == 5 ? s.x * 0.6f : s.x;
                float alpha = 1.0f - exp(-density * pow(clamp(value, 0.0f, 1.0f), 1.6f) * step);
                accumulated += transmittance * alpha * colourMap(fieldIndex, s.x);
                transmittance *= 1.0f - alpha;
            }
            t += step;
        }
        float3 behind = tWall < t1 ? boreholeWall(o + tWall * d, v, U, cake) : background;
        float3 colour = accumulated + transmittance * behind;
        colour = mix(colour, float3(1.0f), 0.3f * fresnel);
        return float4(colour, 1.0);
    }
    """
}

/// An MTKView that turns drags into orbiting and scrolling or pinching into zoom.
final class OrbitMTKView: MTKView {
    var onOrbit: ((CGFloat, CGFloat) -> Void)?
    var onZoom: ((CGFloat) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDragged(with event: NSEvent) {
        onOrbit?(event.deltaX, event.deltaY)
    }

    override func scrollWheel(with event: NSEvent) {
        if event.hasPreciseScrollingDeltas {
            onOrbit?(-event.scrollingDeltaX * 0.5, -event.scrollingDeltaY * 0.5)
        } else {
            onZoom?(event.scrollingDeltaY * 0.04)
        }
    }

    override func magnify(with event: NSEvent) {
        onZoom?(event.magnification)
    }
}

/// Lets the screenshot runner capture the Metal view in each display mode.
@MainActor
final class Invasion3DSnapshotRegistry {
    static let shared = Invasion3DSnapshotRegistry()
    weak var view: MTKView?
    weak var controller: Invasion3DController?
    var lastError: String?

    var summary: String {
        guard let controller else { return "no controller, error=\(lastError ?? "none")" }
        let s = controller.stats
        return "t=\(s.time) h front=\(s.frontMean) in cake=\(s.cakeMean) mm massBalance=\(s.massBalanceError) solves=\(s.pressureSolves) sweeps=\(s.lastIterations) imbalance=\(s.lastImbalance) error=\(controller.errorMessage ?? lastError ?? "none")"
    }

    func snapshots() -> [(String, CGImage)] {
        guard let view, let controller, let renderer = controller.renderer else { return [] }
        let original = (controller.mode, controller.field)
        var images: [(String, CGImage)] = []
        let views: [(String, Invasion3DController.RenderMode, Invasion3DController.Field)] = [
            ("cutaway-filtrate", .cutaway, .filtrate), ("cutaway-damage", .cutaway, .damage),
            ("front", .front, .damage), ("volume-fines", .volume, .retained),
        ]
        for (name, mode, field) in views {
            controller.mode = mode
            controller.field = field
            if let image = renderer.snapshot(size: view.drawableSize) { images.append((name, image)) }
        }
        (controller.mode, controller.field) = original
        return images
    }
}

/// The MTKView that shows the 3D model.
struct Invasion3DMetalView: NSViewRepresentable {
    let controller: Invasion3DController

    final class Coordinator {
        // MTKView holds its delegate weakly.
        var renderer: Invasion3DRenderer?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MTKView {
        let view = OrbitMTKView()
        view.colorPixelFormat = .bgra8Unorm
        view.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        view.preferredFramesPerSecond = 60
        view.onOrbit = { [weak controller] dx, dy in controller?.orbit(dx: Double(dx), dy: Double(dy)) }
        view.onZoom = { [weak controller] amount in controller?.zoom(Double(amount)) }
        guard let device = MTLCreateSystemDefaultDevice() else {
            controller.fail("This Mac has no Metal device.")
            return view
        }
        view.device = device
        do {
            let renderer = try Invasion3DRenderer(device: device)
            context.coordinator.renderer = renderer
            view.delegate = renderer
            controller.attach(renderer)
            Invasion3DSnapshotRegistry.shared.view = view
            Invasion3DSnapshotRegistry.shared.controller = controller
        } catch {
            controller.fail("The Metal shaders did not compile: \(error.localizedDescription)")
        }
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {}
}
