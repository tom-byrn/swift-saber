import AppKit
import SceneKit
import simd
import SaberCore

/// "Sunset Drive": a retro synthwave highway. A neon grid scrolls under the runway towards
/// the player, a striped sun sets behind a city skyline and fans of light rays, solid
/// wireframe mountain ridges line both sides and neon palms frame the road.
///
/// Light groups: floor = grid + runway, back = sun + horizon, rings = mountain ridges,
/// left/right lasers = sun rays on each side.
final class SunsetDriveStage: Stage {
    private let gridSpacing: Float = 4
    private var gridScroll = SCNNode()
    private var gridOffset: Double = 0
    private var gridBoost: Double = 0
    private var gridBaseSpeed: Double = 7

    private var leftRays: [SCNNode] = []
    private var rightRays: [SCNNode] = []
    private var rayPhase: [LightGroup: Double] = [.leftLasers: 0, .rightLasers: 2.1]

    private var sun = SCNNode()
    private var mountainLight: SCNLight?

    private let sunCenter = SIMD3<Float>(0, 12, -170)
    private let sunRadius: Float = 34

    override func build() {
        sky = SkyStyle(zenith: NSColor(calibratedRed: 0.03, green: 0.01, blue: 0.09, alpha: 1),
                       horizon: NSColor(calibratedRed: 0.3, green: 0.07, blue: 0.27, alpha: 1),
                       nadir: NSColor(calibratedRed: 0.035, green: 0.01, blue: 0.05, alpha: 1),
                       glow: NSColor(calibratedRed: 0.55, green: 0.2, blue: 0.22, alpha: 1),
                       glowWidth: 0.08,
                       nebulae: SkyStyle.ring(of: 6, v: 0.36, radius: 0.07,
                                              colors: [NSColor(calibratedRed: 0.2, green: 0.05, blue: 0.24, alpha: 1),
                                                       NSColor(calibratedRed: 0.24, green: 0.07, blue: 0.16, alpha: 1)]))
        fogColor = NSColor(calibratedRed: 0.17, green: 0.04, blue: 0.16, alpha: 1)
        fogStart = 60
        fogEnd = 320

        addFloor(reflectivity: 0.16, color: NSColor(calibratedRed: 0.02, green: 0.008, blue: 0.03, alpha: 1))
        let floorMat = groupMaterial(.floor)
        let floorGlow = groupMaterial(.floor, glow: true, glowOpacity: 0.25)
        addPlatform(trimMaterial: floorMat, body: NSColor(calibratedRed: 0.05, green: 0.02, blue: 0.07, alpha: 1))
        buildGrid(floorMat, floorGlow)
        buildSun()
        buildRays()
        buildMountains()
        buildSkyline()
        buildPalms()
        addBaseLights(ambient: NSColor(calibratedRed: 0.6, green: 0.35, blue: 0.75, alpha: 1), ambientIntensity: 220)
        mountainLight = makeGroupLight(at: SCNVector3(0, 8, -30), range: 45)
        addStars(count: 500, radius: 220, minY: 30, seed: 3)
        addDust(color: NSColor(calibratedRed: 1, green: 0.55, blue: 0.85, alpha: 0.3), birthRate: 22)
    }

    // MARK: Build

    private func buildGrid(_ mat: SCNMaterial, _ glow: SCNMaterial) {
        // Static lines running towards the horizon, leaving the runway itself clear.
        let lines = SCNNode()
        var xs: [Float] = [1.6]
        var x: Float = 4
        while x <= 60 { xs.append(x); x += 3 + x * 0.06 }
        for x in xs {
            for side: Float in [-1, 1] {
                let core: CGFloat = x < 2 ? 0.06 : 0.045
                let b = SCNBox(width: core, height: 0.01, length: 240, chamferRadius: 0)
                b.materials = [mat]
                let n = SCNNode(geometry: b)
                n.simdPosition = SIMD3(side * x, 0.006, -118)
                lines.addChildNode(n)
                if x < 2 {
                    // Runway edges get a soft glow.
                    let g = SCNBox(width: 0.3, height: 0.02, length: 240, chamferRadius: 0)
                    g.materials = [glow]
                    let gn = SCNNode(geometry: g)
                    gn.simdPosition = n.simdPosition
                    lines.addChildNode(gn)
                }
            }
        }
        root.addChildNode(lines.flattenedClone())

        // Cross lines scroll towards the player (moved every frame by `gridOffset`).
        let cross = SCNNode()
        for i in 0..<60 {
            let z = -2 - Float(i) * gridSpacing
            for side: Float in [-1, 1] {
                let b = SCNBox(width: 70, height: 0.01, length: 0.045, chamferRadius: 0)
                b.materials = [mat]
                let n = SCNNode(geometry: b)
                n.simdPosition = SIMD3(side * (1.6 + 35), 0.004, z)
                cross.addChildNode(n)
            }
        }
        gridScroll = cross.flattenedClone()
        root.addChildNode(gridScroll)
    }

