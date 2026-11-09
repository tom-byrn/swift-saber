import AppKit
import SceneKit
import simd
import SaberCore

/// The selectable environments ("arenas") the game can be played in.
enum StageKind: String, Codable, CaseIterable, Identifiable {
    case prismHall
    case sunsetDrive
    case warpTunnel
    case neonSkyline
    case orbit

    var id: String { rawValue }

    var title: String {
        switch self {
        case .prismHall: return "Prism Hall"
        case .sunsetDrive: return "Sunset Drive"
        case .warpTunnel: return "Warp Tunnel"
        case .neonSkyline: return "Neon Skyline"
        case .orbit: return "Orbit"
        }
    }

    var tagline: String {
        switch self {
        case .prismHall: return "A mirrored runway through spinning prism rings and laser fans."
        case .sunsetDrive: return "Race down a neon grid towards a striped retro sun."
        case .warpTunnel: return "A twisting tunnel of light frames streaking through hyperspace."
        case .neonSkyline: return "Rooftop runway above a glowing city, searchlights in the sky."
        case .orbit: return "A platform in deep space, circled by giant gyroscope rings."
        }
    }

    /// SF Symbol shown on the arena card.
    var symbol: String {
        switch self {
        case .prismHall: return "octagon"
        case .sunsetDrive: return "sun.horizon"
        case .warpTunnel: return "tornado"
        case .neonSkyline: return "building.2"
        case .orbit: return "globe"
        }
    }

    /// The colours this arena uses unless the player overrides them.
    var defaultColors: SaberColorScheme {
        let id: String
        switch self {
        case .prismHall: id = "classic"
        case .sunsetDrive: id = "synthwave"
        case .warpTunnel: id = "fireice"
        case .neonSkyline: id = "sunset"
        case .orbit: id = "goldteal"
        }
        return ColorPreset.preset(id: id)?.scheme ?? .classic
    }

    func makeStage(colors: SaberColorScheme) -> Stage {
        switch self {
        case .prismHall: return PrismHallStage(colors: colors)
        case .sunsetDrive: return SunsetDriveStage(colors: colors)
        case .warpTunnel: return WarpTunnelStage(colors: colors)
        case .neonSkyline: return NeonSkylineStage(colors: colors)
        case .orbit: return OrbitStage(colors: colors)
        }
    }
}

/// An arena's sky: a vertical gradient with a glowing band at the horizon and optional
/// nebula clouds. It is drawn as the background and also lights every metal surface
/// (image-based lighting), so dark structures pick up the sky's colour instead of
/// rendering pitch black.
struct SkyStyle {
    struct Nebula {
        /// Position in the lat-long sky image (u: 0...1 around, v: 0 top ... 1 bottom).
        var u: CGFloat
        var v: CGFloat
        /// Radius as a fraction of the image height.
        var radius: CGFloat
        var color: NSColor
    }

    var zenith: NSColor
    var horizon: NSColor
    var nadir: NSColor
    /// Bright band hugging the horizon.
    var glow: NSColor
    /// Half height of the glow band as a fraction of the image height.
    var glowWidth: CGFloat = 0.06
    var nebulae: [Nebula] = []

    /// The same nebula repeated at several longitudes, so some of it is always in view.
    static func ring(of count: Int, v: CGFloat, radius: CGFloat, colors: [NSColor], offset: CGFloat = 0) -> [Nebula] {
        (0..<count).map { i in
            Nebula(u: (offset + CGFloat(i) / CGFloat(count)).truncatingRemainder(dividingBy: 1),
                   v: v + (i % 2 == 0 ? 0 : 0.05), radius: radius * (i % 3 == 0 ? 1.25 : 1),
                   color: colors[i % colors.count])
        }
    }
}

/// Base class for an environment. It owns the five light groups the beatmap drives
/// (back, rings, left/right lasers, floor): subclasses build geometry with `groupMaterial`
/// and animate it in `animate(dt:)`; this class fades every group's colour and brightness.
class Stage {
    let root = SCNNode()

    /// Scene atmosphere for this arena (applied by the renderer). With a sky, keep `fogColor`
    /// close to its horizon so distant geometry melts into the sky rather than into black.
    var fogColor = NSColor(calibratedRed: 0.01, green: 0.012, blue: 0.03, alpha: 1)
    var fogStart: CGFloat = 28
    var fogEnd: CGFloat = 150
    /// Optional sky; without one the arena sits in a plain black void.
    var sky: SkyStyle?
    /// How strongly the sky lights metal surfaces.
    var environmentIntensity: CGFloat = 1.5
    /// The sky image (background + lighting environment), built once after `build()`.
    private(set) lazy var skyImage: CGImage? = sky.flatMap { Textures.sky($0) }
    /// Background brightness for this frame: it swells gently with the back lights.
    private(set) var skyBrightness: CGFloat = 1
    /// Lights never fade below this. Arenas set it above 0 to stay readable through blackouts.
    var restGlow: Double = 0

