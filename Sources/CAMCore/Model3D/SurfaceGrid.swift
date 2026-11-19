import Foundation
import simd

/// A regular grid of top-surface heights over part of the design (a z-buffer looking straight down).
public struct SurfaceGrid: Sendable {
    /// Design XY of the centre of cell (0, 0).
    public let origin: Vec2
    public let cellSize: Double
    public let columns: Int
    public let rows: Int
    /// Highest surface Z per cell (design coordinates); -infinity where nothing covers the cell.
    public var heights: [Float]
    public var covered: [Bool]

    public init(area: Rect2, cellSize: Double) {
        self.cellSize = cellSize
        columns = max(1, Int((area.width / cellSize).rounded(.up)) + 1)
        rows = max(1, Int((area.height / cellSize).rounded(.up)) + 1)
        origin = area.min
        heights = [Float](repeating: -.infinity, count: columns * rows)
        covered = [Bool](repeating: false, count: columns * rows)
    }

    @inlinable public func index(_ c: Int, _ r: Int) -> Int { r * columns + c }
    @inlinable public func center(_ c: Int, _ r: Int) -> Vec2 { Vec2(origin.x + Double(c) * cellSize, origin.y + Double(r) * cellSize) }

    public var bounds: Rect2 {
        Rect2(min: origin, max: Vec2(origin.x + Double(columns - 1) * cellSize, origin.y + Double(rows - 1) * cellSize))
    }

    /// Height at the nearest cell, nil outside the grid or where uncovered.
    public func height(at p: Vec2) -> Float? {
        let c = Int(((p.x - origin.x) / cellSize).rounded()), r = Int(((p.y - origin.y) / cellSize).rounded())
        guard c >= 0, r >= 0, c < columns, r < rows, covered[index(c, r)] else { return nil }
        return heights[index(c, r)]
    }

    /// Z-buffers triangles (max height wins). `map` converts stored positions to (x, y, z) in this grid's space.
    public mutating func rasterize(positions: [SIMD3<Float>], indices: [UInt32], map: (SIMD3<Float>) -> SIMD3<Float>) {
        var i = 0
        while i + 2 < indices.count {
            rasterizeTriangle(SIMD3<Double>(map(positions[Int(indices[i])])),
                              SIMD3<Double>(map(positions[Int(indices[i + 1])])),
                              SIMD3<Double>(map(positions[Int(indices[i + 2])])))
            i += 3
        }
    }

    /// Z-buffers one triangle given in design coordinates.
    public mutating func rasterizeTriangle(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>) {
        let area2 = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        guard abs(area2) > 1e-12 else { return } // vertical walls add nothing seen from above
        let inv = 1 / area2
        let minX = min(a.x, b.x, c.x), maxX = max(a.x, b.x, c.x)
        let minY = min(a.y, b.y, c.y), maxY = max(a.y, b.y, c.y)
        let c0 = max(0, Int(((minX - origin.x) / cellSize).rounded(.up)))
        let c1 = min(columns - 1, Int(((maxX - origin.x) / cellSize).rounded(.down)))
        let r0 = max(0, Int(((minY - origin.y) / cellSize).rounded(.up)))
        let r1 = min(rows - 1, Int(((maxY - origin.y) / cellSize).rounded(.down)))
        guard c0 <= c1, r0 <= r1 else { return }
        let eps = -1e-9
        let cols = columns
        heights.withUnsafeMutableBufferPointer { h in
            covered.withUnsafeMutableBufferPointer { cov in
                for r in r0...r1 {
                    let py = origin.y + Double(r) * cellSize
                    for col in c0...c1 {
                        let px = origin.x + Double(col) * cellSize
                        // Barycentric weights (signed areas), consistent for either winding.
                        let w0 = ((b.x - px) * (c.y - py) - (b.y - py) * (c.x - px)) * inv
                        let w1 = ((c.x - px) * (a.y - py) - (c.y - py) * (a.x - px)) * inv
                        let w2 = 1 - w0 - w1
                        if w0 < eps || w1 < eps || w2 < eps { continue }
                        let z = Float(w0 * a.z + w1 * b.z + w2 * c.z)
                        let k = r * cols + col
                        if z > h[k] { h[k] = z }
                        cov[k] = true
                    }
                }
            }
        }
    }
}

