import Foundation

/// Settings shared by every generator for one run.
public struct GenerationContext: Sendable {
    public var stock: Stock
    public var machine: MachineProfile
    /// Chord tolerance when flattening design curves, mm.
    public var flattenTolerance: Double
    /// Arc tolerance for Clipper's round joins, mm.
    public var arcTolerance: Double
    /// Highest remaining material within a radius of a point (design Z), from the operations already generated.
    /// Lets generators skip depths earlier toolpaths cleared. nil when no model is available.
    public var materialTop: (@Sendable (Vec2, Double) -> Double)?
    /// Clamp and fixture zones. Leads keep the tool clear of them.
    public var keepOuts: [KeepOut] = []
    /// On a rotary blank: how far from the axis the stock reaches at a station along it (design X), once the roundings
    /// that run before this operation have turned it down. nil = the blank as it is (out to a square bar's corners).
    public var rotaryStockRadius: (@Sendable (Double) -> Double)?
    /// On a rotary blank, once a 3D rotary roughing has run before this operation: the most material it left (mm from
    /// the axis, an upper bound) under a tool pointed at the axis at station x along the blank, the blank turned to
    /// angle θ (radians), reaching r either side of its axis (`RadialGrid.highest`): (x, θ, r). nil = no roughing ran.
    public var rotaryMaterial: (@Sendable (Double, Double, Double) -> Double)?
    /// The parts the job's other toolpaths cut (on this face of an indexed rotary job). Leads and corner reliefs keep
    /// clear of them. nil when none are known (an operation generated on its own).
    public var protectedRegions: ProtectedRegions?
    /// The project's display units, which generators' warnings give lengths and feeds in (like the job's checks).
    public var units: LengthUnit
    /// The whole project, for toolpaths that follow what earlier ones cut (rest machining, `RestMachining`). nil when an
    /// operation is generated on its own: a rest toolpath then has no references.
    public var project: Project?

    public init(stock: Stock, machine: MachineProfile, flattenTolerance: Double = 0.01, arcTolerance: Double = 0.005,
                units: LengthUnit = .mm) {
        self.stock = stock
        self.machine = machine
        self.flattenTolerance = flattenTolerance
        self.arcTolerance = arcTolerance
        self.units = units
    }

    /// A length (mm) for a warning, in the display units: "4.000 mm", "0.1575 in".
    public func length(_ mm: Double) -> String { "\(units.format(mm)) \(units.symbol)" }

    /// A feed (mm/min) for a warning, in the display units: "8,001 mm/min", "315.0 in/min".
    public func feed(_ mmPerMinute: Double) -> String {
        let v = units.fromMM(mmPerMinute)
        return "\(v.formatted(.number.precision(.fractionLength(units == .inch ? 1 : 0)))) \(units.feedSymbol)"
    }
}

public enum Severity: String, Codable, Sendable { case info, warning, error }

public struct JobIssue: Hashable, Sendable, Identifiable {
    public var id: String { "\(severity.rawValue):\(operation ?? ""):\(message)" }
    public var severity: Severity
    public var operation: String?
    public var message: String

    public init(_ severity: Severity, _ message: String, operation: String? = nil) {
        self.severity = severity
        self.message = message
        self.operation = operation
    }
}

public struct JobResult: Sendable {
    public var toolpaths: [Toolpath]
    public var issues: [JobIssue]
    /// Acceleration-aware run time (see `CycleTimeEstimator`).
    public var estimate: CycleTimeEstimate?
    /// A run order with fewer tool changes, when one exists (see `OperationScheduler`).
    public var reorder: OperationScheduler.Result?
    /// On a tiled job, each tile's toolpaths; `toolpaths` is then all of them, tile after tile, in job coordinates.
    public var tiling: TiledJob?
    /// On a job nested onto several sheets, each sheet's own job; `toolpaths` is then all of them, sheet after sheet,
    /// each in its sheet's coordinates (`Toolpath.sheet`).
    public var sheets: [SheetJob]?

    public var hasErrors: Bool { issues.contains { $0.severity == .error } }

    /// Best available run-time estimate in seconds.
    public var estimatedSeconds: Double {
        estimate?.total ?? toolpaths.reduce(0) { $0 + $1.estimatedSeconds(rapidRate: 800.inch) }
    }

    /// Estimated seconds for one toolpath's own motions.
    public func estimatedSeconds(toolpath id: UUID) -> Double? {
        guard let e = estimate, let i = toolpaths.firstIndex(where: { $0.id == id }), i < e.toolpathSeconds.count else { return nil }
        return e.toolpathSeconds[i]
    }
}

/// One sheet of a job nested onto several: the sheet as a job of its own (`Project.sheetProject`) and what it cuts.
public struct SheetJob: Sendable {
    /// From 0, in the order they're cut.
    public var index: Int
    public var project: Project
    public var job: JobResult

    /// Whether any toolpath cuts on this sheet: one with nothing to cut gets no file.
    public var cutsAnything: Bool { job.toolpaths.contains { !$0.isEmpty } }
}

/// Turns a project into ordered toolpaths and checks them against the material and machine.
public enum CAMEngine {
    public static func generate(_ project: Project, operationIDs: Set<UUID>? = nil) -> JobResult {
        var job: JobResult
        if project.sheetCount > 1 {
            job = generateSheets(project, operationIDs: operationIDs)
        } else {
            job = generateSheet(project, operationIDs: operationIDs)
            if operationIDs == nil {
                let (issues, reorder) = schedulingIssues(project)
                job.issues += issues
                job.reorder = reorder
            }
        }
        if operationIDs == nil, let note = offMaterialNote(project) { job.issues.append(note) }
        return job
    }

    /// On a flat job, a note when shapes a toolpath cuts lie wholly off the material (or off their sheet): their
    /// toolpaths run past its edges, which is what a design laid out loosely for nesting (the frames and coasters demo)
    /// opens with, so it points to Nest Parts. nil when there are none.
    static func offMaterialNote(_ project: Project) -> JobIssue? {
        guard project.stock.rotary == nil else { return nil }
        let cut = Set(project.operations.filter { $0.enabled && $0.kind.needsShapes }.flatMap(\.shapeIDs))
        let off = project.shapes.filter { shape in
            guard cut.contains(shape.id), !shape.isKeepOut else { return false }
            let size = project.sheetSize(project.sheetIndex(of: shape))
            let bounds = shape.polylines(tolerance: 0.1).bounds
            return !bounds.isEmpty && !bounds.intersects(Rect2(x: 0, y: 0, width: size.x, height: size.y))
        }
        guard let first = off.first else { return nil }
        let which = off.count == 1 ? "“\(first.name)” lies" : "“\(first.name)” and \(off.count - 1) other shape\(off.count == 2 ? "" : "s") lie"
        return JobIssue(.info, "\(which) off the material, so the toolpaths cutting \(off.count == 1 ? "it" : "them") run past its edges: "
            + "that's what the warnings about the material's edges and the work area are about. Toolpaths ▸ Nest Parts… lays the "
            + "parts out on the material, and on more sheets if they don't all fit.")
    }

