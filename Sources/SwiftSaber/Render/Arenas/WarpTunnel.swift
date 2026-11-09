import AppKit
import SceneKit
import simd
import SaberCore

/// "Warp Tunnel": the platform floats through hyperspace inside a long tunnel of square light
/// frames. Spin events twist the tunnel into a spiral, zoom events compress it, star streaks
/// rush past, a cage of hex rings drifts outside the tunnel and a glowing portal waits at the
/// far end.
///
/// Light groups: rings = tunnel frames, floor = runway + chevrons, back = portal,
/// left/right lasers = streak beams running along each tunnel wall.
final class WarpTunnelStage: Stage {
    private let tunnelCenterY: Float = 1.6
    private var frames: [SCNNode] = []
    private var baseAngle: Double = 0
    private var spinVelocity: Double = 0.1
    private var spinTarget: Double = 0.1
    private var twist: Double = 0.04
    private var twistTarget: Double = 0.04
    private var spacing: Double = 5
    private var spacingTarget: Double = 5

    private var chevrons = SCNNode()
    private var chevronOffset: Double = 0
    private let chevronSpacing: Float = 6

    private var leftBeams: [SCNNode] = []
    private var rightBeams: [SCNNode] = []
    private var beamPhase: [LightGroup: Double] = [.leftLasers: 0, .rightLasers: 1.3]

    private var portal: [SCNNode] = []
    private var tunnelLight: SCNLight?

    override func build() {
        sky = SkyStyle(zenith: NSColor(calibratedRed: 0.01, green: 0.015, blue: 0.05, alpha: 1),
                       horizon: NSColor(calibratedRed: 0.04, green: 0.075, blue: 0.17, alpha: 1),
                       nadir: NSColor(calibratedRed: 0.01, green: 0.02, blue: 0.05, alpha: 1),
                       glow: NSColor(calibratedRed: 0.07, green: 0.15, blue: 0.3, alpha: 1),
                       glowWidth: 0.1,
                       nebulae: SkyStyle.ring(of: 5, v: 0.3, radius: 0.12,
                                              colors: [NSColor(calibratedRed: 0.05, green: 0.17, blue: 0.24, alpha: 1),
                                                       NSColor(calibratedRed: 0.15, green: 0.06, blue: 0.25, alpha: 1)])
                           + SkyStyle.ring(of: 4, v: 0.68, radius: 0.1,
                                           colors: [NSColor(calibratedRed: 0.12, green: 0.05, blue: 0.2, alpha: 1)], offset: 0.12))
        fogColor = NSColor(calibratedRed: 0.03, green: 0.055, blue: 0.12, alpha: 1)
        fogStart = 25
        fogEnd = 190

        let floorMat = groupMaterial(.floor)
        let floorGlow = groupMaterial(.floor, glow: true, glowOpacity: 0.3)
        addPlatform(trimMaterial: floorMat, body: NSColor(calibratedWhite: 0.04, alpha: 1))
        buildRunway(floorMat, floorGlow)
        buildFrames()
        buildBeams()
        buildPortal()
        buildCage()
        buildStreaks()
        addBaseLights(ambient: NSColor(calibratedRed: 0.4, green: 0.5, blue: 0.8, alpha: 1), ambientIntensity: 220)
        tunnelLight = makeGroupLight(at: SCNVector3(0, 3, -18), range: 40)
        addStars(count: 600, radius: 200, minY: -200, seed: 21)
    }

    // MARK: Build

