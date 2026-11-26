import Foundation

public extension JobResult {
    /// The job cut down to the toolpaths of the operations `ids` (by `Toolpath.sourceOperationID`), on every tile and
    /// sheet, with the run time worked out again for what's left. The toolpaths are the full job's, never generated
    /// again: later toolpaths are generated against what the earlier ones cut (links over cleared floors, rest passes,
    /// part holds), so a subset generated on its own would be a different program. Tiling's registration holes stay
    /// only with `keepRegistration`.
    func filtered(to ids: Set<UUID>, project: Project, keepRegistration: Bool = false) -> JobResult {
        func keep(_ tp: Toolpath) -> Bool {
            ids.contains(tp.sourceOperationID) || (keepRegistration && tp.sourceOperationID == TileSplitter.registrationOperation)
        }
        var r = self
        r.toolpaths = toolpaths.filter(keep)
        r.reorder = nil
        if var tiled = tiling {
            tiled.tiles = tiled.tiles.map { $0.filter(keep) }
            r.tiling = tiled
        }
        if let sheets {
            r.sheets = sheets.map { s in
                var s = s
                s.job = s.job.filtered(to: ids, project: s.project, keepRegistration: keepRegistration)
                return s
            }
        }
        r.estimate = estimate == nil ? nil : CycleTimeEstimator.estimate(r.toolpaths, project: project)
        return r
    }
}

/// A file for part of a job: a toolpath group (Export Group…) or the selected toolpaths (Export Selected Toolpaths…),
/// and `nativecam-cli post --group` / `--toolpaths`.
///
/// Like a restart (`Restart`), it cuts down the full job rather than generating a subset (`JobResult.filtered`), so its
/// toolpaths are exactly the ones the full file cuts: the same moves, the same links. Those links assume the earlier
/// toolpaths were cut: a minimum-height link rapids down to just above a floor an earlier pocket cleared, and a rest
/// pass follows what the earlier one left. So the file says, in its header and its checks, which earlier toolpaths it
/// assumes were already cut, and when there are any, `fullRetract` regenerates the whole job with every link retracting
/// to safe Z (`RetractMode.full`) for this export only, then cuts that down.
///
/// The file goes through the normal post (`JobExport.files`: tiles, sheets, one file per tool, air cuts) and
/// `GCodeCheck`, so it starts as every NativeCAM file does, with the tool change for its first tool.
public enum JobSubset {
    public struct Request: Hashable, Sendable {
        /// The toolpaths (operation ids) to keep. Those not included in the output are left out, and said so.
        public var operationIDs: Set<UUID>
        /// What the file is, for its header and setup sheet: e.g. "group “Finish”" or "2 selected toolpaths".
        public var label: String
        /// Retract fully between cuts: regenerate the job with `RetractMode.full` before cutting it down.
        public var fullRetract: Bool
        /// Raise every Z by this much (mm) for an air cut; nil for none.
        public var airCut: Double?

        public init(operationIDs: Set<UUID>, label: String, fullRetract: Bool = false, airCut: Double? = nil) {
            self.operationIDs = operationIDs
            self.label = label
            self.fullRetract = fullRetract
            self.airCut = airCut
        }

        /// Group `id` of `project`, named in the label.
        public static func group(_ id: UUID, in project: Project, fullRetract: Bool = false, airCut: Double? = nil) -> Request? {
            guard let g = project.toolpathGroup(id: id) else { return nil }
            return Request(operationIDs: Set(project.members(ofGroup: id).map(\.id)), label: "group “\(g.name)”",
                           fullRetract: fullRetract, airCut: airCut)
        }

        /// The toolpaths `ids`, named by count (or the toolpath's name when there's one).
        public static func toolpaths(_ ids: Set<UUID>, in project: Project, fullRetract: Bool = false, airCut: Double? = nil) -> Request {
            let ops = project.operations.filter { ids.contains($0.id) }
            let label = ops.count == 1 ? "toolpath “\(ops[0].name)”" : "\(ops.count) selected toolpaths"
            return Request(operationIDs: ids, label: label, fullRetract: fullRetract, airCut: airCut)
        }
    }

    /// Why the file can't be written.
    public struct Refusal: Error, Hashable, Sendable, LocalizedError {
        public var message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    public struct Output: Sendable {
        /// The files, each with the subset's header, as raised for an air cut.
        public var files: [JobExport.File]
        public var post: any PostProcessor
        /// The project the files are posted for (with full retracts when asked), and the cut-down job, for the setup sheet.
        public var project: Project
        public var job: JobResult
        /// The toolpaths in the file, in run order, and the ones asked for but not included in the output.
        public var included: [CAMOperation]
        public var skipped: [CAMOperation]
        /// The included toolpaths outside the file that run before its last one: the file assumes they were already cut.
        public var assumedCut: [CAMOperation]
        /// The subset's own findings, then `GCodeCheck` on each file.
        public var issues: [GCodeCheck.Issue]
        /// The header's lines (without comment marks), for showing.
        public var header: [String]
        /// The setup sheet's lines on what part of the job it is (`SetupSheet.html(part:)`).
        public var setupSheetLines: [String]
        /// Whether to offer "Retract fully between cuts": the file assumes earlier toolpaths were cut.
        public var offersFullRetract: Bool { !assumedCut.isEmpty }
    }

