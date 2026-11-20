import AppKit
import CAMCore
import Foundation
import Observation
import simd

/// Sidebar / selection identity.
enum SidebarItem: Hashable {
    case setup
    case shape(UUID)
    case operation(UUID)
}

/// Per-window state that isn't saved in the document: generated toolpaths, selection, simulation playback.
@MainActor
@Observable
final class Workspace {
    // Generated output
    private(set) var job: JobResult?
    private(set) var isGenerating = false
    private var generationTask: Task<Void, Never>?
    private var generationCounter = 0

    // Selection and view
    var selection: Set<SidebarItem> = [.setup]
    var viewPreset: ViewPreset? = .iso
    var fitRequest = 0
    var showVectors = true
    var showToolpaths = true
    var showRapids = true
    /// Toolpath lines over the simulated material hide the result, so they're off while simulating by default.
    var showToolpathsWhileSimulating = false

    // Simulation
    private(set) var session: SimulationSession?
    /// Set when simulating an external G-code file instead of the project's toolpaths.
    private(set) var externalProgramName: String?
    private(set) var simTime: Double = 0
    var isPlaying = false { didSet { isPlaying ? startPlayback() : stopPlayback() } }
    /// Multiple of real time.
    var playbackSpeed: Double = 20
    private(set) var heightField: HeightFieldSnapshot?
    private var heightVersion = 0
    private var playTask: Task<Void, Never>?
    /// While simulating a rotary job: the world Y and Z of the blank's axis, and its A angle at the play head.
    private(set) var rotaryAxis: SIMD2<Float>?
    private(set) var simAngle: Double = 0
    /// When each of the timeline's turns of the blank starts, so playback never skips one.
    private var turnStarts: [Double] = []

    // 3D model preview (the models carved into the stock, shown when not simulating)
    private(set) var modelPreview: HeightFieldSnapshot?
    var showModelPreview = true

    // Scene geometry cache
    private(set) var lines: [LineVertex] = []
    private(set) var geometryVersion = 0

    var isSimulating: Bool { session != nil }

    var selectedShapeIDs: [UUID] {
        selection.compactMap { if case let .shape(id) = $0 { id } else { nil } }
    }

    var selectedOperationID: UUID? {
        for item in selection { if case let .operation(id) = item { return id } }
        return nil
    }

    // MARK: Toolpath generation

    /// Regenerates toolpaths in the background, debounced so typing in a field doesn't thrash.
    func regenerate(_ project: Project, debounce: Bool = true) {
        generationTask?.cancel()
        generationCounter += 1
        let token = generationCounter
        isGenerating = true
        generationTask = Task { [weak self] in
            if debounce { try? await Task.sleep(for: .milliseconds(250)) }
            guard !Task.isCancelled else { return }
            let (result, preview) = await Task.detached(priority: .userInitiated) {
                (CAMEngine.generate(project), Workspace.previewSurface(project))
            }.value
            guard !Task.isCancelled, let self, token == self.generationCounter else { return }
            self.job = result
            self.publishPreview(preview, project: project)
            self.isGenerating = false
            self.rebuildLines(project)
            if self.session != nil && self.externalProgramName == nil {
                // Keep a running simulation in sync with edited toolpaths.
                self.startSimulation(project)
            }
        }
    }

    /// Top surface of all models over the stock (nil when the project has no 3D models).
    nonisolated static func previewSurface(_ project: Project) -> SurfaceGrid? {
        let models = project.shapes.filter { $0.modelSpec != nil }
        guard !models.isEmpty else { return nil }
        let area = project.stock.bounds
        let cell = ModelRaster.cellSize(for: area, preferred: max(project.stock.width, project.stock.height) / 1200, maxCells: 1_500_000)
        return ModelRaster.surface(of: models, over: area, cellSize: cell)
    }

    private func publishPreview(_ g: SurfaceGrid?, project: Project) {
        guard let g else { modelPreview = nil; return }
        let floor = Float(-project.stock.thickness)
        var heights = [Float](repeating: 0, count: g.heights.count)
        for i in heights.indices where g.covered[i] { heights[i] = max(min(0, g.heights[i]), floor) }
        heightVersion += 1
        modelPreview = HeightFieldSnapshot(columns: g.columns, rows: g.rows, cellSize: Float(g.cellSize),
                                           origin: SIMD2(Float(g.origin.x), Float(g.origin.y)), heights: heights,
                                           floorZ: floor, version: heightVersion)
    }

