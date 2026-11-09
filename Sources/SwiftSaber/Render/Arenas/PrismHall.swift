import AppKit
import SceneKit
import simd
import SaberCore

/// The "Prism Hall" stage: a reflective runway in a vast hall, receding octagonal prism rings,
/// sweeping laser fans and a horizon emblem. Light pillars hold up overhead trusses, tiered
/// stands line both sides and prism crystals hang in the air. Every light is driven by the
/// beatmap's light events.
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

    private var crystals: [(node: SCNNode, phase: Double)] = []

    private var backLight: SCNLight?

    override func build() {
        sky = SkyStyle(zenith: NSColor(calibratedRed: 0.012, green: 0.012, blue: 0.045, alpha: 1),
                       horizon: NSColor(calibratedRed: 0.07, green: 0.065, blue: 0.17, alpha: 1),
                       nadir: NSColor(calibratedRed: 0.01, green: 0.01, blue: 0.03, alpha: 1),
                       glow: NSColor(calibratedRed: 0.17, green: 0.13, blue: 0.36, alpha: 1),
                       glowWidth: 0.05)
        fogColor = NSColor(calibratedRed: 0.055, green: 0.05, blue: 0.13, alpha: 1)
        fogStart = 30
        fogEnd = 175

        buildFloor()
        buildStands()
        buildRings()
        buildLasers()
        buildBack()
        buildCrystals()
        addBaseLights(ambient: NSColor(calibratedRed: 0.5, green: 0.52, blue: 0.8, alpha: 1), ambientIntensity: 240)
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
        let pillarBody = Materials.metal(NSColor(calibratedWhite: 0.1, alpha: 1), roughness: 0.4, metalness: 0.75)
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
                // Glowing cap on each pillar.
                let cap = SCNBox(width: 0.8, height: 0.18, length: 0.8, chamferRadius: 0.02)
                cap.materials = [trimMat]
                let cn = SCNNode(geometry: cap)
                cn.position = SCNVector3(x, 14.05, z)
                rails.addChildNode(cn)
            }
        }
        // Overhead trusses join the nearer pillar pairs (the far ones would cross the emblem).
        let underside = groupMaterial(.floor, strength: 0.7)
        for i in 0..<6 {
            let z = Float(-14 - Double(i) * 11)
            let x = Float(7.5 + Double(i % 2) * 1.5)
            rails.addChildNode(Stage.segment(SIMD3(-x, 14.4, z), SIMD3(x, 14.4, z), thickness: 0.55, material: pillarBody))
            rails.addChildNode(Stage.segment(SIMD3(-x, 14.1, z), SIMD3(x, 14.1, z), thickness: 0.07, material: underside))
            // Diagonal braces down to the pillars.
            for side: Float in [-1, 1] {
                rails.addChildNode(Stage.segment(SIMD3(side * (x - 2.5), 14.3, z), SIMD3(side * x, 11.5, z), thickness: 0.22, material: pillarBody))
            }
        }
        root.addChildNode(rails.flattenedClone())

        // Faint floor grid either side of the runway (pulses with the floor lights).
        let gridMat = groupMaterial(.floor, strength: 0.3)
        let grid = SCNNode()
        for x: Float in [2.5, 4.5, 6.5, 10.5, 14.5, 18.5] {
            for side: Float in [-1, 1] {
                grid.addChildNode(Stage.segment(SIMD3(side * x, 0.004, -1.5), SIMD3(side * x, 0.004, -140),
                                                thickness: 0.03, height: 0.004, material: gridMat))
            }
        }
        var gz: Float = -5
        while gz > -140 {
            for side: Float in [-1, 1] {
                grid.addChildNode(Stage.segment(SIMD3(side * 1.7, 0.004, gz), SIMD3(side * 20, 0.004, gz),
                                                thickness: 0.03, height: 0.004, material: gridMat))
            }
            gz -= 5
        }
        root.addChildNode(grid.flattenedClone())
    }

    /// Tiered stands either side of the hall, each step edged with light.
    private func buildStands() {
        let body = Materials.metal(NSColor(calibratedRed: 0.09, green: 0.09, blue: 0.12, alpha: 1), roughness: 0.5, metalness: 0.6)
        let edge = groupMaterial(.floor, strength: 0.6)
        let stands = SCNNode()
        let zNear: Float = -12, zFar: Float = -132
        for side: Float in [-1, 1] {
            for k in 0..<4 {
                let h = Float(1.5) * Float(k + 1)
                let inner = Float(22) + Float(k) * 3
                let box = SCNBox(width: 3, height: CGFloat(h), length: CGFloat(zNear - zFar), chamferRadius: 0)
                box.materials = [body]
                let n = SCNNode(geometry: box)
                n.simdPosition = SIMD3(side * (inner + 1.5), h / 2, (zNear + zFar) / 2)
                stands.addChildNode(n)
                stands.addChildNode(Stage.segment(SIMD3(side * inner, h + 0.02, zNear), SIMD3(side * inner, h + 0.02, zFar),
                                                  thickness: 0.07, material: edge))
            }
            // Vertical dividers on the stand faces every 10 m.
            var z = zNear - 4
            while z > zFar {
                for k in 0..<4 {
                    let inner = Float(22) + Float(k) * 3
                    let h = Float(1.5) * Float(k + 1)
                    stands.addChildNode(Stage.segment(SIMD3(side * (inner - 0.02), h - 1.5, z), SIMD3(side * (inner - 0.02), h, z),
                                                      thickness: 0.05, material: edge))
                }
                z -= 10
            }
        }
        root.addChildNode(stands.flattenedClone())
    }

    /// Octahedral crystals hanging high on either side; they glow with the back lights.
    private func buildCrystals() {
        let mat = groupMaterial(.back, strength: 0.8)
        let glow = groupMaterial(.back, glow: true, glowOpacity: 0.18)
        let spots: [SIMD3<Float>] = [
            SIMD3(-13, 18, -38), SIMD3(14, 19.5, -52), SIMD3(-16, 20, -70), SIMD3(17, 18.5, -86),
            SIMD3(-14, 21, -104), SIMD3(15, 20.5, -118),
        ]
        for (i, p) in spots.enumerated() {
            let gem = SCNNode()
            for flip in [false, true] {
                let pyr = SCNPyramid(width: 1.6, height: 2.2, length: 1.6)
                pyr.materials = [mat]
                let pn = SCNNode(geometry: pyr)
                if flip { pn.eulerAngles.x = .pi }
                gem.addChildNode(pn)
            }
            let halo = SCNSphere(radius: 2.2)
            halo.segmentCount = 16
            halo.materials = [glow]
            gem.addChildNode(SCNNode(geometry: halo))
            let holder = SCNNode()
            holder.addChildNode(gem.flattenedClone())
            holder.simdPosition = p
            root.addChildNode(holder)
            crystals.append((holder, Double(i) * 1.1))
        }
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
            frame.materials = [Materials.metal(NSColor(calibratedWhite: 0.1, alpha: 1), roughness: 0.3, metalness: 0.85)]
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

        // Crystals turn slowly and sway.
        for c in crystals {
            c.node.eulerAngles.y = CGFloat(time * 0.5 + c.phase)
            c.node.eulerAngles.z = CGFloat(0.15 * sin(time * 0.7 + c.phase))
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
