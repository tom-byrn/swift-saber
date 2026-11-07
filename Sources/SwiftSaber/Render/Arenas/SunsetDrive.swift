import AppKit
import SceneKit
import simd
import SaberCore

/// "Sunset Drive": a retro synthwave highway. A neon grid scrolls under the runway towards
/// the player, a striped sun sets on the horizon behind fans of light rays, and wireframe
/// mountain ridges line both sides.
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
        fogColor = NSColor(calibratedRed: 0.035, green: 0.008, blue: 0.055, alpha: 1)
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
        addBaseLights(ambient: NSColor(calibratedRed: 0.6, green: 0.35, blue: 0.75, alpha: 1), ambientIntensity: 160)
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
