import Foundation

/// Settings shared by every generator for one run.
public struct GenerationContext: Sendable {
    public var stock: Stock
    public var machine: MachineProfile
    /// Chord tolerance when flattening design curves, mm.
    public var flattenTolerance: Double
    /// Arc tolerance for Clipper's round joins, mm.
    public var arcTolerance: Double

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

    public var hasErrors: Bool { issues.contains { $0.severity == .error } }

    public func estimatedSeconds(rapidRate: Double) -> Double {
        toolpaths.reduce(0) { $0 + $1.estimatedSeconds(rapidRate: rapidRate) }
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
        for op in project.operations where op.enabled && (operationIDs?.contains(op.id) ?? true) {
            let shapes = project.shapes(for: op)
            if shapes.isEmpty {
                issues.append(JobIssue(.warning, "No shapes selected.", operation: op.name))
                continue
            }
            let generated = generate(op, shapes: shapes, context: ctx)
            for var tp in generated {
                if project.machine.outputArcs {
                    tp = ArcFitter.fit(tp, tolerance: project.machine.arcFitTolerance)
                }
                issues.append(contentsOf: tp.warnings.map { JobIssue(.warning, $0, operation: tp.name) })
                issues.append(contentsOf: validate(tp, operation: op, project: project))
                toolpaths.append(tp)
            }
        }
        issues.append(contentsOf: checkModelBoundaries(project))
        return JobResult(toolpaths: toolpaths, issues: issues)
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
        // Material thickness: through-cuts are fine, but flag anything that digs well into the spoilboard.
        let breakthrough = deepest - stock.thickness
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
        if stock.thickness + stock.clearanceHeight + tp.tool.stickout > machine.travel.z {
            issues.append(JobIssue(.warning, "Material + clearance + tool stickout may exceed the Z travel (\(fmt(machine.travel.z))).",
                                   operation: tp.name))
        }
        // Spindle speed.
        if machine.spindle == .vfdSpindle && (tp.spindleRPM < machine.minRPM || tp.spindleRPM > machine.maxRPM) {
            issues.append(JobIssue(.warning, "Spindle speed \(Int(tp.spindleRPM)) RPM is outside the spindle's \(Int(machine.minRPM))–\(Int(machine.maxRPM)) RPM range.",
                                   operation: tp.name))
        }
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
