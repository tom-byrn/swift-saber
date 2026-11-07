import AppKit
import SceneKit
import simd
import SaberCore

/// The "Prism Hall" stage: a reflective runway in a dark void, receding octagonal prism rings,
/// sweeping laser fans and a horizon emblem. Every light is driven by the beatmap's light events.
final class PrismHallStage: Stage {
    private var rings: [SCNNode] = []
    private var ringAngles: [Double] = []
    private var ringSpinVelocity: Double = 0.15
    private var ringSpinTarget: Double = 0.15
    private var ringSpacing: Double = 7
    private var ringSpacingTarget: Double = 7

    private var leftLasers: [SCNNode] = []
    private var rightLasers: [SCNNode] = []
    private var laserPhase: [LightGroup: Double] = [.leftLasers: 0, .rightLasers: 1.7]

    private var backLight: SCNLight?

    override func build() {
        buildFloor()
        buildRings()
        buildLasers()
        buildBack()
        addBaseLights()
        backLight = makeGroupLight(at: SCNVector3(0, 10, -26))
        addDust()
    }

    // MARK: Build

    private func buildFloor() {
        addFloor()
        let trimMat = groupMaterial(.floor)
        addPlatform(trimMaterial: trimMat)

        // Runway rails.
        let rails = SCNNode()
        for x in [-1.45, 1.45] {
            let b = SCNBox(width: 0.035, height: 0.015, length: 150, chamferRadius: 0)
            b.materials = [trimMat]
            let n = SCNNode(geometry: b)
            n.position = SCNVector3(x, 0.008, -75.8)
            rails.addChildNode(n)
        }
        // Dashed centre line.
        for i in 0..<36 {
            let b = SCNBox(width: 0.02, height: 0.01, length: 1.4, chamferRadius: 0)
            b.materials = [trimMat]
            let n = SCNNode(geometry: b)
            n.position = SCNVector3(0, 0.006, -2.5 - Double(i) * 4)
            rails.addChildNode(n)
        }
        // Side light pillars.
        let pillarBody = Materials.metal(NSColor(calibratedWhite: 0.03, alpha: 1), roughness: 0.4, metalness: 0.8)
        for side in [-1.0, 1.0] {
            for i in 0..<10 {
                let z = -14.0 - Double(i) * 11
                let x = side * (7.5 + Double(i % 2) * 1.5)
                let body = SCNBox(width: 0.6, height: 14, length: 0.6, chamferRadius: 0.02)
                body.materials = [pillarBody]
                let bn = SCNNode(geometry: body)
                bn.position = SCNVector3(x, 7, z)
                rails.addChildNode(bn)
                let strip = SCNBox(width: 0.06, height: 13.6, length: 0.06, chamferRadius: 0)
                strip.materials = [trimMat]
                let sn = SCNNode(geometry: strip)
                sn.position = SCNVector3(x - side * 0.31, 7, z)
                rails.addChildNode(sn)
            }
        }
        root.addChildNode(rails.flattenedClone())
    }

    private func buildRings() {
        let mat = groupMaterial(.rings)
        let glow = groupMaterial(.rings, glow: true)
        let sides = 8
        let radius = 8.0
        for i in 0..<16 {
            let ring = SCNNode()
            for s in 0..<sides {
                let a0 = Double(s) / Double(sides) * 2 * .pi
                let a1 = Double(s + 1) / Double(sides) * 2 * .pi
                let p0 = SIMD2(cos(a0) * radius, sin(a0) * radius)
                let p1 = SIMD2(cos(a1) * radius, sin(a1) * radius)
                let mid = (p0 + p1) / 2
                let len = simd_length(p1 - p0)
                let beam = SCNBox(width: CGFloat(len) * 0.92, height: 0.07, length: 0.07, chamferRadius: 0)
                beam.materials = [mat]
                let bn = SCNNode(geometry: beam)
                bn.position = SCNVector3(mid.x, mid.y, 0)
                bn.eulerAngles.z = CGFloat(atan2(p1.y - p0.y, p1.x - p0.x))
                ring.addChildNode(bn)
                let shell = SCNBox(width: CGFloat(len) * 0.92, height: 0.28, length: 0.28, chamferRadius: 0.1)
                shell.materials = [glow]
                let sn = SCNNode(geometry: shell)
                sn.position = bn.position
                sn.eulerAngles = bn.eulerAngles
                ring.addChildNode(sn)
            }
            // Dark frame behind the neon so rings read as solid prisms.
            let frame = SCNTorus(ringRadius: CGFloat(radius) * 1.02, pipeRadius: 0.25)
            frame.ringSegmentCount = 8
            frame.pipeSegmentCount = 4
            frame.materials = [Materials.metal(NSColor(calibratedWhite: 0.04, alpha: 1), roughness: 0.3, metalness: 0.9)]
            let fn = SCNNode(geometry: frame)
            fn.eulerAngles.x = .pi / 2
            fn.position = SCNVector3(0, 0, -0.3)
            ring.addChildNode(fn)

            let flat = ring.flattenedClone()
            let holder = SCNNode()
            holder.addChildNode(flat)
            holder.position = SCNVector3(0, 4.5, -20 - Double(i) * ringSpacing)
            root.addChildNode(holder)
            rings.append(holder)
            ringAngles.append(Double(i) * 0.12)
        }
    }