    private func buildRunway(_ mat: SCNMaterial, _ glow: SCNMaterial) {
        // A thin floating runway: dark deck with glowing edges.
        let deck = SCNBox(width: 3.0, height: 0.05, length: 150, chamferRadius: 0)
        deck.materials = [Materials.metal(NSColor(calibratedWhite: 0.08, alpha: 1), roughness: 0.3, metalness: 0.8)]
        let dn = SCNNode(geometry: deck)
        dn.position = SCNVector3(0, -0.06, -76)
        root.addChildNode(dn)

        let edges = SCNNode()
        for x: Float in [-1.5, 1.5] {
            edges.addChildNode(Stage.segment(SIMD3(x, -0.03, -0.7), SIMD3(x, -0.03, -150), thickness: 0.05, material: mat))
            edges.addChildNode(Stage.segment(SIMD3(x, -0.025, -0.7), SIMD3(x, -0.025, -150), thickness: 0.16, height: 0.005, material: glow))
            // Guide lights along each edge.
            var z: Float = -2
            while z > -150 {
                edges.addChildNode(Stage.segment(SIMD3(x * 1.07, -0.02, z), SIMD3(x * 1.07, -0.02, z - 0.35), thickness: 0.12, material: mat))
                z -= 3
            }
        }
        // Dashed centre line and deck seams.
        let seams = groupMaterial(.floor, strength: 0.35)
        var z: Float = -1.5
        while z > -150 {
            edges.addChildNode(Stage.segment(SIMD3(0, -0.03, z), SIMD3(0, -0.03, z - 1.2), thickness: 0.035, height: 0.01, material: seams))
            edges.addChildNode(Stage.segment(SIMD3(-1.45, -0.03, z - 2), SIMD3(1.45, -0.03, z - 2), thickness: 0.02, height: 0.01, material: seams))
            z -= 4
        }
        root.addChildNode(edges.flattenedClone())

        // Chevrons on the deck that rush towards the player.
        let ch = SCNNode()
        for i in 0..<24 {
            let z = -3 - Float(i) * chevronSpacing
            for side: Float in [-1, 1] {
                let a = SIMD3<Float>(0, -0.02, z)
                let b = SIMD3<Float>(side * 0.6, -0.02, z + 0.7)
                ch.addChildNode(Stage.segment(a, b, thickness: 0.06, height: 0.01, material: mat))
            }
        }
        chevrons = ch.flattenedClone()
        root.addChildNode(chevrons)
    }

    private func buildFrames() {
        let mat = groupMaterial(.rings)
        let glow = groupMaterial(.rings, glow: true)
        let half: Float = 6.5
        let dark = Materials.metal(NSColor(calibratedWhite: 0.1, alpha: 1), roughness: 0.35, metalness: 0.85)
        let accent = groupMaterial(.rings, strength: 0.7)
        for i in 0..<30 {
            let frame = SCNNode()
            polygonOutline(sides: 4, radius: half * sqrt(2), rotation: .pi / 4, center: .zero, core: 0.12, glow: 0.5,
                           material: mat, glowMaterial: glow, gap: 0.86, into: frame)
            // Inner diamond accent on every third frame.
            if i % 3 == 0 {
                polygonOutline(sides: 4, radius: half * 0.55, rotation: 0, center: .zero, core: 0.07, glow: 0.3,
                               material: mat, glowMaterial: glow, gap: 0.5, into: frame)
            }
            // Dark structural frame so the tunnel reads as solid.
            let shell = SCNNode()
            for s in 0..<4 {
                let a = Float(s) * .pi / 2
                let c = SIMD3<Float>(cos(a) * (half + 0.35), sin(a) * (half + 0.35), -0.25)
                let t = SIMD3<Float>(-sin(a), cos(a), 0) * (half + 0.6)
                shell.addChildNode(Stage.segment(c - t, c + t, thickness: 0.5, material: dark))
            }
            frame.addChildNode(shell)
            // Corner pods fill the gaps between the light bars, each with a beacon.
            for cx: Float in [-1, 1] {
                for cy: Float in [-1, 1] {
                    let pod = SCNBox(width: 1.1, height: 1.1, length: 0.7, chamferRadius: 0.12)
                    pod.materials = [dark]
                    let pn = SCNNode(geometry: pod)
                    pn.simdPosition = SIMD3(cx * half, cy * half, -0.1)
                    pn.eulerAngles.z = .pi / 4
                    frame.addChildNode(pn)
                    let lamp = SCNSphere(radius: 0.2)
                    lamp.segmentCount = 10
                    lamp.materials = [mat]
                    let ln = SCNNode(geometry: lamp)
                    ln.simdPosition = SIMD3(cx * (half - 0.45), cy * (half - 0.45), 0.25)
                    frame.addChildNode(ln)
                }
            }
            // Fins pointing inwards from the middle of each side on alternate frames.
            if i % 2 == 1 {
                for s in 0..<4 {
                    let a = Float(s) * .pi / 2
                    let d = SIMD3<Float>(cos(a), sin(a), 0)
                    frame.addChildNode(Stage.segment(d * (half + 0.2), d * (half - 1.1), thickness: 0.09, material: accent))
                }
            }
            let holder = SCNNode()
            holder.addChildNode(frame.flattenedClone())
            holder.position = SCNVector3(0, CGFloat(tunnelCenterY), CGFloat(-8 - Double(i) * spacing))
            root.addChildNode(holder)
            frames.append(holder)
        }
    }

