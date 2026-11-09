import AppKit
import SceneKit
import simd
import SaberCore

/// "Orbit": a platform drifting in deep space. A giant three-axis gyroscope turns ahead of
/// the runway, a ringed planet glows below, laser fans rise from the void and cross
/// overhead, space stations turn in the distance and asteroids hang against a nebula.
///
/// Light groups: rings = gyroscope, back = planet atmosphere + planetary ring,
/// floor = runway + beacons, left/right lasers = crossing laser fans.
final class OrbitStage: Stage {
    private var gyroOuter = SCNNode()
    private var gyroMiddle = SCNNode()
    private var gyroInner = SCNNode()
    private var gyroHolder = SCNNode()
    private var gyroVelocity: Double = 0.12
    private var gyroTarget: Double = 0.12
    private var gyroAngles = SIMD3<Double>(0, 0, 0)
    private var gyroScale: Double = 1
    private var gyroScaleTarget: Double = 1

    private var leftFan: [SCNNode] = []
    private var rightFan: [SCNNode] = []
    private var fanPhase: [LightGroup: Double] = [.leftLasers: 0, .rightLasers: 1.4]

    private var planet = SCNNode()
    private var gyroLight: SCNLight?
    private var habitats: [(node: SCNNode, rate: Double)] = []
    private let beaconMat = Materials.neon(NSColor(calibratedRed: 0.3, green: 1, blue: 0.5, alpha: 1), intensity: 0.2)

    private let gyroCenter = SIMD3<Float>(0, 10, -78)

    /// Brightens only the silhouette edge of a sphere (an atmosphere rim).
    private static let rimModifier = """
    #pragma body
    float ndv = saturate(dot(normalize(_surface.normal), normalize(_surface.view)));
    float rim = pow(1.0 - ndv, 2.2);
    _surface.emission.rgb *= rim * 3.2;
    """

    override func build() {
        let violet = NSColor(calibratedRed: 0.2, green: 0.06, blue: 0.28, alpha: 1)
        let teal = NSColor(calibratedRed: 0.04, green: 0.17, blue: 0.24, alpha: 1)
        let rose = NSColor(calibratedRed: 0.24, green: 0.05, blue: 0.16, alpha: 1)
        let deepBlue = NSColor(calibratedRed: 0.05, green: 0.08, blue: 0.22, alpha: 1)
        sky = SkyStyle(zenith: NSColor(calibratedRed: 0.008, green: 0.01, blue: 0.03, alpha: 1),
                       horizon: NSColor(calibratedRed: 0.03, green: 0.035, blue: 0.08, alpha: 1),
                       nadir: NSColor(calibratedRed: 0.01, green: 0.012, blue: 0.035, alpha: 1),
                       glow: NSColor(calibratedRed: 0.05, green: 0.06, blue: 0.13, alpha: 1),
                       glowWidth: 0.12,
                       nebulae: SkyStyle.ring(of: 6, v: 0.33, radius: 0.14, colors: [violet, teal, rose])
                           + SkyStyle.ring(of: 5, v: 0.62, radius: 0.12, colors: [deepBlue, violet], offset: 0.1))
        restGlow = 0.16
        fogColor = NSColor(calibratedRed: 0.02, green: 0.025, blue: 0.06, alpha: 1)
        fogStart = 90
        fogEnd = 460

        let floorMat = groupMaterial(.floor)
        let floorGlow = groupMaterial(.floor, glow: true, glowOpacity: 0.3)
        addPlatform(trimMaterial: floorMat, body: NSColor(calibratedWhite: 0.06, alpha: 1))
        buildRunway(floorMat, floorGlow)
        buildGyroscope()
        buildPlanet()
        buildFans()
        buildAsteroids()
        buildStation(at: SIMD3(-50, 16, -125), scale: 1, tilt: SIMD3(0.2, 0.5, 0.1), rate: 0.12)
        buildStation(at: SIMD3(62, -6, -170), scale: 1.3, tilt: SIMD3(-0.15, -0.6, -0.2), rate: -0.09)
        addBaseLights(ambient: NSColor(calibratedRed: 0.45, green: 0.5, blue: 0.65, alpha: 1), ambientIntensity: 200, keyIntensity: 1100)
        gyroLight = makeGroupLight(at: SCNVector3(gyroCenter.x, gyroCenter.y, gyroCenter.z + 20), range: 60)
        addStars(count: 1400, radius: 300, minY: -300, seed: 99)
        addDust(color: NSColor(calibratedRed: 0.7, green: 0.85, blue: 1, alpha: 0.3), birthRate: 16)
    }