    private func buildSun() {
        let mat = groupMaterial(.back)
        let glow = groupMaterial(.back, glow: true, glowOpacity: 0.18)
        let holder = SCNNode()
        let r = sunRadius
        // Horizontal slices: solid on top, then stripes whose gaps widen towards the horizon.
        var y = r
        while y > -r * 0.5 {
            let band: Float, gap: Float
            if y > r * 0.18 {
                band = 1.2; gap = 0
            } else {
                let t = min(1, (r * 0.18 - y) / (r * 0.55))
                band = 2.6 - 1.7 * t
                gap = 0.45 + 1.7 * t
            }
            let yc = y - band / 2
            let chord = 2 * sqrt(max(r * r - yc * yc, 0))
            if chord > 0.5 {
                let b = SCNBox(width: CGFloat(chord), height: CGFloat(band + (gap == 0 ? 0.05 : 0)), length: 0.3, chamferRadius: 0)
                b.materials = [mat]
                let n = SCNNode(geometry: b)
                n.simdPosition = sunCenter + SIMD3(0, yc, 0)
                holder.addChildNode(n)
            }
            y -= band + gap
        }
        // Soft halo behind the disc.
        for (scale, z) in [(Float(1.25), Float(-2)), (Float(1.6), Float(-3))] {
            let disc = SCNCylinder(radius: CGFloat(r * scale), height: 0.1)
            disc.radialSegmentCount = 64
            disc.materials = [glow]
            let dn = SCNNode(geometry: disc)
            dn.eulerAngles.x = .pi / 2
            dn.simdPosition = sunCenter + SIMD3(0, 0, z)
            holder.addChildNode(dn)
        }
        // Horizon line.
        let bar = SCNBox(width: 400, height: 0.35, length: 0.3, chamferRadius: 0)
        bar.materials = [mat]
        let barNode = SCNNode(geometry: bar)
        barNode.simdPosition = SIMD3(0, 0.2, -165)
        holder.addChildNode(barNode)
        let barGlow = SCNBox(width: 400, height: 3, length: 0.4, chamferRadius: 0)
        barGlow.materials = [glow]
        let bg = SCNNode(geometry: barGlow)
        bg.simdPosition = barNode.simdPosition
        holder.addChildNode(bg)

        sun = holder.flattenedClone()
        root.addChildNode(sun)
    }

    private func buildRays() {
        for (group, side) in [(LightGroup.leftLasers, Float(-1)), (LightGroup.rightLasers, Float(1))] {
            let mat = groupMaterial(group)
            let glow = groupMaterial(group, glow: true, glowOpacity: 0.3)
            for _ in 0..<5 {
                let pivot = SCNNode()
                pivot.simdPosition = sunCenter + SIMD3(0, 0, -6)
                let core = SCNCylinder(radius: 0.35, height: 160)
                core.radialSegmentCount = 6
                core.materials = [mat]
                let cn = SCNNode(geometry: core)
                cn.position = SCNVector3(0, 80, 0)
                pivot.addChildNode(cn)
                let shell = SCNCylinder(radius: 1.4, height: 160)
                shell.radialSegmentCount = 8
                shell.materials = [glow]
                let sn = SCNNode(geometry: shell)
                sn.position = cn.position
                pivot.addChildNode(sn)
                root.addChildNode(pivot)
                if side < 0 { leftRays.append(pivot) } else { rightRays.append(pivot) }
            }
        }
    }

