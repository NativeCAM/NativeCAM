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
    /// On a job nested onto several sheets, the sheet the canvas and the simulation show (from 0).
    private(set) var sheet = 0
    /// Add Toolpath ▸ Inlay…, waiting in its sheet (any of the add-toolpath menus can ask for it).
    var inlayRequest: InlayRequest?
    /// File ▸ Export Restart… or Restart Here…: the restart sheet, preset to a point.
    var restartPreset: RestartPreset?
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
    /// While simulating wrapped toolpaths: what they've cut, all the way round the blank.
    private(set) var radialField: RadialSnapshot?
    /// While simulating a job with wrapped toolpaths: the sheet's Y at A0 and its radius, for putting the tool over
    /// the axis and wrapping the toolpaths round the blank.
    private var wrapFrame: (centerY: Double, radius: Double)?
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
    /// On a rotary job: the blank with its models on it, shown when not simulating.
    private(set) var rotaryModelPreview: RadialSnapshot?
    /// While the rotary preview is shown: the sheet's Y at A0, its radius and the world Y and Z of the axis, for
    /// drawing wrapped toolpaths round the blank at A0.
    private var previewFrame: (centerY: Double, radius: Double, axis: SIMD2<Float>)?

    // Scene geometry cache
    private(set) var lines: [LineVertex] = []
    private(set) var geometryVersion = 0

    var isSimulating: Bool { session != nil }

    // MARK: Sheets

    /// The project as the canvas shows it: on a job of several sheets, the sheet shown, its material and its shapes
    /// (and the clamps, which are on every sheet). The operations stay the whole job's.
    func shown(_ project: Project) -> Project {
        guard project.sheetCount > 1 else { return project }
        var p = project
        let k = min(sheet, project.sheetCount - 1)
        p.stock = project.stock(forSheet: k)
        p.shapes = project.shapes(onSheet: k)
        return p
    }

    /// Whether a shape is on the sheet shown.
    func isShown(_ shape: DesignShape, in project: Project) -> Bool {
        shape.isKeepOut || project.sheetIndex(of: shape) == min(sheet, project.sheetCount - 1)
    }

    /// The job as the canvas and the simulation show it: the sheet shown's, on a job of several sheets.
    var shownJob: JobResult? {
        guard let job, let sheets = job.sheets, !sheets.isEmpty else { return job }
        return sheets[min(sheet, sheets.count - 1)].job
    }

    /// A new shape goes on the sheet shown.
    func placedOnSheet(_ shape: DesignShape, of project: Project) -> DesignShape {
        var s = shape
        let k = min(sheet, project.sheetCount - 1)
        s.sheet = k > 0 ? k : nil
        return s
    }

    /// Shows another sheet; a running simulation starts again on it.
    func show(sheet k: Int, project: Project) {
        let k = max(0, min(k, project.sheetCount - 1))
        guard k != sheet else { return }
        let sizeChanged = !project.sheetSize(k).isApprox(project.sheetSize(sheet), tolerance: 1e-6)
        sheet = k
        if session != nil && externalProgramName == nil {
            startSimulation(project)
        } else {
            rebuildLines(project)
        }
        if sizeChanged { fitRequest += 1 }
    }

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
            let view = self?.shown(project) ?? project
            let (result, preview, radial) = await Task.detached(priority: .userInitiated) {
                (CAMEngine.generate(project), Workspace.previewSurface(view), RotaryModelPreview.surface(project))
            }.value
            guard !Task.isCancelled, let self, token == self.generationCounter else { return }
            self.job = result
            if self.sheet >= project.sheetCount { self.sheet = project.sheetCount - 1 }
            self.publishPreview(preview, project: project)
            self.publishRotaryPreview(radial, project: project)
            self.isGenerating = false
            self.rebuildLines(project)
            if self.session != nil && self.externalProgramName == nil {
                // Keep a running simulation in sync with edited toolpaths.
                self.startSimulation(project)
            }
        }
    }

    /// Top surface of all models over the stock (nil when the project has no 3D models). Models on a rotary blank are
    /// shown on it instead (`RotaryModelPreview`).
    /// Mouldings' swept surfaces are shown the same way, as a shaded band along their rails.
    nonisolated static func previewSurface(_ project: Project) -> SurfaceGrid? {
        let models = project.shapes.filter { $0.modelSpec != nil && (project.stock.rotary == nil || $0.modelSpec?.rotary == nil) }
            + (project.stock.rotary == nil ? project.mouldingSurfaces : [])
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

    private func publishRotaryPreview(_ g: RadialGrid?, project: Project) {
        guard let g, let blank = project.stock.rotary else {
            rotaryModelPreview = nil
            previewFrame = nil
            return
        }
        heightVersion += 1
        rotaryModelPreview = RadialSnapshot(columns: g.columns, rows: g.rows, cellSize: Float(g.cellSize), originX: Float(g.originX),
                                            radii: g.radii, version: heightVersion)
        previewFrame = (project.stock.originPoint.y, blank.topRadius, SIMD2(Float(project.stock.height / 2), Float(-blank.topRadius)))
        rebuildPathLines(project)
    }

    func estimatedSeconds(_ project: Project) -> Double { job?.estimatedSeconds ?? 0 }

    // MARK: Simulation

    func startSimulation(_ project: Project) {
        let project = shown(project)
        guard let job = shownJob else { return }
        externalProgramName = nil
        beginSession(SimulationSession(toolpaths: job.toolpaths, stock: project.stock,
                                       rapidRate: project.machine.rapidRateForEstimates, cellSize: nil,
                                       estimate: job.estimate,
                                       turnSpeed: project.machine.rotary?.drivenTurnSpeed), project: project)
    }

    func simulateProgram(_ toolpaths: [Toolpath], name: String, project: Project) {
        let project = shown(project)
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
        // The blank's axis is under the middle of the sheet, its top (or the wrap diameter) at the sheet's Z = 0. A
        // program read from a file onto a wrapped job's sheet is drawn flat.
        let rotary = project.stock.rotary.flatMap { s.radial != nil || !$0.isWrapped ? $0 : nil }
        rotaryAxis = rotary.map { SIMD2(Float(project.stock.height / 2), Float(-$0.topRadius)) }
        wrapFrame = s.radial != nil ? rotary.map { (project.stock.originPoint.y, $0.topRadius) } : nil
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
        radialField = nil
        wrapFrame = nil
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
        let angle = session!.blankAngle(at: simTime) ?? 0
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

    /// While simulating a tiled job: how many tiles it has (nil otherwise).
    var tileCount: Int? {
        guard let s = session, externalProgramName == nil, s.timeline.toolpaths.contains(where: { $0.tile != nil }) else { return nil }
        return (s.timeline.toolpaths.compactMap(\.tile).max() ?? 0) + 1
    }

    /// When each tile starts in the simulation, to step through them.
    var tileStartTimes: [Double] {
        guard let s = session, let count = tileCount else { return [] }
        return (0..<count).map { k in
            s.timeline.steps.first { s.timeline.toolpaths[$0.toolpathIndex].tile == k }?.startTime ?? s.timeline.duration
        }
    }

    /// Shows the simulation at the start of a tile (`count` shows the end, every tile cut).
    func seek(toTile index: Int) {
        let starts = tileStartTimes
        isPlaying = false
        seek(to: index < starts.count ? starts[index] : simDuration)
    }

    var rapidCollisionCount: Int { session?.rapidCollisions.count ?? 0 }

    /// Tool tip position, silhouette and the toolpath being cut right now.
    var simTool: (marker: ToolMarker, toolpathName: String)? {
        guard let s = session, let state = s.toolState else { return nil }
        let tp = s.timeline.toolpaths[state.toolpathIndex]
        let sil = tp.tool.silhouette().map { SIMD2<Float>(Float($0.x), Float($0.y)) }
        var p = state.position
        // On a wrapped toolpath the tool stays over the axis while the blank turns under it.
        if let wrap = wrapFrame, s.isWrapped(toolpath: state.toolpathIndex) { p.y = wrap.centerY }
        var name = s.timeline.turn(at: s.time)?.turn.map { "Turning the blank to \(RotaryIndex.label($0.to))" } ?? tp.name
        if let tile = tp.tile, let count = tileCount { name = "Tile \(tile + 1) of \(count) · " + name }
        return (ToolMarker(tip: SIMD3(Float(p.x), Float(p.y), Float(p.z)), silhouette: sil), name)
    }

    private func publishHeights() {
        guard let s = session else { heightField = nil; radialField = nil; return }
        heightVersion += 1
        if rotaryAxis != nil, let rg = s.radialGrid {
            radialField = RadialSnapshot(columns: rg.columns, rows: rg.rows, cellSize: Float(rg.cellSize), originX: Float(rg.originX),
                                         radii: rg.radii, version: heightVersion)
        } else {
            radialField = nil
        }
        // A wrapped job has no faces: the radial grid is all there is.
        if rotaryAxis != nil && s.faces.isEmpty { heightField = nil; return }
        let g = rotaryAxis == nil ? s.grid : s.grid(face: 0)
        // A rotary job's faces go one after another, in `faceAngles` order.
        let faces = rotaryAxis == nil ? 1 : s.faces.count
        let heights = faces == 1 && rotaryAxis == nil ? g.heights : (0..<faces).flatMap { s.grid(face: $0).heights }
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
        let project = shown(project)
        var scene = ViewportScene()
        scene.stockSize = SIMD3(Float(project.stock.width), Float(project.stock.height), Float(project.stock.thickness))
        scene.machineTravel = SIMD2(Float(project.machine.travel.x), Float(project.machine.travel.y))
        scene.gridSpacing = project.displayUnits == .inch ? 25.4 : 10
        // The 3D view is in the blank's frame; on a rotary axis along Y the machine is that turned a quarter turn.
        scene.turned = RotaryFrame(project).alignment == .y
        scene.lines = lines
        scene.geometryVersion = geometryVersion
        scene.heightField = heightField ?? (showModelPreview ? modelPreview : nil)
        scene.tool = simTool?.marker
        scene.showStock = true
        if let session, heightField != nil || radialField != nil, let blank = project.stock.rotary, let axis = rotaryAxis {
            scene.rotary = RotaryBlankView(square: blank.shape == .squareBar, radius: Float(blank.radius), length: Float(blank.length),
                                           axis: axis, angle: Float(simAngle), faceAngles: session.faceAngles.map { Float($0) },
                                           radial: radialField)
            // The spoilboard is the rotary's centre height below the axis (a guess until that's measured).
            let below = project.machine.rotary?.centerHeight ?? blank.outerRadius + 0.5.inch
            scene.stockSize.z = Float(blank.radius + below)
        } else if session == nil, showModelPreview, let preview = rotaryModelPreview, let blank = project.stock.rotary, let frame = previewFrame {
            // The model on the blank, at A0.
            scene.heightField = nil
            scene.rotary = RotaryBlankView(square: blank.shape == .squareBar, radius: Float(blank.radius), length: Float(blank.length),
                                           axis: frame.axis, angle: 0, faceAngles: [], radial: preview)
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
        for shape in shown(project).shapes.reversed() {
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
        // A rest-machined pocket's clearing comes first and has no reliefs: they're on the operation's own toolpath.
        guard let tp = shownJob?.toolpaths.first(where: { $0.sourceOperationID == id && $0.reliefCorners != nil }),
              let corners = tp.reliefCorners, !corners.isEmpty else {
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
    /// the notch is cut), a cross where a corner is left as cut, an orange cross where the relief is left off because
    /// it would cut into nearby geometry or another toolpath's part, and an orange circle where it's cut into another
    /// toolpath's part anyway.
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
            let color = corner.isFlagged ? warning : (corner.isChanged ? changed : standard)
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

    // MARK: Rest areas (the selected rest toolpath's)

    /// The selected toolpath's rest areas: where a 3D rest pass's bit goes, or what a pocket resting from earlier
    /// toolpaths has left to clear. nil when it isn't a rest toolpath or nothing's been generated.
    func selectedRestAreas(_ project: Project) -> [Polyline]? {
        guard let id = selectedOperationID else { return nil }
        return job?.toolpaths.last { $0.sourceOperationID == id && $0.restAreas != nil }?.restAreas
    }

    /// Line geometry shading the selected toolpath's rest areas in a deep amber that stands out against a shaded model
    /// (#108): each outline drawn as a band of parallel lines, so it reads as a thick edge, and cross-hatching inside.
    private func restAreaLines(_ project: Project) -> [LineVertex] {
        guard !isSimulating, rotaryAxis == nil, let loops = selectedRestAreas(project), !loops.isEmpty else { return [] }
        var v: [LineVertex] = []
        let z: Float = 0.055
        let edge = SIMD4<Float>(1, 0.55, 0.05, 1), hatch = SIMD4<Float>(1, 0.6, 0.1, 0.8)
        func line(_ a: Vec2, _ b: Vec2, _ c: SIMD4<Float>) {
            v.append(LineVertex(SIMD3(Float(a.x), Float(a.y), z), c))
            v.append(LineVertex(SIMD3(Float(b.x), Float(b.y), z), c))
        }
        func outline(_ loop: Polyline, _ c: SIMD4<Float>) {
            for i in 0..<loop.segmentCount {
                let (a, b) = loop.segment(i)
                line(a, b, c)
            }
        }
        let diagonal = hypot(project.stock.width, project.stock.height)
        // The edge: each outline and a line either side of it, a small step apart on the material.
        let step = max(0.05, diagonal / 2000)
        for loop in loops {
            outline(loop, edge)
            for d in [step, 2 * step] {
                for band in Clipper.offset([loop], delta: d, end: .joined) { outline(band, edge) }
            }
        }
        // Cross-hatching a fixed distance apart on the material, at least 125 lines each way across the stock's diagonal.
        let bounds = loops.bounds
        let gap = max(0.3, min(1.6, diagonal / 125))
        var raw: [Polyline] = []
        var t = -bounds.height
        while t <= bounds.width {
            raw.append(Polyline([Vec2(bounds.min.x + t, bounds.min.y), Vec2(bounds.min.x + t + bounds.height, bounds.max.y)], closed: false))
            raw.append(Polyline([Vec2(bounds.min.x + t, bounds.max.y), Vec2(bounds.min.x + t + bounds.height, bounds.min.y)], closed: false))
            t += gap * 2.squareRoot()
        }
        for piece in Clipper.clipOpen(raw, to: loops, fill: .evenOdd) {
            guard let a = piece.points.first, let b = piece.points.last else { continue }
            line(a, b, hatch)
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
        let project = shown(project)
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
        v += restAreaLines(project)
        v += wrapGuideLines(project)
        v += tileLines(project)
        vectorLines = v
        publishLines()
    }

    /// On a tiled job: the tile lines in yellow, the overlap either side of each hatched in red (Vectric's colours), and
    /// the registration holes: open circles where they're drilled, the spoilboard pair in front of the material too.
    private func tileLines(_ project: Project) -> [LineVertex] {
        guard showVectors, rotaryAxis == nil, let layout = TileLayout(project) else { return [] }
        let s = project.stock, o = layout.overlap
        let alpha: Float = isSimulating ? 0.35 : 0.9
        let seam = SIMD4<Float>(1, 0.82, 0.15, alpha), band = SIMD4<Float>(1, 0.3, 0.25, alpha * 0.7)
        var v: [LineVertex] = []
        let z: Float = 0.045
        func line(_ a: Vec2, _ b: Vec2, _ c: SIMD4<Float>) {
            v.append(LineVertex(SIMD3(Float(a.x), Float(a.y), z), c))
            v.append(LineVertex(SIMD3(Float(b.x), Float(b.y), z), c))
        }
        // A band from `lo` to `hi` across the material: its edges and 45° hatching.
        func hatch(_ r: Rect2) {
            line(r.min, Vec2(r.max.x, r.min.y), band)
            line(Vec2(r.min.x, r.max.y), r.max, band)
            line(r.min, Vec2(r.min.x, r.max.y), band)
            line(Vec2(r.max.x, r.min.y), r.max, band)
            let gap = max(r.width, r.height) / max(1, (max(r.width, r.height) / max(2 * o, 1)).rounded(.down))
            var t = 0.0
            let span = r.width + r.height
            while t <= span {
                // Diagonal x - y = c, clipped to the band.
                let c = r.min.x - r.max.y + t
                let a = Vec2(max(r.min.x, r.min.y + c), max(r.min.x, r.min.y + c) - c)
                let b = Vec2(min(r.max.x, r.max.y + c), min(r.max.x, r.max.y + c) - c)
                if a.x <= b.x { line(a, b, band) }
                t += gap
            }
        }
        for x in layout.seamsX {
            hatch(Rect2(min: Vec2(x - o, 0), max: Vec2(x + o, s.height)))
            line(Vec2(x, 0), Vec2(x, s.height), seam)
        }
        for y in layout.seamsY {
            hatch(Rect2(min: Vec2(0, y - o), max: Vec2(s.width, y + o)))
            line(Vec2(0, y), Vec2(s.width, y), seam)
        }
        // The job's holes where it has them (individual tiles' move off parts), when it's of this layout.
        let generated = job?.tiling?.layout
        let registration = generated.map { $0.pitch == layout.pitch && $0.tiles == layout.tiles } == true
            ? generated?.registration : layout.registration
        if let reg = registration {
            let hole = SIMD4<Float>(1, 0.55, 0.2, alpha)
            let points = reg.materialHoles(layout.tiles, stock: s).map(\.point) + reg.spoilboard.map { $0 + layout.tiles[0].offset }
            for c in points {
                let n = 32
                for k in 0..<n {
                    line(c + Vec2.fromAngle(2 * .pi * Double(k) / Double(n), length: reg.radius),
                         c + Vec2.fromAngle(2 * .pi * Double(k + 1) / Double(n), length: reg.radius), hole)
                }
            }
        }
        return v
    }

    /// On a wrapped job, dashed guides on the unrolled sheet: the top of the blank at A0 across the middle, and the
    /// seam along the top and bottom edges, where the sheet's edges meet as it wraps.
    private func wrapGuideLines(_ project: Project) -> [LineVertex] {
        guard showVectors, rotaryAxis == nil, project.stock.rotary?.isWrapped == true else { return [] }
        let s = project.stock
        let dash = max(2.0, s.width / 120)
        var v: [LineVertex] = []
        func dashed(_ y: Double, _ color: SIMD4<Float>) {
            var x = 0.0
            while x < s.width {
                let x1 = min(x + dash, s.width)
                v.append(LineVertex(SIMD3(Float(x), Float(y), 0.04), color))
                v.append(LineVertex(SIMD3(Float(x1), Float(y), 0.04), color))
                x += 2 * dash
            }
        }
        let alpha: Float = isSimulating ? 0.3 : 0.75
        dashed(s.height / 2, SIMD4(0.45, 0.85, 0.5, alpha))
        dashed(0, SIMD4(1, 0.65, 0.3, alpha))
        dashed(s.height, SIMD4(1, 0.65, 0.3, alpha))
        return v
    }

    func rebuildPathLines(_ project: Project) {
        var v: [LineVertex] = []
        var turned: [(angle: Double, lines: [LineVertex])] = []
        let dimmed = isSimulating
        let toolpaths = session?.timeline.toolpaths ?? shownJob?.toolpaths ?? []
        if showToolpaths && (!isSimulating || showToolpathsWhileSimulating) {
            let opIndex = Dictionary(uniqueKeysWithValues: project.operations.enumerated().map { ($1.id, $0) })
            for (i, tp) in toolpaths.enumerated() {
                var color = colorForOperation(opIndex[tp.sourceOperationID] ?? i)
                // A rest-machined pocket's clearing (the larger bit) in a paler shade of the pocket's colour.
                if let k = opIndex[tp.sourceOperationID], case let .pocket(p) = project.operations[k].kind,
                   let large = p.clearanceTool, tp.tool.isSameBit(as: large), !tp.tool.isSameBit(as: project.operations[k].tool) {
                    color = SIMD4(color.x + (1 - color.x) * 0.55, color.y + (1 - color.y) * 0.55, color.z + (1 - color.z) * 0.55, color.w)
                }
                let highlight = selectedOperationID == tp.sourceOperationID
                if dimmed { color.w = 0.35 } else if !highlight && selectedOperationID != nil { color.w = 0.45 }
                let rapid = SIMD4<Float>(1, 0.3, 0.3, dimmed ? 0.2 : 0.55)
                let first = v.count
                // While simulating, a wrapped toolpath is drawn wrapped round the blank (with the blank at A0), so it
                // turns with it.
                // Not simulating, with the model shown on the blank, the same at A0.
                let preview = session == nil && showModelPreview ? previewFrame : nil
                let frame = wrapFrame ?? preview.map { (centerY: $0.centerY, radius: $0.radius) }
                let wrap = frame.flatMap { w in tp.wrapDiameter != nil ? w : nil }
                let axisNow = rotaryAxis ?? preview?.axis
                func vertex(_ p: Vec3) -> SIMD3<Float> {
                    guard let w = wrap, let axis = axisNow else { return SIMD3(Float(p.x), Float(p.y), Float(p.z)) }
                    let r = w.radius + p.z, a = (p.y - w.centerY) / w.radius
                    return SIMD3(Float(p.x), axis.x + Float(r * sin(a)), axis.y + Float(r * cos(a)))
                }
                tp.forEachMotion { s, m in
                    guard m.kind != .dwell else { return }
                    if m.kind == .rapid && !showRapids { return }
                    let c = m.kind == .rapid ? rapid : color
                    var p = s
                    var points = m.samples(from: s, maxStep: 0.5)
                    if let w = wrap {
                        // A line on the sheet is a helix round the blank: draw it in 2° steps.
                        let n = max(1, Int((abs(m.end.y - s.y) / w.radius / (2 * .pi / 180)).rounded(.up)))
                        points = (1...n).map { s.lerp(to: m.end, Double($0) / Double(n)) }
                    }
                    for q in points {
                        v.append(LineVertex(vertex(p), c))
                        v.append(LineVertex(vertex(q), c))
                        p = q
                    }
                }
                if rotaryAxis != nil, v.count > first {
                    // Each toolpath is in its face's frame (a wrapped one in the blank's, at A0): keep it apart so it
                    // can turn with the blank.
                    turned.append((wrap == nil ? tp.indexAngle ?? 0 : 0, Array(v[first...])))
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
