import AppKit
import SceneKit
import simd
import SaberCore

enum Palette {
    static let red = NSColor(calibratedRed: 1.0, green: 0.11, blue: 0.2, alpha: 1)
    static let blue = NSColor(calibratedRed: 0.1, green: 0.48, blue: 1.0, alpha: 1)
    static let white = NSColor(calibratedRed: 0.92, green: 0.96, blue: 1.0, alpha: 1)
    static let fog = NSColor(calibratedRed: 0.01, green: 0.012, blue: 0.03, alpha: 1)

    static func saber(_ hand: Hand) -> NSColor { hand == .left ? red : blue }

    static func light(_ c: LightColor) -> NSColor {
        switch c {
        case .off: return .black
        case .red: return red
        case .blue: return blue
        case .white: return white
        }
    }

    /// Dark, saturated block body colors.
    static func blockBody(_ hand: Hand) -> NSColor {
        hand == .left
            ? NSColor(calibratedRed: 0.62, green: 0.05, blue: 0.09, alpha: 1)
            : NSColor(calibratedRed: 0.05, green: 0.22, blue: 0.68, alpha: 1)
    }

    static func mix(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor {
        let a = a.usingColorSpace(.deviceRGB) ?? a
        let b = b.usingColorSpace(.deviceRGB) ?? b
        return NSColor(deviceRed: a.redComponent + (b.redComponent - a.redComponent) * t,
                       green: a.greenComponent + (b.greenComponent - a.greenComponent) * t,
                       blue: a.blueComponent + (b.blueComponent - a.blueComponent) * t,
                       alpha: 1)
    }

    static func simd(_ c: NSColor) -> SIMD3<Float> {
        let c = c.usingColorSpace(.deviceRGB) ?? c
        return SIMD3(Float(c.redComponent), Float(c.greenComponent), Float(c.blueComponent))
    }
}

extension Vec3 {
    var simd: SIMD3<Float> { SIMD3(Float(x), Float(y), Float(z)) }
    var scn: SCNVector3 { SCNVector3(CGFloat(x), CGFloat(y), CGFloat(z)) }
}

extension SIMD3 where Scalar == Float {
    var vec3: Vec3 { Vec3(Double(x), Double(y), Double(z)) }
}

/// Material helpers.
enum Materials {
    /// Unlit neon emitter (feeds the HDR bloom).
    static func neon(_ color: NSColor, intensity: CGFloat = 1.6) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = NSColor.black
        m.emission.contents = color
        m.emission.intensity = intensity
        return m
    }

    /// Additive, transparent glow shell.
    static func glow(_ color: NSColor, intensity: CGFloat = 1.2, opacity: CGFloat = 0.5) -> SCNMaterial {
        let m = neon(color, intensity: intensity)
        m.blendMode = .add
        m.transparency = opacity
        m.writesToDepthBuffer = false
        m.isDoubleSided = true
        return m
    }

    static func metal(_ color: NSColor, roughness: CGFloat = 0.35, metalness: CGFloat = 0.6) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = color
        m.roughness.contents = roughness
        m.metalness.contents = metalness
        return m
    }
}

/// Generates small textures procedurally (no image assets needed).
enum Textures {
    /// Soft round sprite used for particles.
    static let softDot: NSImage = {
        let size = 64
        let img = NSImage(size: NSSize(width: size, height: size))
        img.lockFocus()
        if let ctx = NSGraphicsContext.current?.cgContext {
            let colors = [NSColor.white.cgColor, NSColor.white.withAlphaComponent(0.35).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.35, 1]) {
                let c = CGPoint(x: size / 2, y: size / 2)
                ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: CGFloat(size) / 2, options: [])
            }
        }
        img.unlockFocus()
        return img
    }()
}
