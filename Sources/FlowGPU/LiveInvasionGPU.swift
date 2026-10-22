import FlowCore
import Foundation
import Metal

public enum LiveInvasionGPUError: Error, CustomStringConvertible {
    case noDevice
    case compile(String)
    case allocation

    public var description: String {
        switch self {
        case .noDevice: "This Mac has no Metal device."
        case .compile(let message): "The Metal kernels did not compile: \(message)"
        case .allocation: "Could not allocate GPU buffers."
        }
    }
}

/// Runs `LiveInvasionSolver`'s steps on the GPU with Metal compute.
///
/// Buffers use shared storage, so on Apple Silicon the CPU reads results straight from unified memory
/// without copies. A renderer can draw from `stateBuffer`, `pressure`, `velocity` and `particles` directly.
public final class LiveInvasionGPU {
    public let setup: LiveInvasionSetup
    public let device: MTLDevice
    /// Encode rendering on this queue so it runs after the simulation step.
    public let queue: MTLCommandQueue
    public let pressure: MTLBuffer
    public let mobility: MTLBuffer
    public let k0: MTLBuffer
    public let cells: MTLBuffer
    /// Per cell: (u_x, u_y, largest face flux, 0), m/s.
    public let velocity: MTLBuffer
    /// Per particle: (x, y, age, lifetime), metres and frames.
    public let particles: MTLBuffer
    public let particleCount: Int
    public let wallCells: [Int]
    public var pressureIterations = 120
    public var maxSubsteps = 64
    public var overRelaxation: Float = 1.85
    /// Particle travel per frame at the fastest speed, as a fraction of the domain radius.
    public var particleStep: Float = 0.006

    public private(set) var time = 0.0
    public private(set) var maxSpeed: Float = 0

    private var states: [MTLBuffer]
    private var current = 0
    private var frame = 0
    private let mobilityPipeline, pressurePipeline, velocityPipeline, transportPipeline, particlePipeline: MTLComputePipelineState

    /// Per cell: (filtrate saturation, suspended fines, retained fines, cake thickness in m).
    public var stateBuffer: MTLBuffer { states[current] }
    public var isFinished: Bool { time >= setup.exposureTime }

