import Foundation

/// The material left on a blank turning on a rotary axis, as a cylindrical height grid: for each station along the
/// axis and each angle around it, the distance from the axis to the surface (research_notes/Rotary milling/
/// rotary_milling.md §4.1). Wrapped toolpaths point the tool at the axis, so what they cut is what's visible along a
/// ray from it. A wall the tool cuts parallel (a groove straight along the blank) is drawn as rays stepped by the
/// grid, so it comes out very slightly radial.
///
/// Angles are the material's: a cell at angle α (radians, from the top of the blank at A0 toward +Y) is under the
/// tool when the blank has turned to A = α. Laid flat, the grid is a wrapped job's unrolled sheet: row j's centre is
/// at sheet y = `centerY` + α·`radius`, so `unrolled` lines up with the design.
public struct RadialGrid: Sendable {
    public let columns: Int
    public let rows: Int
    /// Cell size along X, which is also the arc each row spans at `radius`, mm.
    public let cellSize: Double
    /// X of column 0's centre.
    public let originX: Double
    /// Distance from the axis the sheet's Z = 0 is at (the wrap radius, or the blank's on a faces job), mm.
    public let radius: Double
    /// Sheet Y of the top of the blank at A0.
    public let centerY: Double
    /// Distance from the axis to the surface, row-major (row × columns + column), mm.
    public var radii: [Float]
    /// The blank's surface before any cut, one per row (a square bar's distance changes around it), mm.
    public let initial: [Float]

    init(stock: Stock, cellSize requested: Double?, maxCells: Int) {
        let blank = stock.rotary ?? RotaryStock(diameter: max(stock.thickness * 2, 1), length: stock.width)
        let r = blank.topRadius
        let around = 2 * .pi * max(r, 0.5)
        let minimum = (max(stock.width * around, 1) / Double(maxCells)).squareRoot()
        let cell = requested.map { max($0, minimum, 0.02) } ?? max(0.2, minimum)
        rows = max(32, Int((around / cell).rounded()))
        cellSize = around / Double(rows)
        columns = max(1, Int((stock.width / cellSize).rounded(.up)))
        originX = cellSize / 2
        radius = r
        centerY = stock.originPoint.y
        let n = rows, cols = columns
        let step = 2 * Double.pi / Double(n)
        let start = (0..<n).map { j in Float(blank.surfaceRadius(atDegrees: (-.pi + (Double(j) + 0.5) * step) * 180 / .pi)) }
        initial = start
        radii = start.flatMap { [Float](repeating: $0, count: cols) }
    }

    /// Angle step between rows, radians.
    public var angleStep: Double { 2 * .pi / Double(rows) }

    /// Angle of row `j`'s centre, radians, from just above −π (the seam) to just below π.
    public func angle(row j: Int) -> Double { -.pi + (Double(j) + 0.5) * angleStep }

    /// The row an angle falls in, any number of turns round.
    public func row(atAngle a: Double) -> Int {
        let j = Int(((a + .pi) / angleStep).rounded(.down)) % rows
        return j < 0 ? j + rows : j
    }

    /// The column a station along the axis falls in, or nil off the blank.
    public func column(at x: Double) -> Int? {
        let c = Int(((x - originX) / cellSize).rounded())
        return c >= 0 && c < columns ? c : nil
    }

    /// Distance from the axis to the surface at station `x` and angle `a` (radians).
    public func radius(at x: Double, angle a: Double) -> Float? {
        column(at: x).map { radii[row(atAngle: a) * columns + $0] }
    }

    /// Volume removed so far, mm³: each cell is a wedge between its old and new radius.
    public var removedVolume: Double {
        var total = 0.0
        for j in 0..<rows {
            let r0 = Double(initial[j])
            for c in 0..<columns {
                let r = Double(max(radii[j * columns + c], 0))
                total += (r0 * r0 - r * r) / 2
            }
        }
        return total * angleStep * cellSize
    }