    // MARK: Build

    private func buildRunway(_ mat: SCNMaterial, _ glow: SCNMaterial) {
        let deck = SCNBox(width: 2.9, height: 0.06, length: 62, chamferRadius: 0.02)
        deck.materials = [Materials.metal(NSColor(calibratedRed: 0.1, green: 0.105, blue: 0.13, alpha: 1), roughness: 0.25, metalness: 0.85)]
        let dn = SCNNode(geometry: deck)
        dn.position = SCNVector3(0, -0.05, -31.5)
        root.addChildNode(dn)

        let h = SCNNode()
        for x: Float in [-1.45, 1.45] {
            h.addChildNode(Stage.segment(SIMD3(x, -0.01, -0.7), SIMD3(x, -0.01, -62.5), thickness: 0.05, material: mat))
            h.addChildNode(Stage.segment(SIMD3(x, -0.005, -0.7), SIMD3(x, -0.005, -62.5), thickness: 0.16, height: 0.005, material: glow))
            var z: Float = -4
            while z > -62 {
                let beacon = SCNSphere(radius: 0.06)
                beacon.segmentCount = 10
                beacon.materials = [mat]
                let bn = SCNNode(geometry: beacon)
                bn.simdPosition = SIMD3(x * 1.08, 0.05, z)
                h.addChildNode(bn)
                z -= 4
            }
        }
        // The runway's far end: a bright threshold bar.
        h.addChildNode(Stage.segment(SIMD3(-1.45, 0, -62.5), SIMD3(1.45, 0, -62.5), thickness: 0.08, material: mat))

        // Truss under the deck and fins along its sides, so the runway reads as a structure.
        let frame = Materials.metal(NSColor(calibratedWhite: 0.16, alpha: 1), roughness: 0.35, metalness: 0.85)
        let tips = groupMaterial(.floor, strength: 0.8)
        h.addChildNode(Stage.segment(SIMD3(0, -0.9, -1), SIMD3(0, -0.9, -62.5), thickness: 0.3, material: frame))
        var tz: Float = -2
        while tz > -62 {
            for x: Float in [-1.3, 1.3] {
                h.addChildNode(Stage.segment(SIMD3(x, -0.08, tz), SIMD3(0, -0.9, tz - 2), thickness: 0.08, material: frame))
                h.addChildNode(Stage.segment(SIMD3(0, -0.9, tz - 2), SIMD3(x, -0.08, tz - 4), thickness: 0.08, material: frame))
            }
            tz -= 4
        }
        var fz: Float = -6
        while fz > -62 {
            for side: Float in [-1, 1] {
                h.addChildNode(Stage.segment(SIMD3(side * 1.45, -0.05, fz), SIMD3(side * 2.7, -0.35, fz + 0.8), thickness: 0.06, height: 0.25, material: frame))
                h.addChildNode(Stage.segment(SIMD3(side * 2.65, -0.33, fz + 0.75), SIMD3(side * 2.85, -0.38, fz + 0.9), thickness: 0.09, material: tips))
            }
            fz -= 8
        }
        root.addChildNode(h.flattenedClone())
    }

    /// One gyroscope ring (built in the XZ plane, then turned by `tilt`).
    private func gyroRing(radius: CGFloat, tilt: SCNVector3, mat: SCNMaterial, glow: SCNMaterial) -> SCNNode {
        let n = SCNNode()
        let core = SCNTorus(ringRadius: radius, pipeRadius: 0.16)
        core.ringSegmentCount = 120
        core.pipeSegmentCount = 8
        core.materials = [mat]
        n.addChildNode(SCNNode(geometry: core))
        let shell = SCNTorus(ringRadius: radius, pipeRadius: 0.7)
        shell.ringSegmentCount = 120
        shell.pipeSegmentCount = 8
        shell.materials = [glow]
        n.addChildNode(SCNNode(geometry: shell))
        // Dark structural band so the ring reads as an object, not just a line.
        let band = SCNTorus(ringRadius: radius, pipeRadius: 0.45)
        band.ringSegmentCount = 120
        band.pipeSegmentCount = 6
        band.materials = [Materials.metal(NSColor(calibratedWhite: 0.12, alpha: 1), roughness: 0.3, metalness: 0.85)]
        let bn = SCNNode(geometry: band)
        bn.scale = SCNVector3(1, 1.6, 1)
        bn.position = SCNVector3(0, -0.2, 0)
        n.addChildNode(bn)
        // Marker lights around the ring.
        for k in 0..<16 {
            let a = Float(k) / 16 * 2 * .pi
            let p = SIMD3<Float>(cos(a), 0, sin(a))
            n.addChildNode(Stage.segment(p * Float(radius - 1.2), p * Float(radius + 1.2), thickness: 0.18, material: mat))
        }
        let wrapper = SCNNode()
        let flat = n.flattenedClone()
        flat.eulerAngles = tilt
        wrapper.addChildNode(flat)
        return wrapper
    }

