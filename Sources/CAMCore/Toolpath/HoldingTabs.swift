import Foundation

/// Holding tabs for 3D cut-outs (#173): strips of material a flat 3D roughing or finishing leaves under the tabs of the
/// cut-out that holds its part, so the part stays joined to the board while the 3D passes cut everywhere else to full
/// depth.
///
/// Before this, a 3D pass ahead of a tabbed cut-out held its whole floor a tab thickness above the material's bottom
/// (`PartHold`, #155), leaving a skin all round the model for the cut-out to cut through. Now each tab of that cut-out
/// becomes a raised strip in the 3D passes' targets (`Model3DGenerator.targets`): the tab's base length along the wall,
/// its top at the tab's top (plus the toolpath's allowance), from just inside the model's silhouette out past where the
/// 3D toolpath reaches. Roughing, adaptive clearing, finishing and rest finishing all cut from those targets, so they
/// can't disagree; finishing rolls over the strips.
///
/// There's one source of truth: the cut-out's own `TabSettings`. Tabs placed by hand are used where they are; evenly
/// spaced tabs are placed at fixed points of each drawn outline (`evenMarks`) rather than from wherever the loop is
/// entered, and the cut-out is cut with exactly those (`anchoredMarks`), so its tabs land on the strips whatever order
/// the job runs in. Plain 2D profiles are cut as before. Triangular tabs get a flat strip at their full height.
///
/// Where strips can't be applied (Whole material, a tab on a narrow part of the silhouette, a model thinner than the
/// tab where it joins, or anything ambiguous), #166's whole-floor hold stays, with a note saying why. The floor is never
/// cut through without one or the other.
public enum HoldingTabs {
    /// One tab's strip, in design coordinates.
    public struct Strip: Sendable, Equatable {
        /// The tab's middle on the cut-out's drawn wall.
        public var centre: Vec2
        /// Along the wall (unit).
        public var tangent: Vec2
        /// Out of the part, away from the model (unit).
        public var normal: Vec2
        /// The tab's base length along the wall, mm.
        public var width: Double
        /// How far the strip reaches in from the wall (to just inside the model's silhouette), and out from it (past
        /// where the 3D toolpath reaches), mm.
        public var inner: Double
        public var outer: Double
        /// The tab's top (design Z).
        public var top: Double

        /// Whether `p` is inside the strip, `shrink` in from its sides (negative grows it).
        public func contains(_ p: Vec2, shrink: Double = 0) -> Bool {
            let d = p - centre
            let u = d.dot(tangent), v = d.dot(normal)
            return abs(u) <= width / 2 - shrink && v >= -inner + shrink && v <= outer - shrink
        }

        /// Its outline, counter-clockwise.
        public var outline: Polyline {
            let a = tangent * (width / 2)
            let pts = [centre - a - normal * inner, centre + a - normal * inner, centre + a + normal * outer, centre - a + normal * outer]
            return Polyline(pts, closed: true).oriented(counterClockwise: true)
        }
    }

    /// The strips a 3D toolpath leaves.
    public struct Strips: Sendable, Equatable {
        public var cutOut: String
        public var cutOutID: UUID
        public var strips: [Strip]
        public var tabs: TabSettings
        /// The tabs' top (design Z).
        public var top: Double
        /// Worth a look, but the strips still hold: a tab standing proud of the model's edge.
        public var warnings: [String]
    }

    /// What a flat 3D roughing or finishing does to keep its part on the tabs of the cut-out that holds it.
    public enum Decision: Sendable, Equatable {
        /// Nothing to hold: not a flat 3D toolpath next to a tabbed cut-out, or its floor is above the tabs anyway.
        case none
        /// Strips under the cut-out's tabs; the floor is cut to full depth elsewhere.
        case strips(Strips)
        /// The whole floor held a tab thickness up (`PartHold`); `reason` says why strips weren't used (nil when the hold
        /// can't be made at all, which is an error in the checks).
        case hold(PartHold.Hold, reason: String?)
        /// The cut-out's tabs are below this toolpath's floor, which leaves at least their thickness under the part.
        case belowFloor(cutOut: String)

