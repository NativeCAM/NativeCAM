// Draws the NativeCAM app icon and writes an .iconset folder for `iconutil`.
//   swift scripts/make-icon.swift Resources/AppIcon.iconset && iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
// Artwork follows the macOS icon grid: an 824 pt rounded-square body centred on a 1024 pt canvas.
import AppKit
import CoreGraphics
import Foundation

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func linear(_ ctx: CGContext, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

func drawIcon(_ ctx: CGContext) {
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Drop shadow under the body (as macOS icons have).
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(squircle)
    ctx.setFillColor(color(0x1B2233))
    ctx.fillPath()
    ctx.restoreGState()

    // Background: deep slate gradient with a soft top highlight.
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    linear(ctx, [color(0x2E3A55), color(0x141A28)], from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 100))
    linear(ctx, [color(0xFFFFFF, 0.10), color(0xFFFFFF, 0)], from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 620))

    // Faint machine-bed grid.
    ctx.setStrokeColor(color(0x8FA8D8, 0.10))
    ctx.setLineWidth(2)
    var g: CGFloat = 132
    while g < 924 {
        ctx.move(to: CGPoint(x: g, y: 100)); ctx.addLine(to: CGPoint(x: g, y: 924))
        ctx.move(to: CGPoint(x: 100, y: g)); ctx.addLine(to: CGPoint(x: 924, y: g))
        g += 64
    }
    ctx.strokePath()

    // Wooden board in cross-section with a V-groove being carved.
    let boardTop: CGFloat = 520, boardBottom: CGFloat = 250
    let notchHalf: CGFloat = 92, notchDepth: CGFloat = 150
    let board = CGMutablePath()
    board.move(to: CGPoint(x: 168, y: boardBottom))
    board.addLine(to: CGPoint(x: 856, y: boardBottom))
    board.addLine(to: CGPoint(x: 856, y: boardTop))
    board.addLine(to: CGPoint(x: 512 + notchHalf, y: boardTop))
    board.addLine(to: CGPoint(x: 512, y: boardTop - notchDepth))
    board.addLine(to: CGPoint(x: 512 - notchHalf, y: boardTop))
    board.addLine(to: CGPoint(x: 168, y: boardTop))
    board.closeSubpath()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, 0.45))
    ctx.addPath(board)
    ctx.setFillColor(color(0xC8925A))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(board)
    ctx.clip()
    linear(ctx, [color(0xEBC48D), color(0xB97F45)], from: CGPoint(x: 512, y: boardTop), to: CGPoint(x: 512, y: boardBottom))
    // Grain.
    ctx.setStrokeColor(color(0x8A5A2B, 0.28))
    ctx.setLineWidth(5)
    for (i, y) in stride(from: boardBottom + 34, to: boardTop - 10, by: 46).enumerated() {
        ctx.move(to: CGPoint(x: 168, y: y))
        ctx.addCurve(to: CGPoint(x: 856, y: y + CGFloat(i % 2 == 0 ? 8 : -8)),
                     control1: CGPoint(x: 380, y: y + 22), control2: CGPoint(x: 640, y: y - 22))
    }
    ctx.strokePath()
    // Freshly cut groove walls: darker on the left, catching light on the right.
    ctx.setFillColor(color(0x6E4421, 0.55))
    ctx.move(to: CGPoint(x: 512 - notchHalf, y: boardTop)); ctx.addLine(to: CGPoint(x: 512, y: boardTop - notchDepth))
    ctx.addLine(to: CGPoint(x: 512 - notchHalf - 26, y: boardTop)); ctx.fillPath()
    ctx.restoreGState()
    // Top edge highlight.
    ctx.setStrokeColor(color(0xFFE2B8, 0.9))
    ctx.setLineWidth(6)
    ctx.move(to: CGPoint(x: 168, y: boardTop)); ctx.addLine(to: CGPoint(x: 512 - notchHalf, y: boardTop))
    ctx.move(to: CGPoint(x: 512 + notchHalf, y: boardTop)); ctx.addLine(to: CGPoint(x: 856, y: boardTop))
    ctx.strokePath()

    // V-bit: cone matching the groove, short body, then shank.
    let tip = CGPoint(x: 512, y: boardTop - notchDepth + 8)
    let coneTopY = tip.y + notchDepth + 8
    let coneR = notchHalf + 6
    let bit = CGMutablePath()
    bit.move(to: tip)
    bit.addLine(to: CGPoint(x: 512 + coneR, y: coneTopY))
    bit.addLine(to: CGPoint(x: 512 + coneR, y: coneTopY + 70))
    bit.addLine(to: CGPoint(x: 512 + 46, y: coneTopY + 96))
    bit.addLine(to: CGPoint(x: 512 + 46, y: 870))
    bit.addLine(to: CGPoint(x: 512 - 46, y: 870))
    bit.addLine(to: CGPoint(x: 512 - 46, y: coneTopY + 96))
    bit.addLine(to: CGPoint(x: 512 - coneR, y: coneTopY + 70))
    bit.addLine(to: CGPoint(x: 512 - coneR, y: coneTopY))
    bit.closeSubpath()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 10, height: -8), blur: 18, color: color(0x000000, 0.45))
    ctx.addPath(bit)
    ctx.setFillColor(color(0xC9CFD8))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(bit)
    ctx.clip()
    linear(ctx, [color(0x8E98A6), color(0xF4F6F9), color(0xB8C0CB), color(0x6F7886)],
           from: CGPoint(x: 512 - coneR, y: 0), to: CGPoint(x: 512 + coneR, y: 0))
    // Flute: a darker sweep across the cutting cone.
    ctx.setFillColor(color(0x3B4350, 0.55))
    ctx.move(to: tip)
    ctx.addLine(to: CGPoint(x: 512 + 20, y: coneTopY + 70))
    ctx.addLine(to: CGPoint(x: 512 - 34, y: coneTopY + 70))
    ctx.closePath()
    ctx.fillPath()
    // Collet ring.
    ctx.setFillColor(color(0x2A303A, 0.35))
    ctx.fill(CGRect(x: 512 - 46, y: coneTopY + 96, width: 92, height: 10))
    ctx.restoreGState()

    // Toolpath glow along the groove.
    ctx.setStrokeColor(color(0x4FA3FF, 0.95))
    ctx.setLineWidth(7)
    ctx.setLineCap(.round)
    ctx.setLineDash(phase: 0, lengths: [26, 18])
    ctx.move(to: CGPoint(x: 210, y: 590)); ctx.addLine(to: CGPoint(x: 512 - coneR - 26, y: 590))
    ctx.move(to: CGPoint(x: 512 + coneR + 26, y: 590)); ctx.addLine(to: CGPoint(x: 814, y: 590))
    ctx.strokePath()
    ctx.restoreGState()

    // Subtle inner border.
    ctx.addPath(squircle)
    ctx.setStrokeColor(color(0xFFFFFF, 0.08))
    ctx.setLineWidth(3)
    ctx.strokePath()
}

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let master = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
drawIcon(master)
let masterImage = master.makeImage()!

let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in sizes {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(masterImage, in: CGRect(x: 0, y: 0, width: px, height: px))
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try rep.representation(using: .png, properties: [:])!.write(to: outDir.appendingPathComponent("\(name).png"))
}
print("Wrote \(outDir.path)")