public enum ModelRaster {
    /// Composite top surface (max over models) of the model shapes in `shapes`, sampled over `area`.
    public static func surface(of shapes: [DesignShape], over area: Rect2, cellSize: Double) -> SurfaceGrid {
        var grid = SurfaceGrid(area: area, cellSize: cellSize)
        for shape in shapes where shape.modelSpec != nil {
            shape.forEachModelTriangle { a, b, c in grid.rasterizeTriangle(a, b, c) }
        }
        return grid
    }

    /// Cell size giving at most `maxCells` cells over `area`, but no coarser than needed.
    public static func cellSize(for area: Rect2, preferred: Double, maxCells: Int = 4_000_000) -> Double {
        let minimum = (max(area.width * area.height, 1) / Double(maxCells)).squareRoot()
        return max(preferred, minimum)
    }
}

/// Marching squares over a boolean grid: closed loops around `true` cells, outer loops counter-clockwise.
public enum GridContours {
    public static func loops(mask: [Bool], columns: Int, rows: Int, origin: Vec2, cellSize: Double) -> [Polyline] {
        // Lattice points on cell-centre squares live on edge midpoints. Encode an edge midpoint as doubled
        // integer coordinates: horizontal edge between (c,r)-(c+1,r) -> (2c+1, 2r); vertical (c,r)-(c,r+1) -> (2c, 2r+1).
        struct P: Hashable { let x: Int32; let y: Int32 }
        func inside(_ c: Int, _ r: Int) -> Bool {
            c >= 0 && r >= 0 && c < columns && r < rows && mask[r * columns + c]
        }
        var next: [P: P] = [:]
        next.reserveCapacity(1024)
        // Squares span cell centres (c,r)…(c+1,r+1); pad by one so borders close.
        for r in -1..<rows {
            for c in -1..<columns {
                let bl = inside(c, r), br = inside(c + 1, r), tr = inside(c + 1, r + 1), tl = inside(c, r + 1)
                let code = (bl ? 1 : 0) | (br ? 2 : 0) | (tr ? 4 : 0) | (tl ? 8 : 0)
                if code == 0 || code == 15 { continue }
                let bottom = P(x: Int32(2 * c + 1), y: Int32(2 * r))
                let right = P(x: Int32(2 * c + 2), y: Int32(2 * r + 1))
                let top = P(x: Int32(2 * c + 1), y: Int32(2 * r + 2))
                let left = P(x: Int32(2 * c), y: Int32(2 * r + 1))
                // Segments oriented with the inside on the left (counter-clockwise around filled regions).
                switch code {
                case 1: next[bottom] = left
                case 2: next[right] = bottom
                case 3: next[right] = left
                case 4: next[top] = right
                case 5: next[bottom] = left; next[top] = right   // saddle: keep the two corners separate
                case 6: next[top] = bottom
                case 7: next[top] = left
                case 8: next[left] = top
                case 9: next[bottom] = top
                case 10: next[right] = bottom; next[left] = top  // saddle
                case 11: next[right] = top
                case 12: next[left] = right
                case 13: next[bottom] = right
                case 14: next[left] = bottom
                default: break
                }
            }
        }
        var loops: [Polyline] = []
        var remaining = next
        while let (start, _) = remaining.first {
            var pts: [Vec2] = []
            var p = start
            var guardCount = 0
            while let q = remaining.removeValue(forKey: p), guardCount < 10_000_000 {
                pts.append(Vec2(origin.x + Double(p.x) * 0.5 * cellSize, origin.y + Double(p.y) * 0.5 * cellSize))
                p = q
                guardCount += 1
                if p == start { break }
            }
            if pts.count >= 3 { loops.append(Polyline(pts, closed: true).simplifiedCollinear()) }
        }
        return loops
    }
}

extension Polyline {
    /// Drops vertices that lie exactly on the line between their neighbours (staircase runs from marching squares).
    func simplifiedCollinear() -> Polyline {
        guard isClosed, points.count > 3 else { return self }
        var out: [Vec2] = []
        let n = points.count
        for i in 0..<n {
            let a = points[(i + n - 1) % n], b = points[i], c = points[(i + 1) % n]
            if abs((b - a).cross(c - b)) > 1e-12 { out.append(b) }
        }
        return out.count >= 3 ? Polyline(out, closed: true) : self
    }
}