    private func buildGyroscope() {
        let mat = groupMaterial(.rings)
        let glow = groupMaterial(.rings, glow: true, glowOpacity: 0.3)
        gyroHolder.simdPosition = gyroCenter
        root.addChildNode(gyroHolder)

        // Gimbal: the outer ring faces the player and turns about Y, the middle ring lies flat
        // and tips about X, the inner ring stands side-on and rolls about Z.
        gyroOuter.addChildNode(gyroRing(radius: 26, tilt: SCNVector3(CGFloat.pi / 2, 0, 0), mat: mat, glow: glow))
        gyroMiddle.addChildNode(gyroRing(radius: 20.5, tilt: SCNVector3(0, 0, 0), mat: mat, glow: glow))
        gyroInner.addChildNode(gyroRing(radius: 15, tilt: SCNVector3(0, 0, CGFloat.pi / 2), mat: mat, glow: glow))
        gyroMiddle.addChildNode(gyroInner)
        gyroOuter.addChildNode(gyroMiddle)
        gyroHolder.addChildNode(gyroOuter)

        // Glowing core.
        let core = SCNSphere(radius: 2.4)
        core.segmentCount = 32
        core.materials = [mat]
        gyroHolder.addChildNode(SCNNode(geometry: core))
        let halo = SCNSphere(radius: 5)
        halo.segmentCount = 32
        halo.materials = [glow]
        gyroHolder.addChildNode(SCNNode(geometry: halo))
    }

    private func buildPlanet() {
        let center = SIMD3<Float>(95, -70, -300)
        let radius: CGFloat = 110
        let holder = SCNNode()

        let body = SCNSphere(radius: radius)
        body.segmentCount = 96
        // Nearly black so only the atmosphere rim and the lit crescent read.
        body.materials = [Materials.metal(NSColor(calibratedRed: 0.012, green: 0.014, blue: 0.024, alpha: 1), roughness: 0.9, metalness: 0.05)]
        holder.addChildNode(SCNNode(geometry: body))

        let atmosphere = SCNSphere(radius: radius * 1.035)
        atmosphere.segmentCount = 96
        let rim = groupMaterial(.back, glow: true, glowOpacity: 0.9)
        rim.shaderModifiers = [.surface: OrbitStage.rimModifier]
        rim.isDoubleSided = false
        atmosphere.materials = [rim]
        holder.addChildNode(SCNNode(geometry: atmosphere))

        // A thin planetary ring.
        let ringMat = groupMaterial(.back, glow: true, glowOpacity: 0.22)
        for (r, pipe) in [(CGFloat(175), CGFloat(5)), (CGFloat(192), CGFloat(2.5))] {
            let ring = SCNTorus(ringRadius: r, pipeRadius: pipe)
            ring.ringSegmentCount = 160
            ring.pipeSegmentCount = 6
            ring.materials = [ringMat]
            let rn = SCNNode(geometry: ring)
            rn.scale = SCNVector3(1, 0.04, 1)
            holder.addChildNode(rn)
        }

        holder.simdPosition = center
        holder.eulerAngles = SCNVector3(0.32, 0, -0.38)
        planet = holder
        root.addChildNode(planet)
    }

    private func buildFans() {
        for (group, side) in [(LightGroup.leftLasers, Float(-1)), (LightGroup.rightLasers, Float(1))] {
            let mat = groupMaterial(group)
            let glow = groupMaterial(group, glow: true, glowOpacity: 0.3)
            // Emitter: a glowing node down in the void.
            let origin = SIMD3<Float>(side * 16, -24, -62)
            let emitter = SCNSphere(radius: 0.9)
            emitter.materials = [mat]
            let en = SCNNode(geometry: emitter)
            en.simdPosition = origin
            root.addChildNode(en)
            for _ in 0..<5 {
                let pivot = SCNNode()
                pivot.simdPosition = origin
                let core = SCNCylinder(radius: 0.07, height: 170)
                core.radialSegmentCount = 6
                core.materials = [mat]
                let cn = SCNNode(geometry: core)
                cn.position = SCNVector3(0, 85, 0)
                pivot.addChildNode(cn)
                let shell = SCNCylinder(radius: 0.3, height: 170)
                shell.radialSegmentCount = 8
                shell.materials = [glow]
                let sn = SCNNode(geometry: shell)
                sn.position = cn.position
                pivot.addChildNode(sn)
                root.addChildNode(pivot)
                if side < 0 { leftFan.append(pivot) } else { rightFan.append(pivot) }
            }
        }
    }