    /// A job nested onto several sheets: each sheet generated as a job of its own. Checks that every sheet has are
    /// listed once; the others say which sheet. The run order is checked once, for the whole job.
    static func generateSheets(_ project: Project, operationIDs: Set<UUID>?) -> JobResult {
        let n = project.sheetCount
        var sheets: [SheetJob] = []
        var toolpaths: [Toolpath] = []
        for k in 0..<n {
            let p = project.sheetProject(k)
            let job = generateSheet(p, operationIDs: operationIDs)
            sheets.append(SheetJob(index: k, project: p, job: job))
            for tp in job.toolpaths { toolpaths.append(sheetToolpath(tp, sheet: k)) }
        }
        var onSheets: [String: Int] = [:]
        for s in sheets { for id in Set(s.job.issues.map(\.id)) { onSheets[id, default: 0] += 1 } }
        var issues: [JobIssue] = []
        var listed = Set<String>()
        for s in sheets {
            for issue in s.job.issues {
                if onSheets[issue.id] == n {
                    if listed.insert(issue.id).inserted { issues.append(issue) }
                } else {
                    var i = issue
                    i.message = "Sheet \(s.index + 1): " + issue.message
                    issues.append(i)
                }
            }
        }
        // A sheet with nothing to cut (its parts nested elsewhere, or taken off it) gets no file.
        for s in sheets where !s.cutsAnything {
            issues.append(JobIssue(.warning, "Sheet \(s.index + 1) has nothing to cut, so Export skips it. Nest the parts again to "
                + "close the gap, or put parts on it."))
        }
        let cutting = sheets.filter(\.cutsAnything)
        let files = cutting.reduce(0) { $0 + (JobExport.files($1.project, job: $1.job)?.files.count ?? 1) }
        let perTool = files > cutting.count ? ", one per tool on each sheet," : ", one per sheet,"
        issues.append(JobIssue(.info, "Nested onto \(n) sheets, cut one after another. Export saves \(files) files\(perTool) "
            + "and a setup sheet with a page for each sheet."))
        var estimate: CycleTimeEstimate?
        let estimates = sheets.compactMap(\.job.estimate)
        if estimates.count == n {
            estimate = CycleTimeEstimate(total: estimates.reduce(0) { $0 + $1.total },
                                         feedSeconds: estimates.reduce(0) { $0 + $1.feedSeconds },
                                         rapidSeconds: estimates.reduce(0) { $0 + $1.rapidSeconds },
                                         overheadSeconds: estimates.reduce(0) { $0 + $1.overheadSeconds },
                                         toolpathSeconds: estimates.flatMap(\.toolpathSeconds),
                                         motionSeconds: estimates.flatMap(\.motionSeconds),
                                         constantVelocity: estimates.reduce(0) { $0 + $1.constantVelocity },
                                         leadInSeconds: estimates.flatMap(\.leadInSeconds),
                                         endSeconds: estimates.reduce(0) { $0 + $1.endSeconds })
        }
        var job = JobResult(toolpaths: toolpaths, issues: issues, estimate: estimate, sheets: sheets)
        if operationIDs == nil {
            let (more, reorder) = schedulingIssues(project)
            job.issues += more
            job.reorder = reorder
        }
        return job
    }

    /// A sheet's toolpath as the whole job lists it: marked with its sheet, and on every sheet after the first with an
    /// ID of its own (made from its ID and the sheet), so the job's toolpaths are all different.
    public static func sheetToolpath(_ tp: Toolpath, sheet k: Int) -> Toolpath {
        var t = tp
        t.sheet = k
        guard k > 0 else { return t }
        t.operationID = tp.sourceOperationID
        t.id = RotaryIndex.toolpathID(operation: tp.id, role: 1000, position: k)
        return t
    }