    private struct GroupState {
        var color: LightColor = .blue
        var base: Double = 0
        var flash: Double = 0
        var shown = SIMD3<Float>(0, 0, 0)
    }

    private var materials: [LightGroup: [(material: SCNMaterial, strength: CGFloat)]] = [:]
    private var states: [LightGroup: GroupState] = [:]
    private(set) var colors: SaberColorScheme

    /// Laser sweep speed per group (set by `.speed` events).
    var laserSpeed: [LightGroup: Double] = [.leftLasers: 0.6, .rightLasers: 0.6]
    var time: Double = 0

    init(colors: SaberColorScheme) {
        self.colors = colors
        for g in LightGroup.allCases {
            materials[g] = []
            states[g] = GroupState()
        }
        build()
        idle()
    }

    // MARK: Subclass hooks

    /// Builds the arena's geometry under `root`.
    func build() {}

    /// Per-frame animation after the lights were updated.
    func animate(dt: Double) {}

    /// Ring spin event (direction +1 / -1).
    func spin(_ direction: Double) {}

    /// Ring zoom event.
    func zoom() {}

    /// Called every frame with each group's current colour and brightness multiplier
    /// (for SceneKit lights that should follow a group).
    func groupDidUpdate(_ group: LightGroup, color: NSColor, level: CGFloat) {}

    /// The calm lighting shown in menus.
    func idle() {
        apply(.on(.blue), to: .back)
        apply(.on(.blue), to: .floor)
        apply(.on(.blue), to: .rings)
        apply(.on(.red), to: .leftLasers)
        apply(.on(.blue), to: .rightLasers)
        laserSpeed[.leftLasers] = 0.5
        laserSpeed[.rightLasers] = 0.5
    }

    // MARK: Lights

    func setColors(_ c: SaberColorScheme) { colors = c }

    /// A material lit by light group `g`. `strength` scales its brightness, for secondary
    /// details (floor seams, window trims) that should follow the group without competing with it.
    func groupMaterial(_ g: LightGroup, glow: Bool = false, glowOpacity: CGFloat = 0.35, strength: CGFloat = 1) -> SCNMaterial {
        let m = glow ? Materials.glow(.black, intensity: 1, opacity: glowOpacity) : Materials.neon(.black)
        materials[g]!.append((m, strength))
        return m
    }

    func lightColor(_ c: LightColor) -> SIMD3<Float> {
        switch c {
        case .off: return .zero
        case .red: return colors.leftLights.simd
        case .blue: return colors.rightLights.simd
        case .white: return Palette.simd(Palette.white)
        }
    }

