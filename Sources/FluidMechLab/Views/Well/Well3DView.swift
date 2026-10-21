import AppKit
import FlowCore
import SceneKit
import SwiftUI

/// Options for the 3D model.
struct Scene3DOptions: Equatable {
    /// Radial exaggeration so pipe and damage radii are visible against depth.
    var radialExaggeration: Double = 60
    var showStrata = true
    var showCasing = true
    var showDamage = true
}

/// Interactive 3D model of the well path, strings, reservoir and damaged zone.
struct Well3DView: NSViewRepresentable {
    let well: WellModel
    let damage: MudInvasionResult?
    let options: Scene3DOptions

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .multisampling4X
        view.backgroundColor = .clear
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.inertiaEnabled = true
        Well3DSnapshotRegistry.shared.view = view
        update(view, resetCamera: true)
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        let signature = Signature(well: well, damageSkin: damage?.skin, options: options)
        if context.coordinator.signature != signature {
            let first = context.coordinator.signature == nil
            context.coordinator.signature = signature
            update(view, resetCamera: first || context.coordinator.wellName != well.name)
            context.coordinator.wellName = well.name
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    struct Signature: Equatable {
        let well: WellModel
        let damageSkin: Double?
        let options: Scene3DOptions
    }

    final class Coordinator {
        var signature: Signature?
        var wellName = ""
    }

    private func update(_ view: SCNView, resetCamera: Bool) {
        let builder = WellSceneBuilder(well: well, damage: damage, options: options)
        let scene = builder.build()
        let previousCamera = view.pointOfView
        view.scene = scene
        if resetCamera || previousCamera == nil {
            view.pointOfView = scene.rootNode.childNode(withName: "camera", recursively: false)
        } else if let previousCamera {
            scene.rootNode.addChildNode(previousCamera)
            view.pointOfView = previousCamera
        }
    }
}

/// Lets the CI snapshot tool grab the SceneKit view, which a plain view capture cannot render.
@MainActor
final class Well3DSnapshotRegistry {
    static let shared = Well3DSnapshotRegistry()
    weak var view: SCNView?
}

/// Builds the SceneKit scene. One scene unit = 100 ft; y is up (negative TVD).
struct WellSceneBuilder {
    let well: WellModel
    let damage: MudInvasionResult?
    let options: Scene3DOptions

    private let unit = 100.0

    private func point(atMD md: Double) -> SCNVector3 {
        let p = well.trajectory.position(atMD: md)
        let az = well.trajectory.azimuth * .pi / 180
        let north = p.displacement * cos(az)
        let east = p.displacement * sin(az)
        return SCNVector3(CGFloat(east / unit), CGFloat(-p.tvd / unit), CGFloat(-north / unit))
    }

    /// Radius in scene units for a diameter in inches, exaggerated.
    private func radius(diameterInches d: Double) -> CGFloat {
        CGFloat(d / 24 / unit * options.radialExaggeration)
    }

