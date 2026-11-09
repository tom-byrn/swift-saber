import AppKit
import SceneKit
import simd
import SaberCore

/// "Neon Skyline": a floating skybridge high above a night city. Neon-trimmed towers with lit
/// windows, billboards and blinking antennas fall away on both sides, flying traffic streams
/// between them, glowing streets run far below, searchlights sweep the sky and three halos
/// hover over the runway under a huge moon.
///
/// Light groups: floor = bridge + streets, rings = tower trim + halos, back = moon,
/// left/right lasers = searchlights on each side.
final class NeonSkylineStage: Stage {
    private var halos: [SCNNode] = []
    private var haloAngles: [Double] = [0, 1, 2]
    private var haloSpin: Double = 0.15
    private var haloSpinTarget: Double = 0.15
    private var haloTilt: Double = 0.3
    private var haloHeight: Double = 13
    private var haloHeightTarget: Double = 13

    private var leftLights: [(node: SCNNode, offset: Double)] = []
    private var rightLights: [(node: SCNNode, offset: Double)] = []
    private var searchPhase: [LightGroup: Double] = [.leftLasers: 0, .rightLasers: 1.9]

    private var cityLight: SCNLight?
    private let beaconMat = Materials.neon(NSColor(calibratedRed: 1, green: 0.12, blue: 0.15, alpha: 1), intensity: 0.2)
    private var traffic: [(node: SCNNode, speed: Double, spacing: Double)] = []
    private var trafficOffset: Double = 0

    private let streetY: Float = -70

    override func build() {
        sky = SkyStyle(zenith: NSColor(calibratedRed: 0.02, green: 0.015, blue: 0.065, alpha: 1),
                       horizon: NSColor(calibratedRed: 0.17, green: 0.07, blue: 0.21, alpha: 1),
                       nadir: NSColor(calibratedRed: 0.2, green: 0.09, blue: 0.12, alpha: 1),
                       glow: NSColor(calibratedRed: 0.36, green: 0.14, blue: 0.28, alpha: 1),
                       glowWidth: 0.09)
        fogColor = NSColor(calibratedRed: 0.1, green: 0.045, blue: 0.13, alpha: 1)
        fogStart = 35
        fogEnd = 270

        let floorMat = groupMaterial(.floor)
        let floorGlow = groupMaterial(.floor, glow: true, glowOpacity: 0.3)
        addPlatform(trimMaterial: floorMat, body: NSColor(calibratedWhite: 0.05, alpha: 1))
        buildBridge(floorMat, floorGlow)
        buildCity(floorMat, floorGlow)
        buildHalos()
        buildSearchlights()
        buildMoon()
        buildTraffic()
        addBaseLights(ambient: NSColor(calibratedRed: 0.5, green: 0.42, blue: 0.75, alpha: 1), ambientIntensity: 230)
        cityLight = makeGroupLight(at: SCNVector3(0, 6, -20), range: 40)
        addStars(count: 350, radius: 260, minY: 40, seed: 5)
        addDust(color: NSColor(calibratedRed: 1, green: 0.8, blue: 0.6, alpha: 0.25), birthRate: 18)
    }

    // MARK: Build

