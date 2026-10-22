import FlowCore
import FlowGPU
import MetalKit
import QuartzCore

/// Fields the live view can colour the rock by.
enum LiveField: Int, CaseIterable, Identifiable {
    case filtrate
    case damage
    case permeability
    case fines
    case pressure

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .filtrate: "Filtrate"
        case .damage: "Damage k/k₀"
        case .permeability: "Permeability"
        case .fines: "Retained Fines"
        case .pressure: "Pressure"
        }
    }

    var legend: (low: String, high: String) {
        switch self {
        case .filtrate: ("Oil", "Filtrate")
        case .damage: ("Undamaged", "Severe")
        case .permeability: ("0.1 × mean", "10 × mean")
        case .fines: ("None", "σmax")
        case .pressure: ("Pore", "Mud")
        }
    }
}

/// Draws the GPU invasion model every frame and steps it forward while playing.
@MainActor
final class LiveFlowRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let fieldPipeline: MTLRenderPipelineState
    private let particlePipeline: MTLRenderPipelineState
    private(set) var solver: LiveInvasionGPU?
    private var lastFrame: CFTimeInterval = 0
    private var lastStats: CFTimeInterval = 0
    weak var controller: LiveFlowController?

    init(device: MTLDevice) throws {
        self.device = device
        let library = try device.makeLibrary(source: LiveFlowRenderer.shaderSource, options: nil)
        let field = MTLRenderPipelineDescriptor()
        field.vertexFunction = library.makeFunction(name: "fieldVertex")
        field.fragmentFunction = library.makeFunction(name: "fieldFragment")
        field.colorAttachments[0].pixelFormat = .bgra8Unorm
        fieldPipeline = try device.makeRenderPipelineState(descriptor: field)

        let points = MTLRenderPipelineDescriptor()
        points.vertexFunction = library.makeFunction(name: "particleVertex")
        points.fragmentFunction = library.makeFunction(name: "particleFragment")
        let attachment = points.colorAttachments[0]!
        attachment.pixelFormat = .bgra8Unorm
        attachment.isBlendingEnabled = true
        attachment.sourceRGBBlendFactor = .sourceAlpha
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        particlePipeline = try device.makeRenderPipelineState(descriptor: points)
        super.init()
    }

    func reset(setup: LiveInvasionSetup) throws {
        solver = try LiveInvasionGPU(setup: setup, device: device, particleCount: 6144)
        lastFrame = 0
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let solver, let controller else { return }
        let now = CACurrentMediaTime()
        let elapsed = lastFrame == 0 ? 1.0 / 60 : min(now - lastFrame, 1.0 / 20)
        lastFrame = now

        if controller.isPlaying && !solver.isFinished {
            solver.advance(by: solver.setup.exposureTime / controller.playbackSeconds * elapsed)
        } else if controller.showParticles {
            solver.animateParticles()
        }
        if now - lastStats > 0.2 || solver.isFinished != controller.isFinished {
            lastStats = now
            controller.receive(stats: solver.stats, finished: solver.isFinished)
        }

        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let buffer = solver.queue.makeCommandBuffer() else { return }
        encode(into: buffer, pass: pass, size: view.drawableSize, solver: solver, controller: controller)
        buffer.present(drawable)
        buffer.commit()
    }

    /// Renders one frame into an offscreen texture and returns it as an image (used for screenshots).
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
                        solver: LiveInvasionGPU, controller: LiveFlowController) {
        let background = controller.background
        pass.colorAttachments[0].clearColor = MTLClearColor(red: background.r, green: background.g, blue: background.b, alpha: 1)
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        let setup = solver.setup
        let front = controller.referenceFrontDepth(atHours: solver.time / 3600).map { setup.wellboreRadius + $0 * 0.0254 } ?? -1
        var params: [Float] = [
            Float(setup.size), Float(setup.cellSize), Float(setup.wellboreRadius), Float(setup.domainRadius),
            Float(controller.field.rawValue), Float(size.width), Float(size.height), Float(LiveFlowController.viewExtent(setup)),
            Float(LiveFlowController.cakeExaggeration), Float(front),
            Float(background.r), Float(background.g), Float(background.b),
            Float(setup.damageCoefficient), Float(setup.filtrateDamageFactor), Float(setup.maxRetention),
        ]
        let length = params.count * MemoryLayout<Float>.stride

        encoder.setRenderPipelineState(fieldPipeline)
        encoder.setFragmentBuffer(solver.stateBuffer, offset: 0, index: 0)
        encoder.setFragmentBuffer(solver.pressure, offset: 0, index: 1)
        encoder.setFragmentBuffer(solver.k0, offset: 0, index: 2)
        encoder.setFragmentBuffer(solver.cells, offset: 0, index: 3)
        encoder.setFragmentBytes(&params, length: length, index: 4)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        if controller.showParticles {
            encoder.setRenderPipelineState(particlePipeline)
            encoder.setVertexBuffer(solver.particles, offset: 0, index: 0)
            encoder.setVertexBytes(&params, length: length, index: 1)
            encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: solver.particleCount)
        }
        encoder.endEncoding()
    }

    // MARK: Shaders

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    #define R_SIZE 0
    #define R_DX 1
    #define R_RW 2
    #define R_RADIUS 3
    #define R_FIELD 4
    #define R_W 5
    #define R_H 6
    #define R_EXTENT 7
    #define R_CAKEX 8
    #define R_FRONT 9
    #define R_BG 10
    #define R_BETA 13
    #define R_FD 14
    #define R_SIGMAMAX 15

    struct FieldOut { float4 position [[position]]; };

    vertex FieldOut fieldVertex(uint vid [[vertex_id]]) {
        float2 corners[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
        FieldOut out;
        out.position = float4(corners[vid], 0.0, 1.0);
        return out;
    }

    static float3 ramp(float t, float3 a, float3 b, float3 c) {
        t = clamp(t, 0.0f, 1.0f);
        return t < 0.5f ? mix(a, b, t * 2.0f) : mix(b, c, t * 2.0f - 1.0f);
    }

    static float fieldValue(uint index, int field, device const float4 *state, device const float *p,
                            device const float *k0, constant float *R) {
        float4 st = state[index];
        float ratio = (1.0f - (1.0f - R[R_FD]) * st.x) / (1.0f + R[R_BETA] * st.z);
        switch (field) {
            case 0: return st.x;
            case 1: return 1.0f - ratio;
            case 2: return clamp(0.5f + 0.5f * log10(max(k0[index] * ratio, 1e-6f)), 0.0f, 1.0f);
            case 3: return st.z / R[R_SIGMAMAX];
            default: return p[index];
        }
    }

    static float3 colourFor(int field, float t) {
        float3 sand = float3(0.87, 0.80, 0.64);
        switch (field) {
            case 0: return ramp(t, sand, float3(0.30, 0.60, 0.92), float3(0.06, 0.20, 0.62));
            case 1: return ramp(t, sand, float3(0.96, 0.56, 0.18), float3(0.55, 0.05, 0.08));
            case 2: return ramp(t, float3(0.27, 0.00, 0.33), float3(0.13, 0.57, 0.55), float3(0.99, 0.91, 0.14));
            case 3: return ramp(t, sand, float3(0.70, 0.45, 0.80), float3(0.32, 0.10, 0.45));
            default: return ramp(t, float3(0.12, 0.22, 0.55), float3(0.20, 0.72, 0.62), float3(0.98, 0.84, 0.25));
        }
    }

    fragment float4 fieldFragment(FieldOut in [[stage_in]],
                                  device const float4 *state [[buffer(0)]],
                                  device const float *p [[buffer(1)]],
                                  device const float *k0 [[buffer(2)]],
                                  device const uchar *cell [[buffer(3)]],
                                  constant float *R [[buffer(4)]]) {
        float w = R[R_W], h = R[R_H];
        float scale = R[R_EXTENT] / (min(w, h) * 0.5f);
        float2 world = float2(in.position.x - w * 0.5f, h * 0.5f - in.position.y) * scale;
        float r = length(world);
        float rw = R[R_RW], radius = R[R_RADIUS], dx = R[R_DX];
        uint n = uint(R[R_SIZE]);
        float3 background = float3(R[R_BG], R[R_BG + 1], R[R_BG + 2]);
        int field = int(R[R_FIELD]);

        if (r > radius) {
            float edge = smoothstep(radius + 2.0f * scale, radius, r);
            return float4(mix(background, float3(0.5), 0.35f * edge), 1.0);
        }

        float2 dir = r > 0.0f ? world / r : float2(1.0, 0.0);
        if (r < rw) {
            // Borehole full of mud, with the external cake drawn exaggerated on the wall.
            float2 wallPoint = dir * (rw + 0.75f * dx);
            int2 wc = int2(floor(wallPoint / dx + float(n) * 0.5f));
            uint wi = uint(wc.y) * n + uint(wc.x);
            if (cell[wi] != 0) {
                wallPoint = dir * (rw + 1.5f * dx);
                wc = int2(floor(wallPoint / dx + float(n) * 0.5f));
                wi = uint(wc.y) * n + uint(wc.x);
            }
            float cake = state[wi].w * R[R_CAKEX];
            float3 mud = float3(0.30, 0.25, 0.22);
            if (r > rw - cake) {
                float stripe = 0.5f + 0.5f * sin((rw - r) / max(cake, 1e-6f) * 18.0f);
                return float4(mix(float3(0.42, 0.29, 0.17), float3(0.55, 0.40, 0.24), stripe), 1.0);
            }
            float speckle = fract(sin(dot(floor(world / (dx * 0.5f)), float2(39.346, 11.135))) * 43758.5453);
            return float4(mud * (0.95f + 0.05f * speckle), 1.0);
        }

        // Bilinear sample of cell-centre values.
        float2 g = world / dx + float(n) * 0.5f - 0.5f;
        int2 i0 = clamp(int2(floor(g)), int2(0), int2(int(n) - 2));
        float2 t = g - float2(i0);
        float v00 = fieldValue(uint(i0.y) * n + uint(i0.x), field, state, p, k0, R);
        float v10 = fieldValue(uint(i0.y) * n + uint(i0.x + 1), field, state, p, k0, R);
        float v01 = fieldValue(uint(i0.y + 1) * n + uint(i0.x), field, state, p, k0, R);
        float v11 = fieldValue(uint(i0.y + 1) * n + uint(i0.x + 1), field, state, p, k0, R);
        float value = mix(mix(v00, v10, t.x), mix(v01, v11, t.x), t.y);
        float3 colour = colourFor(field, value);

        // Grain texture so the rock reads as rock.
        float grain = fract(sin(dot(floor(world / (dx * 0.35f)), float2(12.9898, 78.233))) * 43758.5453);
        colour *= 0.94f + 0.06f * grain;

        // Dashed ring: the filtrate front from the 1D model, for comparison.
        float front = R[R_FRONT];
        if (front > 0.0f && abs(r - front) < 1.2f * scale) {
            float angle = atan2(world.y, world.x);
            if (fract(angle * 36.0f / 6.2831853f) < 0.55f) { colour = mix(colour, float3(1.0), 0.85f); }
        }
        return float4(colour, 1.0);
    }

    struct ParticleOut {
        float4 position [[position]];
        float size [[point_size]];
        float alpha;
    };

    vertex ParticleOut particleVertex(uint vid [[vertex_id]],
                                      device const float4 *particles [[buffer(0)]],
                                      constant float *R [[buffer(1)]]) {
        float4 q = particles[vid];
        float w = R[R_W], h = R[R_H];
        float scale = R[R_EXTENT] / (min(w, h) * 0.5f);
        ParticleOut out;
        out.position = float4(2.0f * q.x / (scale * w), 2.0f * q.y / (scale * h), 0.0, 1.0);
        out.size = max(2.5f, min(w, h) / 380.0f);
        float life = q.z / max(q.w, 1.0f);
        out.alpha = 0.6f * smoothstep(0.0f, 0.12f, life) * (1.0f - smoothstep(0.75f, 1.0f, life));
        return out;
    }

    fragment float4 particleFragment(ParticleOut in [[stage_in]], float2 pc [[point_coord]]) {
        // White core with a dark rim, so tracers read on light and dark fields alike.
        float d = length(pc - float2(0.5));
        float a = in.alpha * (1.0f - smoothstep(0.42f, 0.5f, d));
        float3 c = mix(float3(1.0), float3(0.08, 0.10, 0.14), smoothstep(0.18f, 0.32f, d));
        return float4(c, a);
    }
    """
}
