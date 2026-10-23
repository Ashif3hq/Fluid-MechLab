import FlowCore
import Foundation
import Metal

/// Runs the 3D invasion model (`Invasion3DSolver`) on the GPU with Metal compute.
///
/// Each cycle solves the pressure equation to tolerance (red-black line SOR, checked by the largest local
/// correction and by the balance of wall inflow against outer outflow), computes the face flow rates, and then
/// takes the transport steps the Courant and cake-coupling limits allow. Buffers use shared storage, so on
/// Apple Silicon the CPU reads results straight from unified memory.
public final class Invasion3DGPU {
    public let setup: Invasion3DSetup
    public let device: MTLDevice
    /// Encode rendering on this queue so it runs after the simulation work.
    public let queue: MTLCommandQueue
    public let pressure: MTLBuffer
    public let mobility: MTLBuffer
    public let k0: MTLBuffer
    public let flux: MTLBuffer
    public let speed: MTLBuffer

    public var omega: Float = 1.85
    /// Line sweeps per convergence check.
    public var sweepsPerCheck = 8
    public var maxSweeps = 6000
    /// Largest local pressure correction accepted as converged.
    public var correctionTolerance: Float = 2e-6

    public private(set) var time = 0.0
    public private(set) var injected = 0.0
    public private(set) var pressureSolves = 0
    public private(set) var transportSteps = 0
    public private(set) var lastIterations = 0
    public private(set) var lastImbalance = 0.0
    public private(set) var lastCorrection: Float = 0
    public private(set) var lastWallInflow = 0.0

    private var states: [MTLBuffer]
    private var current = 0
    private let geometry: MTLBuffer
    private let cPrime: MTLBuffer
    private let dPrime: MTLBuffer
    private let maxima: MTLBuffer
    private let outflowBuffer: MTLBuffer
    private var skinPressure: MTLBuffer?
    private let mobilityPipeline, linePipeline, residualPipeline, fluxPipeline, transportPipeline, displayPipeline: MTLComputePipelineState

    /// Per cell: (filtrate saturation, suspended fines, retained fines, cake thickness in m on the wall cell of each column).
    public var stateBuffer: MTLBuffer { states[current] }
    public var isFinished: Bool { time >= setup.exposureTime * (1 - 1e-9) }

    public init(setup: Invasion3DSetup, device: MTLDevice? = MTLCreateSystemDefaultDevice()) throws {
        guard let device else { throw LiveInvasionGPUError.noDevice }
        guard let queue = device.makeCommandQueue() else { throw LiveInvasionGPUError.allocation }
        self.setup = setup
        self.device = device
        self.queue = queue

        let library: MTLLibrary
        do {
            let options = MTLCompileOptions()
            // Precise math: the Kahan sums and the thin-cake series rely on it.
            options.fastMathEnabled = false
            library = try device.makeLibrary(source: Invasion3DShaders.source, options: options)
        } catch {
            throw LiveInvasionGPUError.compile(error.localizedDescription)
        }
        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else { throw LiveInvasionGPUError.compile("missing \(name)") }
            return try device.makeComputePipelineState(function: function)
        }
        mobilityPipeline = try pipeline("mobility3D")
        linePipeline = try pipeline("line3D")
        residualPipeline = try pipeline("residual3D")
        fluxPipeline = try pipeline("flux3D")
        transportPipeline = try pipeline("transport3D")
        displayPipeline = try pipeline("display3D")