    func build() -> SCNScene {
        let scene = SCNScene()
        let root = scene.rootNode
        let tdTVD = well.trajectory.position(atMD: well.totalDepth).tvd
        let maxDisp = well.trajectory.position(atMD: well.totalDepth).displacement
        let halfWidth = CGFloat(max(maxDisp, 1500) / unit) * 0.75 + 6
        let centre = point(atMD: well.totalDepth)
        let centreX = centre.x / 2, centreZ = centre.z / 2

        // Lights.
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 450
        root.addChildNode(ambient)
        let sun = SCNNode()
        sun.light = SCNLight()
        sun.light?.type = .directional
        sun.light?.intensity = 900
        sun.eulerAngles = SCNVector3(-CGFloat.pi / 3, CGFloat.pi / 5, 0)
        root.addChildNode(sun)

        // Ground surface.
        let ground = SCNBox(width: halfWidth * 2, height: 0.25, length: halfWidth * 2, chamferRadius: 0)
        ground.firstMaterial = material(NSColor(calibratedRed: 0.42, green: 0.55, blue: 0.32, alpha: 0.9))
        let groundNode = SCNNode(geometry: ground)
        groundNode.position = SCNVector3(centreX, 0.125, centreZ)
        root.addChildNode(groundNode)

        // Overburden strata.
        if options.showStrata {
            let tops = stride(from: 0.0, to: well.reservoirTop, by: max(well.reservoirTop / 5, 500)).map { $0 }
            let palette: [NSColor] = [
                NSColor(calibratedRed: 0.78, green: 0.70, blue: 0.56, alpha: 1),
                NSColor(calibratedRed: 0.66, green: 0.64, blue: 0.60, alpha: 1),
                NSColor(calibratedRed: 0.74, green: 0.66, blue: 0.52, alpha: 1),
            ]
            for (i, top) in tops.enumerated() {
                let bottom = i + 1 < tops.count ? tops[i + 1] : well.reservoirTop
                addLayer(root, top: top, bottom: bottom, halfWidth: halfWidth, x: centreX, z: centreZ,
                         color: palette[i % palette.count].withAlphaComponent(0.10))
            }
        }

        // Reservoir slab.
        addLayer(root, top: well.reservoirTop, bottom: well.reservoirBottom, halfWidth: halfWidth, x: centreX, z: centreZ,
                 color: NSColor(calibratedRed: 0.95, green: 0.76, blue: 0.30, alpha: 0.45))
        // Underburden.
        addLayer(root, top: well.reservoirBottom, bottom: max(tdTVD, well.reservoirBottom) + 300, halfWidth: halfWidth, x: centreX, z: centreZ,
                 color: NSColor(calibratedRed: 0.55, green: 0.52, blue: 0.50, alpha: 0.12))

        // Open hole along the full path.
        let holeColor = NSColor(calibratedRed: 0.35, green: 0.25, blue: 0.18, alpha: 0.9)
        addTube(root, from: 0, to: well.totalDepth, radius: radius(diameterInches: well.reservoirBitSize) * 0.5 + 0.02, color: holeColor)

        // Casing strings (translucent steel).
        if options.showCasing {
            let sorted = well.casings.sorted { $0.outerDiameter > $1.outerDiameter }
            for (i, c) in sorted.enumerated() {
                let alpha = 0.18 + 0.12 * CGFloat(i)
                addTube(root, from: c.top, to: c.shoe, radius: radius(diameterInches: c.outerDiameter),
                        color: NSColor(calibratedWhite: 0.75, alpha: min(alpha, 0.6)), metallic: true)
            }
        }

        // Tubing.
        addTube(root, from: 0, to: well.tubing.shoe, radius: radius(diameterInches: well.tubing.outerDiameter),
                color: NSColor(calibratedRed: 0.20, green: 0.45, blue: 0.90, alpha: 1), metallic: true)

        // Packer.
        let packer = SCNCylinder(radius: radius(diameterInches: well.casings.map(\.innerDiameter).min() ?? 6), height: 0.25)
        packer.firstMaterial = material(.black)
        let packerNode = SCNNode(geometry: packer)
        packerNode.position = point(atMD: well.packerDepth)
        orient(packerNode, alongMD: well.packerDepth)
        root.addChildNode(packerNode)

        // Perforations and damaged zone.
        for perf in well.perforations {
            addTube(root, from: perf.top, to: perf.bottom, radius: radius(diameterInches: well.reservoirBitSize) * 0.5 + 0.06,
                    color: NSColor.systemRed.withAlphaComponent(0.9))
            if options.showDamage, let damage {
                let invasionInches = damage.filtrateInvasionDepth
                let outer = radius(diameterInches: well.reservoirBitSize + 2 * invasionInches) * 0.5 + 0.08
                let minRatio = damage.profile.map(\.permeabilityRatio).min() ?? 1
                addTube(root, from: perf.top - 10, to: perf.bottom + 10, radius: outer,
                        color: NSColor.systemRed.withAlphaComponent(CGFloat(0.12 + 0.4 * (1 - minRatio))))
                if damage.solidsInvasionDepth > 0 {
                    let solids = radius(diameterInches: well.reservoirBitSize + 2 * damage.solidsInvasionDepth) * 0.5 + 0.07
                    addTube(root, from: perf.top - 5, to: perf.bottom + 5, radius: solids,
                            color: NSColor.systemBrown.withAlphaComponent(0.55))
                }
            }
        }

        // Camera looking at the middle of the well from the side and slightly above.
        let camera = SCNNode()
        camera.name = "camera"
        camera.camera = SCNCamera()
        camera.camera?.zFar = 2000
        camera.camera?.fieldOfView = 40
        let span = CGFloat(max(tdTVD, maxDisp) / unit)
        let target = SCNVector3(centreX, CGFloat(-tdTVD / unit) * 0.55, centreZ)
        camera.position = SCNVector3(target.x + span * 1.05, target.y + span * 0.35, target.z + span * 1.05)
        camera.look(at: target)
        root.addChildNode(camera)

        return scene
    }

    private func material(_ color: NSColor, metallic: Bool = false) -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = color
        m.lightingModel = metallic ? .physicallyBased : .blinn
        if metallic {
            m.metalness.contents = 0.8
            m.roughness.contents = 0.35
        }
        m.transparency = color.alphaComponent
        m.isDoubleSided = color.alphaComponent < 1
        m.writesToDepthBuffer = color.alphaComponent > 0.5
        return m
    }