    public init(setup: LiveInvasionSetup, device: MTLDevice? = MTLCreateSystemDefaultDevice(), particleCount: Int = 16384) throws {
        guard let device else { throw LiveInvasionGPUError.noDevice }
        guard let queue = device.makeCommandQueue() else { throw LiveInvasionGPUError.allocation }
        self.setup = setup
        self.device = device
        self.queue = queue

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: LiveInvasionShaders.source, options: nil)
        } catch {
            throw LiveInvasionGPUError.compile(error.localizedDescription)
        }
        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else { throw LiveInvasionGPUError.compile("missing \(name)") }
            return try device.makeComputePipelineState(function: function)
        }
        mobilityPipeline = try pipeline("mobilityKernel")
        pressurePipeline = try pipeline("pressureKernel")
        velocityPipeline = try pipeline("velocityKernel")
        transportPipeline = try pipeline("transportKernel")
        particlePipeline = try pipeline("particleKernel")

        let count = setup.size * setup.size
        func buffer<T>(_ values: [T]) throws -> MTLBuffer {
            guard let b = values.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }) else {
                throw LiveInvasionGPUError.allocation
            }
            return b
        }
        pressure = try buffer(setup.radialPressure())
        mobility = try buffer(setup.k0)
        k0 = try buffer(setup.k0)
        cells = try buffer(setup.cells.map(\.rawValue))
        velocity = try buffer([SIMD4<Float>](repeating: .zero, count: count))
        let empty = [SIMD4<Float>](repeating: .zero, count: count)
        states = [try buffer(empty), try buffer(empty)]

        // Round up to whole threadgroups so no thread runs past the end.
        let particleTotal = max(64, (particleCount + 63) / 64 * 64)
        self.particleCount = particleTotal
        var rng = SystemRandomNumberGenerator()
        let rw = Float(setup.wellboreRadius), radius = Float(setup.domainRadius)
        let seeds: [SIMD4<Float>] = (0..<particleTotal).map { _ in
            let angle = Float.random(in: 0..<(2 * .pi), using: &rng)
            let r = Float.random(in: rw...(rw + 0.3 * (radius - rw)), using: &rng)
            let life = Float.random(in: 90...330, using: &rng)
            return SIMD4(r * cos(angle), r * sin(angle), Float.random(in: 0..<life, using: &rng), life)
        }
        particles = try buffer(seeds)
        wallCells = setup.wallCells
    }

    // MARK: Stepping

    /// Advances the simulation by up to `target` seconds and moves the tracer particles.
    /// Returns the simulated time covered.
    @discardableResult
    public func advance(by target: Double) -> Double {
        let target = min(target, setup.exposureTime - time)
        guard target > 0 else {
            animateParticles()
            return 0
        }

        // Pass 1: mobility, pressure and velocity. Wait for it, because the substep count depends on the fastest flux.
        guard let solve = queue.makeCommandBuffer(), let encoder = solve.makeComputeCommandEncoder() else { return 0 }
        dispatchGrid(encoder, mobilityPipeline, buffers: [mobility, k0, cells, stateBuffer], params: params())
        for _ in 0..<pressureIterations {
            for colour in 0..<2 {
                dispatchGrid(encoder, pressurePipeline, buffers: [pressure, mobility, cells, stateBuffer], params: params(colour: colour))
            }
        }
        dispatchGrid(encoder, velocityPipeline, buffers: [velocity, pressure, mobility, cells, stateBuffer], params: params())
        encoder.endEncoding()
        solve.commit()
        solve.waitUntilCompleted()

        let maxFlux = readMaxima()
        let steps = setup.substeps(target: target, maxFaceFlux: maxFlux, maxSubsteps: maxSubsteps)

        // Pass 2: transport substeps, then particles. Later work on `queue` (such as rendering) runs after this.
        guard let move = queue.makeCommandBuffer(), let transport = move.makeComputeCommandEncoder() else { return 0 }
        let stepParams = params(dt: steps.dt)
        for _ in 0..<steps.count {
            let next = 1 - current
            dispatchGrid(transport, transportPipeline,
                         buffers: [states[next], states[current], pressure, mobility, cells, velocity], params: stepParams)
            current = next
        }
        encodeParticles(transport)
        transport.endEncoding()
        move.commit()

        let covered = Double(steps.count) * steps.dt
        time += covered
        return covered
    }

    /// Moves the particles through the current velocity field without advancing time (used while paused or finished).
    public func animateParticles() {
        guard let buffer = queue.makeCommandBuffer(), let encoder = buffer.makeComputeCommandEncoder() else { return }
        encodeParticles(encoder)
        encoder.endEncoding()
        buffer.commit()
    }

    /// Blocks until queued GPU work finishes. Tests use this before reading buffers.
    public func waitUntilIdle() {
        guard let buffer = queue.makeCommandBuffer() else { return }
        buffer.commit()
        buffer.waitUntilCompleted()
    }

    // MARK: Reading results

    public var stats: LiveInvasionStats {
        let n = setup.size * setup.size
        let state = stateBuffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: n)
        let p = UnsafeBufferPointer(start: pressure.contents().bindMemory(to: Float.self, capacity: n), count: n)
        let m = UnsafeBufferPointer(start: mobility.contents().bindMemory(to: Float.self, capacity: n), count: n)
        return LiveInvasionMetrics.stats(
            setup: setup, wallCells: wallCells, time: time,
            pressure: p, saturation: { state[$0].x }, retained: { state[$0].z }, cake: { state[$0].w }, mobility: m)
    }

    /// Copies the per-cell state out of GPU memory.
    public func readState() -> [SIMD4<Float>] {
        let n = setup.size * setup.size
        return Array(UnsafeBufferPointer(start: stateBuffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: n), count: n))
    }

    public func readPressure() -> [Float] {
        let n = setup.size * setup.size
        return Array(UnsafeBufferPointer(start: pressure.contents().bindMemory(to: Float.self, capacity: n), count: n))
    }

    // MARK: Helpers

    private func readMaxima() -> Double {
        let n = setup.size * setup.size
        let v = velocity.contents().bindMemory(to: SIMD4<Float>.self, capacity: n)
        var flux: Float = 0
        var speed: Float = 0
        for i in 0..<n {
            flux = max(flux, v[i].z)
            speed = max(speed, (v[i].x * v[i].x + v[i].y * v[i].y).squareRoot())
        }
        maxSpeed = speed
        return Double(flux)
    }

    private func encodeParticles(_ encoder: MTLComputeCommandEncoder) {
        frame = (frame + 1) % 1_000_000
        var values = params()
        encoder.setComputePipelineState(particlePipeline)
        encoder.setBuffer(particles, offset: 0, index: 0)
        encoder.setBuffer(velocity, offset: 0, index: 1)
        encoder.setBytes(&values, length: values.count * MemoryLayout<Float>.stride, index: 2)
        encoder.dispatchThreadgroups(MTLSize(width: particleCount / 64, height: 1, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
    }

    private func dispatchGrid(_ encoder: MTLComputeCommandEncoder, _ pipeline: MTLComputePipelineState, buffers: [MTLBuffer], params: [Float]) {
        var values = params
        encoder.setComputePipelineState(pipeline)
        for (index, buffer) in buffers.enumerated() { encoder.setBuffer(buffer, offset: 0, index: index) }
        encoder.setBytes(&values, length: values.count * MemoryLayout<Float>.stride, index: buffers.count)
        let groups = (setup.size + 15) / 16
        encoder.dispatchThreadgroups(MTLSize(width: groups, height: groups, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
    }

    private func params(dt: Double = 0, colour: Int = 0) -> [Float] {
        typealias P = LiveInvasionShaders.P
        var v = [Float](repeating: 0, count: P.allCases.count)
        v[P.size.rawValue] = Float(setup.size)
        v[P.dx.rawValue] = Float(setup.cellSize)
        v[P.velocityScale.rawValue] = Float(setup.velocityScale)
        v[P.porosity.rawValue] = Float(setup.porosity)
        v[P.displaceablePorosity.rawValue] = Float(setup.displaceablePorosity)
        v[P.cakeGrowth.rawValue] = Float(setup.cakeGrowth)
        v[P.equilibriumCake.rawValue] = Float(setup.equilibriumCake)
        v[P.bridgingCake.rawValue] = Float(setup.bridgingCake)
        v[P.cakeMobility.rawValue] = Float(setup.cakeMobility)
        v[P.finesInlet.rawValue] = Float(setup.finesInlet)
        v[P.filtrationCoefficient.rawValue] = Float(setup.filtrationCoefficient)
        v[P.damageCoefficient.rawValue] = Float(setup.damageCoefficient)
        v[P.maxRetention.rawValue] = Float(setup.maxRetention)
        v[P.filtrateDamageFactor.rawValue] = Float(setup.filtrateDamageFactor)
        v[P.outerResistance.rawValue] = Float(setup.outerResistance)
        v[P.wallFactor.rawValue] = Float(LiveInvasionSetup.wallFactor)
        v[P.dt.rawValue] = Float(dt)
        v[P.omega.rawValue] = overRelaxation
        v[P.colour.rawValue] = Float(colour)
        v[P.wellboreRadius.rawValue] = Float(setup.wellboreRadius)
        v[P.domainRadius.rawValue] = Float(setup.domainRadius)
        v[P.particleStep.rawValue] = particleStep * Float(setup.domainRadius)
        v[P.frame.rawValue] = Float(frame)
        v[P.maxSpeed.rawValue] = maxSpeed
        return v
    }
}
