import AppKit
import SceneKit
import simd
import SaberCore

/// The "Prism Hall" stage: a reflective runway in a dark void, receding octagonal prism rings,
/// sweeping laser fans and a horizon emblem. Every light is driven by the beatmap's light events.
final class StageEnvironment {
    let root = SCNNode()

    private struct GroupState {
        var color: LightColor = .off
        var base: Double = 0
        var flash: Double = 0
        var shown = SIMD3<Float>(0, 0, 0)
    }

    private var materials: [LightGroup: [SCNMaterial]] = [:]
    private var states: [LightGroup: GroupState] = [:]

    private var rings: [SCNNode] = []
    private var ringAngles: [Double] = []
    private var ringSpinVelocity: Double = 0.15
    private var ringSpinTarget: Double = 0.15
    private var ringSpacing: Double = 7
    private var ringSpacingTarget: Double = 7

    private var leftLasers: [SCNNode] = []
    private var rightLasers: [SCNNode] = []
    private var laserSpeed: [LightGroup: Double] = [.leftLasers: 0.6, .rightLasers: 0.6]
    private var laserPhase: [LightGroup: Double] = [.leftLasers: 0, .rightLasers: 1.7]

    private let backLight = SCNLight()
    private var time: Double = 0

    var bloomEnabled = true

    init() {
        for g in LightGroup.allCases {
            materials[g] = []
            states[g] = GroupState()
        }
        buildFloor()
        buildRings()
        buildLasers()
        buildBack()
        buildLights()
        buildParticles()
        idle()
    }

    private func groupMaterial(_ g: LightGroup, glow: Bool = false) -> SCNMaterial {
        let m = glow ? Materials.glow(.black, intensity: 1, opacity: 0.35) : Materials.neon(.black)
        materials[g]!.append(m)
        return m
    }

    // MARK: Build

