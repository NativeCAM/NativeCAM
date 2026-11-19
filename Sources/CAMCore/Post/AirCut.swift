import Foundation

/// A dry run: the same program with every Z raised by a set height, so the machine traces the job in the air
/// before it cuts. Autodesk's post guide recommends exactly this before running a new post or machine.
public enum AirCut {
    /// The project and toolpaths with every height raised by `height` (mm): each move's Z, the toolpaths' start
    /// heights, the safe Z and the park height. X and Y don't change.
    public static func raise(_ project: Project, _ toolpaths: [Toolpath], by height: Double) -> (Project, [Toolpath]) {
        var p = project
        p.stock.clearanceHeight += height
        p.stock.plungeHeight += height
        p.stock.homePosition.z += height
        let raised = toolpaths.map { tp -> Toolpath in
            var t = tp
            t.start.z += height
            t.motions = tp.motions.map { m in
                var r = m
                r.end.z += height
                return r
            }
            return t
        }
        return (p, raised)
    }

    /// The air-cut file for a job, with a note at the top saying so; nil when the machine has no post.
    public static func post(_ project: Project, toolpaths: [Toolpath], height: Double, date: Date = Date())
        -> (gcode: String, project: Project, toolpaths: [Toolpath], post: any PostProcessor)? {
        let (p, raised) = raise(project, toolpaths, by: height)
        guard let post = PostProcessors.post(for: p, date: date) else { return nil }
        let u = p.machine.outputUnits
        let d = post.dialect
        let amount = String(format: "%.\(d.coordinateDecimals(u))f", u.fromMM(height))
        let note = d.comment("AIR CUT: every Z raised \(amount) \(u.symbol), X and Y unchanged. Nothing should touch the material.")
            + d.lineEnding
        return (note + post.post(raised), p, raised, post)
    }
}