    private func buildMountains() {
        let mat = groupMaterial(.rings)
        let glow = groupMaterial(.rings, glow: true, glowOpacity: 0.3)
        let holder = SCNNode()
        let fill = Materials.silhouette(NSColor(calibratedRed: 0.07, green: 0.015, blue: 0.09, alpha: 1))
        let farFill = Materials.silhouette(NSColor(calibratedRed: 0.11, green: 0.025, blue: 0.13, alpha: 1))
        var rng = SeededRandom(seed: 11)
        for side: Float in [-1, 1] {
            for layer in 0..<2 {
                let z: Float = layer == 0 ? -80 : -125
                let startX: Float = layer == 0 ? 16 : 26
                let heightScale: Float = layer == 0 ? 1 : 1.6
                var pts: [SIMD3<Float>] = [SIMD3(side * startX, 0, z)]
                var x = startX
                while x < 170 {
                    x += Float(rng.next(5, 12))
                    let ramp: Float = min(1, (x - startX) / 25 + 0.35)
                    let peak: Float = Float(rng.next(7, 20)) * heightScale * ramp
                    let peakZ: Float = z + Float(rng.next(-8, 8))
                    pts.append(SIMD3<Float>(side * x, peak, peakZ))
                    x += Float(rng.next(5, 12))
                    let valley: Float = Float(rng.next(0.5, 5)) * heightScale
                    let valleyZ: Float = z + Float(rng.next(-8, 8))
                    pts.append(SIMD3<Float>(side * x, valley, valleyZ))
                }
                let core: CGFloat = layer == 0 ? 0.16 : 0.24
                // Solid body under the ridge line so the range blocks out the sky behind it.
                holder.addChildNode(Stage.curtain(pts, baseY: 0, material: layer == 0 ? fill : farFill))
                for i in 0..<(pts.count - 1) {
                    neonSegment(pts[i], pts[i + 1], core: core, glow: core * 5, material: mat, glowMaterial: glow, into: holder)
                }
                // Wireframe facets: each peak drops to the ground towards the viewer and away.
                for p in pts where p.y > 4 {
                    for dz: Float in [14, -12] {
                        let foot = SIMD3<Float>(p.x - side * Float(rng.next(-6, 6)), 0, p.z + dz)
                        holder.addChildNode(Stage.segment(p, foot, thickness: core * 0.5, material: mat))
                    }
                }
            }
        }
        root.addChildNode(holder.flattenedClone())
    }

    /// A low city skyline on the horizon, silhouetted against the sun.
    private func buildSkyline() {
        let body = Materials.silhouette(NSColor(calibratedRed: 0.05, green: 0.01, blue: 0.07, alpha: 1))
        let trim = groupMaterial(.rings, strength: 0.5)
        let windowsMat = groupMaterial(.back, strength: 0.35)
        let city = SCNNode()
        var rng = SeededRandom(seed: 29)
        var x: Float = -150
        while x < 150 {
            let w = Float(rng.next(3, 8))
            let centre = abs(x + w / 2)
            let h = Float(centre < 40 ? rng.next(2, 6.5) : rng.next(3, 12))
            let z = Float(-150 - rng.next(0, 8))
            let box = SCNBox(width: CGFloat(w), height: CGFloat(h), length: 4, chamferRadius: 0)
            box.materials = [body]
            let n = SCNNode(geometry: box)
            n.simdPosition = SIMD3(x + w / 2, h / 2, z)
            city.addChildNode(n)
            city.addChildNode(Stage.segment(SIMD3(x, h, z + 2.05), SIMD3(x + w, h, z + 2.05), thickness: 0.12, material: trim))
            // A few lit window rows.
            var wy: Float = 1.2
            while wy < h - 0.8 {
                if rng.next(0, 1) < 0.45 {
                    city.addChildNode(Stage.segment(SIMD3(x + 0.6, wy, z + 2.05), SIMD3(x + w - 0.6, wy, z + 2.05),
                                                    thickness: 0.05, height: 0.3, material: windowsMat))
                }
                wy += 1.4
            }
            // Antenna on some of the taller blocks.
            if h > 8 && rng.next(0, 1) < 0.5 {
                city.addChildNode(Stage.segment(SIMD3(x + w / 2, h, z), SIMD3(x + w / 2, h + 3, z), thickness: 0.12, material: trim))
            }
            x += w + Float(rng.next(0.2, 2.5))
        }
        root.addChildNode(city.flattenedClone())
    }

