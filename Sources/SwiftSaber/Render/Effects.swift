import AppKit
import SceneKit
import simd
import SaberCore

/// Short-lived visual effects: sliced halves, floating score numbers, miss markers.
final class EffectsLayer {
    let root = SCNNode()

    private struct Debris {
        var node: SCNNode
        var velocity: SIMD3<Float>
        var spinAxis: SIMD3<Float>
        var spinRate: Float
        var age: Double
        var life: Double
    }

    private struct Popup {
        var node: SCNNode
        var start: SIMD3<Float>
        var age: Double
        var life: Double
        var rise: Float
    }

    private var debris: [Debris] = []
    private var transients: [(node: SCNNode, age: Double, life: Double)] = []
    private var popups: [Popup] = []
    private var textCache: [String: SCNGeometry] = [:]
    private var rng = SystemRandomNumberGenerator()

    // MARK: Debris

    func addHalves(_ a: SCNNode, _ b: SCNNode, normal: SIMD3<Float>, motion: SIMD2<Float>, forwardSpeed: Float) {
        let push = SIMD3<Float>(motion.x, motion.y, 0) * 1.6
        for (node, sign) in [(a, Float(1)), (b, Float(-1))] {
            root.addChildNode(node)
            // Mostly sideways separation; only a little drift towards the camera so halves never fill the view.
            let v = push + normal * (1.1 * sign) + SIMD3<Float>(0, 0.4, forwardSpeed * 0.1)
            let axis = simd_normalize(simd_cross(normal, SIMD3<Float>(motion.x, motion.y, 0.01)) + SIMD3<Float>(0, 0, 0.001))
            debris.append(Debris(node: node, velocity: v, spinAxis: axis, spinRate: sign * Float.random(in: 6...10, using: &rng),
                                 age: 0, life: 0.65))
        }
    }

    /// Bomb burst: re-uses the debris system with a few dark fragments.
    func addBurst(at p: SIMD3<Float>, template: SCNNode) {
        for _ in 0..<6 {
            let n = template.clone()
            n.scale = SCNVector3(0.35, 0.35, 0.35)
            n.simdPosition = p
            root.addChildNode(n)
            let dir = simd_normalize(SIMD3<Float>(Float.random(in: -1...1, using: &rng), Float.random(in: -0.2...1, using: &rng), Float.random(in: -1...1, using: &rng)))
            debris.append(Debris(node: n, velocity: dir * 4, spinAxis: dir, spinRate: 12, age: 0, life: 0.6))
        }
    }

    /// One-shot particle burst; the holder node is removed once the particles are gone.
    func addParticles(_ system: SCNParticleSystem, at p: SIMD3<Float>, life: Double = 1.0) {
        let n = SCNNode()
        n.simdPosition = p
        n.addParticleSystem(system)
        root.addChildNode(n)
        transients.append((n, 0, life))
    }

    // MARK: Popups

    func addPopup(_ text: String, at p: SIMD3<Float>, color: NSColor, scale: Float = 1) {
        let geometry: SCNGeometry
        if let g = textCache[text] {
            geometry = g
        } else {
            let t = SCNText(string: text, extrusionDepth: 0)
            t.font = NSFont.systemFont(ofSize: 10, weight: .heavy)
            t.flatness = 0.25
            t.alignmentMode = CATextLayerAlignmentMode.center.rawValue
            let m = Materials.neon(.white, intensity: 1.4)
            m.isDoubleSided = true
            t.materials = [m]
            geometry = t
            textCache[text] = t
        }
        let textNode = SCNNode(geometry: geometry)
        let (minB, maxB) = textNode.boundingBox
        textNode.pivot = SCNMatrix4MakeTranslation((minB.x + maxB.x) / 2, (minB.y + maxB.y) / 2, 0)
        let holder = SCNNode()
        holder.addChildNode(textNode)
        let s = 0.02 * CGFloat(scale)
        holder.scale = SCNVector3(s, s, s)
        holder.simdPosition = p
        // Tint per popup without touching the cached geometry's material.
        let tinted = textNode.geometry!.copy() as! SCNGeometry
        let m = Materials.neon(color, intensity: 1.5)
        m.isDoubleSided = true
        tinted.materials = [m]
        textNode.geometry = tinted
        root.addChildNode(holder)
        popups.append(Popup(node: holder, start: p, age: 0, life: 0.65, rise: 0.45))
    }

    // MARK: Update

    func update(dt: Double) {
        let g = SIMD3<Float>(0, -9.8, 0)
        let fdt = Float(dt)
        for i in debris.indices.reversed() {
            debris[i].age += dt
            let d = debris[i]
            if d.age >= d.life {
                d.node.removeFromParentNode()
                debris.remove(at: i)
                continue
            }
            debris[i].velocity += g * fdt * 0.8
            d.node.simdPosition += debris[i].velocity * fdt
            if d.node.simdPosition.z > 0.3 {
                d.node.removeFromParentNode()
                debris.remove(at: i)
                continue
            }
            d.node.simdOrientation = simd_quatf(angle: d.spinRate * fdt, axis: d.spinAxis) * d.node.simdOrientation
            let p = d.age / d.life
            d.node.opacity = CGFloat(1 - p * p)
        }
        for i in transients.indices.reversed() {
            transients[i].age += dt
            if transients[i].age >= transients[i].life {
                transients[i].node.removeFromParentNode()
                transients.remove(at: i)
            }
        }
        for i in popups.indices.reversed() {
            popups[i].age += dt
            let pop = popups[i]
            if pop.age >= pop.life {
                pop.node.removeFromParentNode()
                popups.remove(at: i)
                continue
            }
            let p = Float(pop.age / pop.life)
            pop.node.simdPosition = pop.start + SIMD3<Float>(0, pop.rise * (1 - (1 - p) * (1 - p)), 0)
            pop.node.opacity = CGFloat(p < 0.6 ? 1 : 1 - (p - 0.6) / 0.4)
        }
    }

    func clear() {
        for d in debris { d.node.removeFromParentNode() }
        for p in popups { p.node.removeFromParentNode() }
        for t in transients { t.node.removeFromParentNode() }
        debris.removeAll()
        popups.removeAll()
        transients.removeAll()
    }
}