    private func buildBridge(_ mat: SCNMaterial, _ glow: SCNMaterial) {
        let deck = SCNBox(width: 3.2, height: 0.3, length: 170, chamferRadius: 0)
        deck.materials = [Materials.metal(NSColor(calibratedWhite: 0.09, alpha: 1), roughness: 0.3, metalness: 0.75)]
        let dn = SCNNode(geometry: deck)
        dn.position = SCNVector3(0, -0.16, -84)
        root.addChildNode(dn)

        let h = SCNNode()
        for x: Float in [-1.6, 1.6] {
            h.addChildNode(Stage.segment(SIMD3(x, 0.0, -0.7), SIMD3(x, 0.0, -170), thickness: 0.05, material: mat))
            h.addChildNode(Stage.segment(SIMD3(x, 0.005, -0.7), SIMD3(x, 0.005, -170), thickness: 0.16, height: 0.005, material: glow))
            // Low railing posts with a top rail.
            h.addChildNode(Stage.segment(SIMD3(x * 1.02, 0.55, -2), SIMD3(x * 1.02, 0.55, -170), thickness: 0.025, material: mat))
            var z: Float = -3
            while z > -170 {
                h.addChildNode(Stage.segment(SIMD3(x * 1.02, 0, z), SIMD3(x * 1.02, 0.55, z), thickness: 0.025, material: mat))
                z -= 3
            }
        }
        // Deck seams.
        let seams = groupMaterial(.floor, strength: 0.3)
        var sz: Float = -2
        while sz > -170 {
            h.addChildNode(Stage.segment(SIMD3(-1.55, 0.002, sz), SIMD3(1.55, 0.002, sz), thickness: 0.025, height: 0.004, material: seams))
            sz -= 3
        }
        // Support struts below the deck, fading into the dark.
        var z: Float = -10
        let strut = Materials.metal(NSColor(calibratedWhite: 0.1, alpha: 1), roughness: 0.4, metalness: 0.8)
        while z > -170 {
            h.addChildNode(Stage.segment(SIMD3(0, -0.3, z), SIMD3(0, -40, z), thickness: 0.6, material: strut))
            z -= 30
        }
        root.addChildNode(h.flattenedClone())
    }