        public var strips: Strips? { if case let .strips(s) = self { s } else { nil } }
    }

    // MARK: Deciding

    /// What `op` does, in `project`.
    public static func decide(_ op: CAMOperation, in project: Project) -> Decision {
        guard let hold = PartHold.hold(for: op, in: project) else { return .none }
        guard hold.possible else { return .hold(hold, reason: nil) }
        switch plan(op, in: project) {
        case let .strips(s): return .strips(s)
        case let .below(name): return .belowFloor(cutOut: name)
        case let .fallback(why): return .hold(hold, reason: why)
        case .unchanged: return .hold(hold, reason: nil)
        }
    }

    /// `unchanged`: the Model outline boundary, where #166's hold is kept as it is (strips would reach past what the
    /// toolpath cuts).
    private enum Plan { case strips(Strips), below(String), fallback(String), unchanged }

    private static func plan(_ op: CAMOperation, in project: Project) -> Plan {
        let units = project.displayUnits
        func fmt(_ mm: Double) -> String { "\(units.format(mm)) \(units.symbol)" }
        guard let b = PartHold.boundary(of: op) else { return .fallback("it isn't a flat 3D toolpath.") }
        if b.boundary == .material {
            return .fallback("Boundary is Whole material, which cuts everything round the model to its base, so strips under the "
                + "tabs would join nothing. Set Boundary to Selected vectors, with the cut-out's vector, to leave strips instead.")
        }
        guard b.boundary == .vectors else { return .unchanged }
        let reached = PartHold.cutOutsReached(by: op, in: project)
        guard reached.count == 1, let cutOut = reached.first, case let .profile(p) = cutOut.kind else {
            return .fallback("it reaches the parts of \(reached.count) tabbed cut-outs, so which tabs to leave strips under isn't clear.")
        }
        let name = "“\(cutOut.name)”"
        guard p.side == .outside else { return .fallback("\(name) isn't an outside cut, so its tabs aren't round the model.") }
        guard let floor = PartHold.unheldFloor(op, in: project) else { return .fallback("its models have no base.") }
        let top = -p.depth.cutDepth + p.tabs.thickness
        guard top > floor + 1e-6 else { return .below(cutOut.name) }
        let shapes = project.shapes(for: op).filter { !$0.isKeepOut }
        var ignored: [String] = []
        guard let (models, regions, mode) = Model3DGenerator.boundaryRegions(shapes: shapes, boundary: b.boundary, margin: b.margin,
                                                                             stock: project.stock, warnings: &ignored), mode == .vectors else {
            return .fallback("it has no closed vector selected for its boundary.")
        }
        let silhouette = Region.build(from: models.flatMap { $0.polylines(tolerance: 0.05) }, fill: .nonZero)
        guard !silhouette.isEmpty else { return .fallback("its model has no outline from above.") }
        guard let marks = p.tabs.placed ?? evenMarks(cutOut, params: p, in: project) else {
            return .fallback("\(name)'s tabs take up most of its outline, so they're left off it.")
        }
        let cutOutShapes = project.shapes(for: cutOut).filter { !$0.isKeepOut }
        let index = ContourMarks.Index(cutOutShapes, flatten: 0.01)
        let tol = ContourMarks.tolerance(toolRadius: cutOut.tool.radius)
        let thickness = project.stock.thickness
        let tabWood = top + thickness
        let w = p.tabs.width
        let step = 0.25
        let reachBounds = regions.map(\.bounds).reduce(Rect2.empty) { $0.union($1) }
        func inSilhouette(_ q: Vec2) -> Bool { silhouette.contains { $0.contains(q) } }
        func inReach(_ q: Vec2) -> Bool { regions.contains { $0.contains(q) } }
        var strips: [Strip] = []
        var warnings: [String] = []
        var proud: [(tab: Int, by: Double)] = []
        if cutOut.tool.hasUndercut {
            return .fallback("\(name)'s bit is wider at its tip than above it, so it leaves its tabs off.")
        }
        for (k, mark) in marks.enumerated() {
            // A tab placed by hand that's no longer on its shape is left off the cut: it holds nothing, and gets no strip.
            guard let drawn = index.resolve(mark, tolerance: tol), let outline = index.outline(near: drawn, within: tol + 0.01) else { continue }
            let label = marks.count == 1 ? "its tab" : "tab \(k + 1)"
            let roundModel = silhouette.contains { region in region.outer.points.contains { outline.contains($0) } }
            guard roundModel else {
                guard !outline.bounds.intersects(reachBounds) else {
                    return .fallback("\(name) cuts out another part this toolpath reaches, which isn't round the model.")
                }
                continue
            }
            let c = outline.closestPoint(to: drawn)
            let (a0, a1) = outline.segment(c.segment)
            let tangent = (a1 - a0).normalized
            var normal = tangent.perpRight
            if outline.contains(drawn + normal * 0.05) { normal = -normal }
            // How far in the model's silhouette is across the tab's width.
            let span = (outline.bounds.width + outline.bounds.height)
            func inward(from q: Vec2) -> Double? {
                var d = 0.0
                while d <= span {
                    if inSilhouette(q - normal * d) { return d }
                    d += step
                }
                return nil
            }
            var depths: [Double] = []
            for u in stride(from: -w / 2, through: w / 2 + 1e-9, by: max(step, w / 8)) {
                guard let d = inward(from: drawn + tangent * u) else {
                    return .fallback("\(label) of \(name) isn't opposite the model across its whole length (a narrow part of the "
                        + "model's outline). Move it on the canvas, or change the tab count.")
                }
                depths.append(d)
            }
            let reachIn = (depths.max() ?? 0) + 1
            // The silhouette's width along the wall just inside the joint: a narrow spike snaps off whatever holds it.
            let probe = drawn - normal * ((depths.min() ?? 0) + w / 2)
            func along(_ dir: Vec2) -> Double {
                var d = 0.0
                while d < 4 * w, inSilhouette(probe + dir * (d + step)) { d += step }
                return d
            }
            let across = along(tangent) + along(-tangent)
            if across < 2 * w {
                return .fallback("\(label) of \(name) is on a narrow part of the model (\(fmt(across)) across, less than twice the "
                    + "tab's length), which could snap off. Move the tab on the canvas, or change the tab count.")
            }
            // The model's edge where the strip joins it.
            let area = Rect2(min: drawn, max: drawn).union(drawn - normal * (reachIn + 1) + tangent * (w / 2 + 1))
                .union(drawn - normal * (reachIn + 1) - tangent * (w / 2 + 1)).union(drawn + tangent * (w / 2 + 1))
                .union(drawn - tangent * (w / 2 + 1))
            let grid = ModelRaster.surface(of: models, over: area.insetBy(-1), cellSize: step)
            var edge = Double.infinity
            for (j, u) in stride(from: -w / 2, through: w / 2 + 1e-9, by: max(step, w / 8)).enumerated() where j < depths.count {
                let q = drawn + tangent * u - normal * (depths[j] + 0.5)
                if let h = grid.height(at: q) { edge = min(edge, Double(h)) }
            }
            guard edge.isFinite else { return .fallback("the model's edge couldn't be found where \(label) of \(name) joins it.") }
            if edge + thickness < tabWood / 2 {
                return .fallback("the model is only \(fmt(max(0, edge + thickness))) thick where \(label) of \(name) joins it, "
                    + "less than half the tab's \(fmt(tabWood)), so it would break off there. Lift the model, or move the tab.")
            }
            if edge < top - 0.25 { proud.append((k + 1, top - edge)) }
            // Out past where the 3D toolpath reaches: its boundary, plus its bit's width, plus a millimetre.
            var d = 0.0
            while d < span + 1000, inReach(drawn + normal * d) { d += step }
            let reachOut = d + op.tool.diameter + 1
            strips.append(Strip(centre: drawn, tangent: tangent, normal: normal, width: w, inner: reachIn, outer: reachOut, top: top))
        }
        guard !strips.isEmpty else { return .fallback("\(name) has no tabs on its outline round the model.") }
        if let most = proud.map(\.by).max() {
            let which = proud.count == 1 ? "Tab \(proud[0].tab) of \(name) stands \(fmt(most))"
                : "\(proud.count) tabs of \(name) stand up to \(fmt(most))"
            warnings.append(which + " proud of the model's edge where \(proud.count == 1 ? "it joins" : "they join") it, so there's a block "
                + "to trim off there after the cut-out.")
        }
        return .strips(Strips(cutOut: cutOut.name, cutOutID: cutOut.id, strips: strips, tabs: p.tabs, top: top, warnings: warnings))
    }