    private func buildBeams() {
        for (group, side) in [(LightGroup.leftLasers, Float(-1)), (LightGroup.rightLasers, Float(1))] {
            let mat = groupMaterial(group)
            let glow = groupMaterial(group, glow: true, glowOpacity: 0.3)
            for _ in 0..<4 {
                let n = SCNNode()
                let core = SCNBox(width: 0.06, height: 0.06, length: 150, chamferRadius: 0)
                core.materials = [mat]
                n.addChildNode(SCNNode(geometry: core))
                let shell = SCNBox(width: 0.32, height: 0.32, length: 150, chamferRadius: 0)
                shell.materials = [glow]
                n.addChildNode(SCNNode(geometry: shell))
                n.simdPosition = SIMD3(side * 5.6, tunnelCenterY, -84)
                root.addChildNode(n)
                if side < 0 { leftBeams.append(n) } else { rightBeams.append(n) }
            }
        }
    }

    private func buildPortal() {
        let mat = groupMaterial(.back)
        let glow = groupMaterial(.back, glow: true, glowOpacity: 0.3)
        let center = SIMD3<Float>(0, tunnelCenterY, -165)
        for (i, radius) in [Float(3), 5.5, 8.5].enumerated() {
            let ring = SCNNode()
            polygonOutline(sides: 6 + i * 2, radius: radius, rotation: 0, center: .zero, core: 0.18, glow: 0.9,
                           material: mat, glowMaterial: glow, gap: i == 2 ? 0.7 : 1, into: ring)
            let holder = SCNNode()
            holder.addChildNode(ring.flattenedClone())
            holder.simdPosition = center
            root.addChildNode(holder)
            portal.append(holder)
        }
        let core = SCNCylinder(radius: 2.2, height: 0.1)
        core.radialSegmentCount = 48
        core.materials = [groupMaterial(.back, glow: true, glowOpacity: 0.55)]
        let cn = SCNNode(geometry: core)
        cn.eulerAngles.x = .pi / 2
        cn.simdPosition = center + SIMD3(0, 0, -1)
        root.addChildNode(cn)

        // Spokes, an outer rim and a wide haze so the portal reads from the far end of the tunnel.
        let spokeMat = groupMaterial(.back, strength: 0.6)
        let extra = SCNNode()
        for k in 0..<12 {
            let a = Float(k) / 12 * 2 * .pi
            let d = SIMD3<Float>(cos(a), sin(a), 0)
            extra.addChildNode(Stage.segment(center + d * 3.3 + SIMD3(0, 0, -0.4), center + d * 8.1 + SIMD3(0, 0, -0.4),
                                             thickness: 0.07, material: spokeMat))
        }
        let rim = SCNTorus(ringRadius: 11.5, pipeRadius: 0.16)
        rim.ringSegmentCount = 72
        rim.pipeSegmentCount = 6
        rim.materials = [spokeMat]
        let rn = SCNNode(geometry: rim)
        rn.eulerAngles.x = .pi / 2
        rn.simdPosition = center + SIMD3(0, 0, -0.6)
        extra.addChildNode(rn)
        let haze = SCNCylinder(radius: 15, height: 0.1)
        haze.radialSegmentCount = 48
        haze.materials = [groupMaterial(.back, glow: true, glowOpacity: 0.1)]
        let hn = SCNNode(geometry: haze)
        hn.eulerAngles.x = .pi / 2
        hn.simdPosition = center + SIMD3(0, 0, -2)
        extra.addChildNode(hn)
        root.addChildNode(extra.flattenedClone())
    }

