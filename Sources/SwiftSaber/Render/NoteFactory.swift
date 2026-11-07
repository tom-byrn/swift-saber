import AppKit
import SceneKit
import simd
import SaberCore

/// Builds block and bomb nodes and the sliced halves.
final class NoteFactory {
    /// Every block material carries this modifier so a clone can be clipped by a plane
    /// (used to split a cut block into two real halves). The default plane clips nothing.
    static let clipModifier = """
    #pragma arguments
    float4 cutPlane;
    #pragma body
    float4 localPos = scn_node.inverseModelViewTransform * float4(_surface.position, 1.0);
    if (dot(localPos.xyz, cutPlane.xyz) < cutPlane.w) {
        discard_fragment();
    }
    """
    static let noClip = SCNVector4(0, 0, 0, -1)

    private var arrowPrototypes: [Hand: SCNNode] = [:]
    private var dotPrototypes: [Hand: SCNNode] = [:]
    private let bombPrototype: SCNNode
    private var sparkPrototypes: [Hand: SCNParticleSystem] = [:]
    private(set) var colors: SaberColorScheme

    init(colors: SaberColorScheme) {
        self.colors = colors
        bombPrototype = NoteFactory.makeBomb()
        rebuild()
    }

    /// Recolours the blocks and sparks (affects blocks spawned from now on).
    func setColors(_ c: SaberColorScheme) {
        guard c != colors else { return }
        colors = c
        rebuild()
    }

    private func rebuild() {
        for hand in Hand.allCases {
            let c = colors.saber(hand)
            arrowPrototypes[hand] = NoteFactory.makeBlock(color: c, arrow: true)
            dotPrototypes[hand] = NoteFactory.makeBlock(color: c, arrow: false)
            sparkPrototypes[hand] = NoteFactory.makeSparks(color: c.ns)
        }
    }

    static func clipMaterial(_ m: SCNMaterial) -> SCNMaterial {
        m.shaderModifiers = [.surface: clipModifier]
        m.setValue(NSValue(scnVector4: noClip), forKey: "cutPlane")
        m.isDoubleSided = true
        return m
    }

    static func makeBlock(color: RGBColor, arrow: Bool) -> SCNNode {
        let size = CGFloat(Arena.blockSize)
        let holder = SCNNode()

        let box = SCNBox(width: size, height: size, length: size, chamferRadius: size * 0.14)
        let bodyColor = color.deepened.ns
        let body = Materials.metal(bodyColor, roughness: 0.28, metalness: 0.55)
        body.emission.contents = bodyColor
        body.emission.intensity = 0.55
        box.materials = [clipMaterial(body)]
        holder.addChildNode(SCNNode(geometry: box))

        // Thin glowing frame around the front face.
        let frameMat = clipMaterial(Materials.neon(color.ns, intensity: 1.1))
        let edge = size * 0.98
        let t: CGFloat = 0.018
        let half = size / 2
        let bars: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (0, half - t / 2, edge, t), (0, -half + t / 2, edge, t),
            (half - t / 2, 0, t, edge), (-half + t / 2, 0, t, edge),
        ]
        for (x, y, w, h) in bars {
            let b = SCNBox(width: w, height: h, length: t, chamferRadius: 0)
            b.materials = [frameMat]
            let n = SCNNode(geometry: b)
            n.position = SCNVector3(x, y, half + 0.002)
            holder.addChildNode(n)
        }