    /// Evenly spaced tabs on each of a cut-out's drawn outlines, at fixed points: `count` of them centred at
    /// `L·(k+½)/count` from the outline's first point, whatever order the job runs in. nil when tabs that long take up
    /// most of an outline (as `TabPlan` leaves them off).
    static func evenMarks(_ cutOut: CAMOperation, params p: ProfileParams, in project: Project) -> [ContourMark]? {
        guard p.tabs.count > 0 else { return nil }
        let span = p.tabs.width + cutOut.tool.diameter
        var marks: [ContourMark] = []
        for shape in project.shapes(for: cutOut) where !shape.isKeepOut {
            guard let inverse = shape.transform.inverted else { return nil }
            for outline in shape.polylines(tolerance: 0.01) where outline.isClosed && outline.count >= 3 {
                let L = outline.length
                guard span * Double(p.tabs.count) < L * 0.8 else { return nil }
                for k in 0..<p.tabs.count {
                    marks.append(ContourMark(shapeID: shape.id, point: inverse.apply(outline.point(atDistance: L * (Double(k) + 0.5) / Double(p.tabs.count)))))
                }
            }
        }
        return marks
    }

    // MARK: A whole job

    /// Every flat 3D toolpath's decision in a project, and the tabs each cut-out with strips under it is cut with.
    public struct Job: Sendable {
        public let decisions: [UUID: Decision]
        /// Cut-outs with evenly spaced tabs that 3D toolpaths leave strips under: the fixed tabs they're cut with.
        public let anchored: [UUID: [ContourMark]]
        /// Each cut-out's strips (the first 3D toolpath's: every toolpath on the cut-out leaves them in the same places).
        public let stripsByCutOut: [UUID: Strips]

