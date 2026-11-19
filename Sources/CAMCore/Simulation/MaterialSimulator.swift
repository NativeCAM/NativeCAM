import Foundation

/// Regular grid of surface heights over the stock (a 2.5D "dexel" model, exact for router work).
public struct HeightGrid: Sendable {
    public let columns: Int
    public let rows: Int
    public let cellSize: Double
    /// Design-space XY of the centre of cell (0, 0).
    public let origin: Vec2
    /// Material bottom (−thickness). Heights at or below this are cut through.
    public let floorZ: Float
    public var heights: [Float]

    public init(stock: Stock, cellSize requested: Double? = nil, maxCells: Int = 2_500_000) {
        let area = max(stock.width * stock.height, 1)
        let minimum = (area / Double(maxCells)).squareRoot()
        let cell = requested.map { max($0, minimum, 0.02) } ?? max(0.2, minimum)
        cellSize = cell
        columns = max(1, Int((stock.width / cell).rounded(.up)))
        rows = max(1, Int((stock.height / cell).rounded(.up)))
        origin = Vec2(cell / 2, cell / 2)
        floorZ = Float(-stock.thickness)
        heights = [Float](repeating: 0, count: columns * rows)
    }

    @inlinable public func index(_ col: Int, _ row: Int) -> Int { row * columns + col }

    public func height(at p: Vec2) -> Float? {
        let c = Int(((p.x - origin.x) / cellSize).rounded())
        let r = Int(((p.y - origin.y) / cellSize).rounded())
        guard c >= 0, r >= 0, c < columns, r < rows else { return nil }
        return heights[index(c, r)]
    }

    /// Volume removed so far (mm³).
    public var removedVolume: Double {
        let cellArea = cellSize * cellSize
        return heights.reduce(0.0) { $0 + Double(-max($1, floorZ)) } * cellArea
    }
}

/// Carves a `HeightGrid` with tool motions.
public struct MaterialSimulator: Sendable {
    public private(set) var grid: HeightGrid
    /// Rapid moves that passed through material (time-independent list of positions).
    public private(set) var rapidCollisions: [Vec3] = []
    private var kernels: [UUID: Kernel] = [:]

    struct Kernel: Sendable {
        /// Tool profile height above the tip, sampled at 513 radii from 0 to the tool radius.
        var table: [Float]
        var radius: Double
        var flat: Bool
    }

    public init(stock: Stock, cellSize: Double? = nil) {
        grid = HeightGrid(stock: stock, cellSize: cellSize)
    }

    public mutating func reset() {
        for i in grid.heights.indices { grid.heights[i] = 0 }
        rapidCollisions = []
    }

    private mutating func kernel(for tool: Tool) -> Kernel {
        if let k = kernels[tool.id] { return k }
        let table = (0...512).map { Float(tool.profileHeight(atRadius: tool.radius * Double($0) / 512) ?? 0) }
        let k = Kernel(table: table, radius: tool.radius, flat: tool.shape == .flatEndMill || tool.shape == .surfacing)
        kernels[tool.id] = k
        return k
    }

