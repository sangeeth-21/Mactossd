// Renders the PhotoBridge logo as vector art with Core Graphics.
// Usage: swift scripts/make-icon.swift <out-dir>
// Produces <out-dir>/AppIcon.iconset (for iconutil) and <out-dir>/Logo.png (1024 px).
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build")
let iconset = outDir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func roundedRect(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func linear(_ ctx: CGContext, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

/// Draws everything in a 1024×1024 design space, scaled to `size`.
func render(_ size: Int) -> Data {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // 1. macOS squircle tile with deep indigo → violet gradient and soft drop shadow.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = roundedRect(tile, 185)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.35))
    ctx.addPath(tilePath); ctx.setFillColor(rgb(0x3A2FD9)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(tilePath); ctx.clip()
    linear(ctx, [rgb(0x2D7BFF), rgb(0x5B3BF5), rgb(0x9B3CF0)], from: CGPoint(x: 160, y: 924), to: CGPoint(x: 880, y: 100))
    // soft top glow
    let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [rgb(0xFFFFFF, 0.28), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 330, y: 860), startRadius: 0,
                           endCenter: CGPoint(x: 330, y: 860), endRadius: 560, options: [])
    ctx.restoreGState()

    // 2. Back card (the "drive" copy): translucent, tilted left.
    func card(center: CGPoint, angle: CGFloat, fill: CGColor, shadow: Bool) -> CGRect {
        let w: CGFloat = 430, h: CGFloat = 340
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: angle * .pi / 180)
        let r = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
        if shadow { ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: rgb(0x1A0C6B, 0.45)) }
        ctx.addPath(roundedRect(r, 44)); ctx.setFillColor(fill); ctx.fillPath()
        ctx.restoreGState()
        return r
    }
    _ = card(center: CGPoint(x: 455, y: 575), angle: 9, fill: rgb(0xFFFFFF, 0.30), shadow: false)

    // 3. Front card: white photo with a landscape inside.
    let front = CGPoint(x: 545, y: 520)
    let angle: CGFloat = -7
    let frame = card(center: front, angle: angle, fill: rgb(0xFFFFFF), shadow: true)
    ctx.saveGState()
    ctx.translateBy(x: front.x, y: front.y)
    ctx.rotate(by: angle * .pi / 180)
    let photo = frame.insetBy(dx: 26, dy: 26)
    ctx.addPath(roundedRect(photo, 24)); ctx.clip()
    linear(ctx, [rgb(0x8FD3FF), rgb(0xD9F1FF)], from: CGPoint(x: 0, y: photo.maxY), to: CGPoint(x: 0, y: photo.minY))
    // sun
    ctx.setFillColor(rgb(0xFFC23D))
    ctx.fillEllipse(in: CGRect(x: photo.maxX - 120, y: photo.maxY - 118, width: 72, height: 72))
    // far mountain
    let m1 = CGMutablePath()
    m1.move(to: CGPoint(x: photo.minX - 10, y: photo.minY))
    m1.addLine(to: CGPoint(x: photo.minX + 120, y: photo.minY + 165))
    m1.addLine(to: CGPoint(x: photo.minX + 205, y: photo.minY + 95))
    m1.addLine(to: CGPoint(x: photo.minX + 300, y: photo.minY + 200))
    m1.addLine(to: CGPoint(x: photo.maxX + 10, y: photo.minY + 40))
    m1.addLine(to: CGPoint(x: photo.maxX + 10, y: photo.minY))
    m1.closeSubpath()
    ctx.addPath(m1); ctx.setFillColor(rgb(0x4C6CF0)); ctx.fillPath()
    // near hill
    let m2 = CGMutablePath()
    m2.move(to: CGPoint(x: photo.minX - 10, y: photo.minY))
    m2.addLine(to: CGPoint(x: photo.minX - 10, y: photo.minY + 60))
    m2.addQuadCurve(to: CGPoint(x: photo.maxX + 10, y: photo.minY + 70),
                    control: CGPoint(x: photo.midX, y: photo.minY + 170))
    m2.addLine(to: CGPoint(x: photo.maxX + 10, y: photo.minY))
    m2.closeSubpath()
    ctx.addPath(m2); ctx.setFillColor(rgb(0x2E3FC7)); ctx.fillPath()
    ctx.restoreGState()

    // 4. Sync badge: white disc with two curved arrows (Photos ⇄ SSD).
    let badgeCenter = CGPoint(x: 712, y: 300)
    let badgeR: CGFloat = 128
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0x1A0C6B, 0.45))
    ctx.setFillColor(rgb(0xFFFFFF))
    ctx.fillEllipse(in: CGRect(x: badgeCenter.x - badgeR, y: badgeCenter.y - badgeR, width: badgeR * 2, height: badgeR * 2))
    ctx.restoreGState()

    func arc(from a0: CGFloat, to a1: CGFloat, color: CGColor) {
        let r: CGFloat = 68
        let path = CGMutablePath()
        path.addArc(center: badgeCenter, radius: r, startAngle: a0 * .pi / 180, endAngle: a1 * .pi / 180, clockwise: false)
        ctx.addPath(path)
        ctx.setStrokeColor(color); ctx.setLineWidth(26); ctx.setLineCap(.round)
        ctx.strokePath()
        // arrow head at the end of the arc, pointing along the direction of travel
        let end = a1 * .pi / 180
        let tip = CGPoint(x: badgeCenter.x + cos(end) * r, y: badgeCenter.y + sin(end) * r)
        let tangent = CGPoint(x: -sin(end), y: cos(end))
        let normal = CGPoint(x: cos(end), y: sin(end))
        let head = CGMutablePath()
        head.move(to: CGPoint(x: tip.x + tangent.x * 40, y: tip.y + tangent.y * 40))
        head.addLine(to: CGPoint(x: tip.x - tangent.x * 6 + normal.x * 38, y: tip.y - tangent.y * 6 + normal.y * 38))
        head.addLine(to: CGPoint(x: tip.x - tangent.x * 6 - normal.x * 38, y: tip.y - tangent.y * 6 - normal.y * 38))
        head.closeSubpath()
        ctx.addPath(head); ctx.setFillColor(color); ctx.fillPath()
    }
    arc(from: 20, to: 150, color: rgb(0x2D7BFF))
    arc(from: 200, to: 330, color: rgb(0x8A3CF0))

    let image = ctx.makeImage()!
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try render(base * scale).write(to: iconset.appendingPathComponent(name))
    }
}
try render(1024).write(to: outDir.appendingPathComponent("Logo.png"))
print(iconset.path)