        public init(_ project: Project) {
            var decisions: [UUID: Decision] = [:]
            var anchored: [UUID: [ContourMark]] = [:]
            var byCutOut: [UUID: Strips] = [:]
            guard project.stock.rotary == nil else {
                self.decisions = [:]; self.anchored = [:]; stripsByCutOut = [:]
                return
            }
            for op in project.operations where op.enabled && PartHold.boundary(of: op) != nil {
                let d = HoldingTabs.decide(op, in: project)
                decisions[op.id] = d
                guard let s = d.strips else { continue }
                if byCutOut[s.cutOutID] == nil { byCutOut[s.cutOutID] = s }
                if let cutOut = project.operations.first(where: { $0.id == s.cutOutID }), case let .profile(p) = cutOut.kind,
                   p.tabs.placed == nil, let marks = evenMarks(cutOut, params: p, in: project) {
                    anchored[cutOut.id] = marks
                }
            }
            self.decisions = decisions
            self.anchored = anchored
            stripsByCutOut = byCutOut
        }

        public var hasStrips: Bool { !stripsByCutOut.isEmpty }

        /// `op` as it's cut: a cut-out with strips under its evenly spaced tabs gets them at their fixed places.
        func anchoring(_ op: CAMOperation) -> CAMOperation {
            guard let marks = anchored[op.id], case var .profile(p) = op.kind else { return op }
            p.tabs.placed = marks
            var o = op
            o.kind = .profile(p)
            return o
        }
    }

    // MARK: Checks