        func buffer<T>(_ values: [T]) throws -> MTLBuffer {
            guard let b = values.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: max($0.count, 16), options: .storageModeShared) }) else {
                throw LiveInvasionGPUError.allocation
            }
            return b
        }
        let n = setup.cellCount
        pressure = try buffer(setup.radialPressure().map(Float.init))
        mobility = try buffer(setup.k0)
        k0 = try buffer(setup.k0)
        flux = try buffer([SIMD4<Float>](repeating: .zero, count: n))
        speed = try buffer([Float](repeating: 0, count: n))
        let empty = [SIMD4<Float>](repeating: .zero, count: n)
        states = [try buffer(empty), try buffer(empty), try buffer(empty)]
        let geo = setup.faces + setup.area + setup.volume + setup.halfAxial
        geometry = try buffer(geo.map(Float.init))
        cPrime = try buffer([Float](repeating: 0, count: n))
        dPrime = try buffer([Float](repeating: 0, count: n))
        maxima = try buffer([UInt32](repeating: 0, count: 4))
        outflowBuffer = try buffer([SIMD2<Float>](repeating: .zero, count: setup.columnCount))
    }

    // MARK: Stepping

    /// Advances by up to `target` seconds, stopping early when `budget` seconds of wall-clock time have passed.
    /// Returns the simulated time covered.
    @discardableResult
    public func advance(by target: Double, budget: Double = .infinity, maxCycles: Int = .max) -> Double {
        let end = min(time + target, setup.exposureTime)
        let start = time
        let clock = Date()
        var cycles = 0
        while time < end * (1 - 1e-12) && cycles < maxCycles {
            guard cycle(upTo: end) else { break }
            cycles += 1
            if Date().timeIntervalSince(clock) > budget { break }
        }
        return time - start
    }

    /// One pressure solve and the transport steps it allows. Returns false if the GPU could not take a step.
    @discardableResult
    public func cycle(upTo end: Double) -> Bool {
        // Mobility, then pressure to tolerance.
        guard let first = queue.makeCommandBuffer(), let encoder = first.makeComputeCommandEncoder() else { return false }
        dispatchCells(encoder, mobilityPipeline, buffers: [mobility, k0, stateBuffer], params: params())
        encoder.endEncoding()
        first.commit()
        let result = solvePressure(pressure: pressure, mobility: mobility, noCake: false)
        lastIterations = result.sweeps
        lastImbalance = result.imbalance
        lastCorrection = result.correction
        pressureSolves += 1

        // Fluxes and step limits.
        guard let second = queue.makeCommandBuffer() else { return false }
        resetMaxima(second)
        guard let fluxEncoder = second.makeComputeCommandEncoder() else { return false }
        dispatchCells(fluxEncoder, fluxPipeline, buffers: [flux, speed, pressure, mobility, stateBuffer, maxima, geometry], params: params())
        fluxEncoder.endEncoding()
        second.commit()
        second.waitUntilCompleted()

        let limits = readMaxima()
        let inflow = wallInflow()
        lastWallInflow = inflow
        let step = setup.courant / max(Double(limits.rate), 1e-300)
        let cakeLimit = limits.cake > 0 ? setup.options.cakeCoupling / Double(limits.cake) : .infinity
        let span = min(cakeLimit, Double(setup.options.maxStepsPerPressureSolve) * step, end - time)
        guard span > 0, span.isFinite else { return false }
        let count = max(1, Int((span / step - 1e-9).rounded(.up)))
        let dt = span / Double(count)

        // Transport steps. Later work on `queue` (such as rendering) runs after these.
        guard let third = queue.makeCommandBuffer(), let transport = third.makeComputeCommandEncoder() else { return false }
        let tvd = setup.options.scheme == .tvd
        for _ in 0..<count {
            let others = [0, 1, 2].filter { $0 != current }
            if tvd {
                dispatchCells(transport, transportPipeline,
                              buffers: [states[others[0]], states[current], states[current], flux, speed, outflowBuffer, geometry],
                              params: params(dt: dt, weight: 0, outflowWeight: 0.5))
                dispatchCells(transport, transportPipeline,
                              buffers: [states[others[1]], states[others[0]], states[current], flux, speed, outflowBuffer, geometry],
                              params: params(dt: dt, weight: 0.5, outflowWeight: 0.5))
                current = others[1]
            } else {
                dispatchCells(transport, transportPipeline,
                              buffers: [states[others[0]], states[current], states[current], flux, speed, outflowBuffer, geometry],
                              params: params(dt: dt, weight: 0, outflowWeight: 1))
                current = others[0]
            }
        }
        transport.endEncoding()
        third.commit()
        transportSteps += count
        injected += inflow * span
        time += span
        return true
    }

    /// Blocks until queued GPU work finishes. Tests and exports use this before reading buffers.
    public func waitUntilIdle() {
        guard let buffer = queue.makeCommandBuffer() else { return }
        buffer.commit()
        buffer.waitUntilCompleted()
    }

    // MARK: Pressure

    /// Red-black line SOR until the largest local correction and the inflow-outflow imbalance are within tolerance.
    private func solvePressure(pressure p: MTLBuffer, mobility m: MTLBuffer, noCake: Bool) -> (sweeps: Int, imbalance: Double, correction: Float) {
        var sweeps = 0
        var imbalance = 1.0
        var correction: Float = 1
        let tolerance = setup.options.pressureTolerance
        repeat {
            guard let buffer = queue.makeCommandBuffer() else { break }
            resetMaxima(buffer)
            guard let encoder = buffer.makeComputeCommandEncoder() else { break }
            for _ in 0..<sweepsPerCheck {
                for colour in 0..<2 {
                    dispatchColumns(encoder, linePipeline, buffers: [p, m, stateBuffer, cPrime, dPrime, geometry],
                                    params: params(colour: colour, noCake: noCake))
                }
            }
            dispatchCells(encoder, residualPipeline, buffers: [p, m, stateBuffer, maxima, geometry], params: params(noCake: noCake))
            encoder.endEncoding()
            buffer.commit()
            buffer.waitUntilCompleted()
            sweeps += sweepsPerCheck
            correction = readMaxima().correction
            imbalance = flowImbalance(pressure: p, mobility: m, noCake: noCake).imbalance
        } while (imbalance > tolerance || correction > correctionTolerance) && sweeps < maxSweeps
        return (sweeps, imbalance, correction)
    }

    /// Wall inflow and outer outflow of a pressure field (normalised units), and their relative difference.
    private func flowImbalance(pressure: MTLBuffer, mobility: MTLBuffer, noCake: Bool) -> (inflow: Double, imbalance: Double) {
        let n = setup.cellCount
        let p = pressure.contents().bindMemory(to: Float.self, capacity: n)
        let m = mobility.contents().bindMemory(to: Float.self, capacity: n)
        let state = stateBuffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: n)
        let hr = setup.halfRadial
        var inflow = 0.0, outflowSum = 0.0
        for k in 0..<setup.nz {
            for j in 0..<setup.nt {
                let a = setup.index(0, j, k)
                let cake = noCake ? 0 : Double(state[a].w)
                inflow += (1 - Double(p[a])) / (hr / Double(m[a]) + setup.cakeResistance(cake))
                let last = setup.index(setup.nr - 1, j, k)
                outflowSum += Double(p[last]) / (hr / Double(m[last]) + setup.outerResistance)
            }
        }
        return (inflow, abs(inflow - outflowSum) / max(abs(inflow), 1e-300))
    }

    // MARK: Reading results

    /// Filtrate entering through the wall at the last pressure solve, m³/s.
    private func wallInflow() -> Double {
        let f = flux.contents().bindMemory(to: SIMD4<Float>.self, capacity: setup.cellCount)
        var total = 0.0
        for k in 0..<setup.nz {
            for j in 0..<setup.nt { total += max(Double(f[setup.index(0, j, k)].x), 0) }
        }
        return total
    }

    /// Filtrate that has left through the outer boundary, m³.
    public var outflow: Double {
        let o = outflowBuffer.contents().bindMemory(to: SIMD2<Float>.self, capacity: setup.columnCount)
        var total = 0.0
        for col in 0..<setup.columnCount { total += Double(o[col].x) - Double(o[col].y) }
        return total
    }

    public var stats: Invasion3DStats {
        let n = setup.cellCount
        let state = stateBuffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: n)
        var s = Invasion3DMetrics.stats(
            setup: setup, time: time, wallInflow: lastWallInflow, injected: injected, outflow: outflow,
            saturation: { Double(state[$0].x) }, retained: { Double(state[$0].z) },
            cake: { Double(state[$0 * self.setup.nr].w) })
        s.pressureSolves = pressureSolves
        s.lastIterations = lastIterations
        s.lastImbalance = lastImbalance
        s.transportSteps = transportSteps
        return s
    }

    /// Copies the per-cell state out of GPU memory.
    public func readState() -> [SIMD4<Float>] {
        let n = setup.cellCount
        return Array(UnsafeBufferPointer(start: stateBuffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: n), count: n))
    }

    public func readPressure() -> [Float] {
        let n = setup.cellCount
        return Array(UnsafeBufferPointer(start: pressure.contents().bindMemory(to: Float.self, capacity: n), count: n))
    }

    /// A snapshot of the fields for export, in double precision.
    public func snapshot() -> Invasion3DSnapshot {
        waitUntilIdle()
        let state = readState()
        let p = readPressure()
        var cake = [Double](repeating: 0, count: setup.columnCount)
        for col in 0..<setup.columnCount { cake[col] = Double(state[col * setup.nr].w) }
        return Invasion3DSnapshot(
            setup: setup, time: time, pressure: p.map(Double.init),
            saturation: state.map { Double($0.x) }, fines: state.map { Double($0.y) }, retained: state.map { Double($0.z) },
            cake: cake)
    }

    /// Skin of the damaged zone with the cake removed, from two steady GPU solves (see `Invasion3DSolver.skin`).
    public func computeSkin() -> Double {
        waitUntilIdle()
        guard let buffer = queue.makeCommandBuffer(), let encoder = buffer.makeComputeCommandEncoder() else { return .nan }
        dispatchCells(encoder, mobilityPipeline, buffers: [mobility, k0, stateBuffer], params: params())
        encoder.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        if skinPressure == nil {
            skinPressure = device.makeBuffer(length: setup.cellCount * MemoryLayout<Float>.stride, options: .storageModeShared)
        }
        guard let scratch = skinPressure else { return .nan }
        func rate(_ m: MTLBuffer) -> Double {
            let radial = setup.radialPressure().map(Float.init)
            radial.withUnsafeBytes { scratch.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
            _ = solvePressure(pressure: scratch, mobility: m, noCake: true)
            return flowImbalance(pressure: scratch, mobility: m, noCake: true).inflow
        }
        let q0 = rate(k0), qd = rate(mobility)
        return (q0 / max(qd, 1e-300) - 1) * log(setup.boundaryRadius / setup.wellboreRadius)
    }

    // MARK: Display

    /// Fills the display textures: a 3D texture (nr × nt × nz, rgba16Float) of (field value, saturation, k/k₀, σ/σmax)
    /// and a 2D texture (nt × nz, r16Float or wider) of cake thickness in mm.
    public func encodeDisplay(_ encoder: MTLComputeCommandEncoder, volume: MTLTexture, cake: MTLTexture, field: Int) {
        var values = params(field: field)
        encoder.setComputePipelineState(displayPipeline)
        encoder.setTexture(volume, index: 0)
        encoder.setTexture(cake, index: 1)
        encoder.setBuffer(stateBuffer, offset: 0, index: 0)
        encoder.setBuffer(pressure, offset: 0, index: 1)
        encoder.setBuffer(k0, offset: 0, index: 2)
        encoder.setBytes(&values, length: values.count * MemoryLayout<Float>.stride, index: 3)
        let size = MTLSize(width: 4, height: 8, depth: 8)
        encoder.dispatchThreadgroups(
            MTLSize(width: (setup.nr + 3) / 4, height: (setup.nt + 7) / 8, depth: (setup.nz + 7) / 8),
            threadsPerThreadgroup: size)
    }

    // MARK: Helpers

    private func resetMaxima(_ buffer: MTLCommandBuffer) {
        guard let blit = buffer.makeBlitCommandEncoder() else { return }
        blit.fill(buffer: maxima, range: 0..<maxima.length, value: 0)
        blit.endEncoding()
    }

    private func readMaxima() -> (rate: Float, cake: Float, correction: Float) {
        let m = maxima.contents().bindMemory(to: UInt32.self, capacity: 4)
        return (Float(bitPattern: m[0]), Float(bitPattern: m[1]), Float(bitPattern: m[2]))
    }

    private func dispatchCells(_ encoder: MTLComputeCommandEncoder, _ pipeline: MTLComputePipelineState, buffers: [MTLBuffer], params: [Float]) {
        var values = params
        encoder.setComputePipelineState(pipeline)
        for (index, buffer) in buffers.enumerated() { encoder.setBuffer(buffer, offset: 0, index: index) }
        encoder.setBytes(&values, length: values.count * MemoryLayout<Float>.stride, index: buffers.count)
        let width = 256
        encoder.dispatchThreadgroups(MTLSize(width: (setup.cellCount + width - 1) / width, height: 1, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
    }

    private func dispatchColumns(_ encoder: MTLComputeCommandEncoder, _ pipeline: MTLComputePipelineState, buffers: [MTLBuffer], params: [Float]) {
        var values = params
        encoder.setComputePipelineState(pipeline)
        for (index, buffer) in buffers.enumerated() { encoder.setBuffer(buffer, offset: 0, index: index) }
        encoder.setBytes(&values, length: values.count * MemoryLayout<Float>.stride, index: buffers.count)
        encoder.dispatchThreadgroups(MTLSize(width: (setup.nt + 15) / 16, height: (setup.nz + 3) / 4, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: 16, height: 4, depth: 1))
    }

    private func params(dt: Double = 0, weight: Double = 0, outflowWeight: Double = 0, colour: Int = 0,
                        noCake: Bool = false, field: Int = 0) -> [Float] {
        typealias P = Invasion3DShaders.P
        let s = setup
        var v = [Float](repeating: 0, count: P.allCases.count)
        v[P.nr.rawValue] = Float(s.nr)
        v[P.nt.rawValue] = Float(s.nt)
        v[P.nz.rawValue] = Float(s.nz)
        v[P.dTheta.rawValue] = Float(s.dTheta)
        v[P.dz.rawValue] = Float(s.dz)
        v[P.halfRadial.rawValue] = Float(s.halfRadial)
        v[P.halfAngular.rawValue] = Float(s.halfAngular)
        v[P.anisotropy.rawValue] = Float(s.anisotropy)
        v[P.outerResistance.rawValue] = Float(s.outerResistance)
        v[P.velocityScale.rawValue] = Float(s.velocityScale)
        v[P.porosity.rawValue] = Float(s.porosity)
        v[P.displaceablePorosity.rawValue] = Float(s.displaceablePorosity)
        v[P.cakeGrowth.rawValue] = Float(s.cakeGrowth)
        v[P.equilibriumCake.rawValue] = Float(s.equilibriumCake)
        v[P.bridgingCake.rawValue] = Float(s.bridgingCake)
        v[P.cakeMobility.rawValue] = Float(s.cakeMobility)
        v[P.finesInlet.rawValue] = Float(s.finesInlet)
        v[P.filtrationCoefficient.rawValue] = Float(s.filtrationCoefficient)
        v[P.damageCoefficient.rawValue] = Float(s.damageCoefficient)
        v[P.maxRetention.rawValue] = Float(s.maxRetention)
        v[P.filtrateDamageFactor.rawValue] = Float(s.filtrateDamageFactor)
        v[P.wellboreRadius.rawValue] = Float(s.wellboreRadius)
        v[P.dt.rawValue] = Float(dt)
        v[P.weight.rawValue] = Float(weight)
        v[P.secondOrder.rawValue] = s.options.scheme == .tvd ? 1 : 0
        v[P.outflowWeight.rawValue] = Float(outflowWeight)
        v[P.omega.rawValue] = omega
        v[P.colour.rawValue] = Float(colour)
        v[P.noCake.rawValue] = noCake ? 1 : 0
        v[P.field.rawValue] = Float(field)
        return v
    }
}