    /// Neon palms along both sides of the road, leaning away from it.
    private func buildPalms() {
        let trunkMat = Materials.metal(NSColor(calibratedRed: 0.12, green: 0.06, blue: 0.14, alpha: 1), roughness: 0.6, metalness: 0.3)
        let frond = groupMaterial(.rings, strength: 0.8)
        let ring = groupMaterial(.floor, strength: 0.6)
        let palms = SCNNode()
        var rng = SeededRandom(seed: 47)
        var z: Float = -10
        var side: Float = -1
        while z > -110 {
            let base = SIMD3<Float>(side * Float(rng.next(6.5, 10.5)), 0, z)
            let height = Float(rng.next(7, 9.5))
            let lean = Float(rng.next(1.2, 2.6))
            let s = side
            func trunk(_ t: Float) -> SIMD3<Float> { base + SIMD3<Float>(s * lean * t * t, height * t, 0) }
            let steps = 7
            for i in 0..<steps {
                let a = trunk(Float(i) / Float(steps)), b = trunk(Float(i + 1) / Float(steps))
                let thick = CGFloat(0.34 - 0.14 * Float(i) / Float(steps))
                palms.addChildNode(Stage.segment(a, b, thickness: thick, material: trunkMat))
                // Glowing growth rings up the trunk.
                palms.addChildNode(Stage.segment(a - SIMD3(0, 0.03, 0), a + SIMD3(0, 0.03, 0), thickness: thick + 0.06, material: ring))
            }
            let crown = trunk(1)
            let fronds = 8
            let turn = Float(rng.next(0, 1))
            for f in 0..<fronds {
                let ang = (Float(f) + turn) / Float(fronds) * 2 * .pi
                let dir = SIMD3<Float>(cos(ang), 0, sin(ang))
                let length = Float(rng.next(3, 4))
                var prev = crown
                for k in 1...5 {
                    let t = Float(k) / 5
                    let droop: Float = 1.0 * t - 2.4 * t * t
                    let p: SIMD3<Float> = crown + dir * (length * t) + SIMD3<Float>(0, droop, 0)
                    palms.addChildNode(Stage.segment(prev, p, thickness: 0.09, material: frond))
                    prev = p
                }
            }
            z -= Float(rng.next(9, 14))
            side = -side
        }
        root.addChildNode(palms.flattenedClone())
    }

    // MARK: Events

    override func idle() {
        super.idle()
        gridBaseSpeed = 5
    }

    override func spin(_ direction: Double) {
        gridBoost = 22
    }

    override func zoom() {
        gridBaseSpeed = gridBaseSpeed > 8 ? 6 : 11
    }

    override func groupDidUpdate(_ group: LightGroup, color: NSColor, level: CGFloat) {
        guard group == .rings, let mountainLight else { return }
        mountainLight.color = color
        mountainLight.intensity = min(level, 3) * 300
    }

    override func animate(dt: Double) {
        gridBoost *= exp(-dt * 1.8)
        gridOffset += dt * (gridBaseSpeed + gridBoost)
        gridScroll.simdPosition.z = Float(gridOffset.truncatingRemainder(dividingBy: Double(gridSpacing)))

        // The sun breathes with the back lights.
        let s = 1 + 0.015 * min(level(.back), 3)
        sun.simdScale = SIMD3(repeating: s)
        sun.simdPosition = sunCenter * (1 - s) // keep the disc centred while scaling

        for (group, nodes) in [(LightGroup.leftLasers, leftRays), (LightGroup.rightLasers, rightRays)] {
            let side: Double = group == .leftLasers ? 1 : -1 // positive angle tilts left
            rayPhase[group]! += dt * (laserSpeed[group] ?? 0)
            let ph = rayPhase[group]!
            for (i, n) in nodes.enumerated() {
                let base = 0.22 + Double(i) * 0.28
                let a = side * (base + 0.13 * sin(ph * 1.3 + Double(i) * 0.9))
                n.eulerAngles.z = CGFloat(a)
            }
        }
    }
}