    private func buildCity(_ streetMat: SCNMaterial, _ streetGlow: SCNMaterial) {
        let trim = groupMaterial(.rings)
        let billboardMat = groupMaterial(.back, strength: 0.9)
        let bodyColor = NSColor(calibratedRed: 0.06, green: 0.05, blue: 0.08, alpha: 1)
        let roof = Materials.metal(NSColor(calibratedRed: 0.08, green: 0.07, blue: 0.1, alpha: 1), roughness: 0.6, metalness: 0.5)
        let mast = Materials.metal(NSColor(calibratedWhite: 0.16, alpha: 1), roughness: 0.4, metalness: 0.8)
        // Facades share a few window materials, bucketed by tower height so floors stay ~3.2 m tall.
        let windowTiles = [Textures.windows(seed: 3), Textures.windows(seed: 8)]
        var facades: [Int: SCNMaterial] = [:]
        func facade(height: Float, variant: Int) -> SCNMaterial {
            let bucket = max(1, Int((height / 16).rounded()))
            let key = bucket * 2 + variant
            if let m = facades[key] { return m }
            let texSpan: Float = 32 * 3.2 // the tile is 32 floors tall
            let m = Materials.windowed(body: bodyColor, windows: windowTiles[variant],
                                       repeats: CGSize(width: 0.5, height: CGFloat(Float(bucket * 16) / texSpan)), intensity: 0.85)
            facades[key] = m
            return m
        }
        let beacons = SCNNode()
        let city = SCNNode()
        var rng = SeededRandom(seed: 42)
        let columns: [Float] = [10, 22, 36, 52, 70, 92]
        for side: Float in [-1, 1] {
            for (ci, cx) in columns.enumerated() {
                var z: Float = -4 - Float(rng.next(0, 8))
                while z > -240 {
                    let w = Float(rng.next(6, 10))
                    let d = Float(rng.next(7, 12))
                    let x = side * (cx + Float(rng.next(-1.5, 1.5)))
                    // Towers near the camera stay below the deck so they never block the view.
                    let nearCap: Float = z > -25 ? -6 : (ci == 0 ? 6 : 40)
                    let jitter = Float(rng.next(-30, 10))
                    let distanceLift: Float = min(-z, 160) * 0.08
                    let rawTop: Float = jitter + Float(ci) * 7 + distanceLift
                    let top = min(nearCap, rawTop)
                    let bottom: Float = -95
                    let height = top - bottom
                    let box = SCNBox(width: CGFloat(w), height: CGFloat(height), length: CGFloat(d), chamferRadius: 0)
                    let walls = facade(height: height, variant: Int(rng.next(0, 1.999)))
                    // Order: front, right, back, left, top, bottom.
                    box.materials = [walls, walls, walls, walls, roof, roof]
                    let bn = SCNNode(geometry: box)
                    bn.simdPosition = SIMD3(x, bottom + height / 2, z - d / 2)
                    city.addChildNode(bn)

                    // Neon on the faces that look at the road / player.
                    let faceX = x - side * w / 2 - side * 0.05
                    let front = z + 0.05
                    let back = z - d
                    // Vertical corner strips.
                    city.addChildNode(Stage.segment(SIMD3(faceX, bottom, front), SIMD3(faceX, top, front), thickness: 0.12, material: trim))
                    // Roof outline.
                    city.addChildNode(Stage.segment(SIMD3(faceX, top, front), SIMD3(faceX, top, back), thickness: 0.12, material: trim))
                    city.addChildNode(Stage.segment(SIMD3(faceX, top, front), SIMD3(faceX + side * w, top, front), thickness: 0.12, material: trim))
                    // Antenna mast with a blinking beacon on the taller towers.
                    if top > 12 && rng.next(0, 1) < 0.55 {
                        let mastTop = top + Float(rng.next(5, 12))
                        let mx = x + Float(rng.next(-1.5, 1.5)), mz = z - d / 2
                        city.addChildNode(Stage.segment(SIMD3(mx, top, mz), SIMD3(mx, mastTop, mz), thickness: 0.22, material: mast))
                        let bulb = SCNSphere(radius: 0.35)
                        bulb.segmentCount = 8
                        bulb.materials = [beaconMat]
                        let bn = SCNNode(geometry: bulb)
                        bn.simdPosition = SIMD3(mx, mastTop, mz)
                        beacons.addChildNode(bn)
                    }
                    // A billboard on some road-facing walls of the inner columns.
                    if ci >= 1 && ci <= 3 && top > 10 && rng.next(0, 1) < 0.3 {
                        let bh = Float(rng.next(4, 7))
                        let by = top - 4 - bh / 2
                        let panel = SCNBox(width: 0.12, height: CGFloat(bh), length: CGFloat(d * 0.75), chamferRadius: 0)
                        panel.materials = [billboardMat]
                        let pn = SCNNode(geometry: panel)
                        pn.simdPosition = SIMD3(faceX - side * 0.12, by, z - d / 2)
                        city.addChildNode(pn)
                        // Dark frame around it.
                        let frame = SCNBox(width: 0.08, height: CGFloat(bh + 0.6), length: CGFloat(d * 0.75 + 0.6), chamferRadius: 0)
                        frame.materials = [roof]
                        let fn = SCNNode(geometry: frame)
                        fn.simdPosition = SIMD3(faceX - side * 0.04, by, z - d / 2)
                        city.addChildNode(fn)
                    }
                    // Window bands on some towers.
                    if rng.next(0, 1) > 0.45 {
                        var wy = top - 3
                        let step = Float(rng.next(2.5, 5))
                        while wy > top - 45 && wy > bottom {
                            city.addChildNode(Stage.segment(SIMD3(faceX, wy, front - 0.6), SIMD3(faceX, wy, back + 0.6),
                                                            thickness: 0.07, height: 0.45, material: trim))
                            wy -= step
                        }
                    }
                    z -= d + Float(rng.next(4, 9))
                }
            }
            // Streets far below, between the tower columns.
            for (i, cx) in columns.enumerated() where i < columns.count - 1 {
                let sx = side * (cx + columns[i + 1]) / 2 + side * 3
                city.addChildNode(Stage.segment(SIMD3(sx, streetY, 0), SIMD3(sx, streetY, -260), thickness: 0.5, material: streetMat))
                city.addChildNode(Stage.segment(SIMD3(sx, streetY, 0), SIMD3(sx, streetY, -260), thickness: 2.5, material: streetGlow))
            }
        }
        // Cross streets.
        var cz: Float = -20
        while cz > -260 {
            city.addChildNode(Stage.segment(SIMD3(-110, streetY, cz), SIMD3(110, streetY, cz), thickness: 0.45, material: streetMat))
            cz -= 34
        }
        root.addChildNode(city.flattenedClone())
        root.addChildNode(beacons.flattenedClone())
    }