        // Cut indicator on the front face (+z faces the player). Arrow points down by default.
        let markMat = clipMaterial(Materials.neon(Palette.white, intensity: 2.2))
        if arrow {
            let path = NSBezierPath()
            let w = size * 0.62, h = size * 0.24
            let top = size * 0.02
            path.move(to: NSPoint(x: -w / 2, y: top + h / 2))
            path.line(to: NSPoint(x: w / 2, y: top + h / 2))
            path.line(to: NSPoint(x: 0, y: top - h / 2 - size * 0.06))
            path.close()
            let shape = SCNShape(path: path, extrusionDepth: 0.012)
            shape.materials = [markMat]
            let n = SCNNode(geometry: shape)
            n.position = SCNVector3(0, -size * 0.12, half + 0.004)
            holder.addChildNode(n)
        } else {
            let dot = SCNCylinder(radius: size * 0.13, height: 0.012)
            dot.radialSegmentCount = 24
            dot.materials = [markMat]
            let n = SCNNode(geometry: dot)
            n.eulerAngles.x = .pi / 2
            n.position = SCNVector3(0, 0, half + 0.004)
            holder.addChildNode(n)
        }
        // A single geometry per block keeps clones cheap and makes the clip plane local to one node.
        return holder.flattenedClone()
    }

    static func makeBomb() -> SCNNode {
        let holder = SCNNode()
        let r = CGFloat(Arena.bombRadius) * 0.85
        let core = SCNSphere(radius: r)
        core.segmentCount = 24
        let mat = Materials.metal(NSColor(calibratedWhite: 0.06, alpha: 1), roughness: 0.25, metalness: 0.9)
        mat.emission.contents = NSColor(calibratedRed: 0.25, green: 0.05, blue: 0.35, alpha: 1)
        mat.emission.intensity = 0.25
        core.materials = [mat]
        holder.addChildNode(SCNNode(geometry: core))
        // Spikes along the 14 directions of a cube's faces and corners.
        var dirs: [SIMD3<Float>] = [[1, 0, 0], [-1, 0, 0], [0, 1, 0], [0, -1, 0], [0, 0, 1], [0, 0, -1]]
        for x in [-1, 1] { for y in [-1, 1] { for z in [-1, 1] { dirs.append(simd_normalize(SIMD3<Float>(Float(x), Float(y), Float(z)))) } } }
        let spike = SCNCone(topRadius: 0, bottomRadius: r * 0.28, height: r * 0.7)
        spike.radialSegmentCount = 8
        spike.materials = [mat]
        for d in dirs {
            let n = SCNNode(geometry: spike)
            n.simdPosition = d * Float(r) * 1.05
            n.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: d)
            holder.addChildNode(n)
        }
        return holder.flattenedClone()
    }

    static func makeSparks(color: NSColor) -> SCNParticleSystem {
        let p = SCNParticleSystem()
        p.birthRate = 1600
        p.emissionDuration = 0.03
        p.loops = false
        p.particleLifeSpan = 0.22
        p.particleLifeSpanVariation = 0.1
        p.particleSize = 0.007
        p.particleSizeVariation = 0.003
        p.particleColor = Palette.mix(color, .white, 0.35)
        p.particleImage = Textures.softDot
        p.blendMode = .additive
        p.isLightingEnabled = false
        p.particleVelocity = 2.4
        p.particleVelocityVariation = 1.4
        p.spreadingAngle = 180
        p.stretchFactor = 0.012
        p.acceleration = SCNVector3(0, -3, 0)
        p.particleIntensity = 2
        return p
    }

    // MARK: Instances

    func block(for note: Note, colorHand: Hand) -> SCNNode {
        let proto = note.direction == .any ? dotPrototypes[colorHand]! : arrowPrototypes[colorHand]!
        return proto.clone()
    }

    func bomb() -> SCNNode { bombPrototype.clone() }

    func sparks(for hand: Hand) -> SCNParticleSystem {
        (sparkPrototypes[hand]!.copy() as? SCNParticleSystem) ?? sparkPrototypes[hand]!
    }

    /// Two halves of `block`, split by a plane through its centre with the given world normal.
    func halves(of block: SCNNode, worldNormal: SIMD3<Float>) -> (SCNNode, SCNNode)? {
        guard let geometry = block.geometry else { return nil }
        // Normal in the block's local space.
        let inv = simd_inverse(block.simdWorldOrientation)
        let local = simd_normalize(inv.act(worldNormal))
        func half(_ sign: Float) -> SCNNode {
            let g = geometry.copy() as! SCNGeometry
            g.materials = geometry.materials.map { src -> SCNMaterial in
                let m = src.copy() as! SCNMaterial
                m.setValue(NSValue(scnVector4: SCNVector4(CGFloat(local.x * sign), CGFloat(local.y * sign), CGFloat(local.z * sign), 0)),
                           forKey: "cutPlane")
                return m
            }
            let n = SCNNode(geometry: g)
            n.simdWorldTransform = block.simdWorldTransform
            return n
        }
        return (half(1), half(-1))
    }
}