    private func buildAsteroids() {
        var rng = SeededRandom(seed: 17)
        let rock = Materials.metal(NSColor(calibratedRed: 0.2, green: 0.18, blue: 0.17, alpha: 1), roughness: 0.85, metalness: 0.15)
        let holder = SCNNode()
        var placed = 0
        while placed < 46 {
            let px = Float(rng.next(-110, 110)), py = Float(rng.next(-50, 60)), pz = Float(rng.next(-200, -12))
            let p = SIMD3<Float>(px, py, pz)
            // Keep the play corridor and the gyroscope clear.
            if abs(p.x) < 12 && p.y > -12 && p.y < 34 { continue }
            if simd_length(p - gyroCenter) < 34 { continue }
            let s = SCNSphere(radius: CGFloat(rng.next(0.6, 3.6)))
            s.segmentCount = 7
            s.isGeodesic = true
            s.materials = [rock]
            let n = SCNNode(geometry: s)
            n.simdPosition = p
            let sx = Float(rng.next(0.7, 1.3)), sy = Float(rng.next(0.6, 1.1)), sz = Float(rng.next(0.7, 1.4))
            n.simdScale = SIMD3(sx, sy, sz)
            let rx = rng.next(0, 3), ry = rng.next(0, 3), rz = rng.next(0, 3)
            n.eulerAngles = SCNVector3(rx, ry, rz)
            holder.addChildNode(n)
            placed += 1
        }
        let flat = holder.flattenedClone()
        root.addChildNode(flat)
    }

    /// A space station: a long hub with solar wings and a habitat ring that turns about it.
    private func buildStation(at position: SIMD3<Float>, scale: Float, tilt: SIMD3<Float>, rate: Double) {
        let hull = Materials.metal(NSColor(calibratedWhite: 0.32, alpha: 1), roughness: 0.4, metalness: 0.7)
        let panelMat = Materials.metal(NSColor(calibratedRed: 0.06, green: 0.12, blue: 0.3, alpha: 1), roughness: 0.2, metalness: 0.9)
        let strip = groupMaterial(.rings, strength: 0.8)
        let station = SCNNode()

        // Hub along the x axis with docking modules.
        let fixed = SCNNode()
        fixed.addChildNode(Stage.segment(SIMD3(-14, 0, 0), SIMD3(14, 0, 0), thickness: 2.4, material: hull))
        for x: Float in [-8, 0, 8] {
            let module = SCNCylinder(radius: 1.9, height: 3.5)
            module.radialSegmentCount = 16
            module.materials = [hull]
            let mn = SCNNode(geometry: module)
            mn.simdPosition = SIMD3(x, 0, 0)
            mn.eulerAngles.z = .pi / 2
            fixed.addChildNode(mn)
            fixed.addChildNode(Stage.segment(SIMD3(x - 1.8, 1.25, 0), SIMD3(x + 1.8, 1.25, 0), thickness: 0.16, material: strip))
        }
        // Solar wings at both ends, with a lit seam down each panel.
        for x: Float in [-12, 12] {
            for side: Float in [-1, 1] {
                let wing = SCNBox(width: 3.6, height: 0.12, length: 11, chamferRadius: 0)
                wing.materials = [panelMat]
                let wn = SCNNode(geometry: wing)
                wn.simdPosition = SIMD3(x, 0, side * 7)
                fixed.addChildNode(wn)
                fixed.addChildNode(Stage.segment(SIMD3(x, 0, side * 1.2), SIMD3(x, 0, side * 1.5), thickness: 0.3, material: hull))
                for k in 0..<4 {
                    let pz = side * (2.2 + Float(k) * 2.6)
                    fixed.addChildNode(Stage.segment(SIMD3(x - 1.8, 0.08, pz), SIMD3(x + 1.8, 0.08, pz), thickness: 0.05, material: hull))
                }
                let bulb = SCNSphere(radius: 0.3)
                bulb.segmentCount = 8
                bulb.materials = [beaconMat]
                let bn = SCNNode(geometry: bulb)
                bn.simdPosition = SIMD3(x, 0.2, side * 12.6)
                fixed.addChildNode(bn)
            }
        }
        station.addChildNode(fixed.flattenedClone())

        // Habitat ring around the hub (its axis is the hub), joined by spokes; it turns.
        let habitat = SCNNode()
        let ring = SCNTorus(ringRadius: 8.5, pipeRadius: 1.1)
        ring.ringSegmentCount = 64
        ring.pipeSegmentCount = 12
        ring.materials = [hull]
        habitat.addChildNode(SCNNode(geometry: ring))
        let lights = SCNTorus(ringRadius: 9.6, pipeRadius: 0.14)
        lights.ringSegmentCount = 64
        lights.pipeSegmentCount = 6
        lights.materials = [strip]
        habitat.addChildNode(SCNNode(geometry: lights))
        for k in 0..<4 {
            let a = Float(k) / 4 * 2 * .pi
            habitat.addChildNode(Stage.segment(SIMD3(cos(a) * 1.2, 0, sin(a) * 1.2), SIMD3(cos(a) * 7.5, 0, sin(a) * 7.5),
                                               thickness: 0.45, material: hull))
        }
        // Torus axis is y; turn it to lie along the hub (x).
        let habitatFlat = habitat.flattenedClone()
        habitatFlat.eulerAngles.z = .pi / 2
        let spinner = SCNNode()
        spinner.addChildNode(habitatFlat)
        station.addChildNode(spinner)
        habitats.append((spinner, rate))

        station.simdScale = SIMD3(repeating: scale)
        station.eulerAngles = SCNVector3(CGFloat(tilt.x), CGFloat(tilt.y), CGFloat(tilt.z))
        station.simdPosition = position
        root.addChildNode(station)
    }