    /// Points along a motion, `start` included, at most `step` apart: arcs and straight moves alike.
    static func points(_ m: Motion, from start: Vec3, step: Double) -> [Vec3] {
        guard !m.kind.isArc else { return [start] + m.samples(from: start, maxStep: step) }
        let n = max(1, Int((start.distance(to: m.end) / step).rounded(.up)))
        return (0...n).map { start.lerp(to: m.end, Double($0) / Double(n)) }
    }

    /// How many points of `tp` (feeds, links and rapids, every half millimetre) have the tool's centre inside a strip
    /// (`shrink` in from its sides, a grid cell's worth) below its top, by more than `tolerance` (a finishing pass's own
    /// path tolerance, plus a little): each is the tool cutting into a tab.
    public static func intrusions(_ tp: Toolpath, strips: [Strip], shrink: Double = 0.5, tolerance: Double = 0.05) -> Int {
        guard !strips.isEmpty else { return 0 }
        var n = 0
        tp.forEachMotion { s, m in
            guard m.kind != .dwell else { return }
            for q in points(m, from: s, step: 0.5) {
                for st in strips where q.z < st.top - tolerance && st.contains(q.xy, shrink: shrink) { n += 1 }
            }
        }
        return n
    }

    /// The tabs of the cut-out `tp` cuts that don't line up with the strips 3D toolpaths leave for them, by more than
    /// 0.1 mm: a strip the cut goes through at full depth beside the tab (not lifted over), or a tab the cut lifts
    /// over with no strip under it. Either way the part can come free. `tool` is the cut-out's bit.
    public static func mismatches(_ tp: Toolpath, strips: Strips, tool: Tool) -> Int {
        let l = lineUp(tp, strips: strips, tool: tool)
        return l.strips.filter { $0.eaten || !$0.lifted }.count + l.marks.filter { $0 > 0.1 }.count
    }

    /// Per strip, whether a full-depth pass reaches into it (`eaten`) and whether the cut lifts to the tabs' top over its
    /// middle (`lifted`); per tab the cut leaves on the wall round the model, how far it is from the nearest strip.
    static func lineUp(_ tp: Toolpath, strips: Strips, tool: Tool) -> (strips: [(eaten: Bool, lifted: Bool)], marks: [Double]) {
        let r = tool.radius
        // A rectangular tab is lifted to its top over its whole length; a triangular one only at its top (its sides ramp),
        // so for those the cut must just stay off the floor across the strip.
        let below = strips.tabs.shape == .triangular ? strips.top - strips.tabs.thickness + 0.02 : strips.top - 0.01
        var out: [(eaten: Bool, lifted: Bool)] = []
        for st in strips.strips {
            // The cut's tool centres beside the strip: those at full depth, and every one along the strip's middle (where
            // the tab is narrowest, half way across the kerf).
            var deep: [Vec2] = [], core: [Vec2] = []
            var lifted = false
            tp.forEachMotion { s, m in
                guard m.kind != .rapid, m.kind != .dwell else { return }
                for q in points(m, from: s, step: 0.1) {
                    let d = q.xy - st.centre
                    let u = d.dot(st.tangent), v = d.dot(st.normal)
                    guard v > -r, v < 3 * r + 1, abs(u) < st.width / 2 + 2 * r else { continue }
                    if q.z < below { deep.append(q.xy) }
                    if abs(u) < st.width / 2 - 0.1 { core.append(q.xy) }
                    if abs(u) < 0.5, abs(q.z - strips.top) < 0.01 { lifted = true }
                }
            }
            // A full-depth pass that reaches the strip's middle more than 0.1 mm in from its ends cuts into it.
            let eaten = core.contains { p in deep.contains { $0.distance(to: p) < r - 0.02 } }
            out.append((eaten, lifted))
        }
        // Tabs the cut leaves, and how far each is from its strip.
        var marks: [Double] = []
        for mark in tp.tabMarks ?? [] where mark.cut {
            let near = strips.strips.min { $0.centre.distance(to: mark.point) < $1.centre.distance(to: mark.point) }
            // Only the tabs on the wall round the model (another part of the same cut-out has none).
            guard let near, near.centre.distance(to: mark.point) < 4 * strips.tabs.width else { continue }
            marks.append(near.centre.distance(to: mark.point))
        }
        return (out, marks)
    }