    /// The file(s) for `request`, checked. `job` is the full job as generated (it's generated when nil, and again with
    /// full retracts when asked). Throws a `Refusal` when there's nothing to cut or no post.
    public static func make(_ project: Project, job given: JobResult? = nil, request: Request, date: Date = Date()) throws -> Output {
        var p = project
        let job: JobResult
        if request.fullRetract, project.stock.retract != .full {
            p.stock.retractMode = .full
            job = CAMEngine.generate(p)
        } else {
            job = given ?? CAMEngine.generate(project)
        }
        if job.toolpaths.contains(where: { $0.stopMessage != nil }) {
            throw Refusal("A calibration program is cut whole: export all of it.")
        }
        let ids = request.operationIDs
        let asked = project.operations.filter { ids.contains($0.id) }
        guard !asked.isEmpty else { throw Refusal("No toolpaths to export.") }
        let included = asked.filter(\.enabled)
        let skipped = asked.filter { !$0.enabled }
        let keep = Set(included.map(\.id))
        let cuts = Set(job.toolpaths.filter { !$0.isEmpty }.map(\.sourceOperationID))
        guard !keep.isDisjoint(with: cuts) else {
            throw Refusal(included.isEmpty
                ? "None of the \(request.label)'s toolpaths are included in the output: turn on “Include in output” first."
                : "The \(request.label) has nothing to cut.")
        }
        // The included toolpaths outside the file that run before its last one.
        let lastIndex = project.operations.lastIndex { keep.contains($0.id) && cuts.contains($0.id) } ?? 0
        let assumed = project.operations[..<lastIndex].filter { $0.enabled && !keep.contains($0.id) && cuts.contains($0.id) }
        let cut = job.filtered(to: keep, project: p, keepRegistration: assumed.isEmpty)
        guard let export = JobExport.files(p, job: cut, airCut: request.airCut, date: date) else {
            throw Refusal(PostProcessors.unavailableReason(for: project.machine) ?? "No post processor for this machine.")
        }
        let number = Dictionary(project.operations.filter { $0.enabled && cuts.contains($0.id) }.enumerated().map { ($1.id, $0 + 1) },
                                uniquingKeysWith: { a, _ in a })
        func named(_ op: CAMOperation) -> String { "\(number[op.id].map { "\($0) " } ?? "")\(op.name) (T\(op.tool.number))" }

        // The subset's own findings.
        var issues: [GCodeCheck.Issue] = []
        if !assumed.isEmpty {
            let list = assumed.map(named).joined(separator: ", ")
            if p.stock.retract == .full {
                issues.append(GCodeCheck.Issue(.info, "This file assumes these were already cut: \(list). It retracts fully between cuts, "
                    + "so its links stay above the material if they weren't."))
            } else {
                issues.append(GCodeCheck.Issue(.warning, "This file assumes these were already cut: \(list). Its links stay low over the "
                    + "material they clear, so cut them first, or export it retracting fully between cuts."))
            }
        }
        for op in included {
            let outside = RestMachining.dependencies(of: op, in: project).filter { !keep.contains($0) }
            for dep in outside {
                guard let ref = project.operations.first(where: { $0.id == dep }), ref.enabled else { continue }
                issues.append(GCodeCheck.Issue(.warning, "“\(op.name)” cuts only what “\(ref.name)” left, which isn't in this file. "
                    + "Cut “\(ref.name)” first, or the smaller bit takes the full cut."))
            }
        }
        if !skipped.isEmpty {
            issues.append(GCodeCheck.Issue(.info, "Left out, not included in the output: " + skipped.map(\.name).joined(separator: ", ") + "."))
        }
        if !assumed.isEmpty, job.tiling?.layout.registration != nil {
            issues.append(GCodeCheck.Issue(.info, "The registration holes are left out: the full job's files drill them."))
        }

        // The header on every file.
        let name = project.name.isEmpty ? "Untitled" : project.name
        let inFile = project.operations.filter { keep.contains($0.id) && cuts.contains($0.id) }
        var header = ["PART OF \(name): \(request.label)"]
        header.append("Cuts " + inFile.map(named).joined(separator: ", "))
        if assumed.isEmpty {
            header.append("Starts at the job's first toolpath")
        } else {
            header.append("Assumes already cut: " + assumed.map(named).joined(separator: ", "))
            header.append(p.stock.retract == .full ? "Retracts fully between cuts" : "Links stay low over cleared material: cut those first")
        }
        let dialect = export.post.dialect
        let headerText = header.compactMap { Restart.comment($0, dialect: dialect) }.map { $0 + dialect.lineEnding }.joined()
        // A tile with nothing of the subset to cut gets no file (the others keep their numbers), as a sheet doesn't.
        var files = export.files.filter { $0.toolpaths.contains { !$0.isEmpty } }
        for i in files.indices {
            // An air cut keeps its "AIR CUT" line first (`AirCut.files`), above the part's header.
            if request.airCut != nil, let end = files[i].gcode.range(of: dialect.lineEnding) {
                files[i].gcode.insert(contentsOf: headerText, at: end.upperBound)
            } else {
                files[i].gcode = headerText + files[i].gcode
            }
            issues += GCodeCheck.run(files[i].gcode, toolpaths: files[i].toolpaths, project: files[i].project, dialect: dialect)
                .map { issue in
                    var issue = issue
                    if files.count > 1 { issue.message = "\(files[i].suffix ?? ""): " + issue.message }
                    return issue
                }
        }

        var sheet = ["This file cuts the \(request.label) only: " + inFile.map(named).joined(separator: ", ") + "."]
        if let first = cut.toolpaths.first(where: { !$0.isEmpty }) { sheet.append("Load T\(first.tool.number) \(first.tool.name) first.") }
        if !assumed.isEmpty {
            sheet.append("It assumes these were already cut: " + assumed.map(named).joined(separator: ", ") + ".")
            sheet.append(p.stock.retract == .full ? "It retracts fully between cuts." : "Its links stay low over the material they clear: cut them first.")
        }
        return Output(files: files, post: export.post, project: p, job: cut, included: inFile, skipped: skipped, assumedCut: assumed,
                      issues: issues, header: header, setupSheetLines: sheet)
    }
}
