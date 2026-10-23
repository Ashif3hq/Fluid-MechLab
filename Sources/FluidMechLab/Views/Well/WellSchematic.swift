import FlowCore
import SwiftUI

/// Classic well-construction schematic: strings drawn by rank (not to radial scale), depth to scale.
struct WellSchematic: View {
    let well: WellModel
    var damage: MudInvasionResult?
    var highlightedCasing: UUID?

    @Environment(\.unitSystem) private var units
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Canvas { context, size in
            draw(in: &context, size: size)
        }
        .accessibilityLabel("Well schematic of \(well.name)")
    }

    // MARK: Layout

    private struct Layout {
        let size: CGSize
        let top: CGFloat = 28
        let bottom: CGFloat = 24
        let depthMax: Double
        let centreX: CGFloat
        let maxHalfWidth: CGFloat

        func y(_ md: Double) -> CGFloat {
            top + CGFloat(md / depthMax) * (size.height - top - bottom)
        }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let depthMax = max(well.totalDepth, 1) * 1.03
        let layout = Layout(size: size, depthMax: depthMax, centreX: size.width * 0.42, maxHalfWidth: min(size.width * 0.27, 150))

        let casings = well.casings.sorted { $0.outerDiameter > $1.outerDiameter }
        let ranks = casings.count + 2
        func halfWidth(rank: Int) -> CGFloat {
            layout.maxHalfWidth * CGFloat(ranks - rank) / CGFloat(ranks)
        }
        // Rank 0 = outermost hole; each string gets a casing line and a hole line just outside it.
        let tubingHalf = halfWidth(rank: ranks - 1) * 0.9
        let openHoleHalf = halfWidth(rank: ranks - 1) * 1.6

        drawStrata(&context, layout)

        // Reservoir band.
        let resTop = well.measuredDepth(atTVD: well.reservoirTop)
        let resBottom = well.measuredDepth(atTVD: well.reservoirBottom)
        let resRect = CGRect(x: 0, y: layout.y(resTop), width: size.width, height: max(layout.y(resBottom) - layout.y(resTop), 2))
        context.fill(Path(resRect), with: .color(Color(red: 0.93, green: 0.78, blue: 0.38).opacity(colorScheme == .dark ? 0.35 : 0.45)))
        drawDots(&context, in: resRect)
        context.draw(
            Text("Reservoir").font(.caption2.weight(.semibold)).foregroundColor(.brown),
            at: CGPoint(x: 56, y: resRect.maxY + 2), anchor: .topLeading)

        // Damaged zone around the perforations, width ∝ invasion depth (exaggerated).
        if let damage, let perfTop = well.perforations.map(\.top).min(), let perfBottom = well.perforations.map(\.bottom).max() {
            let reach = min(CGFloat(damage.filtrateInvasionDepth / 24), 1) * (layout.maxHalfWidth * 0.55) + 6
            let inner = halfWidth(rank: casings.count) + 2
            let rect = CGRect(x: layout.centreX - inner - reach, y: layout.y(perfTop - 15),
                              width: 2 * (inner + reach), height: layout.y(perfBottom + 15) - layout.y(perfTop - 15))
            let minRatio = damage.profile.map(\.permeabilityRatio).min() ?? 1
            let strong = Color.red.opacity(0.75 * (1 - minRatio) + 0.15)
            let edge = Double(reach / (2 * (inner + reach)))
            let gradient = Gradient(stops: [
                .init(color: .red.opacity(0), location: 0),
                .init(color: strong, location: edge),
                .init(color: strong, location: 1 - edge),
                .init(color: .red.opacity(0), location: 1),
            ])
            context.fill(Path(roundedRect: rect, cornerRadius: 6),
                         with: .linearGradient(gradient, startPoint: CGPoint(x: rect.minX, y: rect.midY), endPoint: CGPoint(x: rect.maxX, y: rect.midY)))
        }

        // Cement and casing strings, outermost first.
        for (i, c) in casings.enumerated() {
            let casingHalf = halfWidth(rank: i + 1)
            let holeHalf = i == 0 ? halfWidth(rank: 0) : min(halfWidth(rank: i) - 3, casingHalf + (halfWidth(rank: i) - casingHalf) * 0.85)
            let yTop = layout.y(c.top)
            let yShoe = layout.y(c.shoe)
            let yToc = layout.y(max(c.topOfCement, c.top))

            // Cement between hole wall and casing.
            if yShoe > yToc {
                for side in [-1.0, 1.0] {
                    let x0 = layout.centreX + CGFloat(side) * casingHalf
                    let x1 = layout.centreX + CGFloat(side) * holeHalf
                    let r = CGRect(x: min(x0, x1), y: yToc, width: abs(x1 - x0), height: yShoe - yToc)
                    context.fill(Path(r), with: .color(.gray.opacity(0.35)))
                    drawHatch(&context, in: r)
                }
            }
            // Casing walls.
            let highlighted = c.id == highlightedCasing
            let wall = GraphicsContext.Shading.color(highlighted ? .accentColor : (colorScheme == .dark ? .white.opacity(0.85) : .black.opacity(0.8)))
            for side in [-1.0, 1.0] {
                let x = layout.centreX + CGFloat(side) * casingHalf
                var p = Path()
                p.move(to: CGPoint(x: x, y: yTop))
                p.addLine(to: CGPoint(x: x, y: yShoe))
                context.stroke(p, with: wall, lineWidth: highlighted ? 4 : 3)
                // Shoe triangle pointing outward.
                var t = Path()
                t.move(to: CGPoint(x: x, y: yShoe))
                t.addLine(to: CGPoint(x: x + CGFloat(side) * 7, y: yShoe))
                t.addLine(to: CGPoint(x: x, y: yShoe - 9))
                t.closeSubpath()
                context.fill(t, with: wall)
            }
            // Label to the right.
            let labelY = yShoe
            let labelX = layout.centreX + layout.maxHalfWidth + 16
            var leader = Path()
            leader.move(to: CGPoint(x: layout.centreX + casingHalf + 8, y: labelY))
            leader.addLine(to: CGPoint(x: labelX - 4, y: labelY))
            context.stroke(leader, with: .color(.secondary.opacity(0.6)), style: StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
            let text = Text("\(pipeSizeLabel(c.outerDiameter)) \(c.name)\n").font(.caption.weight(.medium))
                + Text("Shoe \(Quantity.depth.format(c.shoe, digits: 0, in: units)) MD").font(.caption2).foregroundColor(.secondary)
            context.draw(text, at: CGPoint(x: labelX, y: labelY), anchor: .leading)
        }

        // Open hole below the deepest shoe, if any.
        let deepestShoe = casings.map(\.shoe).max() ?? 0
        if well.totalDepth > deepestShoe + 1 {
            for side in [-1.0, 1.0] {
                var p = Path()
                let x = layout.centreX + CGFloat(side) * openHoleHalf
                p.move(to: CGPoint(x: x, y: layout.y(deepestShoe)))
                p.addCurve(to: CGPoint(x: x, y: layout.y(well.totalDepth)),
                           control1: CGPoint(x: x + CGFloat(side) * 4, y: layout.y(deepestShoe) + 20),
                           control2: CGPoint(x: x - CGFloat(side) * 4, y: layout.y(well.totalDepth) - 20))
                context.stroke(p, with: .color(.brown), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
            }
        }

        // Perforations: red tunnels through the innermost casing into the rock.
        let innermostHalf = halfWidth(rank: casings.count)
        for perf in well.perforations {
            let y0 = layout.y(perf.top), y1 = layout.y(perf.bottom)
            let count = max(Int((y1 - y0) / 5), 2)
            for k in 0...count {
                let y = y0 + (y1 - y0) * CGFloat(k) / CGFloat(count)
                for side in [-1.0, 1.0] {
                    var p = Path()
                    p.move(to: CGPoint(x: layout.centreX + CGFloat(side) * (innermostHalf - 2), y: y))
                    p.addLine(to: CGPoint(x: layout.centreX + CGFloat(side) * (innermostHalf + 18), y: y))
                    context.stroke(p, with: .color(.red), lineWidth: 1.5)
                }
            }
        }

        // Tubing.
        let tubingColor = GraphicsContext.Shading.color(Color(red: 0.2, green: 0.45, blue: 0.85))
        for side in [-1.0, 1.0] {
            var p = Path()
            let x = layout.centreX + CGFloat(side) * tubingHalf
            p.move(to: CGPoint(x: x, y: layout.y(0)))
            p.addLine(to: CGPoint(x: x, y: layout.y(well.tubing.shoe)))
            context.stroke(p, with: tubingColor, lineWidth: 2)
        }
        // Packer.
        let packerY = layout.y(well.packerDepth)
        for side in [-1.0, 1.0] {
            let x0 = layout.centreX + CGFloat(side) * tubingHalf
            let x1 = layout.centreX + CGFloat(side) * (innermostHalf - 1.5)
            let r = CGRect(x: min(x0, x1), y: packerY - 5, width: abs(x1 - x0), height: 10)
            context.fill(Path(roundedRect: r, cornerRadius: 1.5), with: .color(colorScheme == .dark ? .white.opacity(0.9) : .black))
            var x = Path()
            x.move(to: CGPoint(x: r.minX, y: r.minY)); x.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            x.move(to: CGPoint(x: r.maxX, y: r.minY)); x.addLine(to: CGPoint(x: r.minX, y: r.maxY))
            context.stroke(x, with: .color(colorScheme == .dark ? .black : .white), lineWidth: 1)
        }
        var packerLeader = Path()
        packerLeader.move(to: CGPoint(x: layout.centreX - innermostHalf - 4, y: packerY))
        packerLeader.addLine(to: CGPoint(x: 60, y: packerY))
        context.stroke(packerLeader, with: .color(.secondary.opacity(0.6)), style: StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
        context.draw(Text("Packer").font(.caption2).foregroundColor(.secondary),
                     at: CGPoint(x: 58, y: packerY - 2), anchor: .bottomLeading)

        // Wellhead.
        let headRect = CGRect(x: layout.centreX - halfWidth(rank: 1) - 6, y: layout.top - 18, width: 2 * (halfWidth(rank: 1) + 6), height: 14)
        context.fill(Path(roundedRect: headRect, cornerRadius: 3), with: .color(.gray))
        context.draw(Text("Wellhead").font(.caption2).foregroundColor(.secondary),
                     at: CGPoint(x: headRect.maxX + 6, y: headRect.midY), anchor: .leading)

        drawDepthAxis(&context, layout)
    }

    private func drawStrata(_ context: inout GraphicsContext, _ layout: Layout) {
        let colors: [Color] = [
            Color(red: 0.80, green: 0.74, blue: 0.62), Color(red: 0.72, green: 0.70, blue: 0.64),
            Color(red: 0.78, green: 0.70, blue: 0.58), Color(red: 0.68, green: 0.66, blue: 0.62),
        ]
        let bands = 7
        for i in 0..<bands {
            let y0 = layout.y(layout.depthMax * Double(i) / Double(bands))
            let y1 = layout.y(layout.depthMax * Double(i + 1) / Double(bands))
            let r = CGRect(x: 0, y: y0, width: layout.size.width, height: y1 - y0)
            context.fill(Path(r), with: .color(colors[i % colors.count].opacity(colorScheme == .dark ? 0.16 : 0.22)))
        }
    }

    private func drawHatch(_ context: inout GraphicsContext, in rect: CGRect) {
        guard rect.width > 1, rect.height > 1 else { return }
        var ctx = context
        ctx.clip(to: Path(rect))
        var p = Path()
        var x = rect.minX - rect.height
        while x < rect.maxX {
            p.move(to: CGPoint(x: x, y: rect.maxY))
            p.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += 7
        }
        ctx.stroke(p, with: .color(.gray.opacity(0.5)), lineWidth: 0.5)
    }

    private func drawDots(_ context: inout GraphicsContext, in rect: CGRect) {
        var ctx = context
        ctx.clip(to: Path(rect))
        var y = rect.minY + 3
        var row = 0
        while y < rect.maxY {
            var x = rect.minX + (row % 2 == 0 ? 3 : 8)
            while x < rect.maxX {
                ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.6, height: 1.6)), with: .color(.brown.opacity(0.45)))
                x += 10
            }
            y += 6
            row += 1
        }
    }

    private func drawDepthAxis(_ context: inout GraphicsContext, _ layout: Layout) {
        let displayMax = Quantity.depth.display(layout.depthMax, in: units)
        let step = niceStep(displayMax / 8)
        var d = 0.0
        while d <= displayMax {
            let md = Quantity.depth.engine(d, from: units)
            let y = layout.y(md)
            var tick = Path()
            tick.move(to: CGPoint(x: 44, y: y))
            tick.addLine(to: CGPoint(x: 50, y: y))
            context.stroke(tick, with: .color(.secondary), lineWidth: 0.5)
            context.draw(Text(d.formatted(digits: 0)).font(.caption2.monospacedDigit()).foregroundColor(.secondary),
                         at: CGPoint(x: 40, y: y), anchor: .trailing)
            d += step
        }
        var axis = Path()
        axis.move(to: CGPoint(x: 50, y: layout.top))
        axis.addLine(to: CGPoint(x: 50, y: layout.size.height - layout.bottom))
        context.stroke(axis, with: .color(.secondary.opacity(0.6)), lineWidth: 0.5)
        context.draw(Text("MD (\(Quantity.depth.symbol(units)))").font(.caption2.weight(.semibold)).foregroundColor(.secondary),
                     at: CGPoint(x: 8, y: 10), anchor: .leading)
    }
}

/// 1, 2, 5 × 10ⁿ step close to `raw`.
func niceStep(_ raw: Double) -> Double {
    guard raw > 0 else { return 1 }
    let exponent = floor(log10(raw))
    let base = pow(10, exponent)
    let f = raw / base
    let nice: Double = f < 1.5 ? 1 : f < 3.5 ? 2 : f < 7.5 ? 5 : 10
    return nice * base
}
