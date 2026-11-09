import AppKit
import SceneKit
import simd
import SaberCore

enum Palette {
    static let red = NSColor(calibratedRed: 1.0, green: 0.11, blue: 0.2, alpha: 1)
    static let blue = NSColor(calibratedRed: 0.1, green: 0.48, blue: 1.0, alpha: 1)
    static let white = NSColor(calibratedRed: 0.92, green: 0.96, blue: 1.0, alpha: 1)
    static let fog = NSColor(calibratedRed: 0.01, green: 0.012, blue: 0.03, alpha: 1)

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

    /// Flat, unlit colour: silhouettes (mountains, distant skylines) that should stay a fixed
    /// shade against the sky whatever the lighting does.
    static func silhouette(_ color: NSColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = color
        return m
    }

    /// A building facade: dark body with a tiling texture of lit windows in the emission slot.
    /// `repeats` is how many times the window texture tiles across / up each side face.
    static func windowed(body: NSColor, windows: CGImage?, repeats: CGSize, intensity: CGFloat = 1.1) -> SCNMaterial {
        let m = metal(body, roughness: 0.45, metalness: 0.5)
        m.emission.contents = windows
        m.emission.intensity = intensity
        m.emission.wrapS = .repeat
        m.emission.wrapT = .repeat
        m.emission.minificationFilter = .linear
        m.emission.magnificationFilter = .linear
        m.emission.mipFilter = .linear
        m.emission.contentsTransform = SCNMatrix4MakeScale(repeats.width, repeats.height, 1)
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

extension Textures {
    private static func cg(_ c: NSColor, alpha: CGFloat? = nil) -> CGColor {
        let c = c.usingColorSpace(.sRGB) ?? c
        return c.withAlphaComponent(alpha ?? c.alphaComponent).cgColor
    }

    /// A lat-long (equirectangular) sky: zenith at the top row, horizon across the middle.
    static func sky(_ s: SkyStyle, width: Int = 1024, height: Int = 512) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let w = CGFloat(width), h = CGFloat(height)

        // Base gradient (CoreGraphics y runs up, so y = h is the zenith).
        let below = Palette.mix(s.nadir, s.horizon, 0.65)
        let above = Palette.mix(s.horizon, s.zenith, 0.55)
        let stops: [(NSColor, CGFloat)] = [(s.nadir, 0), (below, 0.43), (s.horizon, 0.5), (above, 0.6), (s.zenith, 1)]
        if let g = CGGradient(colorsSpace: space, colors: stops.map { cg($0.0) } as CFArray, locations: stops.map { $0.1 }) {
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: h), options: [])
        }

        ctx.setBlendMode(.plusLighter)
        // Horizon glow band (a little more of it above the horizon than below).
        let band = s.glowWidth * h
        if let g = CGGradient(colorsSpace: space,
                              colors: [cg(s.glow, alpha: 0), cg(s.glow, alpha: 1), cg(s.glow, alpha: 0.35), cg(s.glow, alpha: 0)] as CFArray,
                              locations: [0, 0.4, 0.62, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: h / 2 - band * 0.8), end: CGPoint(x: 0, y: h / 2 + band * 1.6), options: [])
        }

        // Nebula clouds: soft radial blobs, drawn wrapped so none is cut at the image seam.
        for n in s.nebulae {
            let r = n.radius * h
            guard let g = CGGradient(colorsSpace: space,
                                     colors: [cg(n.color, alpha: 0.9), cg(n.color, alpha: 0.35), cg(n.color, alpha: 0)] as CFArray,
                                     locations: [0, 0.4, 1]) else { continue }
            for shift in [-w, 0, w] {
                let c = CGPoint(x: n.u * w + shift, y: (1 - n.v) * h)
                // Squash vertically: clouds look like wide bands rather than balls.
                ctx.saveGState()
                ctx.translateBy(x: c.x, y: c.y)
                ctx.scaleBy(x: 1.6, y: 0.7)
                ctx.drawRadialGradient(g, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: r, options: [])
                ctx.restoreGState()
            }
        }
        return ctx.makeImage()
    }

    /// A tile of building windows (emission texture): mostly dark, with lit windows in warm and
    /// cool tones and the odd fully lit floor. `columns` x `floors` window cells.
    static func windows(seed: UInt64, columns: Int = 16, floors: Int = 32) -> CGImage? {
        let cw = 16, ch = 24
        let width = columns * cw, height = floors * ch
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        var rng = SeededRandom(seed: seed)
        let tones: [(CGFloat, CGFloat, CGFloat)] = [(1, 0.82, 0.55), (1, 0.9, 0.72), (0.62, 0.85, 1), (0.85, 0.95, 1), (1, 0.55, 0.85)]
        for f in 0..<floors {
            let floorLit = rng.next(0, 1)
            // Some floors are dark, a few are lit end to end (offices working late).
            let chance = floorLit < 0.2 ? 0.05 : (floorLit > 0.9 ? 0.95 : 0.38)
            let floorTone = tones[Int(rng.next(0, Double(tones.count) - 0.001))]
            for c in 0..<columns where rng.next(0, 1) < chance {
                let t = rng.next(0, 1) < 0.75 ? floorTone : tones[Int(rng.next(0, Double(tones.count) - 0.001))]
                let b = CGFloat(rng.next(0.45, 1))
                ctx.setFillColor(CGColor(colorSpace: space, components: [t.0 * b, t.1 * b, t.2 * b, 1])!)
                ctx.fill(CGRect(x: c * cw + 3, y: f * ch + 5, width: cw - 6, height: ch - 10))
            }
        }
        return ctx.makeImage()
    }
}
