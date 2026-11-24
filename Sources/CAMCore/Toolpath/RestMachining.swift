import Foundation

/// Rest machining from earlier toolpaths: which toolpaths a rest toolpath follows, and what Checks says about them.
///
/// - **3D rest finishing** (`Finish3DStrategy.rest`) follows earlier 3D finishing toolpaths on the same model: the ones
///   its `RestSettings.references` names, or automatically every enabled one before it in the run order whose bit is
///   larger (`references(for:in:)`). Only toolpaths that finish the whole surface count: not a pencil pass (which only
///   runs along creases), and not 3D roughing (whose layers leave steps and an allowance).
/// - **Pocket rest from earlier toolpaths** (`PocketParams.restFromEarlier`) follows the enabled pocket toolpaths before
///   it that cut one of its shapes, from its start depth or higher down to its depth or deeper, with a larger bit
///   (`pocketReferences(for:in:)`).
///
/// A rest toolpath has to run after what it follows, so Optimize Run Order keeps it there (`OperationScheduler`).
public enum RestMachining {
    /// What a rest toolpath follows.
    public struct References: Sendable, Equatable {
        /// The toolpaths it follows, in run order: its references that are in the project, including any that are off
        /// or run after it (each with a warning).
        public var operations: [CAMOperation] = []
        /// What Checks says about them: a reference that's off, runs after it, has been deleted or isn't a whole-surface
        /// finish, or that there are none.
        public var warnings: [String] = []
        /// Why the rest toolpath can't cut at all, or nil: a reference whose bit isn't larger than its own, or a bit it
        /// can't rest with.
        public var refusal: String?
        /// The references are picked automatically (not listed by hand).
        public var isAutomatic = true

        public init() {}
    }

    static func label(_ t: Tool) -> String { t.name.isEmpty ? "T\(t.number)" : t.name }

    /// How far into a crevice a bit reaches, for comparing a rest bit with its references: a ball nose's radius, a
    /// tapered ball nose's tip ball, any other bit's radius.
    public static func tipRadius(_ tool: Tool) -> Double {
        switch tool.shape {
        case .ballNose: tool.radius
        case .taperedBallNose: tool.tipDiameter > 1e-6 ? min(tool.tipDiameter, tool.diameter) / 2 : tool.radius
        default: tool.radius
        }
    }

    /// A 3D finishing toolpath that finishes the whole surface inside its boundary, so it can be a reference.
    public static func finishesSurface(_ op: CAMOperation) -> Bool {
        guard case let .finish3D(p) = op.kind else { return false }
        return p.strategy != .pencil
    }

    /// The 3D finishing toolpaths a 3D rest pass could follow, for the inspector: every one that finishes the same
    /// model's surface, other than itself, in run order.
    public static func candidates(for op: CAMOperation, in project: Project) -> [CAMOperation] {
        let models = Set(project.shapes(for: op).filter { $0.modelSpec != nil }.map(\.id))
        return project.operations.filter { $0.id != op.id && finishesSurface($0) && !models.isDisjoint(with: $0.shapeIDs) }
    }