    func estimatedSeconds(_ project: Project) -> Double { job?.estimatedSeconds ?? 0 }

    // MARK: Simulation

    func startSimulation(_ project: Project) {
        guard let job else { return }
        externalProgramName = nil
        beginSession(SimulationSession(toolpaths: job.toolpaths, stock: project.stock,
                                       rapidRate: project.machine.rapidRateForEstimates, cellSize: nil,
                                       durations: job.estimate?.motionSeconds,
                                       turnSpeed: project.machine.rotary?.drivenTurnSpeed), project: project)
    }

    func simulateProgram(_ toolpaths: [Toolpath], name: String, project: Project) {
        externalProgramName = name
        beginSession(SimulationSession(toolpaths: toolpaths, stock: project.stock,
                                       rapidRate: project.machine.rapidRateForEstimates, cellSize: nil,
                                       turnSpeed: project.machine.rotary?.drivenTurnSpeed), project: project)
    }

    private func beginSession(_ s: SimulationSession, project: Project) {
        isPlaying = false
        session = s
        simTime = 0
        simAngle = 0
        // A wrapped job simulates on its unrolled sheet for now, drawn flat.
        rotaryAxis = project.stock.rotary.flatMap { $0.isWrapped ? nil : SIMD2(Float(project.stock.height / 2), Float(-$0.radius)) }
        turnStarts = s.timeline.steps.filter { $0.turn != nil }.map(\.startTime)
        publishHeights()
        rebuildLines(project)
        isPlaying = true
    }

    func stopSimulation(_ project: Project) {
        isPlaying = false
        session = nil
        externalProgramName = nil
        heightField = nil
        simTime = 0
        simAngle = 0
        rotaryAxis = nil
        turnStarts = []
        rebuildLines(project)
    }

    func seek(to t: Double) {
        guard session != nil else { return }
        session!.seek(to: t)
        simTime = session!.time
        publishHeights()
        let angle = session!.timeline.blankAngle(at: simTime) ?? 0
        if angle != simAngle {
            simAngle = angle
            if !rotaryPathLines.isEmpty { publishLines() }
        }
    }

    func jumpToEnd() {
        guard let s = session else { return }
        isPlaying = false
        seek(to: s.timeline.duration)
    }

    var simDuration: Double { session?.timeline.duration ?? 0 }

    var rapidCollisionCount: Int { session?.rapidCollisions.count ?? 0 }

    /// Tool tip position, silhouette and the toolpath being cut right now.
    var simTool: (marker: ToolMarker, toolpathName: String)? {
        guard let s = session, let state = s.toolState else { return nil }
        let tp = s.timeline.toolpaths[state.toolpathIndex]
        let sil = tp.tool.silhouette().map { SIMD2<Float>(Float($0.x), Float($0.y)) }
        let p = state.position
        let name = s.timeline.turn(at: s.time)?.turn.map { "Turning the blank to \(RotaryIndex.label($0.to))" } ?? tp.name
        return (ToolMarker(tip: SIMD3(Float(p.x), Float(p.y), Float(p.z)), silhouette: sil), name)
    }

    private func publishHeights() {
        guard let s = session else { heightField = nil; return }
        let g = s.grid
        heightVersion += 1
        // A rotary job's faces go one after another, in `faceAngles` order.
        let faces = rotaryAxis == nil ? 1 : s.faces.count
        let heights = faces == 1 ? g.heights : (0..<faces).flatMap { s.grid(face: $0).heights }
        heightField = HeightFieldSnapshot(columns: g.columns, rows: g.rows, cellSize: Float(g.cellSize),
                                          origin: SIMD2(Float(g.origin.x), Float(g.origin.y)),
                                          heights: heights, floorZ: g.floorZ, version: heightVersion, layers: faces)
    }

