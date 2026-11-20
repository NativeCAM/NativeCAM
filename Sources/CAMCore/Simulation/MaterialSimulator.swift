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

    /// A grid with every value given (a radial grid laid flat, say).
    public init(columns: Int, rows: Int, cellSize: Double, origin: Vec2, floorZ: Float, heights: [Float]) {
        self.columns = columns
        self.rows = rows
        self.cellSize = cellSize
        self.origin = origin
        self.floorZ = floorZ
        self.heights = heights
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
        /// On a rotary job, the blank's A angle during this step (degrees, as the post writes it); 0 on a flat job.
        /// For a move of a wrapped toolpath, the angle it starts at.
        public var angle: Double = 0
        /// For a move of a wrapped toolpath, the angle it ends at: the blank turns as the tool moves.
        public var endAngle: Double?
        /// Set on a step that turns the blank from one A angle to the next, with the tool waiting at safe Z over the
        /// next cut; its motion is a dwell there.
        public var turn: Turn?
    }

    /// A turn of the rotary axis between toolpaths, in degrees as the post writes them (so 270 to 0 turns back
    /// 270°, the way the controller does, not on by 90°).
    public struct Turn: Sendable, Equatable {
        public var from: Double
        public var to: Double
    }

    public let toolpaths: [Toolpath]
    public private(set) var steps: [Step] = []
    public let duration: Double
    /// True when the timeline turns the blank between toolpaths (a rotary job).
    public let turnsBlank: Bool

    /// `durations`, when given (e.g. `CycleTimeEstimate.motionSeconds`), sets each motion's playback time so the
    /// simulation runs at the machine's real pace; otherwise motions take distance ÷ feed.
    ///
    /// `turnSpeed` (degrees per second) makes it a rotary timeline: the blank starts at A0, turns to each
    /// toolpath's index angle before it cuts (with the tool over its start, as the post does), and turns back to
    /// A0 at the end. Turns take at least a quarter of a second.
    ///
    /// `wrap` (the sheet's Y at A0 and its radius) is for wrapped toolpaths: the blank turns to the angle of a wrapped
    /// toolpath's start before it, then with every move as the tool goes across the sheet.
    public init(toolpaths: [Toolpath], rapidRate: Double, durations: [[Double]]? = nil, turnSpeed: Double? = nil,
                wrap: (centerY: Double, radius: Double)? = nil) {
        self.toolpaths = toolpaths
        var t = 0.0
        var steps: [Step] = []
        var a = 0.0
        func turn(to angle: Double, toolpath i: Int, at p: Vec3) {
            guard let speed = turnSpeed, angle != a else { return }
            let d = max(0.25, abs(angle - a) / max(speed, 1))
            steps.append(Step(toolpathIndex: i, start: p, motion: Motion(kind: .dwell, end: p, feed: d), startTime: t, duration: d,
                              angle: angle, turn: Turn(from: a, to: angle)))
            t += d
            a = angle
        }
        for (i, tp) in toolpaths.enumerated() {
            let wrapped = tp.wrapDiameter != nil ? wrap : nil
            func angle(_ p: Vec3) -> Double { wrapped.map { (p.y - $0.centerY) / $0.radius * 180 / .pi } ?? 0 }
            turn(to: wrapped == nil ? tp.indexAngle ?? 0 : angle(tp.start), toolpath: i, at: tp.start)
            var k = 0
            tp.forEachMotion { s, m in
                var d = m.duration(from: s, rapidRate: rapidRate)
                if let dur = durations, i < dur.count, k < dur[i].count { d = dur[i][k] }
                k += 1
                var step = Step(toolpathIndex: i, start: s, motion: m, startTime: t, duration: d, angle: a)
                if wrapped != nil, m.kind != .dwell {
                    a = angle(m.end)
                    step.endAngle = a
                }
                steps.append(step)
                t += d
            }
        }
        if let last = toolpaths.indices.last { turn(to: 0, toolpath: last, at: toolpaths[last].motions.last?.end ?? toolpaths[last].start) }
        self.steps = steps
        duration = t
        turnsBlank = turnSpeed != nil
    }

    /// The blank's A angle at time `t` (degrees), part way through a turn when one is under way. nil on a flat job.
    public func blankAngle(at t: Double) -> Double? {
        guard turnsBlank else { return nil }
        guard let i = stepIndex(at: t) else { return 0 }
        let s = steps[i]
        let f = s.duration > 0 ? max(0, min(1, (t - s.startTime) / s.duration)) : 1
        if let end = s.endAngle { return s.angle + (end - s.angle) * f }
        guard let turn = s.turn else { return s.angle }
        return turn.from + (turn.to - turn.from) * f
    }

    /// The turn under way at time `t`, if the blank is turning then.
    public func turn(at t: Double) -> Step? {
        guard turnsBlank, let i = stepIndex(at: t), steps[i].turn != nil, t < steps[i].startTime + steps[i].duration else { return nil }
        return steps[i]
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
/// Completed moves are carved into the simulators; the move in progress is carved into a throw-away copy, so the
/// displayed material depends only on the play-head time, not on how the user scrubbed to it.
///
/// A flat job has one simulator. A rotary job has one per face (each distinct index angle), carved in that face's
/// frame: every indexed cut is a top-down cut into the face under the spindle, so each face's height grid is
/// exact, and the material left is the blank minus what every face removed. The face grids reach down to the far
/// side of the blank, so holes drilled past the axis show.
///
/// Wrapped toolpaths carve a radial grid instead (`radial`): the distance from the axis to the surface all the way
/// round, which is what a tool pointing at the axis can reach. A job with both keeps both, and the material left is
/// what all of them leave. A wrapped job has no faces.
public struct SimulationSession: Sendable {
    public let timeline: SimulationTimeline
    /// Material after every fully completed move, one simulator per face (`faceAngles`). Empty on a wrapped job.
    public private(set) var faces: [MaterialSimulator]
    /// Each face's index angle, normalized to 0 ≤ angle < 360 (degrees), in the order the job first cuts them.
    /// [0] on a flat job.
    public let faceAngles: [Double]
    /// Material the wrapped toolpaths leave, after every fully completed move; nil when the job has none.
    public private(set) var radial: RadialSimulator?
    /// The face each toolpath cuts, or -1 for a wrapped toolpath (the radial grid).
    private let faceOfToolpath: [Int]
    /// Committed material plus the partially completed current move (nil when the play head is on a step boundary).
    private var display: (face: Int, simulator: MaterialSimulator)?
    private var radialDisplay: RadialSimulator?
    public private(set) var time: Double = 0
    /// Steps fully applied to `faces`.
    private var appliedSteps = 0

    /// The pace the simulation turns a rotary blank at when the machine's turn speed isn't known, degrees per
    /// second. The run-time estimate assumes the same (`RotaryAxis.nominalTurnSpeed`).
    public static let turnSpeed = RotaryAxis.nominalTurnSpeed / 60

    /// `turnSpeed` is the rotary axis's own speed in degrees per minute (`RotaryAxis.drivenTurnSpeed`); nil turns
    /// the blank at the nominal pace.
    public init(toolpaths: [Toolpath], stock: Stock, rapidRate: Double, cellSize: Double? = nil, durations: [[Double]]? = nil,
                turnSpeed: Double? = nil) {
        let wrapped = toolpaths.contains { $0.wrapDiameter != nil }
        // A program read from a file onto a wrapped job's sheet has no wrapped toolpaths: it's shown flat on the sheet.
        guard let blank = stock.rotary, !blank.isWrapped || wrapped else {
            timeline = SimulationTimeline(toolpaths: toolpaths, rapidRate: rapidRate, durations: durations)
            faces = [MaterialSimulator(stock: stock, cellSize: cellSize)]
            faceAngles = [0]
            faceOfToolpath = toolpaths.map { _ in 0 }
            return
        }
        timeline = SimulationTimeline(toolpaths: toolpaths, rapidRate: rapidRate, durations: durations,
                                      turnSpeed: turnSpeed.map { $0 / 60 } ?? Self.turnSpeed,
                                      wrap: wrapped ? (stock.originPoint.y, blank.topRadius) : nil)
        var angles: [Double] = []
        var faceOf: [Int] = []
        for tp in toolpaths {
            guard tp.wrapDiameter == nil else { faceOf.append(-1); continue }
            let a = RotaryIndex.normalized(tp.indexAngle ?? 0)
            if let i = angles.firstIndex(of: a) { faceOf.append(i) } else { faceOf.append(angles.count); angles.append(a) }
        }
        if angles.isEmpty && !wrapped { angles = [0] }
        var faceStock = stock
        faceStock.thickness = blank.radius + blank.outerRadius
        // Share one flat job's cell budget between the faces.
        let cell = cellSize ?? max(0.2, (max(stock.width * stock.height, 1) * Double(max(angles.count, 1)) / 2_500_000).squareRoot())
        faces = angles.map { _ in MaterialSimulator(stock: faceStock, cellSize: cell) }
        faceAngles = angles
        faceOfToolpath = faceOf
        radial = wrapped ? RadialSimulator(stock: stock, cellSize: cellSize) : nil
    }

    /// The material wrapped toolpaths leave, as it looks at the play head.
    public var radialGrid: RadialGrid? { radialDisplay?.grid ?? radial?.grid }

    /// True when the toolpath at `index` is wrapped (it carves the radial grid, with the blank turning as it cuts).
    public func isWrapped(toolpath index: Int) -> Bool { faceOfToolpath[index] < 0 }

    /// Material on face `face` as it looks at the play head.
    public func grid(face: Int) -> HeightGrid {
        if let display, display.face == face { return display.simulator.grid }
        return faces[face].grid
    }

    /// Material as it looks at the play head: on a rotary job, the face being cut; on a wrapped job, the radial grid
    /// laid flat as the unrolled sheet.
    public var grid: HeightGrid {
        if let radialGrid, faces.isEmpty || toolState.map({ faceOfToolpath[$0.toolpathIndex] < 0 }) == true {
            return radialGrid.unrolled
        }
        return grid(face: toolState.map { max(0, faceOfToolpath[$0.toolpathIndex]) } ?? 0)
    }

    /// Rapid moves that hit material up to the play head.
    public var rapidCollisions: [Vec3] {
        faces.indices.flatMap { i in display?.face == i ? display!.simulator.rapidCollisions : faces[i].rapidCollisions }
            + ((radialDisplay ?? radial)?.rapidCollisions ?? [])
    }

    /// The blank's A angle at time `t` (degrees): part way through a turn, or with the tool on a wrapped toolpath.
    /// nil on a flat job.
    public func blankAngle(at t: Double) -> Double? { timeline.blankAngle(at: t) }

    /// The face the toolpath at `index` cuts.
    public func face(ofToolpath index: Int) -> Int { faceOfToolpath[index] }

    /// Moves the play head, carving forward incrementally or replaying from the start when going back.
    public mutating func seek(to tIn: Double) {
        let t = max(0, min(timeline.duration, tIn))
        if t < time {
            for i in faces.indices { faces[i].reset() }
            radial?.reset()
            appliedSteps = 0
        }
        let steps = timeline.steps
        while appliedSteps < steps.count, steps[appliedSteps].startTime + steps[appliedSteps].duration <= t {
            let s = steps[appliedSteps]
            let tool = timeline.toolpaths[s.toolpathIndex].tool
            let face = faceOfToolpath[s.toolpathIndex]
            if face < 0 { radial?.apply(s.motion, from: s.start, tool: tool, fraction: 1) } else { faces[face].apply(s.motion, from: s.start, tool: tool, fraction: 1) }
            appliedSteps += 1
        }
        display = nil
        radialDisplay = nil
        if appliedSteps < steps.count {
            let s = steps[appliedSteps]
            let f = s.duration > 0 ? (t - s.startTime) / s.duration : 0
            if f > 0 {
                let tool = timeline.toolpaths[s.toolpathIndex].tool
                let face = faceOfToolpath[s.toolpathIndex]
                if face < 0, var d = radial {
                    d.apply(s.motion, from: s.start, tool: tool, fraction: f)
                    radialDisplay = d
                } else if face >= 0 {
                    var d = faces[face]
                    d.apply(s.motion, from: s.start, tool: tool, fraction: f)
                    display = (face, d)
                }
            }
        }
        time = t
    }

    /// Runs the whole job (used for the final-result preview and tests).
    public mutating func runToEnd() { seek(to: timeline.duration) }

    public var toolState: (position: Vec3, toolpathIndex: Int)? { timeline.state(at: time) }
}