    /// Current brightness of a group (roughly 0...3), for animation that reacts to the lights.
    func level(_ g: LightGroup) -> Float {
        let c = states[g]!.shown
        return max(c.x, max(c.y, c.z))
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
            spin(d)
        case .zoom:
            zoom()
        }
        states[group] = s
    }

    final func update(dt: Double) {
        time += dt
        for g in LightGroup.allCases {
            var s = states[g]!
            s.flash *= exp(-dt * 5.5)
            let intensity = Float(max(s.base * 0.85 + s.flash * 2.4, restGlow))
            let target = lightColor(s.color) * intensity
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
            for (m, strength) in materials[g]! {
                m.emission.contents = color
                m.emission.intensity = mult * (m.blendMode == .add ? 0.9 : 1.8) * strength
            }
            groupDidUpdate(g, color: color, level: CGFloat(maxC))
        }
        skyBrightness = 0.9 + 0.2 * CGFloat(min(level(.back), 2.5))
        animate(dt: dt)
    }

    // MARK: Building helpers

    /// A box stretched between two points.
    static func segment(_ a: SIMD3<Float>, _ b: SIMD3<Float>, thickness: CGFloat, height: CGFloat? = nil,
                        material: SCNMaterial) -> SCNNode {
        let d = b - a
        let len = simd_length(d)
        let box = SCNBox(width: thickness, height: height ?? thickness, length: CGFloat(max(len, 0.001)), chamferRadius: 0)
        box.materials = [material]
        let n = SCNNode(geometry: box)
        n.simdPosition = (a + b) / 2
        if len > 0.0001 {
            n.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 0, 1), to: d / len)
        }
        return n
    }

    /// A vertical "curtain" hanging from a polyline down to `baseY` (solid mountain or skyline
    /// silhouettes). Two-sided, so it reads from either side.
    static func curtain(_ points: [SIMD3<Float>], baseY: Float, material: SCNMaterial) -> SCNNode {
        guard points.count > 1 else { return SCNNode() }
        var vertices: [SCNVector3] = []
        var indices: [Int32] = []
        for p in points {
            vertices.append(SCNVector3(p.x, p.y, p.z))
            vertices.append(SCNVector3(p.x, baseY, p.z))
        }
        for i in 0..<(points.count - 1) {
            let a = Int32(i * 2)
            indices += [a, a + 1, a + 2, a + 2, a + 1, a + 3]
        }
        let g = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices)],
                            elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
        material.isDoubleSided = true
        g.materials = [material]
        return SCNNode(geometry: g)
    }

    /// A neon segment: a solid core plus a wider additive glow shell.
    func neonSegment(_ a: SIMD3<Float>, _ b: SIMD3<Float>, core: CGFloat, glow: CGFloat,
                     material: SCNMaterial, glowMaterial: SCNMaterial?, into parent: SCNNode) {
        parent.addChildNode(Stage.segment(a, b, thickness: core, material: material))
        if let gm = glowMaterial {
            parent.addChildNode(Stage.segment(a, b, thickness: glow, material: gm))
        }
    }

    /// Outline of a regular polygon in the XY plane around `center`.
    func polygonOutline(sides: Int, radius: Float, rotation: Float = 0, center: SIMD3<Float>, core: CGFloat, glow: CGFloat,
                        material: SCNMaterial, glowMaterial: SCNMaterial?, gap: Float = 1, into parent: SCNNode) {
        for s in 0..<sides {
            let a0 = rotation + Float(s) / Float(sides) * 2 * .pi
            let a1 = rotation + Float(s + 1) / Float(sides) * 2 * .pi
            var p0 = SIMD3<Float>(cos(a0) * radius, sin(a0) * radius, 0)
            var p1 = SIMD3<Float>(cos(a1) * radius, sin(a1) * radius, 0)
            if gap < 1 {
                let mid = (p0 + p1) / 2
                p0 = mid + (p0 - mid) * gap
                p1 = mid + (p1 - mid) * gap
            }
            neonSegment(center + p0, center + p1, core: core, glow: glow, material: material, glowMaterial: glowMaterial, into: parent)
        }
    }

    /// Dark reflective ground plane.
    func addFloor(reflectivity: CGFloat = 0.22, color: NSColor = NSColor(calibratedWhite: 0.015, alpha: 1)) {
        let floor = SCNFloor()
        floor.reflectivity = reflectivity
        floor.reflectionFalloffEnd = 8
        floor.reflectionResolutionScaleFactor = 0.5
        let fm = SCNMaterial()
        fm.lightingModel = .physicallyBased
        fm.diffuse.contents = color
        fm.roughness.contents = 0.45
        fm.metalness.contents = 0.4
        floor.materials = [fm]
        root.addChildNode(SCNNode(geometry: floor))
    }

    /// The player platform with glowing trim (trim joins `trimMaterial`'s group).
    func addPlatform(trimMaterial: SCNMaterial, body: NSColor = NSColor(calibratedWhite: 0.05, alpha: 1)) {
        let platform = SCNBox(width: 3.4, height: 0.08, length: 2.6, chamferRadius: 0.02)
        platform.materials = [Materials.metal(body, roughness: 0.5, metalness: 0.7)]
        let pn = SCNNode(geometry: platform)
        pn.position = SCNVector3(0, -0.035, 0.6)
        root.addChildNode(pn)
        let trims: [(SCNVector3, CGFloat, CGFloat)] = [
            (SCNVector3(0, 0.01, -0.7), 3.4, 0.03),
            (SCNVector3(0, 0.01, 1.9), 3.4, 0.03),
            (SCNVector3(-1.7, 0.01, 0.6), 0.03, 2.6),
            (SCNVector3(1.7, 0.01, 0.6), 0.03, 2.6),
        ]
        let holder = SCNNode()
        for (pos, w, l) in trims {
            let b = SCNBox(width: w, height: 0.02, length: l, chamferRadius: 0)
            b.materials = [trimMaterial]
            let n = SCNNode(geometry: b)
            n.position = pos
            holder.addChildNode(n)
        }
        root.addChildNode(holder.flattenedClone())
    }

    /// Ambient fill + a soft key light so metal surfaces read.
    func addBaseLights(ambient: NSColor = NSColor(calibratedRed: 0.45, green: 0.5, blue: 0.7, alpha: 1),
                       ambientIntensity: CGFloat = 180, keyIntensity: CGFloat = 900) {
        let a = SCNLight()
        a.type = .ambient
        a.intensity = ambientIntensity
        a.color = ambient
        let an = SCNNode()
        an.light = a
        root.addChildNode(an)

        let key = SCNLight()
        key.type = .directional
        key.intensity = keyIntensity
        key.color = NSColor(calibratedWhite: 0.95, alpha: 1)
        let kn = SCNNode()
        kn.light = key
        kn.eulerAngles = SCNVector3(-0.9, 0.25, 0)
        root.addChildNode(kn)
    }

    /// An omni light whose colour follows a light group (see `groupDidUpdate`).
    func makeGroupLight(at p: SCNVector3, range: CGFloat = 40) -> SCNLight {
        let l = SCNLight()
        l.type = .omni
        l.intensity = 0
        l.attenuationStartDistance = 4
        l.attenuationEndDistance = range
        let n = SCNNode()
        n.light = l
        n.position = p
        root.addChildNode(n)
        return l
    }

    /// Slowly drifting motes of light.
    func addDust(color: NSColor = NSColor(calibratedRed: 0.6, green: 0.75, blue: 1, alpha: 0.35),
                 birthRate: CGFloat = 30, box: SCNVector3 = SCNVector3(14, 8, 40), center: SCNVector3 = SCNVector3(0, 4, -18)) {
        let dust = SCNParticleSystem()
        dust.birthRate = birthRate
        dust.particleLifeSpan = 9
        dust.particleLifeSpanVariation = 3
        dust.particleSize = 0.035
        dust.particleSizeVariation = 0.02
        dust.particleColor = color
        dust.particleImage = Textures.softDot
        dust.blendMode = .additive
        dust.isLightingEnabled = false
        dust.particleVelocity = 0.25
        dust.particleVelocityVariation = 0.2
        dust.spreadingAngle = 180
        dust.emitterShape = SCNBox(width: box.x, height: box.y, length: box.z, chamferRadius: 0)
        dust.birthLocation = .volume
        dust.warmupDuration = 8
        let dn = SCNNode()
        dn.position = center
        dn.addParticleSystem(dust)
        root.addChildNode(dn)
    }

    /// A static starfield (many tiny additive points on a far sphere shell).
    func addStars(count: Int = 700, radius: Float = 180, minY: Float = -10, seed: UInt64 = 7) {
        var rng = SeededRandom(seed: seed)
        var vertices: [SCNVector3] = []
        var indices: [Int32] = []
        for i in 0..<count {
            var p: SIMD3<Float>
            repeat {
                p = SIMD3<Float>(Float(rng.next(-1, 1)), Float(rng.next(-1, 1)), Float(rng.next(-1, 1)))
            } while simd_length(p) < 0.2 || simd_length(p) > 1
            p = simd_normalize(p) * radius
            if p.y < minY { p.y = -p.y }
            if p.z > 10 { p.z = -p.z }
            vertices.append(SCNVector3(p.x, p.y, p.z))
            indices.append(Int32(i))
        }
        let src = SCNGeometrySource(vertices: vertices)
        let element = SCNGeometryElement(indices: indices, primitiveType: .point)
        element.pointSize = 2.2
        element.minimumPointScreenSpaceRadius = 1
        element.maximumPointScreenSpaceRadius = 2.5
        let g = SCNGeometry(sources: [src], elements: [element])
        let m = Materials.neon(NSColor(calibratedRed: 0.8, green: 0.88, blue: 1, alpha: 1), intensity: 1.2)
        g.materials = [m]
        let n = SCNNode(geometry: g)
        n.renderingOrder = -10
        root.addChildNode(n)
    }
}

/// Small deterministic PRNG so arenas look the same every launch.
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 | 1 }
    mutating func nextUInt() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
    /// Uniform in lo...hi.
    mutating func next(_ lo: Double, _ hi: Double) -> Double {
        lo + (hi - lo) * Double(nextUInt() % 1_000_000) / 999_999
    }
}

extension NeonColor {
    var ns: NSColor { NSColor(deviceRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: 1) }
    var simd: SIMD3<Float> { SIMD3(Float(r), Float(g), Float(b)) }
}
