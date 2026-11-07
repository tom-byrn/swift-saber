import AppKit
import SceneKit
import simd
import SaberCore

/// A glowing saber (hilt + blade + glow + light) with a motion trail.
final class SaberVisual {
    let hand: Hand
    let node = SCNNode()
    private let bladeRoot = SCNNode()
    private let light = SCNLight()
    private let trailNode = SCNNode()
    private let trailMaterial: SCNMaterial
    private var trail: [(t: Double, base: SIMD3<Float>, tip: SIMD3<Float>)] = []
    private var visibility: Float = 0
    private var flashAmount: Float = 0
    private var color: NSColor
    private let coreMaterial: SCNMaterial
    private let glowMaterial: SCNMaterial
    private let ringMaterial: SCNMaterial

    static let trailDuration = 0.11

    init(hand: Hand, color rgb: NeonColor, root: SCNNode) {
        self.hand = hand
        let c = rgb.ns
        color = c
        coreMaterial = Materials.neon(Palette.mix(c, .white, 0.7), intensity: 2.2)
        glowMaterial = Materials.glow(c, intensity: 1.6, opacity: 0.55)
        ringMaterial = Materials.neon(c, intensity: 2)
        let tm = SCNMaterial()
        tm.lightingModel = .constant
        tm.diffuse.contents = NSColor.white
        tm.blendMode = .add
        tm.writesToDepthBuffer = false
        tm.isDoubleSided = true
        trailMaterial = tm

        let hilt = CGFloat(Arena.hiltDistance)
        let blade = CGFloat(Arena.bladeLength)

        // Everything is built along -Z, then oriented towards the saber direction.
        let hiltGeo = SCNCylinder(radius: 0.028, height: 0.28)
        hiltGeo.materials = [Materials.metal(NSColor(calibratedWhite: 0.55, alpha: 1), roughness: 0.25, metalness: 1)]
        let hiltNode = SCNNode(geometry: hiltGeo)
        hiltNode.eulerAngles.x = .pi / 2
        hiltNode.position = SCNVector3(0, 0, -(hilt - 0.14))
        bladeRoot.addChildNode(hiltNode)

        let ringGeo = SCNTorus(ringRadius: 0.031, pipeRadius: 0.006)
        ringGeo.materials = [ringMaterial]
        for z in [hilt - 0.24, hilt - 0.04] {
            let r = SCNNode(geometry: ringGeo)
            r.eulerAngles.x = .pi / 2
            r.position = SCNVector3(0, 0, -z)
            bladeRoot.addChildNode(r)
        }

        let core = SCNCapsule(capRadius: 0.012, height: blade)
        core.materials = [coreMaterial]
        let coreNode = SCNNode(geometry: core)
        coreNode.eulerAngles.x = .pi / 2
        coreNode.position = SCNVector3(0, 0, -(hilt + blade / 2))
        bladeRoot.addChildNode(coreNode)

        let glow = SCNCapsule(capRadius: 0.034, height: blade + 0.02)
        glow.materials = [glowMaterial]
        let glowNode = SCNNode(geometry: glow)
        glowNode.eulerAngles.x = .pi / 2
        glowNode.position = coreNode.position
        glowNode.renderingOrder = 10
        bladeRoot.addChildNode(glowNode)

        light.type = .omni
        light.color = color
        light.intensity = 140
        light.attenuationStartDistance = 0.1
        light.attenuationEndDistance = 1.3
        let ln = SCNNode()
        ln.light = light
        ln.position = coreNode.position
        bladeRoot.addChildNode(ln)

        node.addChildNode(bladeRoot)
        node.simdPosition = Arena.pivot(for: hand).simd
        node.opacity = 0
        root.addChildNode(node)

        trailNode.renderingOrder = 20
        root.addChildNode(trailNode)
    }

    /// Recolours the blade, glow, hilt rings, light and trail.
    func setColor(_ rgb: NeonColor) {
        let c = rgb.ns
        color = c
        coreMaterial.emission.contents = Palette.mix(c, .white, 0.7)
        glowMaterial.emission.contents = c
        ringMaterial.emission.contents = c
        light.color = c
    }

    /// Brief brightness kick when the saber cuts something.
    func flash() { flashAmount = 1 }

    func update(input: SaberInput, time: Double, dt: Double) {
        let target: Float = input.active ? 1 : 0
        visibility += (target - visibility) * Float(1 - exp(-dt * 12))
        node.opacity = CGFloat(visibility)
        flashAmount *= Float(exp(-dt * 8))
        coreMaterial.emission.intensity = CGFloat(2.2 + flashAmount * 2)
        glowMaterial.emission.intensity = CGFloat(1.6 + flashAmount * 2.5)
        light.intensity = CGFloat(140 + flashAmount * 300) * CGFloat(visibility)

        guard input.active else {
            trail.removeAll()
            trailNode.geometry = nil
            return
        }
        let dir = input.direction.simd
        node.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 0, -1), to: simd_normalize(dir))
        let pivot = Arena.pivot(for: hand).simd
        let base = pivot + dir * Float(Arena.hiltDistance + Arena.bladeLength * 0.25)
        let tip = pivot + dir * Float(Arena.hiltDistance + Arena.bladeLength)
        trail.append((time, base, tip))
        trail.removeAll { time - $0.t > Self.trailDuration }
        rebuildTrail(now: time)
    }

    private func rebuildTrail(now: Double) {
        guard trail.count >= 2 else {
            trailNode.geometry = nil
            return
        }
        var vertices: [SCNVector3] = []
        var colors: [SIMD4<Float>] = []
        var indices: [Int32] = []
        let c = Palette.simd(color)
        let white = SIMD3<Float>(1, 1, 1)
        for (i, s) in trail.enumerated() {
            let age = Float((now - s.t) / Self.trailDuration)
            let a = max(0, 1 - age)
            let fade = a * a * 0.9
            let tipColor = (c * 0.75 + white * 0.25) * fade
            vertices.append(SCNVector3(s.base.x, s.base.y, s.base.z))
            vertices.append(SCNVector3(s.tip.x, s.tip.y, s.tip.z))
            let baseColor = c * (fade * 0.15)
            colors.append(SIMD4<Float>(baseColor.x, baseColor.y, baseColor.z, fade * 0.15))
            colors.append(SIMD4<Float>(tipColor.x, tipColor.y, tipColor.z, fade))
            if i > 0 {
                let b = Int32((i - 1) * 2)
                indices += [b, b + 1, b + 2, b + 1, b + 3, b + 2]
            }
        }
        let vsrc = SCNGeometrySource(vertices: vertices)
        let data = colors.withUnsafeBufferPointer { Data(buffer: $0) }
        let csrc = SCNGeometrySource(data: data, semantic: .color, vectorCount: colors.count,
                                     usesFloatComponents: true, componentsPerVector: 4,
                                     bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0,
                                     dataStride: MemoryLayout<SIMD4<Float>>.stride)
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        let g = SCNGeometry(sources: [vsrc, csrc], elements: [element])
        g.materials = [trailMaterial]
        trailNode.geometry = g
    }
}
