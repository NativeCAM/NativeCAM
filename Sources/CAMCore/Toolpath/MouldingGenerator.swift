import Foundation

/// Moulding toolpaths (`MouldingParams`): the profile swept along the rails (`MouldingSweep`) becomes a 3D model, which
/// `Model3DGenerator` roughs (when asked, with the roughing bit, as the operation's clearing toolpath) and finishes with
/// the operation's own bit and strategy, the boundary being the swept surface.
public enum MouldingGenerator {
    /// The swept surface of `op` among `shapes` (the operation's profile and rails), with any warning about it; or why
    /// it can't be made.
    public static func surface(op: CAMOperation, params: MouldingParams, shapes: [DesignShape], tolerance: Double = 0.01,
                               units: LengthUnit = .mm) -> Result<(shape: DesignShape, sweep: MouldingSweep, warnings: [String]), MouldingSweep.Refusal> {
        guard let profile = shapes.first(where: { $0.id == params.profileID }) else {
            return .failure(.init(message: "Choose the moulding's profile: the open vector drawn as its cross-section."))
        }
        let lines = profile.polylines(tolerance: tolerance)
        guard lines.count == 1, let line = lines.first else {
            return .failure(.init(message: "The profile '\(profile.name)' is \(lines.count) separate vectors; a moulding's profile "
                + "is one open line."))
        }
        let rails = shapes.filter { $0.id != params.profileID && $0.modelSpec == nil }.flatMap { $0.polylines(tolerance: tolerance) }
        do {
            let section = try MouldingSweep.crossSection(line, flipped: params.flipped, mirrored: params.mirrored)
            let sweep = try MouldingSweep.sweep(section: section, rails: rails, side: params.side)
            var warnings: [String] = []
            if let c = sweep.clampedWidth {
                func fmt(_ mm: Double) -> String { "\(units.format(mm)) \(units.symbol)" }
                warnings.append("The rail turns tighter than the profile is wide: where it turns toward the profile the surface "
                    + "would fold over itself, so the profile is cut back there (to \(fmt(c)) across at the tightest, of its "
                    + "\(fmt(sweep.profileWidth))) and the material beyond is left standing. Use a narrower profile, put it on "
                    + "the rail's other side, or ease the curve.")
            }
            return .success((sweep.modelShape(name: "\(op.name) surface"), sweep, warnings))
        } catch {
            return .failure(error)
        }
    }

    static func generate(op: CAMOperation, params: MouldingParams, shapes: [DesignShape], context: GenerationContext) -> [Toolpath] {
        let made = surface(op: op, params: params, shapes: shapes, tolerance: context.flattenTolerance, units: context.units)
        let model: DesignShape, warnings: [String]
        switch made {
        case let .failure(refusal):
            return [ToolpathBuilder(stock: context.stock, tool: op.tool, startXY: nil)
                .build(id: op.id, name: op.name, tool: op.tool, rpm: op.tool.cutting.spindleRPM, warnings: [refusal.message])]
        case let .success(s):
            model = s.shape
            warnings = s.warnings
        }
        var out: [Toolpath] = []
        if let rough = params.roughing {
            var roughOp = op
            roughOp.tool = rough.tool
            var tp = Model3DGenerator.rough(op: roughOp, params: rough.rough3D, shapes: [model], context: context)
            tp.id = VCarveGenerator.deterministicID(op.id, salt: 1)
            tp.name = "\(op.name) – roughing"
            out.append(tp)
        }
        var finish = params.finish
        finish.boundary = .model
        var tp = Model3DGenerator.finish(op: op, params: finish, shapes: [model], context: context)
        tp.warnings = warnings + tp.warnings
        out.append(tp)
        return out
    }
}

public extension Project {
    /// The swept surface of every enabled moulding that can be swept, as placed 3D models (for the 3D preview and the
    /// canvas).
    var mouldingSurfaces: [DesignShape] {
        operations.compactMap { op -> DesignShape? in
            guard op.enabled, case let .moulding(p) = op.kind,
                  case let .success(s) = MouldingGenerator.surface(op: op, params: p, shapes: shapes(for: op)) else { return nil }
            return s.shape
        }
    }
}