    /// How far the material stands out along a tool pointed at the axis at station `x`, the blank turned to `angle`
    /// (radians), mm from the axis: the most any cell within `reach` of the tool's axis stands along it (r·cos φ, φ its
    /// angle off the tool's axis, taken at the cell's nearer edge). With no reach, the most of the cells round the one
    /// there. Infinity when no cell is in reach (off the blank): nothing is known there.
    public func highest(x: Double, angle a: Double, reach: Double) -> Double {
        let lo = max(0, Int(((x - reach - originX) / cellSize).rounded(.down)) - (reach > 0 ? 0 : 1))
        let hi = min(columns - 1, Int(((x + reach - originX) / cellSize).rounded(.up)) + (reach > 0 ? 0 : 1))
        guard lo <= hi else { return .infinity }
        let center = row(atAngle: a)
        var best = -Double.infinity
        if reach <= 0 {
            for dj in -1...1 {
                let j = ((center + dj) % rows + rows) % rows
                for c in lo...hi { best = max(best, Double(radii[j * columns + c])) }
            }
            return best
        }
        let span = rows / 4 + 1
        let half = angleStep / 2
        for dj in -span...span {
            let j = ((center + dj) % rows + rows) % rows
            // The cell's angle off the tool's axis, nearer edge first.
            let off = max(0, abs((angle(row: j) - a).remainder(dividingBy: 2 * .pi)) - half)
            guard off < .pi / 2 else { continue }
            let c0 = cos(off), s0 = sin(off)
            for c in lo...hi {
                let dx = abs(originX + Double(c) * cellSize - x) - cellSize / 2
                guard dx <= reach else { continue }
                let r = Double(radii[j * columns + c])
                guard r * s0 <= reach else { continue }
                best = max(best, r * c0)
            }
        }
        return best
    }

    /// The grid laid flat as the unrolled sheet: heights measured from `radius` (the sheet's Z = 0), the floor at
    /// the axis.
    public var unrolled: HeightGrid {
        HeightGrid(columns: columns, rows: rows, cellSize: cellSize,
                   origin: Vec2(originX, centerY - .pi * radius + cellSize / 2), floorZ: Float(-radius),
                   heights: radii.map { $0 - Float(radius) })
    }
}

/// Carves a `RadialGrid` with the motions of wrapped toolpaths, which are on the unrolled sheet: X along the axis,
/// sheet Y turning into the angle, Z measured from the sheet's radius. The controller moves X, A and Z together, so a
/// straight line on the sheet is a helix on the blank, sampled here closely enough for the grid.
public struct RadialSimulator: Sendable {
    public private(set) var grid: RadialGrid
    /// Rapid moves that passed through material.
    public private(set) var rapidCollisions: [Vec3] = []
    private var kernels: [UUID: MaterialSimulator.Kernel] = [:]
    /// Farthest any part of the blank reaches from the axis: a tool tip beyond it touches nothing.
    private let outer: Double

    public init(stock: Stock, cellSize: Double? = nil, maxCells: Int = 2_500_000) {
        grid = RadialGrid(stock: stock, cellSize: cellSize, maxCells: maxCells)
        outer = Double(grid.initial.max() ?? 0)
    }

    /// Lowers the surface to `bound(x, angle)` (mm from the axis) wherever that's nearer the axis: what earlier cuts
    /// left, when it's known.
    mutating func lower(to bound: (Double, Double) -> Double) {
        let g = grid
        for j in 0..<g.rows {
            let a = g.angle(row: j)
            for c in 0..<g.columns {
                let i = j * g.columns + c
                let b = bound(g.originX + Double(c) * g.cellSize, a)
                if b < Double(grid.radii[i]) { grid.radii[i] = Float(max(0, b)) }
            }
        }
    }

    public mutating func reset() {
        for j in 0..<grid.rows {
            let r = grid.initial[j]
            for c in 0..<grid.columns { grid.radii[j * grid.columns + c] = r }
        }
        rapidCollisions = []
    }

    private mutating func kernel(for tool: Tool) -> MaterialSimulator.Kernel {
        if let k = kernels[tool.id] { return k }
        let table = (0...512).map { Float(tool.profileHeight(atRadius: tool.radius * Double($0) / 512) ?? 0) }
        let k = MaterialSimulator.Kernel(table: table, radius: tool.radius, flat: tool.shape == .flatEndMill || tool.shape == .surfacing)
        kernels[tool.id] = k
        return k
    }

    /// The tool tip on the sheet as (station, material angle, distance from the axis).
    private func polar(_ p: Vec3) -> (x: Double, a: Double, r: Double) {
        (p.x, (p.y - grid.centerY) / grid.radius, grid.radius + p.z)
    }

    /// Applies one motion starting at `start`. `fraction` < 1 applies only the first part (for playback).
    public mutating func apply(_ m: Motion, from start: Vec3, tool: Tool, fraction: Double = 1) {
        let f = max(0, min(1, fraction))
        guard f > 0 else { return }
        switch m.kind {
        case .dwell:
            return
        case .rapid:
            checkRapid(from: start, to: start.lerp(to: m.end, f), tool: tool)
        case .feed:
            cutLine(from: start, to: start.lerp(to: m.end, f), tool: tool)
        case .arcCW, .arcCCW:
            let samples = m.samples(from: start, maxStep: max(grid.cellSize, 0.25))
            let count = max(1, Int((Double(samples.count) * f).rounded(.up)))
            var p = start
            for q in samples.prefix(count) {
                cutLine(from: p, to: q, tool: tool)
                p = q
            }
        }
    }