    private func buildLasers() {
        for (group, side) in [(LightGroup.leftLasers, -1.0), (LightGroup.rightLasers, 1.0)] {
            let mat = groupMaterial(group)
            let glow = groupMaterial(group, glow: true)
            for i in 0..<5 {
                let pivot = SCNNode()
                pivot.position = SCNVector3(side * (11 + Double(i) * 2.2), 0, -28 - Double(i) * 9)
                let beam = SCNCylinder(radius: 0.05, height: 90)
                beam.radialSegmentCount = 6
                beam.materials = [mat]
                let bn = SCNNode(geometry: beam)
                bn.position = SCNVector3(0, 45, 0)
                pivot.addChildNode(bn)
                let shell = SCNCylinder(radius: 0.22, height: 90)
                shell.radialSegmentCount = 8
                shell.materials = [glow]
                let sn = SCNNode(geometry: shell)
                sn.position = bn.position
                pivot.addChildNode(sn)
                root.addChildNode(pivot)
                if group == .leftLasers { leftLasers.append(pivot) } else { rightLasers.append(pivot) }
            }
        }
    }

    private func buildBack() {
        let mat = groupMaterial(.back)
        let glow = groupMaterial(.back, glow: true)
        let back = SCNNode()
        // Horizon bar.
        let bar = SCNBox(width: 90, height: 0.25, length: 0.2, chamferRadius: 0)
        bar.materials = [mat]
        let barNode = SCNNode(geometry: bar)
        barNode.position = SCNVector3(0, 2.2, -140)
        back.addChildNode(barNode)
        let barGlow = SCNBox(width: 90, height: 1.6, length: 0.4, chamferRadius: 0)
        barGlow.materials = [glow]
        let bg = SCNNode(geometry: barGlow)
        bg.position = barNode.position
        back.addChildNode(bg)

        // Emblem: two nested prisms (hexagon + inverted triangle).
        func polygon(sides: Int, radius: Double, rotation: Double, thickness: CGFloat, center: SCNVector3) {
            for s in 0..<sides {
                let a0 = rotation + Double(s) / Double(sides) * 2 * .pi
                let a1 = rotation + Double(s + 1) / Double(sides) * 2 * .pi
                let p0 = SIMD2(cos(a0) * radius, sin(a0) * radius)
                let p1 = SIMD2(cos(a1) * radius, sin(a1) * radius)
                let mid = (p0 + p1) / 2
                let len = simd_length(p1 - p0)
                let b = SCNBox(width: CGFloat(len), height: thickness, length: thickness, chamferRadius: 0)
                b.materials = [mat]
                let n = SCNNode(geometry: b)
                n.position = SCNVector3(center.x + CGFloat(mid.x), center.y + CGFloat(mid.y), center.z)
                n.eulerAngles.z = CGFloat(atan2(p1.y - p0.y, p1.x - p0.x))
                back.addChildNode(n)
                let g = SCNBox(width: CGFloat(len), height: thickness * 5, length: thickness * 2, chamferRadius: 0)
                g.materials = [glow]
                let gn = SCNNode(geometry: g)
                gn.position = n.position
                gn.eulerAngles = n.eulerAngles
                back.addChildNode(gn)
            }
        }
        let center = SCNVector3(0, 16, -138)
        polygon(sides: 6, radius: 9, rotation: .pi / 6, thickness: 0.35, center: center)
        polygon(sides: 3, radius: 5.2, rotation: -.pi / 2, thickness: 0.3, center: center)
        root.addChildNode(back.flattenedClone())
    }

    // MARK: Events

    override func idle() {
        super.idle()
        ringSpinTarget = 0.12
    }

    override func spin(_ d: Double) {
        ringSpinVelocity = d * 2.4
        ringSpinTarget = d * 0.18
    }

    override func zoom() {
        ringSpacingTarget = ringSpacingTarget > 6 ? 4.2 : 7
    }

    override func groupDidUpdate(_ group: LightGroup, color: NSColor, level: CGFloat) {
        guard group == .rings, let backLight else { return }
        backLight.color = color
        backLight.intensity = min(level, 3) * 350
    }

    override func animate(dt: Double) {
        // Rings: spin decays towards a slow drift; zoom eases spacing.
        ringSpinVelocity += (ringSpinTarget - ringSpinVelocity) * (1 - exp(-dt * 1.6))
        ringSpacing += (ringSpacingTarget - ringSpacing) * (1 - exp(-dt * 2.5))
        for (i, r) in rings.enumerated() {
            ringAngles[i] += ringSpinVelocity * dt * (1 + Double(i) * 0.06)
            r.eulerAngles.z = CGFloat(ringAngles[i])
            r.position.z = CGFloat(-20 - Double(i) * ringSpacing)
        }

        // Lasers sweep around their base.
        for (group, nodes) in [(LightGroup.leftLasers, leftLasers), (LightGroup.rightLasers, rightLasers)] {
            let side: Double = group == .leftLasers ? -1 : 1
            laserPhase[group]! += dt * (laserSpeed[group] ?? 0)
            let ph = laserPhase[group]!
            for (i, n) in nodes.enumerated() {
                let a = 0.55 * sin(ph + Double(i) * 0.7) - side * 0.35
                n.eulerAngles.z = CGFloat(a)
                n.eulerAngles.x = CGFloat(0.25 * sin(ph * 0.7 + Double(i)))
            }
        }
    }
}