    private func buildFloor() {
        let floor = SCNFloor()
        floor.reflectivity = 0.22
        floor.reflectionFalloffEnd = 8
        floor.reflectionResolutionScaleFactor = 0.5
        let fm = SCNMaterial()
        fm.lightingModel = .physicallyBased
        fm.diffuse.contents = NSColor(calibratedWhite: 0.015, alpha: 1)
        fm.roughness.contents = 0.45
        fm.metalness.contents = 0.4
        floor.materials = [fm]
        let floorNode = SCNNode(geometry: floor)
        root.addChildNode(floorNode)

        // Player platform with glowing trim.
        let platform = SCNBox(width: 3.4, height: 0.08, length: 2.6, chamferRadius: 0.02)
        platform.materials = [Materials.metal(NSColor(calibratedWhite: 0.05, alpha: 1), roughness: 0.5, metalness: 0.7)]
        let pn = SCNNode(geometry: platform)
        pn.position = SCNVector3(0, -0.035, 0.6)
        root.addChildNode(pn)

        let trimMat = groupMaterial(.floor)
        let trims: [(SCNVector3, CGFloat, CGFloat)] = [
            (SCNVector3(0, 0.01, -0.7), 3.4, 0.03),
            (SCNVector3(0, 0.01, 1.9), 3.4, 0.03),
            (SCNVector3(-1.7, 0.01, 0.6), 0.03, 2.6),
            (SCNVector3(1.7, 0.01, 0.6), 0.03, 2.6),
        ]
        for (pos, w, l) in trims {
            let b = SCNBox(width: w, height: 0.02, length: l, chamferRadius: 0)
            b.materials = [trimMat]
            let n = SCNNode(geometry: b)
            n.position = pos
            root.addChildNode(n)
        }

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

    private func buildLights() {
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 180
        ambient.color = NSColor(calibratedRed: 0.45, green: 0.5, blue: 0.7, alpha: 1)
        let an = SCNNode()
        an.light = ambient
        root.addChildNode(an)

        let key = SCNLight()
        key.type = .directional
        key.intensity = 900
        key.color = NSColor(calibratedWhite: 0.95, alpha: 1)
        let kn = SCNNode()
        kn.light = key
        kn.eulerAngles = SCNVector3(-0.9, 0.25, 0)
        root.addChildNode(kn)

        backLight.type = .omni
        backLight.intensity = 0
        backLight.attenuationStartDistance = 4
        backLight.attenuationEndDistance = 40
        let bn = SCNNode()
        bn.light = backLight
        bn.position = SCNVector3(0, 10, -26)
        root.addChildNode(bn)
    }

    private func buildParticles() {
        let dust = SCNParticleSystem()
        dust.birthRate = 30
        dust.particleLifeSpan = 9
        dust.particleLifeSpanVariation = 3
        dust.particleSize = 0.035
        dust.particleSizeVariation = 0.02
        dust.particleColor = NSColor(calibratedRed: 0.6, green: 0.75, blue: 1, alpha: 0.35)
        dust.particleImage = Textures.softDot
        dust.blendMode = .additive
        dust.isLightingEnabled = false
        dust.particleVelocity = 0.25
        dust.particleVelocityVariation = 0.2
        dust.spreadingAngle = 180
        dust.emitterShape = SCNBox(width: 14, height: 8, length: 40, chamferRadius: 0)
        dust.birthLocation = .volume
        dust.warmupDuration = 8
        let dn = SCNNode()
        dn.position = SCNVector3(0, 4, -18)
        dn.addParticleSystem(dust)
        root.addChildNode(dn)
    }

    // MARK: Events

    func idle() {
        apply(.on(.blue), to: .back)
        apply(.on(.blue), to: .floor)
        apply(.on(.blue), to: .rings)
        apply(.on(.red), to: .leftLasers)
        apply(.on(.blue), to: .rightLasers)
        laserSpeed[.leftLasers] = 0.5
        laserSpeed[.rightLasers] = 0.5
        ringSpinTarget = 0.12
    }

    func blackout() {
        for g in LightGroup.allCases { apply(.off, to: g) }
    }

    func apply(_ action: LightAction, to group: LightGroup) {
        var s = states[group]!
        switch action {
        case .on(let c):
            s.color = c; s.base = 1; s.flash = 0
        case .flash(let c):
            s.color = c; s.base = 1; s.flash = 1
        case .fade(let c):
            s.color = c; s.base = 0; s.flash = 1
        case .off:
            s.base = 0; s.flash = 0
        case .speed(let v):
            laserSpeed[group] = v
        case .spin(let d):
            ringSpinVelocity = d * 2.4
            ringSpinTarget = d * 0.18
        case .zoom:
            ringSpacingTarget = ringSpacingTarget > 6 ? 4.2 : 7
        }
        states[group] = s
    }

    /// Advances animation. `pulse` adds a little extra glow on the beat in menus.
    func update(dt: Double) {
        time += dt
        for g in LightGroup.allCases {
            var s = states[g]!
            s.flash *= exp(-dt * 5.5)
            let intensity = Float(s.base * 0.85 + s.flash * 2.4)
            let target = Palette.simd(Palette.light(s.color)) * intensity
            let k = Float(1 - exp(-dt * 30))
            s.shown += (target - s.shown) * k
            states[g] = s
            let c = s.shown
            let maxC = max(c.x, max(c.y, c.z))
            let color: NSColor
            let mult: CGFloat
            if maxC > 1 {
                color = NSColor(deviceRed: CGFloat(c.x / maxC), green: CGFloat(c.y / maxC), blue: CGFloat(c.z / maxC), alpha: 1)
                mult = CGFloat(maxC)
            } else {
                color = NSColor(deviceRed: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1)
                mult = 1
            }
            for m in materials[g]! {
                m.emission.contents = color
                m.emission.intensity = mult * (m.blendMode == .add ? 0.9 : 1.8)
            }
            if g == .back || g == .rings {
                if g == .rings {
                    backLight.color = color
                    backLight.intensity = CGFloat(min(maxC, 3)) * 350
                }
            }
        }

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