    /// Applies one motion starting at `start`. `fraction` < 1 applies only the first part (for playback).
    public mutating func apply(_ m: Motion, from start: Vec3, tool: Tool, fraction: Double = 1) {
        let f = max(0, min(1, fraction))
        guard f > 0 else { return }
        switch m.kind {
        case .dwell:
            return
        case .rapid:
            let end = start.lerp(to: m.end, f)
            checkRapid(from: start, to: end, tool: tool)
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

    /// Sweeps the tool along a straight segment.
    public mutating func cutLine(from a: Vec3, to b: Vec3, tool: Tool) {
        // Entirely above the material: nothing to do.
        if a.z >= 0 && b.z >= 0 { return }
        let horizontal = abs(a.z - b.z) < 1e-9
        if horizontal {
            cutHorizontal(from: a.xy, to: b.xy, z: a.z, tool: tool)
            return
        }
        // Sloped or vertical: stamp the tool at closely spaced samples.
        let k = kernel(for: tool)
        let len = a.xy.distance(to: b.xy)
        let steps = max(1, Int((len / (grid.cellSize * 0.5)).rounded(.up)))
        for i in 0...steps {
            let p = a.lerp(to: b, Double(i) / Double(steps))
            stamp(p, kernel: k)
        }
    }

    /// Imprints the tool with its tip at `p`, using exact distances from `p` to each cell centre.
    private mutating func stamp(_ p: Vec3, kernel k: Kernel) {
        guard p.z < 0 else { return }
        let cs = grid.cellSize
        let R = k.radius
        let c0 = max(0, Int(((p.x - R - grid.origin.x) / cs).rounded(.up)))
        let c1 = min(grid.columns - 1, Int(((p.x + R - grid.origin.x) / cs).rounded(.down)))
        let r0 = max(0, Int(((p.y - R - grid.origin.y) / cs).rounded(.up)))
        let r1 = min(grid.rows - 1, Int(((p.y + R - grid.origin.y) / cs).rounded(.down)))
        guard c0 <= c1, r0 <= r1 else { return }
        let z = Float(p.z)
        let cols = grid.columns
        let ox = grid.origin.x, oy = grid.origin.y
        let R2 = R * R
        let scale = Float(512 / max(R, 1e-9))
        grid.heights.withUnsafeMutableBufferPointer { h in
            k.table.withUnsafeBufferPointer { t in
                for r in r0...r1 {
                    let dy = oy + Double(r) * cs - p.y
                    let dy2 = dy * dy
                    if dy2 > R2 { continue }
                    for c in c0...c1 {
                        let dx = ox + Double(c) * cs - p.x
                        let d2 = dx * dx + dy2
                        if d2 > R2 { continue }
                        let v: Float
                        if k.flat {
                            v = z
                        } else {
                            let x = Float(d2.squareRoot()) * scale
                            let i = min(511, Int(x))
                            v = z + t[i] + (t[i + 1] - t[i]) * (x - Float(i))
                        }
                        let idx = r * cols + c
                        if v < h[idx] { h[idx] = v }
                    }
                }
            }
        }
    }

    /// Exact capsule sweep for constant-Z moves: each cell takes the tool height at its distance to the segment.
    private mutating func cutHorizontal(from a: Vec2, to b: Vec2, z: Double, tool: Tool) {
        let cs = grid.cellSize
        let R = tool.radius
        let minX = min(a.x, b.x) - R, maxX = max(a.x, b.x) + R
        let minY = min(a.y, b.y) - R, maxY = max(a.y, b.y) + R
        let c0 = max(0, Int(((minX - grid.origin.x) / cs).rounded(.down)))
        let c1 = min(grid.columns - 1, Int(((maxX - grid.origin.x) / cs).rounded(.up)))
        let r0 = max(0, Int(((minY - grid.origin.y) / cs).rounded(.down)))
        let r1 = min(grid.rows - 1, Int(((maxY - grid.origin.y) / cs).rounded(.up)))
        guard c0 <= c1, r0 <= r1 else { return }
        let ab = b - a
        let l2 = ab.lengthSquared
        let zf = Float(z)
        let cols = grid.columns
        let ox = grid.origin.x, oy = grid.origin.y
        let R2 = R * R
        // Flat-bottomed tools are a common fast path.
        let flat = tool.shape == .flatEndMill || tool.shape == .surfacing
        grid.heights.withUnsafeMutableBufferPointer { h in
            for r in r0...r1 {
                let py = oy + Double(r) * cs
                for c in c0...c1 {
                    let px = ox + Double(c) * cs
                    let apx = px - a.x, apy = py - a.y
                    var t = l2 > 0 ? (apx * ab.x + apy * ab.y) / l2 : 0
                    t = t < 0 ? 0 : (t > 1 ? 1 : t)
                    let dx = apx - ab.x * t, dy = apy - ab.y * t
                    let d2 = dx * dx + dy * dy
                    if d2 > R2 { continue }
                    let i = r * cols + c
                    let v: Float
                    if flat {
                        v = zf
                    } else {
                        guard let hh = tool.profileHeight(atRadius: d2.squareRoot()) else { continue }
                        v = zf + Float(hh)
                    }
                    if v < h[i] { h[i] = v }
                }
            }
        }
    }

    private mutating func checkRapid(from a: Vec3, to b: Vec3, tool: Tool) {
        if a.z >= 0 && b.z >= 0 { return }
        // Straight up can't hit anything.
        if a.xy.distance(to: b.xy) < 1e-6 && b.z >= a.z { return }
        // The nearest cell centre can be up to ~0.7 cells from the tip; allow for the tool's profile there.
        let tolerance = (tool.profileHeight(atRadius: min(tool.radius, grid.cellSize * 0.75)) ?? 0) + 0.05
        let len = a.distance(to: b)
        let steps = max(1, Int((len / max(grid.cellSize, 0.5)).rounded(.up)))
        for i in 0...steps {
            let p = a.lerp(to: b, Double(i) / Double(steps))
            if let h = grid.height(at: p.xy), Double(h) > p.z + tolerance {
                rapidCollisions.append(p)
                return
            }
        }
    }
}

/// A flattened, timed list of motions across all toolpaths, for playback and scrubbing.
public struct SimulationTimeline: Sendable {
    public struct Step: Sendable {
        public var toolpathIndex: Int
        public var start: Vec3
        public var motion: Motion
        public var startTime: Double
        public var duration: Double
    }

    public let toolpaths: [Toolpath]
    public private(set) var steps: [Step] = []
    public let duration: Double

    public init(toolpaths: [Toolpath], rapidRate: Double) {
        self.toolpaths = toolpaths
        var t = 0.0
        var steps: [Step] = []
        for (i, tp) in toolpaths.enumerated() {
            tp.forEachMotion { s, m in
                let d = m.duration(from: s, rapidRate: rapidRate)
                steps.append(Step(toolpathIndex: i, start: s, motion: m, startTime: t, duration: d))
                t += d
            }
        }
        self.steps = steps
        duration = t
    }

    /// Index of the step active at time `t` (binary search).
    public func stepIndex(at t: Double) -> Int? {
        guard !steps.isEmpty else { return nil }
        var lo = 0, hi = steps.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if steps[mid].startTime <= t { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// Tool tip position and toolpath index at time `t`.
    public func state(at t: Double) -> (position: Vec3, toolpathIndex: Int)? {
        guard let i = stepIndex(at: t) else { return nil }
        let s = steps[i]
        let f = s.duration > 0 ? max(0, min(1, (t - s.startTime) / s.duration)) : 1
        let m = s.motion
        if m.kind.isArc {
            let pts = [s.start] + m.samples(from: s.start, maxStep: 0.5)
            let x = f * Double(pts.count - 1)
            let k = min(pts.count - 2, Int(x))
            return (pts[k].lerp(to: pts[k + 1], x - Double(k)), s.toolpathIndex)
        }
        return (s.start.lerp(to: m.end, m.kind == .dwell ? 1 : f), s.toolpathIndex)
    }
}

/// Playback session: keeps the simulated material in sync with a play head.
///
/// Completed moves are carved into `simulator`; the move in progress is carved into a throw-away copy, so the
/// displayed material depends only on the play-head time, not on how the user scrubbed to it.
public struct SimulationSession: Sendable {
    public let timeline: SimulationTimeline
    /// Material after every fully completed move.
    public private(set) var simulator: MaterialSimulator
    /// Committed material plus the partially completed current move (nil when the play head is on a step boundary).
    private var display: MaterialSimulator?
    public private(set) var time: Double = 0
    /// Steps fully applied to `simulator`.
    private var appliedSteps = 0

    public init(toolpaths: [Toolpath], stock: Stock, rapidRate: Double, cellSize: Double? = nil) {
        timeline = SimulationTimeline(toolpaths: toolpaths, rapidRate: rapidRate)
        simulator = MaterialSimulator(stock: stock, cellSize: cellSize)
    }

    /// Material as it looks at the play head.
    public var grid: HeightGrid { (display ?? simulator).grid }

    /// Rapid moves that hit material up to the play head.
    public var rapidCollisions: [Vec3] { (display ?? simulator).rapidCollisions }

    /// Moves the play head, carving forward incrementally or replaying from the start when going back.
    public mutating func seek(to tIn: Double) {
        let t = max(0, min(timeline.duration, tIn))
        if t < time {
            simulator.reset()
            appliedSteps = 0
        }
        let steps = timeline.steps
        while appliedSteps < steps.count, steps[appliedSteps].startTime + steps[appliedSteps].duration <= t {
            let s = steps[appliedSteps]
            simulator.apply(s.motion, from: s.start, tool: timeline.toolpaths[s.toolpathIndex].tool, fraction: 1)
            appliedSteps += 1
        }
        display = nil
        if appliedSteps < steps.count {
            let s = steps[appliedSteps]
            let f = s.duration > 0 ? (t - s.startTime) / s.duration : 0
            if f > 0 {
                var d = simulator
                d.apply(s.motion, from: s.start, tool: timeline.toolpaths[s.toolpathIndex].tool, fraction: f)
                display = d
            }
        }
        time = t
    }

    /// Runs the whole job (used for the final-result preview and tests).
    public mutating func runToEnd() { seek(to: timeline.duration) }

    public var toolState: (position: Vec3, toolpathIndex: Int)? { timeline.state(at: time) }
}