    private func addLayer(_ root: SCNNode, top: Double, bottom: Double, halfWidth: CGFloat, x: CGFloat, z: CGFloat, color: NSColor) {
        let h = CGFloat(max(bottom - top, 1) / unit)
        let box = SCNBox(width: halfWidth * 2, height: h, length: halfWidth * 2, chamferRadius: 0)
        box.firstMaterial = material(color)
        let node = SCNNode(geometry: box)
        node.position = SCNVector3(x, CGFloat(-(top + bottom) / 2 / unit), z)
        node.renderingOrder = -1
        root.addChildNode(node)
    }

    /// A tube following the trajectory between two measured depths, built from short cylinders.
    private func addTube(_ root: SCNNode, from md0: Double, to md1: Double, radius r: CGFloat, color: NSColor, metallic: Bool = false) {
        guard md1 > md0 else { return }
        let mat = material(color, metallic: metallic)
        let step = 100.0
        var a = md0
        while a < md1 - 1e-6 {
            let b = min(a + step, md1)
            let p0 = point(atMD: a), p1 = point(atMD: b)
            let length = distance(p0, p1)
            if length > 1e-6 {
                let cylinder = SCNCylinder(radius: r, height: length)
                cylinder.radialSegmentCount = 24
                cylinder.firstMaterial = mat
                let node = SCNNode(geometry: cylinder)
                node.position = SCNVector3((p0.x + p1.x) / 2, (p0.y + p1.y) / 2, (p0.z + p1.z) / 2)
                align(node, from: p0, to: p1)
                root.addChildNode(node)
            }
            a = b
        }
    }

    private func orient(_ node: SCNNode, alongMD md: Double) {
        align(node, from: point(atMD: md - 5), to: point(atMD: md + 5))
    }

    /// Rotates a node whose local y axis is its length so it points from `p0` to `p1`.
    private func align(_ node: SCNNode, from p0: SCNVector3, to p1: SCNVector3) {
        let d = SCNVector3(p1.x - p0.x, p1.y - p0.y, p1.z - p0.z)
        let len = sqrt(d.x * d.x + d.y * d.y + d.z * d.z)
        guard len > 0 else { return }
        let dir = SCNVector3(d.x / len, d.y / len, d.z / len)
        // Rotation from +y to dir: axis = y × dir, angle = acos(y · dir).
        let axis = SCNVector3(dir.z, 0, -dir.x)
        let axisLen = sqrt(axis.x * axis.x + axis.z * axis.z)
        let angle = acos(max(min(dir.y, 1), -1))
        if axisLen < 1e-6 {
            node.rotation = dir.y > 0 ? SCNVector4(1, 0, 0, 0) : SCNVector4(1, 0, 0, CGFloat.pi)
        } else {
            node.rotation = SCNVector4(axis.x / axisLen, 0, axis.z / axisLen, angle)
        }
    }

    private func distance(_ a: SCNVector3, _ b: SCNVector3) -> CGFloat {
        let dx = a.x - b.x, dy = a.y - b.y, dz = a.z - b.z
        return sqrt(dx * dx + dy * dy + dz * dz)
    }
}

/// The 3D Model pane: viewer plus floating controls and legend.
struct Model3DPane: View {
    let study: StudyCase
    @Environment(SimulationModel.self) private var sim
    @AppStorage("radialExaggeration") private var exaggeration = 60.0
    @State private var options = Scene3DOptions()

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Well3DView(well: study.well, damage: sim.damage, options: resolvedOptions)
                .background(
                    LinearGradient(colors: [Color(nsColor: .windowBackgroundColor), Color(red: 0.55, green: 0.68, blue: 0.82).opacity(0.35)],
                                   startPoint: .bottom, endPoint: .top))

            VStack(alignment: .leading, spacing: 8) {
                Text("View").font(.headline)
                Toggle("Rock layers", isOn: $options.showStrata)
                Toggle("Casing strings", isOn: $options.showCasing)
                Toggle("Damaged zone", isOn: $options.showDamage)
                Divider()
                Text("Radial exaggeration ×\(Int(exaggeration))").font(.caption)
                Slider(value: $exaggeration, in: 5...200).controlSize(.small).frame(width: 180)
                Text("Drag to orbit, scroll or pinch to zoom.").font(.caption2).foregroundStyle(.secondary)
            }
            .toggleStyle(.checkbox)
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(16)

            VStack(alignment: .trailing) {
                Spacer()
                Model3DLegend()
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(16)
        }
    }

    private var resolvedOptions: Scene3DOptions {
        var o = options
        o.radialExaggeration = exaggeration
        return o
    }
}

private struct Model3DLegend: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            row(.blue, "Tubing")
            row(.gray, "Casing")
            row(Color(red: 0.95, green: 0.76, blue: 0.30), "Reservoir")
            row(.red, "Perforations and filtrate zone")
            row(.brown, "Internal filter cake (fines)")
        }
        .font(.caption)
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func row(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 12, height: 12)
            Text(label)
        }
    }
}
