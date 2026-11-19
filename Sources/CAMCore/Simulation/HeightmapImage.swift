import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Renders a simulated height grid to a shaded PNG (used by the CLI and for thumbnails).
public enum HeightmapImage {
    public static func cgImage(_ grid: HeightGrid) -> CGImage? {
        let w = grid.columns, h = grid.rows
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let floor = grid.floorZ
        let light = (x: -0.4, y: 0.5, z: 0.77)
        for r in 0..<h {
            for c in 0..<w {
                let z = grid.heights[grid.index(c, r)]
                // Image rows go top-down; grid rows go bottom-up.
                let o = ((h - 1 - r) * w + c) * 4
                if z <= floor + 1e-4 {
                    pixels[o] = 40; pixels[o + 1] = 44; pixels[o + 2] = 52; pixels[o + 3] = 255
                    continue
                }
                let zl = grid.heights[grid.index(max(0, c - 1), r)]
                let zr = grid.heights[grid.index(min(w - 1, c + 1), r)]
                let zd = grid.heights[grid.index(c, max(0, r - 1))]
                let zu = grid.heights[grid.index(c, min(h - 1, r + 1))]
                let cs = Float(grid.cellSize)
                var nx = Double((zl - zr) / (2 * cs)), ny = Double((zd - zu) / (2 * cs)), nz = 1.0
                let len = (nx * nx + ny * ny + nz * nz).squareRoot()
                nx /= len; ny /= len; nz /= len
                let diffuse = max(0, nx * light.x + ny * light.y + nz * light.z)
                let depthT = Double(min(1, max(0, -z / max(-floor, 1e-3))))
                let shade = 0.35 + 0.65 * diffuse
                let base = (r: 222.0 - 70 * depthT, g: 184.0 - 70 * depthT, b: 135.0 - 60 * depthT)
                pixels[o] = UInt8(max(0, min(255, base.r * shade)))
                pixels[o + 1] = UInt8(max(0, min(255, base.g * shade)))
                pixels[o + 2] = UInt8(max(0, min(255, base.b * shade)))
                pixels[o + 3] = 255
            }
        }
        let data = Data(pixels) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    public static func writePNG(_ grid: HeightGrid, to url: URL) throws {
        guard let image = cgImage(grid),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }
}