    /// One sheet's toolpaths and checks (the whole job, on a job of one sheet), without the run-order check.
    static func generateSheet(_ project: Project, operationIDs: Set<UUID>?) -> JobResult {
        var ctx = GenerationContext(stock: project.stock, machine: project.machine,
                                    flattenTolerance: 0.01,
                                    arcTolerance: min(0.005, project.machine.arcFitTolerance / 2),
                                    units: project.displayUnits)
        ctx.project = project
        var toolpaths: [Toolpath] = []
        var issues: [JobIssue] = []
        // Coarse model of the material as each toolpath removes it (drives links and rest-aware depths). A rotary job
        // keeps one per face: each starts as the full block above the axis and other faces only ever remove material,
        // so a face's model never shows less than is really there, and links never stay down through uncut wood.
        let stock = project.stock
        var models: [Double: MaterialSimulator] = [:]
        func newModel() -> MaterialSimulator {
            MaterialSimulator(stock: stock, cellSize: ModelRaster.cellSize(
                for: stock.bounds, preferred: max(0.5, min(1.0, max(stock.width, stock.height) / 600)), maxCells: 1_000_000))
        }
        let keepOuts = project.shapes.compactMap { s -> [KeepOut]? in
            guard let h = s.keepOutHeight else { return nil }
            return s.polylines(tolerance: 0.1).filter(\.isClosed).map { KeepOut(outline: $0, height: h) }
        }.flatMap { $0 }
        let clearanceZ = max(stock.clearanceHeight, stock.plungeHeight)
        // A tiled job: generated as one, then split into tiles (see `TileSplitter`). Near the tile lines its tiles cut in
        // a different order from the job as a whole, so generators are told the material there is still uncut.
        let layout = TileLayout(project)
        var sources: [TileSplitter.Source] = []
        // Profiles with leads: how each comes back onto its wall where a tile line breaks it.
        var breakLeads: [UUID: BreakLeads] = [:]
        let seamReach = layout.map { $0.overlap + 2 * TileLayout.largestToolRadius(project) + 1 }
        // Every toolpath's parts, built once for the whole pass (from all of them, so the order doesn't matter), when
        // any toolpath has leads or corner reliefs to keep clear of them.
        let parts = ProtectedRegions.needed(project)
            ? ProtectedRegions(project, flattenTolerance: ctx.flattenTolerance, arcTolerance: ctx.arcTolerance) : nil
        // Wrapped rotary jobs cut each operation once on the unrolled sheet; the posts wrap it around the blank.
        let wrap = stock.rotary.flatMap { $0.isWrapped ? $0.wrapDiameterOrBlank : nil }
        func faceKey(_ angle: Double?) -> Double { angle.map(RotaryIndex.normalized) ?? 0 }
        /// One operation's toolpaths at each of its angles, each marked clearing (cut before the operation's own
        /// tool) or not.
        struct Generated {
            var op: CAMOperation
            var wrap: Double?
            var angles: [Double?]
            var perAngle: [[(tp: Toolpath, clearing: Bool)]]
            /// A toolpath cut one way: the same cut both ways, as it has always been, to time it against
            /// (`Toolpath.directionTime`), by angle and index as `perAngle`.
            var bothWays: [[Toolpath?]] = []
        }
        // The stock as the last 3D rotary roughing left it, for the toolpaths after it (see `GenerationContext.rotaryMaterial`).
        var roughed: RadialGrid?
        func generateAll(_ op: CAMOperation, stockRadius: (@Sendable (Double) -> Double)?) -> Generated? {
            let shapes = project.shapes(for: op).filter { !$0.isKeepOut }
            if shapes.isEmpty && op.kind.needsShapes {
                issues.append(JobIssue(.warning, op.vectorSelection?.emptyMessage ?? "No shapes selected.", operation: op.name))
                return nil
            }
            // Rounding and 3D rotary finishing work all the way round the blank, wrapped round it at the sheet's radius,
            // whatever the layout.
            let wrap = op.kind.turnsWholeBlank ? stock.rotary.map { 2 * $0.topRadius } : wrap
            // Flat jobs cut once; rotary jobs once per index angle, each on its own face model (wrapped jobs once, on the
            // unrolled sheet). Every angle is generated first, then cut toolpath by toolpath: a V-carve's flat clearing
            // at every angle, then its V-bit at every angle, so the job changes tools once rather than at every face.
            let angles: [Double?] = stock.rotary == nil || wrap != nil ? [nil] : op.rotaryAngles
            var perAngle: [[(tp: Toolpath, clearing: Bool)]] = []
            var bothWays: [[Toolpath?]] = []
            for (position, angle) in angles.enumerated() {
                let face = faceKey(angle)
                if models[face] == nil { models[face] = newModel() }
                var opContext = ctx
                let snapshot = models[face]!.grid
                if let layout, let reach = seamReach {
                    opContext.materialTop = { p, r in
                        layout.distanceToSeam(p) <= reach + r ? 0 : Double(LinkOptimizer.maxHeight(snapshot, around: p, radius: r))
                    }
                } else {
                    opContext.materialTop = { p, r in Double(LinkOptimizer.maxHeight(snapshot, around: p, radius: r)) }
                }
                opContext.keepOuts = keepOuts
                opContext.rotaryStockRadius = stockRadius
                if let grid = roughed {
                    // A surface per ray: allow for what can stand between rays (a square bar's corner).
                    let between = grid.angleStep * Double(grid.initial.max() ?? 0) + 0.01
                    opContext.rotaryMaterial = { x, a, r in grid.highest(x: x, angle: a, reach: r) + between }
                }
                opContext.protectedRegions = parts?.excluding(op.id, angle: angle)
                if layout != nil, case let .profile(p) = op.kind {
                    breakLeads[op.id] = ProfileGenerator.breakLeads(op: op, params: p, shapes: shapes, context: opContext)
                }
                var generated: [Toolpath]
                var twins: [Toolpath?] = []
                if let refused = refusal(op, context: opContext) {
                    generated = [refused]
                } else if case let .rotaryRough(p) = op.kind {
                    let result = Rotary3DRoughing.generate(op: op, params: p, shapes: shapes, context: opContext)
                    generated = [result.toolpath]
                    if case let .rotaryRough(q)? = op.kind.cutBothWays {
                        twins = [Rotary3DRoughing.generate(op: op, params: q, shapes: shapes, context: opContext).toolpath]
                    }
                    if let left = result.left { roughed = left }
                } else {
                    generated = generate(op, shapes: shapes, context: opContext)
                    if let kind = op.kind.cutBothWays {
                        var twin = op
                        twin.kind = kind
                        let made = generate(twin, shapes: shapes, context: opContext)
                        twins = generated.map { tp in made.first { $0.id == tp.id } }
                    }
                }
                generated = generated.map { withDirectionNote($0, operation: op) }
                // Spindle ▸ Automatic: one speed per toolpath, set before anything reads it (feeds that follow the
                // load hold their chip floor at it; tiles and sheets copy it).
                if op.usesAutomaticSpindle {
                    generated = generated.map { applyAutomaticSpindle($0, operation: op, project: project) }
                    twins = twins.map { $0.map { applyAutomaticSpindle($0, operation: op, project: project) } }
                }
                // Only a toolpath the direction changed is timed against its twin.
                twins = generated.indices.map { i in
                    i < twins.count && twins[i].map { $0.motions != generated[i].motions } == true ? twins[i] : nil
                }
                let clearing = generated.map { $0.id != op.id }
                if let angle {
                    for (index, tp) in generated.enumerated() {
                        // Role 0 is the toolpath that carries the operation's own ID; the others (a V-carve's flat
                        // clearing) count from 1, so a toolpath keeps its IDs whether or not the others exist.
                        let role = tp.id == op.id ? 0 : max(1, index)
                        generated[index].indexAngle = angle
                        generated[index].operationID = op.id
                        generated[index].name += " @ \(RotaryIndex.label(angle))"
                        if position > 0 { generated[index].id = RotaryIndex.toolpathID(operation: op.id, role: role, position: position) }
                    }
                }
                perAngle.append(Array(zip(generated, clearing)).map { (tp: $0.0, clearing: $0.1) })
                bothWays.append(twins)
            }
            return Generated(op: op, wrap: wrap, angles: angles, perAngle: perAngle, bothWays: bothWays)
        }
        func emit(_ g: Generated, clearing: Bool) {
            let op = g.op, wrap = g.wrap
            for index in 0..<(g.perAngle.map(\.count).max() ?? 0) {
                for (position, angle) in g.angles.enumerated() where index < g.perAngle[position].count {
                    guard g.perAngle[position][index].clearing == clearing else { continue }
                    var tp = g.perAngle[position][index].tp
                    var twin = position < g.bothWays.count && index < g.bothWays[position].count ? g.bothWays[position][index] : nil
                    if layout != nil {
                        sources.append(TileSplitter.Source(toolpath: tp, operation: op, leads: tp.id == op.id ? breakLeads[op.id] : nil))
                    }
                    let face = faceKey(angle)
                    var model = models.removeValue(forKey: face) ?? newModel()
                    defer { models[face] = model }
                    // Feeds that follow the load measure the material as it is before this toolpath cuts.
                    let uncut = layout == nil && wrap == nil && op.adjustsFeedsForLoad && FeedScheduler.suits(tp.tool) ? model.grid : nil
                    // Wrapped toolpaths link through safe Z: the blank turns as the tool moves across the sheet, and
                    // only safe Z is sure to clear it (and a square bar's corners) all the way round.
                    if op.kind.is3D && op.kind.turnsWholeBlank {
                        // All the way round the blank, nowhere near a face's model: it would only cost time.
                    } else if stock.retract == .minimum && wrap == nil {
                        let settings = LinkOptimizer.Settings(safeDistance: stock.safeDistance, clearanceZ: clearanceZ,
                                                              stayDownLimit: max(3 * tp.tool.diameter, 10), floorZ: -stock.thickness,
                                                              keepOuts: keepOuts)
                        if let t = twin {
                            // Linked over the same material, which the twin doesn't cut into the job's model.
                            var scratch = model
                            twin = LinkOptimizer.optimize(t, model: &scratch, settings: settings)
                        }
                        tp = LinkOptimizer.optimize(tp, model: &model, settings: settings)
                    } else {
                        tp.forEachMotion { s, m in model.apply(m, from: s, tool: tp.tool) }
                    }
                    if layout != nil {
                        // Checked and kept tile by tile instead.
                        issues.append(contentsOf: tp.warnings.map { JobIssue(.warning, $0, operation: tp.name) })
                        issues.append(contentsOf: (tp.notes ?? []).map { JobIssue(.info, $0, operation: tp.name) })
                        if tp.cuttingExtents == nil, !tp.motions.isEmpty || tp.warnings.isEmpty {
                            issues.append(JobIssue(.warning, "Toolpath is empty.", operation: tp.name))
                        }
                        continue
                    }
                    issues.append(contentsOf: keepOutIssues(tp, keepOuts: keepOuts, clearanceZ: clearanceZ))
                    if let wrap {
                        // 3D rotary roughing and finishing have already lowered their feeds for the rotary axis, and said so.
                        let own = op.kind.is3D && op.kind.turnsWholeBlank
                        // Flutes that follow a model are joined only where they stay on or above their depth below it.
                        var followsModel = false
                        if case let .fluting(f) = op.kind, f.surfaceModelID != nil { followsModel = true }
                        tp = RotaryWrap.prepare(tp, diameter: wrap, clearanceZ: clearanceZ, context: ctx, warns: !own,
                                                mergeTolerance: followsModel ? 1e-6 : nil)
                        twin = twin.map { RotaryWrap.prepare($0, diameter: wrap, clearanceZ: clearanceZ, context: ctx, warns: false,
                                                             mergeTolerance: followsModel ? 1e-6 : nil) }
                    } else if project.machine.outputArcs, op.kind.fitsArcs {
                        // 3D finishing keeps only the arcs that stay on its drop-cutter surface.
                        tp = ArcFitter.fit(tp, for: op, project: project)
                    }
                    if let twin {
                        // The planner's times, as the links will be, before arc fitting (which the twin doesn't get).
                        let mine = CycleTimeEstimator.estimate([tp], project: project).toolpathSeconds.first ?? 0
                        let both = CycleTimeEstimator.estimate([twin], project: project).toolpathSeconds.first ?? 0
                        tp.directionTime = DirectionTime(seconds: mine, bothWaysSeconds: both)
                    }
                    // After arc fitting, so an arc keeps one feed.
                    let (scheduled, notes) = FeedScheduler.apply(tp, operation: op, uncut: uncut, wrapped: wrap != nil, project: project)
                    tp = scheduled
                    issues.append(contentsOf: notes)
                    issues.append(contentsOf: tp.warnings.map { JobIssue(.warning, $0, operation: tp.name) })
                    issues.append(contentsOf: (tp.notes ?? []).map { JobIssue(.info, $0, operation: tp.name) })
                    issues.append(contentsOf: validate(tp, operation: op, project: project))
                    toolpaths.append(tp)
                }
            }
        }
        // Operations next to each other that share a clearance tool cut all their clearing, then each its own tool
        // (see `OperationScheduler.blocks`); every other operation cuts on its own, clearing first.
        let ops = project.operations.filter { $0.enabled && (operationIDs?.contains($0.id) ?? true) }
        let stockRadii = rotaryStockRadii(project)
        for block in OperationScheduler.blocks(ops.map { $0.clearanceTool?.number }) {
            var generated: [Generated] = []
            for k in block {
                guard let g = generateAll(ops[k], stockRadius: stockRadii[ops[k].id] ?? nil) else { continue }
                emit(g, clearing: true)
                generated.append(g)
            }
            for g in generated { emit(g, clearing: false) }
        }
        issues.append(contentsOf: tilingIssues(project, layout: layout))
        var tiled: TiledJob?
        if let layout {
            let result = TileSplitter.run(sources, project: project, layout: layout, keepOuts: keepOuts, clearanceZ: clearanceZ,
                                          newModel: newModel)
            toolpaths = result.toolpaths
            issues.append(contentsOf: result.issues)
            tiled = result.job
        }
        issues.append(contentsOf: checkModelBoundaries(project))
        issues.append(contentsOf: inlayIssues(project, toolpaths: toolpaths))
        issues.append(contentsOf: chamferIssues(project))
        issues.append(contentsOf: edgeProfileIssues(project))
        issues.append(contentsOf: sharedToolNumberIssues(toolpaths, machine: project.machine))
        if let reason = PostProcessors.unavailableReason(for: project.machine) { issues.append(JobIssue(.error, reason)) }
        issues.append(contentsOf: RotaryIndex.issues(project, toolpaths: toolpaths))
        if let tiled {
            issues.append(contentsOf: tiledFileIssues(project, tiled: tiled))
        } else if let post = PostProcessors.post(for: project), !(post is AvidMach4Post) {
            let files = post.files(toolpaths).count
            if files > 1 {
                let hint = post is GenericGCodePost
                    ? " (If the program that sends your files pauses on M6, name it under Machine ▸ Sends files with.)" : ""
                issues.append(JobIssue(.info, "\(post.name) can't stop for a tool change here, so this job is saved as "
                    + "\(files) files, one per tool. Change the bit and re-zero Z\(stock.rotary == nil ? "" : " on the rotation axis") "
                    + "before running each.\(hint)"))
            }
        }
        let estimate = CycleTimeEstimator.estimate(toolpaths, project: project)
        return JobResult(toolpaths: toolpaths, issues: issues, estimate: estimate, tiling: tiled)
    }

