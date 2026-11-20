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

    public init(stock: Stock, machine: MachineProfile, flattenTolerance: Double = 0.01, arcTolerance: Double = 0.005) {
        self.stock = stock
        self.machine = machine
        self.flattenTolerance = flattenTolerance
        self.arcTolerance = arcTolerance
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

/// Turns a project into ordered toolpaths and checks them against the material and machine.
public enum CAMEngine {
    public static func generate(_ project: Project, operationIDs: Set<UUID>? = nil) -> JobResult {
        let ctx = GenerationContext(stock: project.stock, machine: project.machine,
                                    flattenTolerance: 0.01,
                                    arcTolerance: min(0.005, project.machine.arcFitTolerance / 2))
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
        for op in project.operations where op.enabled && (operationIDs?.contains(op.id) ?? true) {
            let shapes = project.shapes(for: op).filter { !$0.isKeepOut }
            if shapes.isEmpty {
                issues.append(JobIssue(.warning, "No shapes selected.", operation: op.name))
                continue
            }
            // Flat jobs cut once; rotary jobs once per index angle, each on its own face model.
            let angles: [Double?] = stock.rotary == nil ? [nil] : op.rotaryAngles
            for (position, angle) in angles.enumerated() {
                let face = angle.map(RotaryIndex.normalized) ?? 0
                var model = models.removeValue(forKey: face) ?? newModel()
                defer { models[face] = model }
                var opContext = ctx
                let snapshot = model.grid
                opContext.materialTop = { p, r in Double(LinkOptimizer.maxHeight(snapshot, around: p, radius: r)) }
                opContext.keepOuts = keepOuts
                let generated = generate(op, shapes: shapes, context: opContext)
                for (role, var tp) in generated.enumerated() {
                    if let angle {
                        tp.indexAngle = angle
                        tp.operationID = op.id
                        tp.name += " @ \(RotaryIndex.label(angle))"
                        if position > 0 { tp.id = RotaryIndex.toolpathID(operation: op.id, role: role, position: position) }
                    }
                    if stock.retract == .minimum {
                        let settings = LinkOptimizer.Settings(safeDistance: stock.safeDistance, clearanceZ: clearanceZ,
                                                              stayDownLimit: max(3 * tp.tool.diameter, 10), floorZ: -stock.thickness,
                                                              keepOuts: keepOuts)
                        tp = LinkOptimizer.optimize(tp, model: &model, settings: settings)
                    } else {
                        tp.forEachMotion { s, m in model.apply(m, from: s, tool: tp.tool) }
                    }
                    issues.append(contentsOf: keepOutIssues(tp, keepOuts: keepOuts, clearanceZ: clearanceZ))
                    if project.machine.outputArcs {
                        tp = ArcFitter.fit(tp, tolerance: project.machine.arcFitTolerance)
                    }
                    issues.append(contentsOf: tp.warnings.map { JobIssue(.warning, $0, operation: tp.name) })
                    issues.append(contentsOf: validate(tp, operation: op, project: project))
                    toolpaths.append(tp)
                }
            }
        }
        issues.append(contentsOf: checkModelBoundaries(project))
        issues.append(contentsOf: sharedToolNumberIssues(toolpaths, machine: project.machine))
        if let reason = PostProcessors.unavailableReason(for: project.machine) { issues.append(JobIssue(.error, reason)) }
        issues.append(contentsOf: RotaryIndex.issues(project, toolpaths: toolpaths))
        if let post = PostProcessors.post(for: project), !(post is AvidMach4Post) {
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
        // Point out (never apply) a run order that fixes dependencies or needs fewer tool changes.
        var reorder: OperationScheduler.Result?
        if operationIDs == nil {
            let r = OperationScheduler.optimize(project)
            let byID = Dictionary(project.operations.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for late in r.outOfOrder {
                guard let early = byID[late.operation], let later = byID[late.mustPrecede] else { continue }
                if case .finish3D = later.kind {
                    issues.append(JobIssue(.warning, "Runs before its roughing (“\(early.name)”). "
                        + "Use Toolpaths ▸ Optimize Run Order to fix the order.", operation: later.name))
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
        return JobResult(toolpaths: toolpaths, issues: issues, estimate: estimate, reorder: reorder)
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

    public static func generate(_ op: CAMOperation, shapes: [DesignShape], context: GenerationContext) -> [Toolpath] {
        switch op.kind {
        case let .profile(p):
            return [ProfileGenerator.generate(op: op, params: p, shapes: shapes, context: context)]
        case let .pocket(p):
            return [PocketGenerator.generate(op: op, params: p, shapes: shapes, context: context)]
        case let .drill(p):
            return [DrillGenerator.generate(op: op, params: p, shapes: shapes, context: context)]
        case let .vcarve(p):
            return VCarveGenerator.generate(op: op, params: p, clearanceTool: p.clearanceTool, shapes: shapes, context: context)
        case let .rough3D(p):
            return [Model3DGenerator.rough(op: op, params: p, shapes: shapes, context: context)]
        case let .finish3D(p):
            return [Model3DGenerator.finish(op: op, params: p, shapes: shapes, context: context)]
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

    static func chipLoadIssues(_ tp: Toolpath, project: Project) -> [JobIssue] {
        let tool = tp.tool
        guard ChipLoad.applies(to: tool), tp.spindleRPM > 0, tool.fluteCount > 0 else { return [] }
        let material = project.stock.material
        let r = ChipLoad.range(material, diameter: tool.diameter)
        let chip = tool.cutting.feedRate / (tp.spindleRPM * Double(tool.fluteCount))
        let inch = { (mm: Double) in String(format: "%.4f in", mm / LengthUnit.mmPerInch) }
        let units = project.displayUnits
        let rec = ChipLoad.recommend(for: tool, material: material, machine: project.machine)
        let suggestion = "Try \(units.format(rec.feed, decimals: units == .inch ? 0 : 0)) \(units.feedSymbol) at \(Int(rec.rpm.rounded())) RPM."
        // Ball and bull noses finish at light engagement, so allow them a little below the end-mill floor.
        let floor = r.lowerBound * (tool.shape == .flatEndMill ? 0.9 : 0.8)
        if chip < floor {
            return [JobIssue(.warning, "Chip load \(inch(chip)) is below the \(inch(r.lowerBound))–\(inch(r.upperBound)) range for this bit in \(material.label.lowercased()); thin chips rub, burn and dull the bit. \(suggestion)",
                             operation: tp.name)]
        }
        if chip > r.upperBound * 1.25 {
            return [JobIssue(.info, "Chip load \(inch(chip)) is above the \(inch(r.lowerBound))–\(inch(r.upperBound)) range for this bit in \(material.label.lowercased()); expect a rougher edge. \(suggestion)",
                             operation: tp.name)]
        }
        return []
    }

    /// Safety and sanity checks: material thickness, tool reach, machine travel, spindle range, rapids into stock.
    public static func validate(_ tp: Toolpath, operation op: CAMOperation, project: Project) -> [JobIssue] {
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
            let past = deepest - blank.diameter
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
        // Tool reach.
        if deepest > tp.tool.fluteLength + 1e-6 {
            issues.append(JobIssue(.warning, "Depth \(fmt(deepest)) exceeds the cutting length of \(tp.tool.name) (\(fmt(tp.tool.fluteLength))).",
                                   operation: tp.name))
        }
        // On rotary stock the chuck and tailstock are past the ends of the blank: the whole cutter stays inside it.
        if stock.rotary != nil, ext.min.x < tp.tool.radius - 1e-6 || ext.max.x > stock.width - tp.tool.radius + 1e-6 {
            issues.append(JobIssue(.error, "Cuts past an end of the blank, where the chuck or tailstock is. Keep the cutter "
                + "inside the blank's length, clear of the chuck jaws.", operation: tp.name))
        }
        // Outside the stock in XY (allow the tool radius for outside profiles).
        let margin = tp.tool.radius + 0.01
        let sb = stock.bounds.insetBy(-margin)
        if ext.min.x < sb.min.x || ext.min.y < sb.min.y || ext.max.x > sb.max.x || ext.max.y > sb.max.y {
            issues.append(JobIssue(.warning, "Toolpath extends beyond the material edges.", operation: tp.name))
        }
        // Machine travel (relative to the work origin, assuming the material sits inside the work area).
        let lo = stock.toWork(Vec3(ext.min.x, ext.min.y, ext.min.z))
        let hi = stock.toWork(Vec3(ext.max.x, ext.max.y, ext.max.z))
        if hi.x - lo.x > machine.travel.x || hi.y - lo.y > machine.travel.y {
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
        issues.append(contentsOf: chipLoadIssues(tp, project: project))
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