    // MARK: Events

    override func idle() {
        super.idle()
        gyroTarget = 0.12
    }

    override func spin(_ d: Double) {
        gyroVelocity = d * 2.2
        gyroTarget = d * 0.22
    }

    override func zoom() {
        gyroScaleTarget = gyroScaleTarget > 0.9 ? 0.72 : 1
    }

    override func groupDidUpdate(_ group: LightGroup, color: NSColor, level: CGFloat) {
        guard group == .rings, let gyroLight else { return }
        gyroLight.color = color
        gyroLight.intensity = min(level, 3) * 420
    }

    override func animate(dt: Double) {
        gyroVelocity += (gyroTarget - gyroVelocity) * (1 - exp(-dt * 1.4))
        gyroScale += (gyroScaleTarget - gyroScale) * (1 - exp(-dt * 2.2))
        gyroAngles += SIMD3(1.0, 1.35, 0.8) * gyroVelocity * dt
        gyroOuter.eulerAngles = SCNVector3(0, CGFloat(gyroAngles.y), 0)
        gyroMiddle.eulerAngles = SCNVector3(CGFloat(gyroAngles.x) + 1.1, 0, 0)
        gyroInner.eulerAngles = SCNVector3(0, 0, CGFloat(gyroAngles.z) + 0.7)
        gyroHolder.simdScale = SIMD3(repeating: Float(gyroScale))

        planet.eulerAngles.y = CGFloat(time * 0.01)

        for h in habitats { h.node.eulerAngles.x = CGFloat(time * h.rate) }
        let blink = time.truncatingRemainder(dividingBy: 2.2)
        beaconMat.emission.intensity = blink < 0.15 ? 2.6 : 0.2

        // The two fans lean across each other above the runway.
        for (group, nodes) in [(LightGroup.leftLasers, leftFan), (LightGroup.rightLasers, rightFan)] {
            let side: Double = group == .leftLasers ? -1 : 1
            fanPhase[group]! += dt * (laserSpeed[group] ?? 0)
            let ph = fanPhase[group]!
            for (i, n) in nodes.enumerated() {
                // Positive z-rotation tilts a beam to the left, so the left fan leans right (negative).
                let lean = side * (0.12 + Double(i) * 0.13)
                n.eulerAngles.z = CGFloat(lean + 0.16 * sin(ph + Double(i) * 0.8))
                n.eulerAngles.x = CGFloat(-0.25 + 0.12 * sin(ph * 0.6 + Double(i)))
            }
        }
    }
}