    // MARK: Words

    static func stripsNote(_ s: Strips, units: LengthUnit, thickness: Double) -> String {
        func fmt(_ mm: Double) -> String { "\(units.format(mm)) \(units.symbol)" }
        let n = s.strips.count
        let shape = s.tabs.shape == .triangular ? " (the triangular tabs get flat strips at their full height)" : ""
        return "Leaves a strip under \(n == 1 ? "the tab" : "each of the \(n) tabs") of “\(s.cutOut)” (\(fmt(s.tabs.width)) long, "
            + "its top \(fmt(-s.top)) deep, \(fmt(s.top + thickness)) above the material's bottom)\(shape), so the part stays "
            + "joined to the board; elsewhere it cuts to full depth."
    }

    static func belowNote(_ cutOut: String) -> String {
        "The tabs of “\(cutOut)” are below this toolpath's floor, which leaves at least their thickness under the part, so "
            + "nothing is held for them."
    }

    static func mismatchError(_ n: Int, strips: Strips) -> String {
        "\(n == 1 ? "1 tab doesn't" : "\(n) tabs don't") line up with the strips the 3D toolpaths leave under them (by more than "
            + "0.1 mm), so the part could come free. Generate the job again; if it stays, place the tabs by hand."
    }

    static func intrusionError(_ s: Strips) -> String {
        "Cuts into the strips left under the tabs of “\(s.cutOut)”, below their top, so the part could come free."
    }

    /// The inspector's read-only Tabs line for a flat 3D roughing or finishing, nil when it has nothing to hold.
    public static func summary(for op: CAMOperation, in project: Project) -> String? {
        let units = project.displayUnits
        func fmt(_ mm: Double) -> String { "\(units.format(mm)) \(units.symbol)" }
        switch decide(op, in: project) {
        case .none: return nil
        case let .strips(s):
            let shape = s.tabs.shape == .triangular ? " triangular" : ""
            return "Leaves the \(s.strips.count)\(shape) tabs of “\(s.cutOut)” (\(s.strips.count) × \(fmt(s.tabs.width)), "
                + "\(fmt(s.top + project.stock.thickness)) thick)."
        case let .hold(h, why):
            guard h.possible else { return "The floor can't be held for the tabs of “\(h.cutOut)”: see Checks." }
            return "Holds the whole floor \(fmt(h.tabThickness)) up for the tabs of “\(h.cutOut)”" + (why.map { ": \($0)" } ?? ".")
        case let .belowFloor(name): return "The tabs of “\(name)” are below this toolpath's floor."
        }
    }

    /// The models whose 3D toolpaths leave strips under a cut-out's tabs, by name: for the profile inspector's caption.
    public static func leftBy(_ cutOut: CAMOperation, in project: Project) -> [String] {
        let job = Job(project)
        var names: [String] = []
        for op in project.operations where job.decisions[op.id]?.strips?.cutOutID == cutOut.id {
            for s in project.shapes(for: op) where s.modelSpec != nil && !names.contains(s.name) { names.append(s.name) }
        }
        return names
    }

    /// The setup sheet's line for each cut-out 3D toolpaths leave strips under.
    static func setupSheetNotes(_ project: Project, units: LengthUnit) -> [(cutOut: String, text: String)] {
        func fmt(_ mm: Double) -> String { "\(units.format(mm)) \(units.symbol)" }
        let job = Job(project)
        return project.operations.compactMap { cutOut in
            guard let s = job.stripsByCutOut[cutOut.id] else { return nil }
            let height = s.top + project.stock.thickness
            return (cutOut.name, "3D toolpaths leave strips under these tabs, so the part stays on them through the 3D passes. The "
                + "tabs' tops are \(fmt(height)) above the spoilboard: caliper the material before you cut, and re-zero Z carefully "
                + "after each tool change, since a Z off by that much leaves the tabs thinner, or cuts them through.")
        }
    }
}