    private func startPlayback() {
        playTask?.cancel()
        playTask = Task { [weak self] in
            var last = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                guard let self, self.isPlaying, self.session != nil else { return }
                let now = Date()
                let dt = now.timeIntervalSince(last)
                last = now
                // Slow down for a turn of a rotary blank so it can be seen at any speed, and never skip one.
                var speed = self.playbackSpeed
                if let turn = self.session?.timeline.turn(at: self.simTime) { speed = min(speed, max(1, turn.duration / 0.6)) }
                var target = min(self.simDuration, self.simTime + dt * speed)
                if let next = self.turnStarts.first(where: { $0 > self.simTime }), next < target { target = next + 1e-6 }
                self.seek(to: target)
                if target >= self.simDuration { self.isPlaying = false }
            }
        }
    }

    private func stopPlayback() {
        playTask?.cancel()
        playTask = nil
    }

    // MARK: Scene

    func viewportScene(_ project: Project) -> ViewportScene {
        var scene = ViewportScene()
        scene.stockSize = SIMD3(Float(project.stock.width), Float(project.stock.height), Float(project.stock.thickness))
        scene.machineTravel = SIMD2(Float(project.machine.travel.x), Float(project.machine.travel.y))
        scene.gridSpacing = project.displayUnits == .inch ? 25.4 : 10
        scene.lines = lines
        scene.geometryVersion = geometryVersion
        scene.heightField = heightField ?? (showModelPreview ? modelPreview : nil)
        scene.tool = simTool?.marker
        scene.showStock = true
        if let session, heightField != nil, let blank = project.stock.rotary, let axis = rotaryAxis {
            scene.rotary = RotaryBlankView(square: blank.shape == .squareBar, radius: Float(blank.radius), length: Float(blank.length),
                                           axis: axis, angle: Float(simAngle), faceAngles: session.faceAngles.map { Float($0) })
            // The spoilboard is the rotary's centre height below the axis (a guess until that's measured).
            let below = project.machine.rotary?.centerHeight ?? blank.outerRadius + 0.5.inch
            scene.stockSize.z = Float(blank.radius + below)
        }
        return scene
    }

    static let palette: [SIMD4<Float>] = [
        SIMD4(0.30, 0.62, 1.00, 1), SIMD4(0.35, 0.85, 0.45, 1), SIMD4(1.00, 0.62, 0.20, 1),
        SIMD4(0.75, 0.45, 1.00, 1), SIMD4(0.20, 0.85, 0.85, 1), SIMD4(1.00, 0.45, 0.70, 1),
    ]

    func colorForOperation(_ index: Int) -> SIMD4<Float> { Workspace.palette[index % Workspace.palette.count] }

    // MARK: Shape geometry (cached: text outlines come from CoreText and are not free)

    private var outlineCache: [UUID: (shape: DesignShape, outlines: [Polyline])] = [:]

    func outlines(_ shape: DesignShape) -> [Polyline] {
        if let c = outlineCache[shape.id], c.shape == shape { return c.outlines }
        let o = shape.polylines(tolerance: 0.05)
        outlineCache[shape.id] = (shape, o)
        return o
    }

    /// Topmost shape whose outline is within `tolerance` of `p`. Like outline-mode drawing apps (and Vectric),
    /// vectors are picked by their lines, so a big outer boundary doesn't swallow clicks inside the board;
    /// text is the exception, since clicking inside a letter is the natural way to grab it.
    func hitTest(_ p: Vec2, tolerance: Double, project: Project) -> UUID? {
        var bestInside: (id: UUID, area: Double)?
        for shape in project.shapes.reversed() {
            let polys = outlines(shape)
            let b = polys.bounds
            guard b.insetBy(-tolerance).contains(p) else { continue }
            for poly in polys where poly.closestPoint(to: p).distance <= tolerance { return shape.id }
            if case .text = shape.kind, polys.contains(where: { $0.isClosed && $0.contains(p) }) {
                let area = b.width * b.height
                if area < (bestInside?.area ?? .infinity) { bestInside = (shape.id, area) }
            }
        }
        return bestInside?.id
    }

    // MARK: Corner relief marks (the selected profile or pocket's corners, changed by clicking them)

    /// The selected toolpath's relief corners and its bit radius, when it has corner reliefs.
    func selectedReliefCorners(_ project: Project) -> (operation: UUID, corners: [ReliefCorner], radius: Double)? {
        guard let id = selectedOperationID, let op = project.operations.first(where: { $0.id == id }) else { return nil }
        switch op.kind {
        case let .profile(p) where p.cornerRelief != nil && p.side != .on: break
        case let .pocket(p) where p.cornerRelief != nil: break
        default: return nil
        }
        guard let tp = job?.toolpaths.first(where: { $0.sourceOperationID == id }), let corners = tp.reliefCorners, !corners.isEmpty else {
            return nil
        }
        return (id, corners, tp.tool.radius)
    }

    /// The selected toolpath's corner under `p`: on its relief circle or at the corner itself.
    func cornerHit(_ p: Vec2, tolerance: Double, project: Project) -> (operation: UUID, corner: ReliefCorner)? {
        guard let marks = selectedReliefCorners(project) else { return nil }
        var best: (ReliefCorner, Double)?
        for corner in marks.corners {
            var d = corner.point.distance(to: p)
            if let tip = corner.tip { d = min(d, max(0, tip.distance(to: p) - marks.radius)) }
            if d <= tolerance * 1.5, d < (best?.1 ?? .infinity) { best = (corner, d) }
        }
        return best.map { (marks.operation, $0.0) }
    }

    /// Line geometry for the selected toolpath's corner marks: the relief's circle (the bit at its tip, exactly where
    /// the notch is cut), a cross where a corner is left as cut, an orange cross where the relief is blocked.
    private func reliefMarkLines(_ project: Project) -> [LineVertex] {
        guard !isSimulating, let marks = selectedReliefCorners(project) else { return [] }
        var v: [LineVertex] = []
        let z: Float = 0.06
        let changed = Workspace.accent, standard = SIMD4<Float>(0.6, 0.9, 1, 1), warning = SIMD4<Float>(1, 0.6, 0.2, 1)
        func line(_ a: Vec2, _ b: Vec2, _ c: SIMD4<Float>) {
            v.append(LineVertex(SIMD3(Float(a.x), Float(a.y), z), c))
            v.append(LineVertex(SIMD3(Float(b.x), Float(b.y), z), c))
        }
        let r = marks.radius
        for corner in marks.corners {
            let color = corner.blocked ? warning : (corner.isChanged ? changed : standard)
            if let tip = corner.tip {
                let n = 40
                for k in 0..<n {
                    line(tip + Vec2.fromAngle(2 * .pi * Double(k) / Double(n), length: r),
                         tip + Vec2.fromAngle(2 * .pi * Double(k + 1) / Double(n), length: r), color)
                }
            } else {
                let s = max(0.4 * r, 0.5)
                line(corner.point + Vec2(-s, -s), corner.point + Vec2(s, s), color)
                line(corner.point + Vec2(-s, s), corner.point + Vec2(s, -s), color)
            }
        }
        return v
    }

    // MARK: Canvas drag preview (committed to the document once, on mouse-up, so it's a single undo step)

    private(set) var dragOffset: Vec2?
    private(set) var dragShapeIDs: Set<UUID> = []

    func setDragPreview(_ ids: Set<UUID>, offset: Vec2?, project: Project) {
        dragShapeIDs = offset == nil ? [] : ids
        dragOffset = offset
        rebuildVectorLines(project)
    }

    // MARK: Line geometry

    private var vectorLines: [LineVertex] = []
    private var pathLines: [LineVertex] = []
    /// While simulating a rotary job: each toolpath's lines with its index angle, turned with the blank when
    /// they're published.
    private var rotaryPathLines: [(angle: Double, lines: [LineVertex])] = []

    /// The system accent colour (selection highlight), like every other Mac app.
    static var accent: SIMD4<Float> {
        let c = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
        return SIMD4(Float(c.redComponent), Float(c.greenComponent), Float(c.blueComponent), 1)
    }

    /// Rebuilds line geometry for vectors and toolpaths.
    func rebuildLines(_ project: Project) {
        rebuildPathLines(project)
        rebuildVectorLines(project)
    }

    func rebuildVectorLines(_ project: Project) {
        var v: [LineVertex] = []
        let selected = Set(selectedShapeIDs)
        let opShapes: Set<UUID> = {
            guard let id = selectedOperationID, let op = project.operations.first(where: { $0.id == id }) else { return [] }
            return Set(op.shapeIDs)
        }()
        let dimmed = isSimulating
        // A rotary job's vectors are drawn on the flat design sheet, which the turning blank doesn't show.
        if showVectors && rotaryAxis == nil {
            let accent = Workspace.accent
            for shape in project.shapes {
                let isSel = selected.contains(shape.id)
                let isOp = opShapes.contains(shape.id)
                let normal: SIMD4<Float> = shape.isKeepOut ? SIMD4(1, 0.35, 0.3, dimmed ? 0.4 : 0.95) : SIMD4(0.92, 0.92, 0.95, dimmed ? 0.35 : 0.9)
                let color: SIMD4<Float> = isSel ? accent : (isOp ? SIMD4(0.6, 0.9, 1, 1) : normal)
                let offset = dragShapeIDs.contains(shape.id) ? (dragOffset ?? .zero) : .zero
                let z: Float = 0.05
                for poly in outlines(shape) {
                    for i in 0..<poly.segmentCount {
                        let (a, b) = poly.segment(i)
                        v.append(LineVertex(SIMD3(Float(a.x + offset.x), Float(a.y + offset.y), z), color))
                        v.append(LineVertex(SIMD3(Float(b.x + offset.x), Float(b.y + offset.y), z), color))
                    }
                }
            }
        }
        v += reliefMarkLines(project)
        vectorLines = v
        publishLines()
    }

    func rebuildPathLines(_ project: Project) {
        var v: [LineVertex] = []
        var turned: [(angle: Double, lines: [LineVertex])] = []
        let dimmed = isSimulating
        let toolpaths = session?.timeline.toolpaths ?? job?.toolpaths ?? []
        if showToolpaths && (!isSimulating || showToolpathsWhileSimulating) {
            let opIndex = Dictionary(uniqueKeysWithValues: project.operations.enumerated().map { ($1.id, $0) })
            for (i, tp) in toolpaths.enumerated() {
                var color = colorForOperation(opIndex[tp.sourceOperationID] ?? i)
                let highlight = selectedOperationID == tp.sourceOperationID
                if dimmed { color.w = 0.35 } else if !highlight && selectedOperationID != nil { color.w = 0.45 }
                let rapid = SIMD4<Float>(1, 0.3, 0.3, dimmed ? 0.2 : 0.55)
                let first = v.count
                tp.forEachMotion { s, m in
                    guard m.kind != .dwell else { return }
                    if m.kind == .rapid && !showRapids { return }
                    let c = m.kind == .rapid ? rapid : color
                    var p = s
                    for q in m.samples(from: s, maxStep: 0.5) {
                        v.append(LineVertex(SIMD3(Float(p.x), Float(p.y), Float(p.z)), c))
                        v.append(LineVertex(SIMD3(Float(q.x), Float(q.y), Float(q.z)), c))
                        p = q
                    }
                }
                if rotaryAxis != nil, v.count > first {
                    // Each toolpath is in its face's frame: keep it apart so it can turn with the blank.
                    turned.append((tp.indexAngle ?? 0, Array(v[first...])))
                    v.removeSubrange(first...)
                }
            }
        }
        rotaryPathLines = turned
        pathLines = v
        publishLines()
    }

    private func publishLines() {
        var turned: [LineVertex] = []
        if let axis = rotaryAxis {
            for group in rotaryPathLines {
                let a = Float((simAngle - group.angle) * .pi / 180), c = cos(a), s = sin(a)
                for v in group.lines {
                    let y = v.position.y - axis.x, z = v.position.z - axis.y
                    turned.append(LineVertex(SIMD3(v.position.x, axis.x + y * c - z * s, axis.y + y * s + z * c), v.color))
                }
            }
        }
        lines = pathLines + turned + vectorLines
        geometryVersion += 1
    }
}