    /// Points out (never applies) a run order that fixes dependencies or needs fewer tool changes.
    static func schedulingIssues(_ project: Project) -> (issues: [JobIssue], reorder: OperationScheduler.Result?) {
        var issues: [JobIssue] = []
        var reorder: OperationScheduler.Result?
        do {
            let r = OperationScheduler.optimize(project)
            let byID = Dictionary(project.operations.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for late in r.outOfOrder {
                guard let early = byID[late.operation], let later = byID[late.mustPrecede] else { continue }
                // A rest toolpath before what it rests on says so itself (`RestMachining.references`).
                if RestMachining.dependencies(of: later, in: project).contains(early.id) { continue }
                if early.kind.is3D && later.kind.is3D {
                    issues.append(JobIssue(.warning, "Runs before its roughing (“\(early.name)”). "
                        + "Use Toolpaths ▸ Optimize Run Order to fix the order.", operation: later.name))
                } else if case let .edgeProfile(ep) = early.kind, case let .profile(pp) = later.kind, pp.tabs.enabled {
                    // Left on tabs it reaches down to: it would cut into them.
                    let u = project.displayUnits
                    func fmt(_ mm: Double) -> String { "\(u.format(mm)) \(u.symbol)" }
                    let top = OperationScheduler.tabTop(pp)
                    issues.append(JobIssue(.warning, "Runs after “\(later.name)” cuts its part out, and at \(fmt(ep.depth(for: early.tool))) "
                        + "deep its profile reaches the tabs holding the part (their tops are \(fmt(max(0, top))) below the material "
                        + "top), so it cuts into them and can free the part. Use Toolpaths ▸ Optimize Run Order to run it first, or "
                        + "make the profile shallower than the tabs' tops.", operation: early.name))
                } else if !early.kind.needsShapes {
                    issues.append(JobIssue(.warning, "Runs before the blank is rounded (“\(early.name)”), so it cuts the blank "
                        + "before it's round. Use Toolpaths ▸ Optimize Run Order to fix the order.", operation: later.name))
                } else {
                    issues.append(JobIssue(.warning, "Runs after “\(later.name)” has cut its part free, so the part can shift. "
                        + "Use Toolpaths ▸ Optimize Run Order to fix the order.", operation: early.name))
                }
            }
            if r.changed { reorder = r }
            if r.toolChangesAfter < r.toolChangesBefore {
                let saved = r.toolChangesBefore - r.toolChangesAfter
                let seconds = Double(saved) * project.machine.toolChangeTime
                let time = seconds < 60 ? "\(Int(seconds.rounded())) s" : "\(Int((seconds / 60).rounded())) min"
                let what = project.machine.toolChange == .atc ? "tool changes" : "collet swaps and touch-offs"
                issues.append(JobIssue(.info, "A different run order saves \(saved) tool change\(saved == 1 ? "" : "s") "
                    + "(about \(time) of \(what)). Use Toolpaths ▸ Optimize Run Order."))
            }
        }
        return (issues, reorder)
    }

    /// Tiling that's on but can't apply: a rotary job, or material that fits in one tile.
    static func tilingIssues(_ project: Project, layout: TileLayout?) -> [JobIssue] {
        guard let t = project.tiling, t.enabled, layout == nil else { return [] }
        if project.stock.rotary != nil {
            return [JobIssue(.error, "Rotary jobs can't be tiled: the blank turns between the chuck and tailstock and can't move "
                + "through the machine. Turn off tiling in Job Setup.")]
        }
        return [JobIssue(.info, "The material fits in one tile, so tiling makes no difference: the job is saved as one file.")]
    }

    /// What a tiled export saves: a file per tile (and per tool where the controller can't stop for a change).
    static func tiledFileIssues(_ project: Project, tiled: TiledJob) -> [JobIssue] {
        let layout = tiled.layout, u = project.displayUnits
        func len(_ mm: Double) -> String { u.format(mm, decimals: u == .inch ? 3 : 1) }
        let pitch = layout.mode == .feedThroughX ? layout.pitch.x : layout.pitch.y
        let how: String
        switch layout.mode {
        case .feedThroughY: how = "moving the material \(len(pitch)) \(u.symbol) along Y between them"
        case .feedThroughX: how = "moving the material \(len(pitch)) \(u.symbol) along X between them"
        case .grid: how = "\(layout.columns) across and \(layout.rows) up, \(len(layout.pitch.x)) × \(len(layout.pitch.y)) \(u.symbol) each"
        }
        let files = JobExport.files(project, job: JobResult(toolpaths: [], issues: [], tiling: tiled))?.files.count ?? layout.count
        let perTool = files > layout.count ? ", one per tool in each tile," : ""
        return [JobIssue(.info, "Cut in \(layout.count) tiles, \(how). Export saves \(files) files\(perTool) and a setup sheet with a page for each tile.")]
    }

    /// For each operation on a rotary blank, how far the stock reaches from the axis along the blank once the enabled
    /// roundings before it in the run order have turned it down (nil before the first rounding). A rounding counts
    /// between its start and end stations only, so elsewhere the stock is taken to be the blank as it was.
    static func rotaryStockRadii(_ project: Project) -> [UUID: (@Sendable (Double) -> Double)?] {
        guard let blank = project.stock.rotary else { return [:] }
        var out: [UUID: (@Sendable (Double) -> Double)?] = [:]
        var rounded: [(from: Double, to: Double, radius: Double)] = []
        for op in project.operations where op.enabled {
            if rounded.isEmpty {
                out[op.id] = .some(nil)
            } else {
                let spans = rounded, outer = blank.outerRadius
                out[op.id] = { x in spans.reduce(outer) { x >= $1.from - 1e-9 && x <= $1.to + 1e-9 ? min($0, $1.radius) : $0 } }
            }
            if case let .rounding(p) = op.kind {
                rounded.append((p.startX ?? op.tool.radius, p.endX ?? blank.length - op.tool.radius,
                                RoundingGenerator.finishedRadius(p, blank: blank)))
            }
        }
        return out
    }

    /// With "Selected vectors" boundaries, a 3D finish assumes the band its tool can touch was cleared by a 3D rough
    /// of the same model. Warn when the rough's margin is too small for that (the finish would cut uncut scrap).
    static func checkModelBoundaries(_ project: Project) -> [JobIssue] {
        var issues: [JobIssue] = []
        let ops = project.operations.filter(\.enabled)
        for finish in ops {
            guard case let .finish3D(fp) = finish.kind, fp.boundary == .vectors else { continue }
            let reach = (fp.boundaryMargin ?? Finish3DParams.autoMargin(tool: finish.tool)) + finish.tool.radius
            let models = Set(project.shapes(for: finish).filter { $0.modelSpec != nil }.map(\.id))
            for rough in ops {
                guard case let .rough3D(rp) = rough.kind, rp.boundary == .vectors,
                      !models.isDisjoint(with: rough.shapeIDs) else { continue }
                let cleared = rp.boundaryMargin ?? Rough3DParams.autoMargin(tool: rough.tool)
                if cleared + 1e-6 < reach {
                    let u = project.displayUnits
                    issues.append(JobIssue(.warning, "Finishing reaches \(u.format(reach)) \(u.symbol) past the boundary but '\(rough.name)' only clears \(u.format(cleared)) \(u.symbol); the ball will cut uncut material there. Increase the roughing margin.", operation: finish.name))
                }
            }
        }
        return issues
    }

    /// V-carve inlays: whether each plug will seat in its pocket with the glue gap it asks for (see `VCarveInlay`).
    /// A plug's pocket is the inlay pocket that shares one of its shapes, or the only one in the project. Toolpaths
    /// turned off are checked too: the two sides are usually exported one at a time.
    static func inlayIssues(_ project: Project, toolpaths: [Toolpath]) -> [JobIssue] {
        let u = project.displayUnits
        func fmt(_ mm: Double) -> String { "\(u.format(mm)) \(u.symbol)" }
        func bit(_ t: Tool) -> String {
            let name = t.name.isEmpty ? "T\(t.number)" : t.name
            guard t.shape.isTapered else { return "\(name) (a \(t.shape.label.lowercased()))" }
            return "\(name) (\(Int(t.includedAngle.rounded()))°\(t.tipDiameter > 1e-6 ? ", \(fmt(t.tipDiameter)) tip" : ""))"
        }
        var issues: [JobIssue] = []
        for plug in project.operations {
            guard case let .vcarve(params) = plug.kind, let inlay = params.inlay, inlay.role == .plug else { continue }
            func warn(_ message: String) { issues.append(JobIssue(.warning, message, operation: plug.name)) }
            let tool = plug.tool
            if inlay.glueGap <= 1e-9 {
                warn("No glue gap: the plug's face reaches the pocket's floor just as the walls meet, leaving no room for glue. "
                    + "About \(fmt(VCarveInlay.defaultGlueGap)) is typical.")
            } else if inlay.glueGap >= inlay.pocketDepth - 1e-9 {
                warn("The glue gap (\(fmt(inlay.glueGap))) isn't less than the pocket depth (\(fmt(inlay.pocketDepth))), so the plug "
                    + "has no walls to fit by.")
            } else if inlay.glueGap < 2 * VCarveGenerator.inlayPocketRidge - 1e-9 {
                warn("The glue gap (\(fmt(inlay.glueGap))) is smaller than the ridges a V-bit can leave where it clears the pocket's "
                    + "floor (up to \(fmt(2 * VCarveGenerator.inlayPocketRidge))), so the plug may bottom out on them.")
            }
            if inlay.surfaceClearance <= 1e-9 {
                warn("No surface clearance: the plug board's carved floor meets the pocket board's surface just as the walls meet, "
                    + "so there's nothing left to press in or plane off.")
            }
            if tool.shape.isTapered {
                let reach = min(tool.taperHeight, tool.fluteLength)
                if inlay.plugCutDepth > reach + 1e-6 {
                    warn("The plug is cut \(fmt(inlay.plugCutDepth)) deep (start depth plus surface clearance), but \(bit(tool))'s V is "
                        + "only \(fmt(reach)) tall. Use a smaller pocket depth or a taller V-bit.")
                }
                if tool.tipDiameter > 1e-6 {
                    let proud = tool.tipDiameter / 2 / tool.halfAngleTangent
                    warn("\(bit(tool)) has a flat tip, so narrow parts of the plug come out up to \(fmt(proud)) taller than the "
                        + "pocket's grooves there and can stop it seating. A pointed V-bit fits best.")
                }
            }
            guard let pocket = project.inlayPocket(for: plug), case let .vcarve(pocketParams) = pocket.kind else { continue }
            let a = pocket.tool
            if a.shape.isTapered != tool.shape.isTapered || abs(a.includedAngle - tool.includedAngle) > 0.01
                || abs(a.tipDiameter - tool.tipDiameter) > 0.005 {
                warn("Uses \(bit(tool)), but its pocket “\(pocket.name)” uses \(bit(a)). Cut both with the same V-bit, or their "
                    + "walls won't meet.")
            }
            guard let flat = pocketParams.flatDepth else {
                warn("Its pocket “\(pocket.name)” has no flat depth, so the plug's depths can't be matched to it. Give the pocket a "
                    + "flat depth of \(fmt(inlay.pocketDepth)) (the plug's pocket depth).")
                continue
            }
            // A raster stepover the user widened leaves taller ridges on the pocket's floor than the rings would.
            if pocketParams.vBitClearsFlats, pocketParams.flatRaster != nil, a.shape.isTapered, inlay.glueGap > 1e-9 {
                let stepover = pocketParams.vBitRasterStepover(a)
                let ridge = VCarveParams.vBitRidge(a, spacing: stepover)
                if ridge > pocketParams.vBitRasterRidge + 1e-9, 2 * ridge > inlay.glueGap - 1e-9 {
                    warn("“\(pocket.name)” clears its floor in raster lines \(fmt(stepover)) apart, which leave ridges up to "
                        + "\(fmt(ridge)) tall: too close to the \(fmt(inlay.glueGap)) glue gap, so the plug may bottom out on them. "
                        + "Use the pocket's automatic stepover.")
                }
            }
            if abs(flat - inlay.pocketDepth) > 0.005 {
                let gap = flat - inlay.plugStartDepth
                if gap <= 1e-6 {
                    warn("Pocket depth is \(fmt(inlay.pocketDepth)), but “\(pocket.name)” is only \(fmt(flat)) deep (its flat depth), "
                        + "so the plug bottoms out before its walls meet. Set Pocket depth to \(fmt(flat)).")
                } else {
                    warn("Pocket depth is \(fmt(inlay.pocketDepth)), but “\(pocket.name)” is \(fmt(flat)) deep (its flat depth), so "
                        + "the plug would sit \(fmt(gap)) off the pocket's floor instead of the \(fmt(inlay.glueGap)) glue gap. Set "
                        + "Pocket depth to \(fmt(flat)).")
                }
            }
            // Both sides in one file, on top of each other: the plug would cut away the pocket.
            if pocket.enabled && plug.enabled {
                func extents(_ op: CAMOperation) -> Rect2 {
                    let ids: Set<UUID> = [op.id, VCarveGenerator.deterministicID(op.id, salt: 1)]
                    return toolpaths.filter { ids.contains($0.sourceOperationID) }.compactMap(\.cuttingExtents)
                        .reduce(Rect2.empty) { $0.union(Rect2(x: $1.min.x, y: $1.min.y, width: $1.max.x - $1.min.x, height: $1.max.y - $1.min.y)) }
                }
                let p = extents(pocket), q = extents(plug)
                if !p.isEmpty, !q.isEmpty, p.min.x < q.max.x, q.min.x < p.max.x, p.min.y < q.max.y, q.min.y < p.max.y {
                    warn("Overlaps its pocket “\(pocket.name)”, and both are included in the output. Cut the plug from a separate "
                        + "board: turn off Include in output for one side before exporting the other.")
                }
            }
        }
        return issues
    }

    /// Chamfers that don't fit the profile cutting the same shapes from the same vector. A bevel on the profile's waste
    /// side is cut away with the waste; a top-edge bevel on the part's side slopes down into the part from the top of
    /// its wall, leaving a sharp lip. A bottom-edge bevel on the part's side is what bevels a part's (or a hole's) top
    /// edge before it's cut out.
    static func chamferIssues(_ project: Project) -> [JobIssue] {
        var issues: [JobIssue] = []
        let ops = project.operations.filter(\.enabled)
        for chamfer in ops {
            guard case let .chamfer(c) = chamfer.kind else { continue }
            let depth = c.startDepth + c.depth(with: chamfer.tool)
            for profile in ops {
                guard case let .profile(p) = profile.kind, p.side != .on, p.depth.cutDepth > depth - 1e-6,
                      !Set(profile.shapeIDs).isDisjoint(with: chamfer.shapeIDs) else { continue }
                let outsideCut = p.side == .outside
                let partSide: ChamferParams.Side = outsideCut ? .inside : .outside
                let what = outsideCut ? "the part it cuts out" : "the rim of the hole it cuts"
                let fix = "To bevel \(what), set Side to \(partSide.label) and Vector to Bottom edge."
                if c.side != partSide {
                    let half = c.side == .both ? "half of " : ""
                    issues.append(JobIssue(.warning, "“\(profile.name)” cuts \(p.side.rawValue) the same shapes, where \(half)this "
                        + "bevel lies, so it cuts the bevel away. \(fix)", operation: chamfer.name))
                } else if c.edge == .top {
                    issues.append(JobIssue(.warning, "“\(profile.name)” cuts these shapes on the same vector as this bevel's top edge, "
                        + "so the bevel slopes down from the top of the wall and leaves a sharp lip along it. \(fix)", operation: chamfer.name))
                }
            }
        }
        return issues
    }

    /// Edge profiles that reach the tabs of a cut-out that runs after them, on the same shapes: before the part is cut
    /// out they take the top off the tabs along the edge, leaving them thinner than set (or cutting through them). Run
    /// after the cut-out, the run-order check says so instead (`schedulingIssues`).
    static func edgeProfileIssues(_ project: Project) -> [JobIssue] {
        let u = project.displayUnits
        func fmt(_ mm: Double) -> String { "\(u.format(mm)) \(u.symbol)" }
        var issues: [JobIssue] = []
        let ops = project.operations.filter(\.enabled)
        for (i, edge) in ops.enumerated() {
            guard case let .edgeProfile(e) = edge.kind else { continue }
            let depth = e.depth(for: edge.tool)
            for cutOut in ops[(i + 1)...] {
                guard case let .profile(p) = cutOut.kind, p.side != .on, p.tabs.enabled, p.tabs.count > 0,
                      project.stock.rotary == nil, p.depth.cutDepth >= project.stock.thickness - 0.01,
                      !Set(cutOut.shapeIDs).isDisjoint(with: edge.shapeIDs), !OperationScheduler.clearsTabs(depth, of: cutOut) else { continue }
                let top = max(0, OperationScheduler.tabTop(p))
                let left = p.depth.cutDepth - depth
                let what = left > 1e-6 ? "takes the top off them along the edge, leaving them \(fmt(left)) thick there instead of "
                    + "\(fmt(p.tabs.thickness))" : "cuts through them along the edge, so they won't hold the part"
                issues.append(JobIssue(.warning, "At \(fmt(depth)) deep, its profile reaches below the tops of the tabs “\(cutOut.name)” "
                    + "leaves (\(fmt(top)) below the material top), so it \(what). Make the profile shallower than the tabs' tops, "
                    + "or the tabs thinner.", operation: edge.name))
            }
        }
        return issues
    }

    /// An empty toolpath saying why, when the operation's bit is one its kind of toolpath can't cut with
    /// (`CAMOperation.toolRefusal`).
    static func refusal(_ op: CAMOperation, context: GenerationContext) -> Toolpath? {
        guard let why = op.toolRefusal else { return nil }
        return ToolpathBuilder(stock: context.stock, tool: op.tool, startXY: nil)
            .build(id: op.id, name: op.name, tool: op.tool, rpm: op.tool.cutting.spindleRPM, warnings: [why])
    }

    /// The operation's own toolpath (the last, after any clearing) with the warning, for Checks, that its passes can't
    /// all hold the cut direction chosen (`OperationKind.passDirectionNote`).
    static func withDirectionNote(_ tp: Toolpath, operation op: CAMOperation) -> Toolpath {
        guard tp.id == op.id, let note = op.kind.passDirectionNote, tp.cuttingExtents != nil else { return tp }
        var t = tp
        t.warnings.append(note)
        return t
    }

    public static func generate(_ op: CAMOperation, shapes: [DesignShape], context: GenerationContext) -> [Toolpath] {
        if let refused = refusal(op, context: context) { return [refused] }
        switch op.kind {
        case let .profile(p):
            return [ProfileGenerator.generate(op: op, params: p, shapes: shapes, context: context)]
        case let .pocket(p):
            return PocketGenerator.generate(op: op, params: p, shapes: shapes, context: context)
        case let .drill(p):
            return [DrillGenerator.generate(op: op, params: p, shapes: shapes, context: context)]
        case let .vcarve(p):
            return VCarveGenerator.generate(op: op, params: p, clearanceTool: p.clearanceTool, shapes: shapes, context: context)
        case let .rough3D(p):
            return [Model3DGenerator.rough(op: op, params: p, shapes: shapes, context: context)]
        case let .finish3D(p):
            return [Model3DGenerator.finish(op: op, params: p, shapes: shapes, context: context)]
        case let .rounding(p):
            return [RoundingGenerator.generate(op: op, params: p, context: context)]
        case let .rotaryFinish(p):
            return [Rotary3DGenerator.generate(op: op, params: p, shapes: shapes, context: context)]
        case let .rotaryRough(p):
            return [Rotary3DRoughing.generate(op: op, params: p, shapes: shapes, context: context).toolpath]
        case let .chamfer(p):
            return [ChamferGenerator.generate(op: op, params: p, shapes: shapes, context: context)]
        case let .fluting(p):
            return [FlutingGenerator.generate(op: op, params: p, shapes: shapes, context: context)]
        case let .prism(p):
            return [PrismGenerator.generate(op: op, params: p, shapes: shapes, context: context)]
        case let .edgeProfile(p):
            return [EdgeProfileGenerator.generate(op: op, params: p, shapes: shapes, context: context)]
        case let .moulding(p):
            return MouldingGenerator.generate(op: op, params: p, shapes: shapes, context: context)
        }
    }

    /// Different bits under one T number. The post writes a tool change only when the number changes (and Mach4's
    /// M6 macro only stops when it differs from the loaded tool), so a toolpath that follows another with the same
    /// number but a different bit cuts with the wrong bit. Elsewhere in the run it's still wrong on a tool changer
    /// (one bit per pocket and length offset) and a trap with manual changes: Optimize Run Order treats one number
    /// as one bit, so it may put the two back to back.
    static func sharedToolNumberIssues(_ toolpaths: [Toolpath], machine: MachineProfile) -> [JobIssue] {
        var issues: [JobIssue] = []
        func label(_ t: Tool) -> String { t.name.isEmpty ? "T\(t.number)" : t.name }
        // The toolpath whose bit was loaded at the last tool change the G-code writes.
        var loaded: Toolpath?
        // The first toolpath for each distinct bit, per number, and the bits already reported.
        var bits: [Int: [Toolpath]] = [:]
        var reported: [Int: [Tool]] = [:]
        for tp in toolpaths {
            let n = tp.tool.number
            if let l = loaded, l.tool.number == n {
                if !l.tool.isSameBit(as: tp.tool) {
                    issues.append(JobIssue(.error, "Uses T\(n) for \(label(tp.tool)), but “\(l.name)” just before it uses T\(n) "
                        + "for \(label(l.tool)). No tool change is written between them, so this would cut with the "
                        + "\(label(l.tool)). Give each bit its own tool number.", operation: tp.name))
                    reported[n, default: []].append(tp.tool)
                }
            } else {
                loaded = tp
            }
            let known = bits[n, default: []]
            guard !known.contains(where: { $0.tool.isSameBit(as: tp.tool) }) else { continue }
            bits[n, default: []].append(tp)
            guard let other = known.first, !reported[n, default: []].contains(where: { $0.isSameBit(as: tp.tool) }) else { continue }
            reported[n, default: []].append(tp.tool)
            if machine.toolChange == .atc {
                issues.append(JobIssue(.error, "Uses T\(n) for \(label(tp.tool)), but “\(other.name)” uses T\(n) for "
                    + "\(label(other.tool)). The tool changer holds one bit per number, so one of them would cut with the "
                    + "wrong bit. Give each bit its own tool number.", operation: tp.name))
            } else {
                issues.append(JobIssue(.warning, "Uses T\(n) for \(label(tp.tool)), but “\(other.name)” uses T\(n) for "
                    + "\(label(other.tool)). Give each bit its own tool number: the machine and Optimize Run Order treat "
                    + "one number as one bit, so a different run order could skip this tool change.", operation: tp.name))
            }
        }
        return issues
    }

    /// Cutting inside a clamp zone is an error; clamps taller than the safe Z make the post's moves between
    /// toolpaths unsafe.
    static func keepOutIssues(_ tp: Toolpath, keepOuts: [KeepOut], clearanceZ: Double) -> [JobIssue] {
        guard !keepOuts.isEmpty else { return [] }
        var issues: [JobIssue] = []
        var hit = false
        tp.forEachMotion { s, m in
            guard !hit, m.kind != .rapid, m.kind != .dwell else { return }
            if keepOuts.contains(where: { LinkOptimizer.crosses($0, from: s.xy, to: m.end.xy, radius: tp.tool.radius) }) { hit = true }
        }
        if hit { issues.append(JobIssue(.error, "Cuts into a clamp / keep-out zone.", operation: tp.name)) }
        if let tall = keepOuts.map(\.height).max(), tall >= clearanceZ {
            issues.append(JobIssue(.warning, "A clamp is as tall as the safe Z; raise Safe Z above the clamps.", operation: tp.name))
        }
        return issues
    }

    /// Safety and sanity checks: material thickness, tool reach, machine travel, spindle range, rapids into stock.
    public static func validate(_ tp: Toolpath, operation op: CAMOperation, project: Project, checkTravel: Bool = true) -> [JobIssue] {
        var issues: [JobIssue] = []
        let stock = project.stock
        let machine = project.machine
        let units = project.displayUnits
        func fmt(_ mm: Double) -> String { "\(units.format(mm)) \(units.symbol)" }

        guard let ext = tp.cuttingExtents else {
            if !tp.motions.isEmpty || tp.warnings.isEmpty {
                issues.append(JobIssue(.warning, "Toolpath is empty.", operation: tp.name))
            }
            return issues
        }
        let deepest = -ext.min.z
        if let blank = stock.rotary {
            // Cutting past the axis is fine (a hole through a dowel); past the far side the tool is in the air.
            let past = deepest - (blank.topRadius + blank.radius)
            if past > 1 {
                issues.append(JobIssue(.warning, "Cuts \(fmt(past)) past the far side of the blank.", operation: tp.name))
            } else if past > 1e-6 {
                issues.append(JobIssue(.info, "Cuts through the blank.", operation: tp.name))
            }
        }
        // Material thickness: through-cuts are fine, but flag anything that digs well into the spoilboard.
        let breakthrough = stock.rotary == nil ? deepest - stock.thickness : 0
        if breakthrough > 0.04.inch {
            issues.append(JobIssue(.warning, "Cuts \(fmt(breakthrough)) into the spoilboard (material is \(fmt(stock.thickness)) thick).",
                                   operation: tp.name))
        } else if breakthrough > 1e-6 {
            issues.append(JobIssue(.info, "Cuts through the material (\(fmt(breakthrough)) into the spoilboard).", operation: tp.name))
        }
        // Tool reach. 3D rotary roughing and finishing measure their own, from the stock they cut rather than the sheet's top.
        // Flutes that follow a model go no deeper than their depth below its surface (the 3D finish before them has
        // cleared the wood above it), so that's what the bit's cutting length has to reach, not the depth below the
        // sheet's top or the blank's surface (#139).
        var reach = deepest
        if case let .fluting(f) = op.kind, f.surfaceModelID != nil { reach = f.depth }
        // Past the flutes the shank rubs, which is worth a clear warning; past the stickout a 2.5D cut drives the collet
        // nut into the stock, which is an error (#151). A 3D surface can fall away from the collet, so there it stays the
        // warning.
        if op.kind.is3D && op.kind.turnsWholeBlank {
        } else if !op.kind.is3D, reach > tp.tool.stickout + 1e-6 {
            issues.append(JobIssue(.error, "Depth \(fmt(reach)) is more than \(tp.tool.name) sticks out of the collet "
                + "(\(fmt(tp.tool.stickout))), so the collet nut would hit the stock. Cut shallower, or let the bit out "
                + "further and set its stickout.", operation: tp.name))
        } else if reach > tp.tool.fluteLength + 1e-6 {
            issues.append(JobIssue(.warning, "Depth \(fmt(reach)) exceeds the cutting length of \(tp.tool.name) (\(fmt(tp.tool.fluteLength))), "
                + "so the shank rubs below the flutes.", operation: tp.name))
        }
        // On rotary stock the chuck and tailstock are past the ends of the blank: the whole cutter stays inside it.
        if stock.rotary != nil, ext.min.x < tp.tool.radius - 1e-6 || ext.max.x > stock.width - tp.tool.radius + 1e-6 {
            issues.append(JobIssue(.error, "Cuts past an end of the blank, where the chuck or tailstock is. Keep the cutter "
                + "inside the blank's length, clear of the chuck jaws.", operation: tp.name))
        }
        // Outside the stock in XY (allow the tool radius for outside profiles). A wrapped sheet's Y goes round the
        // blank, so past its top or bottom edge a cut just carries on round.
        let wrapped = tp.wrapDiameter != nil
        let margin = tp.tool.radius + 0.01
        let sb = stock.bounds.insetBy(-margin)
        if ext.min.x < sb.min.x || ext.max.x > sb.max.x || (!wrapped && (ext.min.y < sb.min.y || ext.max.y > sb.max.y)) {
            issues.append(JobIssue(.warning, "Toolpath extends beyond the material edges.", operation: tp.name))
        }
        // Machine travel (relative to the work origin, assuming the material sits inside the work area), in the blank's
        // frame: on a rotary axis along Y, the blank's length takes Y travel and its width X. A wrapped toolpath doesn't
        // move across the blank.
        let lo = stock.toWork(Vec3(ext.min.x, ext.min.y, ext.min.z))
        let hi = stock.toWork(Vec3(ext.max.x, ext.max.y, ext.max.z))
        let travel = RotaryFrame(stock: stock, machine: machine).blankTravel(machine.travel)
        if checkTravel, hi.x - lo.x > travel.x || (!wrapped && hi.y - lo.y > travel.y) {
            issues.append(JobIssue(.error, "Toolpath is larger than the \(machine.displayName) work area.", operation: tp.name))
        }
        if let blank = stock.rotary {
            // Safe Z above the spoilboard: the axis height, the blank's radius and the clearance.
            if let center = machine.rotary?.centerHeight, center + blank.radius + stock.clearanceHeight + tp.tool.stickout > machine.travel.z {
                issues.append(JobIssue(.warning, "Rotary centre height + blank radius + clearance + tool stickout may exceed the "
                    + "Z travel (\(fmt(machine.travel.z))).", operation: tp.name))
            }
        } else if stock.thickness + stock.clearanceHeight + tp.tool.stickout > machine.travel.z {
            issues.append(JobIssue(.warning, "Material + clearance + tool stickout may exceed the Z travel (\(fmt(machine.travel.z))).",
                                   operation: tp.name))
        }
        // Spindle speed.
        if machine.spindle == .vfdSpindle && (tp.spindleRPM < machine.minRPM || tp.spindleRPM > machine.maxRPM) {
            issues.append(JobIssue(.warning, "Spindle speed \(Int(tp.spindleRPM)) RPM is outside the spindle's \(Int(machine.minRPM))–\(Int(machine.maxRPM)) RPM range.",
                                   operation: tp.name))
        }
        // Chip load against the chart for this material (thin chips rub and burn; very thick ones tear).
        issues.append(contentsOf: chipLoadIssues(tp, project: project, operation: op))
        // Feeds.
        let maxFeed = tp.motions.filter { $0.kind != .rapid && $0.kind != .dwell }.map(\.feed).max() ?? 0
        if maxFeed > machine.maxFeedRate + 1e-6 {
            issues.append(JobIssue(.warning, "Feed \(fmt(maxFeed))/min exceeds the machine's configured maximum.", operation: tp.name))
        }
        // Rapids that move sideways below the material top would crash into stock.
        var crash = false
        tp.forEachMotion { s, m in
            if m.kind == .rapid, s.xy.distance(to: m.end.xy) > 1e-6, min(s.z, m.end.z) < -1e-6 { crash = true }
        }
        if crash {
            issues.append(JobIssue(.error, "A rapid move travels sideways below the material surface.", operation: tp.name))
        }
        return issues
    }
}
