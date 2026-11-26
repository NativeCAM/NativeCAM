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

    /// The air-cut files for a job (one, or one per tool when the post splits jobs), each marked at the top; nil
    /// when the machine has no post.
    public static func files(_ project: Project, toolpaths: [Toolpath], height: Double, date: Date = Date())
        -> (files: [PostedFile], project: Project, post: any PostProcessor)? {
        let (p, raised) = raise(project, toolpaths, by: height)
        guard let post = PostProcessors.post(for: p, date: date) else { return nil }
        let u = p.machine.outputUnits
        let d = post.dialect
        let amount = String(format: "%.\(d.coordinateDecimals(u))f", u.fromMM(height))
        let note = d.comment("AIR CUT: Z raised \(amount) \(u.symbol), X and Y unchanged") + d.lineEnding
        let files = post.files(raised).map { f in
            var marked = f
            marked.gcode = note + f.gcode
            marked.suffix = " (air cut)" + (f.suffix ?? "")
            return marked
        }
        return (files, p, post)
    }

    /// The air-cut file for a single-file job.
    public static func post(_ project: Project, toolpaths: [Toolpath], height: Double, date: Date = Date())
        -> (gcode: String, project: Project, toolpaths: [Toolpath], post: any PostProcessor)? {
        guard let r = files(project, toolpaths: toolpaths, height: height, date: date) else { return nil }
        return (r.files.map(\.gcode).joined(), r.project, r.files.flatMap(\.toolpaths), r.post)
    }
}

// MARK: File names (#192)

public extension AirCut {
    /// What every air-cut file's name carries, before its other suffixes: "Sign (air cut).tap",
    /// "Sign - Finish (air cut).tap", "Sign (air cut) - tile 1 of 2.tap".
    static let marker = " (air cut)"

    /// `stem` without a trailing " (air cut)", so adding the files' suffixes (which start with it on an air cut)
    /// doesn't write it twice.
    static func unmarked(_ stem: String) -> String {
        stem.hasSuffix(marker) ? String(stem.dropLast(marker.count)) : stem
    }

    /// The path of each file of a job or part of one, from the stem chosen for it (a path or name without its
    /// extension). An air cut's files always carry " (air cut)", even a single file, as `post --air-cut` names them,
    /// so an air cut and the real cut never share a name. A real cut's single file is `stem.ext`.
    static func paths(_ files: [JobExport.File], stem: String, airCut: Bool, fileExtension: String) -> [String] {
        paths(suffixes: files.map(\.suffix), stem: stem, airCut: airCut, fileExtension: fileExtension)
    }

    /// `paths(_:stem:airCut:fileExtension:)` from the files' suffixes alone, for a program that isn't a job's export
    /// (spoilboard surfacing's, `Surfacing.paths`).
    static func paths(suffixes: [String?], stem: String, airCut: Bool, fileExtension: String) -> [String] {
        let base = airCut ? unmarked(stem) : stem
        if suffixes.count == 1, !airCut { return [base + "." + fileExtension] }
        return suffixes.map { s in
            var suffix = s ?? ""
            if airCut, !suffix.hasPrefix(marker) { suffix = marker + suffix }
            return base + suffix + "." + fileExtension
        }
    }

    /// Whether a G-code file says it's an air cut: an "AIR CUT" comment in its first lines, as every air cut NativeCAM
    /// writes starts with (the full job's, part of one, a restart's).
    static func isAirCut(_ gcode: String) -> Bool {
        gcode.split(whereSeparator: \.isNewline).prefix(60).contains { $0.contains("AIR CUT") }
    }

    /// Why files can't be written at `paths`, or nil when they can. `airCut` says whether they're an air cut;
    /// `existing` reads a file already at a path (nil when there's none).
    ///
    /// - A real cut's name mustn't say "air cut": someone would run it believing the bit stays in the air.
    /// - An air cut's name must say it.
    /// - An air cut never overwrites a file that isn't one: that file may be the real cut, and after it's replaced
    ///   the real cut is gone, or worse, an older real cut stays under a name the operator takes for the air cut.
    /// - No two of the files share a name.
    static func namingProblem(_ paths: [String], airCut: Bool, existing: (String) -> String?) -> String? {
        var seen = Set<String>()
        for path in paths {
            let name = (path as NSString).lastPathComponent
            let stem = (name as NSString).deletingPathExtension
            guard seen.insert(path.lowercased()).inserted else { return "Two files would both be named “\(name)”." }
            if airCut {
                guard stem.contains(marker.dropFirst()) else {
                    return "“\(name)” doesn't say it's an air cut. An air cut's name must include “(air cut)”."
                }
                if let text = existing(path), !isAirCut(text) {
                    return "“\(name)” already exists and isn't an air cut (it has no AIR CUT line at the top): it may be the real "
                        + "cut. Move or rename it, or choose another name."
                }
            } else if stem.lowercased().contains("air cut") || stem.lowercased().contains("aircut") {
                return "“\(name)” says it's an air cut, but this file cuts at full depth. Choose a name without “air cut”."
            }
        }
        return nil
    }

    /// `namingProblem` against the files on disk.
    static func namingProblemOnDisk(_ paths: [String], airCut: Bool) -> String? {
        namingProblem(paths, airCut: airCut, existing: onDisk)
    }

    /// The start of the file at `path`, for `namingProblem`'s `existing`: nil when there's none, and "" (not an air cut)
    /// when it can't be read.
    static func onDisk(_ path: String) -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        guard let data = FileManager.default.contents(atPath: path) else { return "" }
        return String(decoding: data.prefix(16_384), as: UTF8.self)
    }
}