    /// Sweeps the tool along a straight line on the sheet (a helix on the blank).
    public mutating func cutLine(from a: Vec3, to b: Vec3, tool: Tool) {
        let p = polar(a), q = polar(b)
        if p.r >= outer && q.r >= outer { return }
        let k = kernel(for: tool)
        let around = abs(q.a - p.a) * max(p.r, q.r, 0)
        let span = max(abs(q.x - p.x), around, abs(q.r - p.r))
        let steps = max(1, Int((span / (grid.cellSize * 0.5)).rounded(.up)))
        for i in 0...steps {
            let t = Double(i) / Double(steps)
            stamp(x: p.x + (q.x - p.x) * t, angle: p.a + (q.a - p.a) * t, tip: p.r + (q.r - p.r) * t, kernel: k)
        }
    }

    /// Imprints the tool with its tip `tip` from the axis over station `x`, the blank turned to `angle`. A cell's ray
    /// at angle φ from the tool's axis meets the tool where t·cos φ − tip = h(√(dx² + (t·sin φ)²)), h being the tool's
    /// height above its tip at that distance from its axis; the ray keeps only what's nearer the axis than that. A ray
    /// whose old surface is outside the tool's reach sideways is left alone: what the tool cuts there is hidden
    /// behind material it doesn't touch.
    private mutating func stamp(x xt: Double, angle at: Double, tip rt: Double, kernel k: RadialGrid.Kernel) {
        guard rt < outer else { return }
        let g = grid
        let R = k.radius
        let c0 = max(0, Int(((xt - R - g.originX) / g.cellSize).rounded(.up)))
        let c1 = min(g.columns - 1, Int(((xt + R - g.originX) / g.cellSize).rounded(.down)))
        guard c0 <= c1 else { return }
        let reach = rt > R ? asin(R / rt) : .pi / 2
        let span = min(g.rows / 2, Int((reach / g.angleStep).rounded(.up)) + 1)
        let center = g.row(atAngle: at)
        // The material angle of row `center`, the same number of turns round as `at`.
        let centerAngle = at - (at - g.angle(row: center)).remainder(dividingBy: 2 * .pi)
        let cols = g.columns, rows = g.rows
        let scale = Float(512 / max(R, 1e-9))
        let R2 = R * R
        grid.radii.withUnsafeMutableBufferPointer { radii in
            k.table.withUnsafeBufferPointer { table in
                for dj in -span...span {
                    let phi = centerAngle + Double(dj) * g.angleStep - at
                    let c = cos(phi), s = abs(sin(phi))
                    guard c > 0.05 else { continue }
                    var j = (center + dj) % rows
                    if j < 0 { j += rows }
                    let floorT = rt / c
                    for col in c0...c1 {
                        let dx = g.originX + Double(col) * g.cellSize - xt
                        let dx2 = dx * dx
                        guard dx2 <= R2 else { continue }
                        let idx = j * cols + col
                        let old = Double(radii[idx])
                        // Already below the tool along this ray, or out of its reach sideways.
                        guard old > floorT, dx2 + old * old * s * s <= R2 else { continue }
                        var t = floorT
                        if !k.flat {
                            for _ in 0..<2 {
                                let l2 = dx2 + t * t * s * s
                                guard l2 <= R2 else { break }
                                let u = Float(l2.squareRoot()) * scale
                                let i = min(511, Int(u))
                                t = (rt + Double(table[i] + (table[i + 1] - table[i]) * (u - Float(i)))) / c
                            }
                        }
                        guard dx2 + t * t * s * s <= R2 + 1e-9, t < old else { continue }
                        radii[idx] = Float(t)
                    }
                }
            }
        }
    }

    private mutating func checkRapid(from a: Vec3, to b: Vec3, tool: Tool) {
        let p = polar(a), q = polar(b)
        if p.r >= outer && q.r >= outer { return }
        let tolerance = (tool.profileHeight(atRadius: min(tool.radius, grid.cellSize * 0.75)) ?? 0) + 0.05
        let span = max(abs(q.x - p.x), abs(q.a - p.a) * max(p.r, q.r, 0), abs(q.r - p.r))
        let steps = max(1, Int((span / max(grid.cellSize, 0.5)).rounded(.up)))
        for i in 0...steps {
            let t = Double(i) / Double(steps)
            let x = p.x + (q.x - p.x) * t, ang = p.a + (q.a - p.a) * t, r = p.r + (q.r - p.r) * t
            if let surface = grid.radius(at: x, angle: ang), Double(surface) > r + tolerance {
                rapidCollisions.append(a.lerp(to: b, t))
                return
            }
        }
    }
}

extension RadialGrid {
    typealias Kernel = MaterialSimulator.Kernel
}
