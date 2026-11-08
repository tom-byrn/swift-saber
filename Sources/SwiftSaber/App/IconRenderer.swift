import AppKit

/// Draws the app icon in code: a dark tile with a glowing block and two crossed blades.
enum IconRenderer {
    /// `fullBleed` draws just the tile, filling the whole square (iOS masks the corners itself).
    static func draw(in rect: CGRect, context ctx: CGContext, fullBleed: Bool = false) {
        // Every size is relative to the macOS canvas, whose tile is inset by 9 % on each side,
        // so the full-bleed iPhone icon is exactly the Mac icon's tile.
        let s = fullBleed ? rect.width / 0.82 : rect.width
        let inset = s * 0.09
        let tile = fullBleed ? rect : rect.insetBy(dx: inset, dy: inset)
        let radius = tile.width * 0.22

        // Background tile
        let tilePath = fullBleed ? CGPath(rect: tile, transform: nil)
            : CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.saveGState()
        ctx.addPath(tilePath)
        ctx.clip()
        let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                            colors: [CGColor(red: 0.09, green: 0.02, blue: 0.12, alpha: 1),
                                     CGColor(red: 0.01, green: 0.02, blue: 0.08, alpha: 1)] as CFArray,
                            locations: [0, 1])!
        ctx.drawLinearGradient(bg, start: CGPoint(x: tile.minX, y: tile.maxY), end: CGPoint(x: tile.maxX, y: tile.minY), options: [])

        // Concentric prism rings
        let center = CGPoint(x: tile.midX, y: tile.midY)
        for i in 0..<5 {
            let r = tile.width * (0.16 + CGFloat(i) * 0.1)
            let path = CGMutablePath()
            for k in 0...8 {
                let a = CGFloat(k) / 8 * 2 * .pi + .pi / 8
                let p = CGPoint(x: center.x + cos(a) * r, y: center.y + sin(a) * r)
                if k == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            ctx.addPath(path)
            ctx.setStrokeColor(i % 2 == 0 ? CGColor(red: 0.2, green: 0.5, blue: 1, alpha: 0.22) : CGColor(red: 1, green: 0.2, blue: 0.3, alpha: 0.18))
            ctx.setLineWidth(s * 0.006)
            ctx.strokePath()
        }

        // Block
        let block = CGRect(x: center.x - s * 0.15, y: center.y - s * 0.15, width: s * 0.3, height: s * 0.3)
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: -0.18)
        ctx.translateBy(x: -center.x, y: -center.y)
        let blockPath = CGPath(roundedRect: block, cornerWidth: s * 0.04, cornerHeight: s * 0.04, transform: nil)
        ctx.setShadow(offset: .zero, blur: s * 0.05, color: CGColor(red: 0.2, green: 0.5, blue: 1, alpha: 0.9))
        ctx.addPath(blockPath)
        ctx.setFillColor(CGColor(red: 0.06, green: 0.24, blue: 0.7, alpha: 1))
        ctx.fillPath()
        // Arrow
        let arrow = CGMutablePath()
        arrow.move(to: CGPoint(x: center.x - s * 0.09, y: center.y + s * 0.03))
        arrow.addLine(to: CGPoint(x: center.x + s * 0.09, y: center.y + s * 0.03))
        arrow.addLine(to: CGPoint(x: center.x, y: center.y - s * 0.06))
        arrow.closeSubpath()
        ctx.setShadow(offset: .zero, blur: s * 0.03, color: CGColor(gray: 1, alpha: 1))
        ctx.addPath(arrow)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()

        // Blades
        func blade(from a: CGPoint, to b: CGPoint, color: CGColor) {
            ctx.saveGState()
            ctx.setLineCap(.round)
            ctx.setShadow(offset: .zero, blur: s * 0.06, color: color)
            ctx.setStrokeColor(color)
            ctx.setLineWidth(s * 0.045)
            ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.95))
            ctx.setLineWidth(s * 0.016)
            ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
            ctx.restoreGState()
        }
        blade(from: CGPoint(x: tile.minX + s * 0.1, y: tile.minY + s * 0.12),
              to: CGPoint(x: tile.maxX - s * 0.12, y: tile.maxY - s * 0.1),
              color: CGColor(red: 1, green: 0.15, blue: 0.25, alpha: 1))
        blade(from: CGPoint(x: tile.maxX - s * 0.1, y: tile.minY + s * 0.12),
              to: CGPoint(x: tile.minX + s * 0.12, y: tile.maxY - s * 0.1),
              color: CGColor(red: 0.2, green: 0.55, blue: 1, alpha: 1))
        ctx.restoreGState()

        // Rim
        if !fullBleed {
            ctx.addPath(tilePath)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.12))
            ctx.setLineWidth(s * 0.006)
            ctx.strokePath()
        }
    }

    static func bitmap(pixels: Int, fullBleed: Bool = false) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let gc = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        draw(in: CGRect(x: 0, y: 0, width: pixels, height: pixels), context: gc.cgContext, fullBleed: fullBleed)
        gc.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    static func image(size: Int) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size))
        if let rep = bitmap(pixels: size) { img.addRepresentation(rep) }
        return img
    }

    /// The iPhone app's 1024 px icon: the same artwork, full bleed and opaque.
    static func exportIOSIcon(to url: URL) {
        guard let rep = bitmap(pixels: 1024, fullBleed: true), let image = rep.cgImage,
              let ctx = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
        ctx.setFillColor(CGColor(red: 0.01, green: 0.02, blue: 0.08, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
        guard let opaque = ctx.makeImage(),
              let png = NSBitmapImageRep(cgImage: opaque).representation(using: .png, properties: [:]) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? png.write(to: url)
    }

    static func exportIconset(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sizes: [(String, Int)] = [
            ("icon_16x16", 16), ("icon_16x16@2x", 32),
            ("icon_32x32", 32), ("icon_32x32@2x", 64),
            ("icon_128x128", 128), ("icon_128x128@2x", 256),
            ("icon_256x256", 256), ("icon_256x256@2x", 512),
            ("icon_512x512", 512), ("icon_512x512@2x", 1024),
        ]
        for (name, px) in sizes {
            guard let rep = bitmap(pixels: px), let png = rep.representation(using: .png, properties: [:]) else { continue }
            try? png.write(to: dir.appendingPathComponent("\(name).png"))
        }
    }
}