    /// Lanes of flying cars streaming through the gaps between tower columns and above the roofs:
    /// white headlights coming towards the player, red tail lights heading away.
    private func buildTraffic() {
        let headColor = NSColor(calibratedRed: 1, green: 0.93, blue: 0.82, alpha: 1)
        let tailColor = NSColor(calibratedRed: 1, green: 0.16, blue: 0.2, alpha: 1)
        let head = Materials.neon(headColor, intensity: 1.5)
        let tail = Materials.neon(tailColor, intensity: 1.5)
        let headGlow = Materials.glow(headColor, intensity: 1, opacity: 0.35)
        let tailGlow = Materials.glow(tailColor, intensity: 1, opacity: 0.35)
        let lanes: [(x: Float, y: Float, towards: Bool, spacing: Float)] = [
            (-44, -12, true, 13), (-45.5, -18, false, 17), (44, -15, false, 15), (45.5, -9, true, 12),
            (-61, -24, true, 16), (61, -20, false, 14), (-81, -7, false, 18), (81, -30, true, 15),
            (-26, 46, true, 22), (28, 48.5, false, 19), (-50, 52, false, 24), (52, 50, true, 20),
        ]
        for lane in lanes {
            let n = SCNNode()
            var z = lane.spacing
            while z > -290 {
                for (mat, w, h, l) in [(lane.towards ? head : tail, CGFloat(0.5), CGFloat(0.22), CGFloat(1.5)),
                                       (lane.towards ? headGlow : tailGlow, CGFloat(1.4), CGFloat(0.9), CGFloat(3))] {
                    let car = SCNBox(width: w, height: h, length: l, chamferRadius: 0)
                    car.materials = [mat]
                    let cn = SCNNode(geometry: car)
                    cn.simdPosition = SIMD3(lane.x, lane.y, z)
                    n.addChildNode(cn)
                }
                z -= lane.spacing
            }
            let flat = n.flattenedClone()
            root.addChildNode(flat)
            traffic.append((node: flat, speed: lane.towards ? 20.0 : -16.0, spacing: Double(lane.spacing)))
        }
    }

    private func buildHalos() {
        let mat = groupMaterial(.rings)
        let glow = groupMaterial(.rings, glow: true, glowOpacity: 0.3)
        for (i, z) in [Float(-32), -64, -96].enumerated() {
            let radius = CGFloat(8 + i * 2)
            let ring = SCNNode()
            let core = SCNTorus(ringRadius: radius, pipeRadius: 0.12)
            core.ringSegmentCount = 96
            core.pipeSegmentCount = 8
            core.materials = [mat]
            ring.addChildNode(SCNNode(geometry: core))
            let shell = SCNTorus(ringRadius: radius, pipeRadius: 0.55)
            shell.ringSegmentCount = 96
            shell.pipeSegmentCount = 8
            shell.materials = [glow]
            ring.addChildNode(SCNNode(geometry: shell))
            // Ticks around the halo.
            for k in 0..<12 {
                let a = Float(k) / 12 * 2 * .pi
                let p = SIMD3<Float>(cos(a), 0, sin(a))
                ring.addChildNode(Stage.segment(p * Float(radius - 0.9), p * Float(radius + 0.9), thickness: 0.1, material: mat))
            }
            let holder = SCNNode()
            holder.addChildNode(ring.flattenedClone())
            holder.simdPosition = SIMD3(0, Float(haloHeight), z)
            root.addChildNode(holder)
            halos.append(holder)
        }
    }

    private func buildSearchlights() {
        for (group, side) in [(LightGroup.leftLasers, Float(-1)), (LightGroup.rightLasers, Float(1))] {
            let mat = groupMaterial(group)
            let glow = groupMaterial(group, glow: true, glowOpacity: 0.16)
            for i in 0..<4 {
                let pivot = SCNNode()
                pivot.simdPosition = SIMD3(side * (20 + Float(i) * 9), Float(4 + i * 3), -40 - Float(i) * 24)
                let core = SCNCylinder(radius: 0.18, height: 140)
                core.radialSegmentCount = 6
                core.materials = [mat]
                let cn = SCNNode(geometry: core)
                cn.position = SCNVector3(0, 70, 0)
                pivot.addChildNode(cn)
                let cone = SCNCone(topRadius: 3.2, bottomRadius: 0.4, height: 140)
                cone.radialSegmentCount = 12
                cone.materials = [glow]
                let gn = SCNNode(geometry: cone)
                gn.position = cn.position
                pivot.addChildNode(gn)
                // Lamp housing.
                let lamp = SCNCylinder(radius: 0.7, height: 0.8)
                lamp.materials = [Materials.metal(NSColor(calibratedWhite: 0.1, alpha: 1), roughness: 0.3, metalness: 0.9)]
                pivot.addChildNode(SCNNode(geometry: lamp))
                root.addChildNode(pivot)
                let entry = (node: pivot, offset: Double(i) * 1.3)
                if side < 0 { leftLights.append(entry) } else { rightLights.append(entry) }
            }
        }
    }

