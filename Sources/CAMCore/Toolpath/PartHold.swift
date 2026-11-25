import Foundation

/// Keeps a 3D toolpath from cutting a part free before the tabbed cut-out that's meant to hold it (#155).
///
/// With Boundary ▸ Selected vectors or Whole material, 3D roughing and finishing cut everything round the model down to
/// the model's base. A model as deep as the board puts that floor on the board's bottom face, so the 3D pass cuts the
/// part free, tabs and all, before its profile cut-out runs. When the job has a tabbed cut-out through the material
/// whose part the 3D toolpath reaches, the toolpath's floor is held a tab thickness (the thickest such cut-out's)
/// above the material's bottom, across the whole pass: the part stays joined to the board, as the tabs would hold it,
/// whichever runs first. Below that the model is left for the cut-out. When the floor can't be held (tabs as thick as
/// the material), the job's checks make it an error instead (`CAMEngine`).
public enum PartHold {
    public struct Hold: Sendable, Equatable {
        /// The lowest design Z (0 = material top) the 3D toolpath may cut to.
        public var z: Double
        /// The tab thickness held, mm.
        public var tabThickness: Double
        /// The cut-out whose tabs set it.
        public var cutOut: String
        /// Whether the floor can be held: false when the tabs are as thick as the material, so holding it would leave
        /// nothing to cut.
        public var possible: Bool { z < -0.01 }
    }

    /// Whether a profile leaves tabs that hold the part it cuts out. The one place that decides it, so tabs placed by
    /// hand only need to change this: a tab count alone doesn't say whether any tabs are cut.
    public static func holdsPart(_ p: ProfileParams) -> Bool {
        p.side != .on && p.tabs.enabled && p.tabs.count > 0 && p.tabs.thickness > 1e-6
    }

    /// Whether `op` is a profile through the flat material that leaves tabs: a cut-out its part stays on.
    public static func isTabbedCutOut(_ op: CAMOperation, thickness: Double) -> ProfileParams? {
        guard op.enabled, case let .profile(p) = op.kind, holdsPart(p), p.depth.cutDepth >= thickness - 0.01 else { return nil }
        return p
    }

    /// A flat 3D roughing or finishing's boundary, its allowance and its margin round selected vectors.
    static func boundary(of op: CAMOperation) -> (boundary: ModelBoundary, allowance: Double, margin: Double)? {
        switch op.kind {
        case let .rough3D(p): (p.boundary, p.allowance, p.boundaryMargin ?? Rough3DParams.autoMargin(tool: op.tool))
        case let .finish3D(p): (p.boundary, p.allowance, p.boundaryMargin ?? Finish3DParams.autoMargin(tool: op.tool))
        default: nil
        }
    }

    /// The lowest a 3D toolpath could cut, unheld: its models' base plus the allowance (design Z). nil for other kinds.
    static func unheldFloor(_ op: CAMOperation, in project: Project) -> Double? {
        guard let b = boundary(of: op) else { return nil }
        guard let base = project.shapes(for: op).compactMap({ $0.modelSpec?.bottomZ }).min() else { return nil }
        return base + b.allowance
    }

    /// Whether a flat 3D toolpath, unheld, cuts round its model down to the material's bottom (a boundary of
    /// selected vectors or the whole material with the model's base there).
    public static func reachesBottom(_ op: CAMOperation, in project: Project) -> Bool {
        guard project.stock.rotary == nil, let b = boundary(of: op), b.boundary != .model,
              let floor = unheldFloor(op, in: project) else { return false }
        return floor <= -project.stock.thickness + 0.01
    }

    /// The floor `op` has to hold for the tabbed cut-outs whose parts it reaches, when it would otherwise cut below it;
    /// nil when there's nothing to hold (not a flat 3D roughing or finishing, no tabbed cut-out near it, or its floor
    /// is above the tabs anyway).
    public static func hold(for op: CAMOperation, in project: Project) -> Hold? {
        let stock = project.stock
        guard stock.rotary == nil, op.enabled, let b = boundary(of: op), let floor = unheldFloor(op, in: project) else { return nil }
        let shapes = project.shapes(for: op).filter { !$0.isKeepOut }
        // Where the toolpath can cut, per sheet: the whole sheet with Whole material, else its shapes' boxes grown by
        // how far past them it may go.
        let grow = op.tool.radius + (b.boundary == .vectors ? max(0, b.margin) : 0) + 0.01
        var reach: [(sheet: Int, rect: Rect2)] = []
        for s in shapes {
            let sheet = project.sheetIndex(of: s)
            if b.boundary == .material {
                let size = project.sheetSize(sheet)
                reach.append((sheet, Rect2(x: 0, y: 0, width: size.x, height: size.y)))
            } else if b.boundary == .vectors || s.modelSpec != nil {
                let r = s.bounds
                if !r.isEmpty { reach.append((sheet, r.insetBy(-grow))) }
            }
        }
        var best: (thickness: Double, name: String)?
        for cutOut in project.operations {
            guard cutOut.id != op.id, let p = isTabbedCutOut(cutOut, thickness: stock.thickness) else { continue }
            let near = project.shapes(for: cutOut).contains { s in
                let r = s.bounds
                let sheet = project.sheetIndex(of: s)
                return !r.isEmpty && reach.contains { $0.sheet == sheet && $0.rect.intersects(r) }
            }
            guard near else { continue }
            // Tabs whose tops are deeper than the material's bottom less their thickness (a cut-out into the
            // spoilboard) leave less, but a floor a whole tab thickness up holds at least as much as they do.
            if best.map({ p.tabs.thickness > $0.thickness }) ?? true { best = (p.tabs.thickness, cutOut.name) }
        }
        guard let best else { return nil }
        let z = min(0, -(stock.thickness - best.thickness))
        guard floor < z - 1e-6 else { return nil }
        return Hold(z: z, tabThickness: best.thickness, cutOut: best.name)
    }

    /// The Checks note for a held floor.
    static func note(_ hold: Hold, stock: Stock, units: LengthUnit) -> String {
        func fmt(_ mm: Double) -> String { "\(units.format(mm)) \(units.symbol)" }
        return "Holds its floor at \(fmt(-hold.z)) deep, \(fmt(hold.tabThickness)) above the material's bottom (the tab thickness "
            + "of “\(hold.cutOut)”), so it doesn't cut the part free before its tabs hold it. Below that the model is left for the "
            + "cut-out to finish."
    }

    /// The Checks error when the floor can't be held.
    static func impossible(_ hold: Hold, stock: Stock, units: LengthUnit) -> String {
        func fmt(_ mm: Double) -> String { "\(units.format(mm)) \(units.symbol)" }
        return "Cuts round the model to within a tab thickness of the material's bottom, which cuts the part free before "
            + "“\(hold.cutOut)” and its tabs hold it, and its floor can't be held a tab thickness up: the tabs are "
            + "\(fmt(hold.tabThickness)) thick in \(fmt(stock.thickness)) material. Make the tabs thinner, lift the model, or set "
            + "Boundary to Model outline."
    }

    /// The Checks error when a held toolpath still cuts below its floor.
    static func stillCutsThrough(_ hold: Hold, deepest: Double, units: LengthUnit) -> String {
        func fmt(_ mm: Double) -> String { "\(units.format(mm)) \(units.symbol)" }
        return "Cuts to \(fmt(deepest)) deep, below the floor held for the tabs of “\(hold.cutOut)” (\(fmt(-hold.z))), so it can "
            + "cut the part free before they hold it. Lift the model, or set Boundary to Model outline."
    }
}