    /// Large hexagonal rings outside the tunnel walls, adding depth beyond the frames.
    private func buildCage() {
        let mat = groupMaterial(.back, strength: 0.45)
        let strut = Materials.metal(NSColor(calibratedWhite: 0.12, alpha: 1), roughness: 0.4, metalness: 0.8)
        let cage = SCNNode()
        for i in 0..<7 {
            let z = Float(-18 - i * 21)
            let center = SIMD3<Float>(0, tunnelCenterY, z)
            let rotation = Float(i) * 0.21
            polygonOutline(sides: 6, radius: 14, rotation: rotation, center: center, core: 0.12, glow: 0,
                           material: mat, glowMaterial: nil, into: cage)
            polygonOutline(sides: 6, radius: 14.6, rotation: rotation, center: center + SIMD3(0, 0, -0.4), core: 0.45, glow: 0,
                           material: strut, glowMaterial: nil, gap: 0.9, into: cage)
        }
        root.addChildNode(cage.flattenedClone())
    }

    private func buildStreaks() {
        let p = SCNParticleSystem()
        p.birthRate = 260
        p.particleLifeSpan = 1.7
        p.particleLifeSpanVariation = 0.4
        p.particleSize = 0.03
        p.particleSizeVariation = 0.015
        p.particleColor = NSColor(calibratedRed: 0.75, green: 0.85, blue: 1, alpha: 0.7)
        p.particleImage = Textures.softDot
        p.blendMode = .additive
        p.isLightingEnabled = false
        p.emitterShape = SCNBox(width: 34, height: 22, length: 20, chamferRadius: 0)
        p.birthLocation = .volume
        p.emittingDirection = SCNVector3(0, 0, 1)
        p.spreadingAngle = 0
        p.particleVelocity = 55
        p.particleVelocityVariation = 15
        p.stretchFactor = 0.06
        p.warmupDuration = 2
        let n = SCNNode()
        n.position = SCNVector3(0, CGFloat(tunnelCenterY), -85)
        n.addParticleSystem(p)
        root.addChildNode(n)
    }

    // MARK: Events

    override func idle() {
        super.idle()
        spinTarget = 0.1
        twistTarget = 0.04
    }

    override func spin(_ d: Double) {
        spinVelocity = d * 2.2
        spinTarget = d * 0.15
        twistTarget = twistTarget > 0.06 ? 0.035 : 0.11
    }

    override func zoom() {
        spacingTarget = spacingTarget > 4 ? 3.2 : 5
    }

    override func groupDidUpdate(_ group: LightGroup, color: NSColor, level: CGFloat) {
        guard group == .rings, let tunnelLight else { return }
        tunnelLight.color = color
        tunnelLight.intensity = min(level, 3) * 320
    }

    override func animate(dt: Double) {
        spinVelocity += (spinTarget - spinVelocity) * (1 - exp(-dt * 1.5))
        twist += (twistTarget - twist) * (1 - exp(-dt * 1.2))
        spacing += (spacingTarget - spacing) * (1 - exp(-dt * 2.5))
        baseAngle += spinVelocity * dt
        for (i, f) in frames.enumerated() {
            f.eulerAngles.z = CGFloat(baseAngle + twist * Double(i) * 1.6)
            f.position.z = CGFloat(-8 - Double(i) * spacing)
        }

        chevronOffset += dt * 14
        chevrons.simdPosition.z = Float(chevronOffset.truncatingRemainder(dividingBy: Double(chevronSpacing)))

        for (i, p) in portal.enumerated() {
            p.eulerAngles.z = CGFloat(time * (i % 2 == 0 ? 0.3 : -0.45) * Double(i + 1))
        }

        // Wall beams glide up and down the tunnel walls.
        for (group, nodes) in [(LightGroup.leftLasers, leftBeams), (LightGroup.rightLasers, rightBeams)] {
            let side: Float = group == .leftLasers ? -1 : 1
            beamPhase[group]! += dt * (laserSpeed[group] ?? 0) * 1.4
            let ph = beamPhase[group]!
            for (i, n) in nodes.enumerated() {
                let y = tunnelCenterY + Float(5.2 * sin(ph + Double(i) * 1.57))
                n.simdPosition = SIMD3(side * 5.6, y, -84)
            }
        }
    }
}