    private func buildMoon() {
        let mat = groupMaterial(.back)
        let glow = groupMaterial(.back, glow: true, glowOpacity: 0.2)
        let holder = SCNNode()
        let center = SIMD3<Float>(0, 40, -235)
        polygonOutline(sides: 48, radius: 22, center: center, core: 0.5, glow: 2.4, material: mat, glowMaterial: glow, into: holder)
        polygonOutline(sides: 48, radius: 17, center: center + SIMD3(0, 0, 0.5), core: 0.25, glow: 1.2, material: mat, glowMaterial: nil, gap: 0.55, into: holder)
        let disc = SCNCylinder(radius: 21.5, height: 0.2)
        disc.radialSegmentCount = 64
        disc.materials = [glow]
        let dn = SCNNode(geometry: disc)
        dn.eulerAngles.x = .pi / 2
        dn.simdPosition = center + SIMD3(0, 0, -1)
        holder.addChildNode(dn)
        root.addChildNode(holder.flattenedClone())
    }

    // MARK: Events

    override func idle() {
        super.idle()
        haloSpinTarget = 0.15
    }

    override func spin(_ d: Double) {
        haloSpin = d * 2.6
        haloSpinTarget = d * 0.2
        haloTilt = haloTilt > 0.4 ? 0.25 : 0.6
    }

    override func zoom() {
        haloHeightTarget = haloHeightTarget > 11 ? 8.5 : 13
    }

    override func groupDidUpdate(_ group: LightGroup, color: NSColor, level: CGFloat) {
        guard group == .rings, let cityLight else { return }
        cityLight.color = color
        cityLight.intensity = min(level, 3) * 280
    }

    override func animate(dt: Double) {
        // Antenna beacons blink in a slow double pulse.
        let blink = time.truncatingRemainder(dividingBy: 1.8)
        beaconMat.emission.intensity = (blink < 0.12 || (blink > 0.3 && blink < 0.42)) ? 2.4 : 0.2

        trafficOffset += dt
        for t in traffic {
            t.node.simdPosition.z = Float((trafficOffset * t.speed).truncatingRemainder(dividingBy: t.spacing))
        }

        haloSpin += (haloSpinTarget - haloSpin) * (1 - exp(-dt * 1.5))
        haloHeight += (haloHeightTarget - haloHeight) * (1 - exp(-dt * 2))
        for (i, h) in halos.enumerated() {
            haloAngles[i] += haloSpin * dt * (i % 2 == 0 ? 1 : -1.2)
            let tilt = haloTilt * (i % 2 == 0 ? 1 : -1)
            h.simdOrientation = simd_quatf(angle: Float(tilt), axis: SIMD3(1, 0, 0)) * simd_quatf(angle: Float(haloAngles[i]), axis: SIMD3(0, 1, 0))
            h.simdPosition.y = Float(haloHeight + Double(i) * 1.5)
        }

        for (group, lights) in [(LightGroup.leftLasers, leftLights), (LightGroup.rightLasers, rightLights)] {
            let side: Float = group == .leftLasers ? -1 : 1
            searchPhase[group]! += dt * (laserSpeed[group] ?? 0)
            let ph = searchPhase[group]!
            for l in lights {
                let dir = SIMD3<Float>(-side * 0.3 + Float(0.6 * sin(ph + l.offset)), 1,
                                       -0.2 + Float(0.4 * cos(ph * 0.8 + l.offset)))
                l.node.simdOrientation = simd_quatf(from: SIMD3(0, 1, 0), to: simd_normalize(dir))
            }
        }
    }
}