    /// The toolpaths a 3D rest pass follows (empty for any other toolpath).
    public static func references(for op: CAMOperation, in project: Project) -> References {
        guard case let .finish3D(p) = op.kind, p.strategy == .rest else { return References() }
        var out = References()
        let tool = op.tool
        guard tool.shape == .ballNose || tool.shape == .taperedBallNose else {
            out.refusal = "Rest finishing needs a ball nose or a tapered ball nose: '\(label(tool))' is a \(tool.shape.label.lowercased())."
            return out
        }
        let ops = project.operations
        let index = ops.firstIndex { $0.id == op.id } ?? ops.count
        let models = Set(project.shapes(for: op).filter { $0.modelSpec != nil }.map(\.id))
        let size = tipRadius(tool)
        if let ids = p.restSettings.references {
            out.isAutomatic = false
            var seen = Set<UUID>()
            var missing = 0
            for id in ids where seen.insert(id).inserted {
                guard id != op.id, let k = ops.firstIndex(where: { $0.id == id }) else { missing += 1; continue }
                let ref = ops[k]
                guard finishesSurface(ref) else {
                    out.warnings.append("“\(ref.name)” isn't a 3D finishing toolpath that covers the surface, so it isn't counted as a "
                        + "reference. Choose a raster, waterline, steep-and-shallow or rest finish.")
                    continue
                }
                out.operations.append(ref)
                if models.isDisjoint(with: ref.shapeIDs) {
                    out.warnings.append("“\(ref.name)” doesn't finish the same model, so it leaves nothing for this toolpath to follow.")
                }
                if !ref.enabled {
                    out.warnings.append("“\(ref.name)”, one of its references, is turned off, so this job doesn't cut it. This rest pass "
                        + "still assumes it was cut first: turn it on, or make sure it was cut before.")
                }
                if k > index {
                    out.warnings.append("Runs before “\(ref.name)”, one of its references, so it would cut what that larger bit hasn't "
                        + "cut yet. Use Toolpaths ▸ Optimize Run Order to fix the order.")
                }
                if tipRadius(ref.tool) <= size + 1e-6 {
                    out.refusal = out.refusal ?? "'\(label(tool))' isn't smaller than '\(label(ref.tool))', the bit “\(ref.name)” finishes "
                        + "with, so it can't reach anywhere that one couldn't. A rest pass needs a smaller bit than each of its references."
                }
            }
            if missing > 0 {
                out.warnings.append(missing == 1 ? "One of its references has been deleted, so it isn't counted."
                                    : "\(missing) of its references have been deleted, so they aren't counted.")
            }
        } else {
            for ref in ops[..<min(index, ops.count)] where ref.enabled && finishesSurface(ref) && !models.isDisjoint(with: ref.shapeIDs)
                && tipRadius(ref.tool) > size + 1e-6 {
                out.operations.append(ref)
            }
        }
        if out.operations.isEmpty && out.refusal == nil {
            out.warnings.append(out.isAutomatic
                ? "No enabled 3D finishing toolpath on this model runs before this one with a larger bit, so there's nothing to rest "
                    + "from and it cuts nothing. Put it after the main finish, or choose its references."
                : "None of its references can be followed, so it cuts nothing.")
        }
        return out
    }

    /// The pocket toolpaths a pocket resting from earlier toolpaths follows (empty for any other toolpath).
    public static func pocketReferences(for op: CAMOperation, in project: Project) -> References {
        guard case let .pocket(p) = op.kind, p.restsFromEarlier else { return References() }
        var out = References()
        let ops = project.operations
        let index = ops.firstIndex { $0.id == op.id } ?? ops.count
        let shapes = Set(op.shapeIDs)
        for ref in ops[..<min(index, ops.count)] where ref.enabled && !shapes.isDisjoint(with: ref.shapeIDs) {
            guard case let .pocket(q) = ref.kind else { continue }
            if q.depth.cutDepth < p.depth.cutDepth - 1e-6 || q.depth.startDepth > p.depth.startDepth + 1e-6 {
                out.warnings.append("“\(ref.name)” doesn't cut these shapes as deep as this one, so it isn't counted: this toolpath "
                    + "clears what it leaves below it.")
                continue
            }
            guard ref.tool.diameter > op.tool.diameter + 1e-6 else { continue }
            out.operations.append(ref)
        }
        if out.operations.isEmpty {
            out.warnings.append("No enabled pocket toolpath before this one cuts these shapes as deep with a larger bit, so it clears the "
                + "whole pocket. Put it after the larger bit's pocket.")
        }
        return out
    }

    /// The operations `op` rests on, which have to run before it: its 3D rest references or the pockets it rests from.
    public static func dependencies(of op: CAMOperation, in project: Project) -> [UUID] {
        switch op.kind {
        case .finish3D: references(for: op, in: project).operations.map(\.id)
        case .pocket: pocketReferences(for: op, in: project).operations.map(\.id)
        default: []
        }
    }
}
