import CAMCore
import Foundation

// nativecam-cli: generate G-code for a project's machine and simulate jobs without the UI.
//
//   nativecam-cli demo <out.nativecam>                       write the demo sign project
//   nativecam-cli demo3d <out.nativecam>                     write the 3D relief demo project
//   nativecam-cli demonest <out.nativecam>                   write the shelf-parts demo project (for Nest Parts)
//   nativecam-cli demosheets <out.nativecam>                 write the shelf, frames and coasters demo (more sheets, part in part)
//   nativecam-cli new <out.nativecam>                        write an empty project (default PRO6060 setup)
//   nativecam-cli post <project.nativecam> [-o out.tap] [--air-cut height] [--sheet out.html] [--force]
//                                                      generate toolpaths + G-code, check the file against the
//                                                      controller and the toolpaths, print issues. With an error in
//                                                      the job's checks or the file's, refuses to write it and exits
//                                                      1 unless --force (warnings don't stop it). --air-cut raises
//                                                      every Z by height (in the G-code's units); --sheet writes a
//                                                      printable setup sheet
//   nativecam-cli post <project.nativecam> --restart-toolpath n [--restart-pass p] | --restart-line N
//                     [--restart-exact] [--restart-no-stop] [--restart-file n] [--restart-from running.tap]
//                     [--air-cut height] [-o out.tap] [--force]
//                                                      write a restart file: the rest of the job from toolpath n (from
//                                                      1 in the file's run order), its pass p, or the cutting move on
//                                                      line N of the full file, snapped back to the start of its pass
//                                                      unless --restart-exact. Stops over the restart point unless
//                                                      --restart-no-stop. --restart-file picks a tile, sheet or tool
//                                                      file (from 1); --restart-from names the file that was running
//                                                      and checks the project still writes it. A refusal exits 1 and
//                                                      --force doesn't override it
//   nativecam-cli post <project.nativecam> --group name | --toolpaths 1,3,Name [--full-retract] [--air-cut height]
//                     [--sheet out.html] [-o out.tap] [--force]
//                                                      write a file for part of the job: a toolpath group, or toolpaths
//                                                      by number in the run order, id or name. It's the full job cut
//                                                      down (never generated on its own), so it says which earlier
//                                                      toolpaths it assumes were cut; --full-retract regenerates the job
//                                                      with full retracts first. Writes "<project> - <group>.tap" unless -o
//   nativecam-cli sim  <project.nativecam|file.tap> [--png out.png] [--cell mm] [--heights out.bin]
//                                                      (--heights: little-endian header Int32 cols, Int32 rows,
//                                                       Float64 cell, origin x, origin y, then Float32 heights)
//                                                      simulate material removal, print stats (a G-code file's
//                                                      tapping and boring cycles are read as Avid Mach4 runs them)
//   nativecam-cli acceptance [machine.nativecam] [--controller grbl|grblHAL|fluidNC|carbideMotion] [--sender gSender]
//                     [--units inch|mm] [--tool-change m6|pause|atc] [-o out]
//                                                      write the acceptance test program for a controller: run it in
//                                                      check mode, then as an air cut, then 0.5 mm deep in scrap
//   nativecam-cli calibrate timing|rotary|ladder [project.nativecam] [--controller c] [--sender s] [--units inch|mm] [-o stem]
//                     timing: [--window WxH] [--air height]; ladder: [--tool n] [--material kind] [--depth d] [--rungs n] [--step-rpm]
//                                                      write a calibration program for the project's machine (Avid's
//                                                      PRO6060 without one): stem.tap (or the controller's extension),
//                                                      its recording sheet stem.html and, for timing and rotary, the
//                                                      times file stem-times.csv. Lengths are in the G-code's units
//   nativecam-cli calibrate fit <times.csv> [more-times.csv] [project.nativecam] [--apply] [-o out.nativecam]
//                                                      fit the machine's acceleration, Z rapid, corner tolerance and turn
//                                                      speed to the measured times, print each value before and after
//                                                      and the F-change and G93 verdicts; --apply writes the fitted values
//                                                      into the project's machine (in place unless -o)
//   nativecam-cli surface [project.nativecam] [--area bed|WxH] [--inset x] [--bit n] [--stepover 50] [--depth d] [--passes n]
//                     [--along x|y] [--one-way] [--overshoot x] [--clamp-overshoot] [--clearance z] [--board t]
//                     [--controller c] [--units inch|mm] [-o file] [--no-air-cut]
//                                                      write a spoilboard surfacing program for the project's machine
//                                                      (Avid's PRO6060 without one): the whole bed (the travel less the
//                                                      inset) or a WxH board, with the starter surfacing bit unless --bit
//                                                      names a tool in the project or the starter library. Z zero is the
//                                                      top of the spoilboard, XY zero the area's front-left corner. Also
//                                                      writes an air-cut copy (file-air.tap) unless --no-air-cut. Lengths
//                                                      are in the G-code's units; stepover in percent. A refusal or a
//                                                      failed check exits 1 and writes nothing
//   nativecam-cli machine <settings> [--apply project.nativecam [-o out.nativecam]]
//                                                      read machine limits from Grbl $$, Mach4 Machine.ini, LinuxCNC
//                                                      INI, FluidNC YAML or Fusion .mch; optionally apply to a project
//   nativecam-cli tools <library.tools|.vtdb|.json> [-o out.json]
//                                                      read a Fusion 360, Vectric or NativeCAM tool library, print what
//                                                      came across, optionally save it as a NativeCAM library (T1, T2, …)
//   nativecam-cli template save <project.nativecam> -o <out.nativecamtemplate> [--no-setup]
//                                                      save the project's toolpaths (and job setup) as a template
//   nativecam-cli template apply <template.nativecamtemplate> <project.nativecam> [-o out.nativecam | --in-place]
//                     [--setup] [--tools library.json] [--create-layers | --skip-missing]
//                                                      add a template's toolpaths to a project, matching tools to the
//                                                      library (the starter library unless --tools), and print what
//                                                      each toolpath found; --setup uses the template's job setup.
//                                                      Layers the design lacks are refused unless --create-layers makes
//                                                      them (empty) or --skip-missing leaves out their toolpaths.
//                                                      Writes "<project> + <template>.nativecam" beside the project
//                                                      unless -o names the file or --in-place overwrites the project
//   nativecam-cli nest <project.nativecam> [-o out.nativecam | --in-place] [--spacing x] [--margin x] [--turns none|90|N]
//                     [--grain] [--seconds s] [--seed n] [--evaluations n] [--sheets n] [--sheet-size WxH] [--no-holes]
//                     [--svg preview.svg]
//                                                      nest every part on the sheet as Toolpaths ▸ Nest Parts does
//                                                      (--sheets: parts that don't fit go on up to n sheets, sized
//                                                      --sheet-size after the first; --no-holes keeps parts out of
//                                                      other parts' holes)
//                                                      (lengths in the project's units; spacing and margin default to
//                                                      twice the cut-out bit plus 1/8 in or 3 mm); prints the utilization and
//                                                      what didn't fit. Writes "<project> nested.nativecam" beside the
//                                                      project unless -o or --in-place
//   nativecam-cli import <project.nativecam> <file>… (-o out.nativecam | --in-place) [--units in|mm] [--layer name]
//                     [--keep-coords | --center | --at x,y] [--sheet n] [--depth d] [--up z|y]
//                                                      add vector files (DXF, SVG, PDF, AI) and 3D models (STL, OBJ,
//                                                      3MF, PLY, USD) as File ▸ Import does (--layer: every vector
//                                                      shape on that layer), then have toolpaths that
//                                                      find vectors by layer or kind pick them up. Prints the unit
//                                                      assumed for each file, each shape added and every toolpath whose
//                                                      vectors changed. A DXF without $INSUNITS needs --units. Drawings
//                                                      keep the file's coordinates and are refused when they don't fit
//                                                      the material, unless --center or --at x,y (the drawing's
//                                                      lower-left corner, project units) places them; models are always
//                                                      centred and fitted. A refusal exits 1 and writes nothing
//   nativecam-cli rebind <project.nativecam> (-o out.nativecam | --in-place)
//                                                      Recalculate All's vector binding: toolpaths that find vectors by
//                                                      layer or kind look again; prints every toolpath whose vectors
//                                                      changed (and writes the file even when none did)
//   nativecam-cli save <project.nativecam> (-o out.nativecam | --in-place) [--rebind]
//                                                      read and write the project again, so formatVersion is what it
//                                                      needs; prints the format before and after
//   post and sim take --rebind: rebind in memory, print what changed, then post or simulate. The project isn't saved.

func fail(_ message: String) -> Never {
    // What was printed so far comes before the refusal, also when both go to one pipe.
    fflush(stdout)
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

func loadProject(_ path: String) -> Project {
    do {
        return try Project.decode(Data(contentsOf: URL(fileURLWithPath: path)))
    } catch {
        fail("Can't read project \(path): \(error.localizedDescription)")
    }
}

func option(_ name: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

/// "1 vector", "2 vectors".
func counted(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

/// The file `import`, `rebind` and `save` write: -o's, or the project with --in-place. One of them is required, and
/// -o naming the project itself is refused (that's --in-place), so nothing is overwritten by surprise.
func requiredOutput(project: String, usage: String) -> String {
    let out = option("-o", in: args)
    let inPlace = args.contains("--in-place")
    if out != nil && inPlace { fail("Pass -o or --in-place, not both.\n" + usage) }
    if inPlace { return project }
    guard let out else { fail("Say where to write the project: -o out.nativecam, or --in-place to overwrite \(project).\n" + usage) }
    let same = URL(fileURLWithPath: out).standardizedFileURL.resolvingSymlinksInPath().path
        == URL(fileURLWithPath: project).standardizedFileURL.resolvingSymlinksInPath().path
    if same { fail("-o names the project itself. Pass --in-place to overwrite it, or -o another file.\n" + usage) }
    return out
}

/// The arguments that aren't options, from `from`, skipping the values of options that take one. An unknown option is
/// refused.
func positionals(from start: Int, valued: Set<String>, flags: Set<String>, usage: String) -> [String] {
    var out: [String] = []
    var i = start
    while i < args.count {
        let a = args[i]
        if valued.contains(a) {
            guard i + 1 < args.count else { fail("\(a) needs a value.\n" + usage) }
            i += 2
            continue
        }
        if flags.contains(a) { i += 1; continue }
        if a.hasPrefix("-") && a.count > 1 { fail("Unknown option \(a).\n" + usage) }
        out.append(a)
        i += 1
    }
    return out
}

/// The toolpaths whose vectors a rebind changed, one line each, and those it left alone because their vectors were
/// chosen by hand.
func printBinding(_ changes: [VectorBindingChange], project: Project, prefix: String = "") {
    let u = project.displayUnits
    if changes.isEmpty {
        print("\(prefix)No changes: every toolpath that finds its vectors by layer or kind already has them.")
    } else {
        print("\(prefix)Toolpaths whose vectors changed:")
        for c in changes {
            let added = Set(c.newShapeIDs).subtracting(c.oldShapeIDs).count, removed = Set(c.oldShapeIDs).subtracting(c.newShapeIDs).count
            var how: [String] = []
            if added > 0 { how.append("\(added) added") }
            if removed > 0 { how.append("\(removed) removed") }
            if added == 0 && removed == 0 { how.append("reordered") }
            let none = c.newShapeIDs.isEmpty ? "; it now has no vectors" : ""
            print("\(prefix)  \(c.name) (\(c.rule.label(u))): \(c.oldShapeIDs.count) → \(counted(c.newShapeIDs.count, "vector")) (\(how.joined(separator: ", ")))\(none)")
        }
    }
    let byHand = project.operations.filter { $0.kind.needsShapes && ($0.vectorSelection == nil || $0.vectorSelection == .selection) }
    if !byHand.isEmpty {
        print("\(prefix)Kept as chosen by hand: " + byHand.map { "\($0.name) (\(counted($0.shapeIDs.count, "vector")))" }.joined(separator: ", "))
    }
}

/// `post --rebind`, `sim --rebind`: the project with its toolpaths rebound, in memory only.
func rebound(_ project: Project) -> Project {
    var p = project
    let changes = p.bindVectorChanges()
    printBinding(changes, project: p, prefix: "Rebind: ")
    return p
}

/// The format a project file says it's in, read from its JSON.
func savedFormat(_ path: String) -> Int? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    return json["formatVersion"] as? Int
}

func write(_ project: Project, to out: String) {
    do { try project.encoded().write(to: URL(fileURLWithPath: out)) } catch { fail("Can't write \(out): \(error.localizedDescription)") }
    print("Wrote \(out) (format \(project.formatVersion))")
}

/// Where `template apply` writes without -o: "<project> + <template>.nativecam" beside the project, or with " 2",
/// " 3"… when that file is already there.
func templatedPath(project: String, template: String) -> String {
    let projectURL = URL(fileURLWithPath: project)
    let dir = projectURL.deletingLastPathComponent()
    let stem = "\(projectURL.deletingPathExtension().lastPathComponent) + \(URL(fileURLWithPath: template).deletingPathExtension().lastPathComponent)"
    var n = 1
    while true {
        let url = dir.appendingPathComponent(n == 1 ? stem : "\(stem) \(n)").appendingPathExtension("nativecam")
        if !FileManager.default.fileExists(atPath: url.path) { return url.path }
        n += 1
    }
}

func formatTime(_ s: Double) -> String {
    let t = Int(s.rounded())
    return String(format: "%d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60)
}

/// `post --restart-*`: writes the restart file, or exits 1 with the refusal or the failed checks.
func postRestart(_ project: Project, job: JobResult, airCut: Double?) {
    func number(_ name: String) -> Int? {
        guard let text = option(name, in: args) else { return nil }
        guard let n = Int(text), n >= 1 else { fail("\(name) needs a whole number from 1") }
        return n
    }
    if option("--sheet", in: args) != nil { fail("--sheet is for the full job: post it without --restart-*") }
    var request = Restart.Request(file: (number("--restart-file") ?? 1) - 1, airCut: airCut)
    request.exact = args.contains("--restart-exact")
    request.pauseAbove = !args.contains("--restart-no-stop")
    if let line = number("--restart-line") {
        guard option("--restart-pass", in: args) == nil else { fail("Give --restart-line or --restart-pass, not both") }
        request.start = .line(line)
    } else {
        guard let toolpath = number("--restart-toolpath") else { fail("A restart needs --restart-toolpath n or --restart-line N") }
        request.toolpath = toolpath - 1
        request.start = number("--restart-pass").map { .pass($0) } ?? .toolpath
    }
    if let running = option("--restart-from", in: args) {
        guard let text = (try? String(contentsOfFile: running, encoding: .utf8)) ?? (try? String(contentsOfFile: running, encoding: .isoLatin1))
        else { fail("Can't read \(running)") }
        request.runningFile = text
        request.runningFileName = (running as NSString).lastPathComponent
    }
    let restart: Restart.Output
    do {
        restart = try Restart.make(project, job: job, request: request)
    } catch {
        fail("Restart refused: \(error.localizedDescription)")
    }
    for line in restart.header { print("  \(line)") }
    for issue in restart.issues { print("[\(issue.severity.rawValue)] Restart: \(issue.text)") }
    let errors = restart.issues.filter { $0.severity == .error }.count
    if errors > 0 {
        let reason = "the restart failed \(errors) check\(errors == 1 ? "" : "s")"
        guard args.contains("--force") else { fail("Not written: \(reason). Fix the errors above, or pass --force to write it anyway.") }
        print("Writing it anyway (--force): \(reason).")
    }
    let stem = option("-o", in: args).map { ($0 as NSString).deletingPathExtension } ?? (args[1] as NSString).deletingPathExtension
    let path = stem + (restart.file.suffix ?? "") + "." + restart.post.fileExtension
    do { try restart.file.gcode.write(toFile: path, atomically: true, encoding: .ascii) } catch { fail("Can't write \(path): \(error)") }
    let lines = restart.file.gcode.components(separatedBy: "\n").count - 1
    print("Restart: \(restart.toolpaths.count) toolpath\(restart.toolpaths.count == 1 ? "" : "s"), \(lines) lines -> \(path)")
    print("Estimated run time of the restart: \(formatTime(restart.remainingSeconds))")
}

/// `post --group name` / `--toolpaths list`: writes the file for part of the job, cut down from the full job, or exits 1.
func postSubset(_ project: Project, job: JobResult, airCut: Double?) {
    if args.contains(where: { $0.hasPrefix("--restart") }) { fail("Give --group or --toolpaths, or a restart, not both") }
    var request: JobSubset.Request
    var nameSuffix: String
    if let name = option("--group", in: args) {
        guard option("--toolpaths", in: args) == nil else { fail("Give --group or --toolpaths, not both") }
        let matches = project.toolpathGroups.filter { $0.name == name || $0.id.uuidString.caseInsensitiveCompare(name) == .orderedSame }
        guard matches.count == 1, let group = matches.first, let r = JobSubset.Request.group(group.id, in: project) else {
            let names = project.toolpathGroups.map { "“\($0.name)”" }.joined(separator: ", ")
            fail(matches.count > 1 ? "\(matches.count) groups are called “\(name)”: give its id instead"
                : "No group “\(name)” in the project" + (names.isEmpty ? " (it has no groups)" : "; its groups are \(names)"))
        }
        request = r
        nameSuffix = " - " + group.name
    } else {
        // Toolpaths by number in the run order (from 1), id or name, separated by commas.
        var ids = Set<UUID>()
        for item in option("--toolpaths", in: args)!.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if let n = Int(item) {
                guard n >= 1, n <= project.operations.count else { fail("The project has \(project.operations.count) toolpaths; there's no \(n)") }
                ids.insert(project.operations[n - 1].id)
            } else if let op = project.operations.first(where: { $0.id.uuidString.caseInsensitiveCompare(item) == .orderedSame }) {
                ids.insert(op.id)
            } else {
                let named = project.operations.filter { $0.name == item }
                guard named.count == 1 else { fail(named.isEmpty ? "No toolpath “\(item)”" : "\(named.count) toolpaths are called “\(item)”: give its number") }
                ids.insert(named[0].id)
            }
        }
        request = .toolpaths(ids, in: project)
        nameSuffix = " - " + (ids.count == 1 ? project.operations.first { ids.contains($0.id) }!.name : "selected")
    }
    request.fullRetract = args.contains("--full-retract")
    request.airCut = airCut
    let subset: JobSubset.Output
    do { subset = try JobSubset.make(project, job: job, request: request) } catch { fail("Not written: \(error.localizedDescription)") }
    for line in subset.header { print("  \(line)") }
    for issue in subset.issues { print("[\(issue.severity.rawValue)] Part of the job: \(issue.text)") }
    let jobErrors = job.issues.filter { $0.severity == .error }.count
    let errors = subset.issues.filter { $0.severity == .error }.count
    if jobErrors + errors > 0 {
        var reasons: [String] = []
        if jobErrors > 0 { reasons.append("the job has \(jobErrors) error\(jobErrors == 1 ? "" : "s")") }
        if errors > 0 { reasons.append("the G-code failed \(errors) check\(errors == 1 ? "" : "s")") }
        let reason = reasons.joined(separator: " and ")
        guard args.contains("--force") else { fail("Not written: \(reason). Fix the errors above, or pass --force to write it anyway.") }
        print("Writing it anyway (--force): \(reason).")
    }
    let stem = option("-o", in: args).map { ($0 as NSString).deletingPathExtension }
        ?? ((args[1] as NSString).deletingPathExtension + nameSuffix)
    let ext = subset.post.fileExtension
    let names = JobExport.fileNames(subset.files, base: stem + "." + ext, fileExtension: ext)
    for (file, path) in zip(subset.files, names) {
        do { try file.gcode.write(toFile: path, atomically: true, encoding: .ascii) } catch { fail("Can't write \(path): \(error)") }
    }
    if let sheet = option("--sheet", in: args) {
        let html = SetupSheet.html(project: subset.project, job: subset.job, gcodeFile: (names[0] as NSString).lastPathComponent,
                                   checks: subset.issues, part: subset.setupSheetLines)
        do { try html.write(toFile: sheet, atomically: true, encoding: .utf8) } catch { fail("Can't write \(sheet): \(error)") }
        print("Setup sheet -> \(sheet)")
    }
    let lines = subset.files.map(\.gcode).joined().components(separatedBy: "\n").count - 1
    print("Part of the job: \(subset.included.count) toolpath\(subset.included.count == 1 ? "" : "s"), \(lines) lines -> "
          + names.joined(separator: ", "))
    if let e = subset.job.estimate { print("Estimated run time of the part: \(formatTime(e.total))") }
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    print("usage: nativecam-cli demo <out.nativecam> | post <project> [-o out.tap] [--restart-*] | surface [project] [-o file] | sim <project|tap> [--png out.png] [--cell mm]"
          + " | tools <library> [-o out.json] | import <project> <file>… (-o out | --in-place) | rebind <project> (-o out | --in-place)"
          + " | save <project> (-o out | --in-place)")
    exit(0)
}

switch command {
case "demo", "demo3d", "demonest", "demosheets", "new":
    guard args.count >= 2 else { fail("usage: nativecam-cli \(command) <out.nativecam>") }
    let project = command == "demo3d" ? Project.demoRelief() : command == "demonest" ? Project.demoNesting()
        : command == "demosheets" ? Project.demoNestingSheets() : command == "new" ? Project() : Project.demoSign()
    do {
        var url = URL(fileURLWithPath: args[1])
        try project.encoded().write(to: url)
        var values = URLResourceValues()
        values.hasHiddenExtension = true
        try? url.setResourceValues(values)
        print("Wrote \(args[1])")
    } catch {
        fail("Can't write: \(error.localizedDescription)")
    }

case "post":
    guard args.count >= 2 else { fail("usage: nativecam-cli post <project.nativecam> [-o out.tap] [--air-cut height] [--sheet out.html] [--force]\n"
                                         + "       nativecam-cli post <project.nativecam> --restart-toolpath n [--restart-pass p] | --restart-line N "
                                         + "[--restart-exact] [--restart-no-stop] [--restart-file n] [--restart-from running.tap]") }
    // --rebind: toolpaths that find vectors by layer or kind look again first, in memory only (the file isn't saved).
    let project = args.contains("--rebind") ? rebound(loadProject(args[1])) : loadProject(args[1])
    let start = Date()
    let job = CAMEngine.generate(project)
    let elapsed = Date().timeIntervalSince(start)
    for issue in job.issues {
        print("[\(issue.severity.rawValue)] \(issue.operation.map { "\($0): " } ?? "")\(issue.message)")
    }
    let noPost = PostProcessors.unavailableReason(for: project.machine) ?? "No post processor for this machine."
    var airCut: Double?
    if let text = option("--air-cut", in: args) {
        guard let h = Double(text), h > 0 else { fail("--air-cut needs a height above zero") }
        airCut = project.machine.outputUnits.toMM(h)
    }
    if args.contains(where: { $0.hasPrefix("--restart") }) {
        postRestart(project, job: job, airCut: airCut)
        exit(0)
    }
    if option("--group", in: args) != nil || option("--toolpaths", in: args) != nil {
        postSubset(project, job: job, airCut: airCut)
        exit(0)
    }
    // One file, one per tool where the controller can't stop for a change, and on a tiled job that for each tile.
    guard let output = JobExport.files(project, job: job, airCut: airCut) else { fail(noPost) }
    let post = output.post
    var checks: [GCodeCheck.Issue] = []
    for file in output.files {
        let found = GCodeCheck.run(file.gcode, toolpaths: file.toolpaths, project: file.project, dialect: post.dialect)
        for issue in found { print("[\(issue.severity.rawValue)] G-code\(output.files.count > 1 ? file.suffix ?? "" : ""): \(issue.text)") }
        checks += found
    }
    let stem = option("-o", in: args).map { ($0 as NSString).deletingPathExtension } ?? (args[1] as NSString).deletingPathExtension
    if let sheet = option("--sheet", in: args) {
        let html = SetupSheet.html(project: project, job: job, gcodeFile: (stem as NSString).lastPathComponent + "." + post.fileExtension,
                                   checks: checks)
        do { try html.write(toFile: sheet, atomically: true, encoding: .utf8) } catch { fail("Can't write \(sheet): \(error)") }
        print("Setup sheet -> \(sheet)")
    }
    // Errors in the job's own checks stop it as G-code check errors do, as the app's "Export Anyway?" does; warnings
    // and notes don't.
    let jobErrors = job.issues.filter { $0.severity == .error }.count
    let fileErrors = checks.filter { $0.severity == .error }.count
    if jobErrors + fileErrors > 0 {
        var reasons: [String] = []
        if jobErrors > 0 { reasons.append("the job has \(jobErrors) error\(jobErrors == 1 ? "" : "s")") }
        if fileErrors > 0 { reasons.append("the G-code failed \(fileErrors) check\(fileErrors == 1 ? "" : "s")") }
        let reason = reasons.joined(separator: " and ")
        guard args.contains("--force") else {
            fail("Not written: \(reason). Fix the errors above, or pass --force to write it anyway.")
        }
        print("Writing it anyway (--force): \(reason).")
    }
    var outputs: [String] = []
    for file in output.files {
        let path = stem + (file.suffix ?? "") + "." + post.fileExtension
        do { try file.gcode.write(toFile: path, atomically: true, encoding: .ascii) } catch { fail("Can't write \(path): \(error)") }
        outputs.append(path)
    }
    let out = outputs.joined(separator: ", ")
    let gcode = output.files.map(\.gcode).joined()
    let lines = gcode.components(separatedBy: "\n").count - 1
    print(String(format: "Generated %d toolpaths in %.2fs, %d lines -> %@", job.toolpaths.count, elapsed, lines, out))
    if let e = job.estimate {
        print("Estimated run time: \(formatTime(e.total)) (cutting \(formatTime(e.feedSeconds)), rapids \(formatTime(e.rapidSeconds)), "
              + "tool changes/pauses \(formatTime(e.overheadSeconds)); distance/feed alone: \(formatTime(e.constantVelocity)))")
        for (tp, seconds) in zip(job.toolpaths, e.toolpathSeconds) { print("  \(tp.name): \(formatTime(seconds))") }
    }

case "acceptance":
    // A short program exercising everything a post writes, for trying a controller: check mode, air cut, then scrap.
    var machine = args.count >= 2 && !args[1].hasPrefix("-") ? loadProject(args[1]).machine : MachineProfile()
    if let family = option("--controller", in: args) {
        machine.controller = ControllerProfile(family: ControllerFamily(rawValue: family), sender: option("--sender", in: args))
        machine.model = .custom
    }
    if let units = option("--units", in: args) { machine.outputUnits = units == "mm" ? .mm : .inch }
    switch option("--tool-change", in: args) {
    case "pause": machine.toolChange = .manualPause
    case "atc": machine.toolChange = .atc
    case "m6": machine.toolChange = .manualM6
    default: break
    }
    let (project, toolpaths) = AcceptanceTest.job(machine: machine)
    guard let post = PostProcessors.post(for: project) else {
        fail(PostProcessors.unavailableReason(for: machine) ?? "No post processor for this machine.")
    }
    let stem = option("-o", in: args).map { ($0 as NSString).deletingPathExtension } ?? "acceptance-\(post.dialect.id)"
    for file in post.files(toolpaths) {
        for issue in GCodeCheck.run(file.gcode, toolpaths: file.toolpaths, project: project, dialect: post.dialect) {
            print("[\(issue.severity.rawValue)] G-code\(file.suffix ?? ""): \(issue.text)")
        }
        let path = stem + (file.suffix ?? "") + "." + post.fileExtension
        do { try file.gcode.write(toFile: path, atomically: true, encoding: .ascii) } catch { fail("Can't write \(path): \(error)") }
        print("\(post.name) acceptance test -> \(path)")
    }

case "calibrate":
    // Calibration programs for the project's machine, and fitting its values to the times measured with them.
    let usage = "usage: nativecam-cli calibrate timing|rotary|ladder [project.nativecam] [--controller c] [-o stem]"
        + " | calibrate fit <times.csv> [project.nativecam] [--apply] [-o out.nativecam]"
    guard args.count >= 2 else { fail(usage) }
    let sub = args[1]
    let rest = Array(args.dropFirst(2))
    let projectPath = rest.first { $0.hasSuffix(".nativecam") }
    let loaded = projectPath.map(loadProject)
    if sub == "fit" {
        let csvs = rest.filter { $0.lowercased().hasSuffix(".csv") }
        guard !csvs.isEmpty else { fail("usage: nativecam-cli calibrate fit <times.csv> [project.nativecam] [--apply] [-o out.nativecam]") }
        let machine = loaded?.machine ?? MachineProfile()
        let result: Calibration.FitResult
        do {
            let times = try csvs.map { path -> Calibration.Times in
                do { return try Calibration.readTimes(String(contentsOfFile: path, encoding: .utf8)) } catch let r as Calibration.Refused {
                    throw Calibration.Refused("\(path): \(r.reason)")
                }
            }
            result = try Calibration.fit(times, machine: machine)
        } catch {
            fail("Not fitted: \(error.localizedDescription)")
        }
        let u = loaded?.displayUnits ?? machine.outputUnits
        print("Fitted \(result.programs.map(\.label).joined(separator: " and ")) times for \(machine.displayName), \(machine.controllerLabel):")
        for line in result.report(u) { print(line) }
        if args.contains("--apply") {
            guard var project = loaded, let path = projectPath else { fail("--apply needs the project whose machine to change") }
            if result.changes.isEmpty {
                print("Nothing to apply: the fitted values are the machine's own.")
            } else {
                result.apply(to: &project.machine)
                let out = option("-o", in: args) ?? path
                do { try project.encoded().write(to: URL(fileURLWithPath: out)) } catch { fail("Can't write \(out): \(error)") }
                print("Applied \(result.changes.map { $0.label.lowercased() }.joined(separator: ", ")) to \(out)")
            }
        } else if loaded != nil, !result.changes.isEmpty {
            print("Nothing changed: add --apply to write these values into the project's machine.")
        }
        exit(0)
    }
    guard let kind = Calibration.Kind(rawValue: sub) else { fail(usage) }
    var machine = loaded?.machine ?? MachineProfile()
    if let family = option("--controller", in: args) {
        machine.controller = ControllerProfile(family: ControllerFamily(rawValue: family), sender: option("--sender", in: args))
        machine.model = .custom
    }
    if let units = option("--units", in: args) { machine.outputUnits = units == "mm" ? .mm : .inch }
    let u = machine.outputUnits
    func length(_ name: String) -> Double? {
        guard let text = option(name, in: args) else { return nil }
        guard let v = Double(text), v > 0 else { fail("\(name) takes a length in \(u.symbol)") }
        return u.toMM(v)
    }
    let program: Calibration.Program
    do {
        switch kind {
        case .timing:
            var options = Calibration.TimingOptions.defaults(u)
            if let text = option("--window", in: args) {
                let parts = text.lowercased().split(separator: "x").compactMap { Double($0) }
                guard parts.count == 2, parts.allSatisfy({ $0 > 0 }) else { fail("--window takes a width and height, e.g. 24x24, in \(u.symbol)") }
                options.window = Vec2(u.toMM(parts[0]), u.toMM(parts[1]))
            }
            if let air = length("--air") { options.airHeight = air }
            program = try Calibration.timing(machine: machine, options: options)
        case .rotary:
            program = try Calibration.rotary(machine: machine)
        case .ladder:
            let number = option("--tool", in: args).map { Int($0) ?? -1 } ?? 1
            let projectTools = loaded?.operations.map(\.tool) ?? []
            guard let tool = projectTools.first(where: { $0.number == number }) ?? ToolLibrary.starter.tool(number: number) else {
                fail("--tool \(number): no such tool in the project or the starter library")
            }
            var material = loaded?.stock.material ?? .hardwood
            if let text = option("--material", in: args) {
                guard let m = MaterialKind(rawValue: text) else {
                    fail("--material takes one of: \(MaterialKind.allCases.map(\.rawValue).joined(separator: ", "))")
                }
                material = m
            }
            var options = Calibration.LadderOptions(tool: tool, material: material, depth: length("--depth"))
            if let text = option("--rungs", in: args) { options.rungs = Int(text) ?? options.rungs }
            options.stepRPM = args.contains("--step-rpm")
            program = try Calibration.ladder(machine: machine, options: options)
        }
    } catch {
        fail("Not written: \(error.localizedDescription)")
    }
    for issue in program.issues { print("[\(issue.severity.rawValue)] \(issue.text)") }
    if !program.passedChecks { fail("Not written: the \(kind.label.lowercased()) failed its checks.") }
    let stem = option("-o", in: args).map { ($0 as NSString).deletingPathExtension } ?? kind.fileStem
    let gcodePath = stem + "." + program.fileExtension, sheetPath = stem + ".html", timesPath = stem + "-times.csv"
    do {
        try program.gcode.write(toFile: gcodePath, atomically: true, encoding: .ascii)
        try RecordingSheet.html(program).write(toFile: sheetPath, atomically: true, encoding: .utf8)
        if kind != .ladder { try Calibration.timesCSV(program).write(toFile: timesPath, atomically: true, encoding: .utf8) }
    } catch {
        fail("Can't write: \(error.localizedDescription)")
    }
    print("\(program.dialect.name) \(kind.label.lowercased()) -> \(gcodePath)")
    print("Recording sheet -> \(sheetPath)")
    if kind != .ladder { print("Times file -> \(timesPath)") }
    for s in program.sections {
        print("  \(s.id)  \(s.name): \(s.count)x, about \(String(format: "%.1f", s.estimate)) s")
    }
    for r in program.rungs {
        print("  Rung \(r.number): \(Calibration.feed(r.feed, u)) at \(Int(r.rpm)) RPM, \(Calibration.chipText(r.chipLoad, u)), \(r.chart.label.lowercased())")
    }
    print("Moves take about \(formatTime(program.estimatedSeconds))\(kind == .ladder ? "" : ", plus the stops")")

case "surface":
    // A standalone spoilboard surfacing program, checked, with an air-cut copy. The project (if any) only lends its machine
    // and tools; it isn't changed.
    let rest = Array(args.dropFirst())
    let loaded = rest.first { $0.hasSuffix(".nativecam") }.map(loadProject)
    var machine = loaded?.machine ?? MachineProfile()
    if let family = option("--controller", in: args) {
        machine.controller = ControllerProfile(family: ControllerFamily(rawValue: family), sender: option("--sender", in: args))
        machine.model = .custom
    }
    if let units = option("--units", in: args) { machine.outputUnits = units == "mm" ? .mm : .inch }
    let u = machine.outputUnits
    func length(_ name: String) -> Double? {
        guard let text = option(name, in: args) else { return nil }
        guard let v = Double(text), v >= 0 else { fail("\(name) takes a length in \(u.symbol)") }
        return u.toMM(v)
    }
    var tool = Surfacing.starterBit
    if let text = option("--bit", in: args) {
        let number = Int(text.uppercased().trimmingCharacters(in: CharacterSet(charactersIn: "T"))) ?? -1
        let projectTools = loaded?.operations.map(\.tool) ?? []
        guard let t = projectTools.first(where: { $0.number == number }) ?? ToolLibrary.starter.tool(number: number) else {
            fail("--bit \(text): no such tool in the project or the starter library")
        }
        tool = t
    }
    var options = Surfacing.Options.defaults(u, tool: tool)
    if let text = option("--area", in: args), text.lowercased() != "bed" {
        let parts = text.lowercased().split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2, parts.allSatisfy({ $0 > 0 }) else { fail("--area takes bed or a width and height, e.g. 24x36, in \(u.symbol)") }
        options.area = .custom(Vec2(u.toMM(parts[0]), u.toMM(parts[1])))
    }
    if let text = option("--stepover", in: args) {
        guard let v = Double(text.trimmingCharacters(in: CharacterSet(charactersIn: "%"))) else { fail("--stepover takes a percentage, e.g. 50") }
        options.stepover = v / 100
    }
    if let d = length("--depth") { options.depth = d }
    if let text = option("--passes", in: args) {
        guard let n = Int(text) else { fail("--passes takes a whole number") }
        options.passes = n
    }
    if let text = option("--along", in: args) {
        guard let a = Surfacing.Along(rawValue: text.lowercased()) else { fail("--along takes x or y") }
        options.along = a
    }
    if args.contains("--one-way") { options.direction = .oneWay }
    options.overshoot = length("--overshoot")
    options.inset = length("--inset")
    options.clampOvershoot = args.contains("--clamp-overshoot")
    if let c = length("--clearance") { options.clearance = c }
    options.boardThickness = length("--board")
    let program: Surfacing.Program
    do {
        program = try Surfacing.program(machine: machine, options: options)
    } catch {
        fail("Not written: \(error.localizedDescription)")
    }
    for issue in program.issues { print("[\(issue.severity.rawValue)] \(issue.text)") }
    for issue in program.airIssues { print("[\(issue.severity.rawValue)] Air cut: \(issue.text)") }
    if !program.passedChecks { fail("Not written: the surfacing program failed its checks.") }
    let path = option("-o", in: args) ?? program.fileName
    let stem = (path as NSString).deletingPathExtension
    let ext = (path as NSString).pathExtension.isEmpty ? program.fileExtension : (path as NSString).pathExtension
    let gcodePath = stem + "." + ext, airPath = stem + "-air." + ext
    let air = !args.contains("--no-air-cut")
    do {
        try program.gcode.write(toFile: gcodePath, atomically: true, encoding: .ascii)
        if air { try program.airGCode.write(toFile: airPath, atomically: true, encoding: .ascii) }
    } catch {
        fail("Can't write: \(error.localizedDescription)")
    }
    let plan = program.plan
    print("\(program.dialect.name) spoilboard surfacing -> \(gcodePath)")
    if air { print("Air cut (Z raised \(Calibration.length(Surfacing.airHeight(u), u))) -> \(airPath)") }
    print("  \(Calibration.size(plan.area, u)), \(plan.lines.count) lines \(options.along == .x ? "along X" : "along Y") "
        + "\(Calibration.length(plan.spacing, u)) apart, \(options.direction.label.lowercased()), "
        + "\(options.passes) x \(Calibration.length(options.depth, u)) = \(Calibration.length(plan.totalDepth, u)) deep")
    print("  \(tool.name): \(Calibration.feed(plan.feed, u)), \(Int(plan.rpm)) RPM; overshoot \(Calibration.length(plan.overshoot, u)), "
        + "entry: \(plan.entry == .ramp ? "ramp of \(Calibration.length(plan.rampLength, u))" : "plunge past the edge")")
    for line in program.setup.prefix(2) { print("  " + line) }
    print("Estimated run time: \(formatTime(program.estimatedSeconds))")

case "machine":
    // Read machine limits from a controller's settings ($$ dump, Machine.ini, LinuxCNC INI, FluidNC YAML, Fusion .mch).
    guard args.count >= 2 else { fail("usage: nativecam-cli machine <settings file> [--apply project.nativecam [-o out.nativecam]]") }
    let found: MachineImport
    do { found = try MachineSettingsImporter.load(url: URL(fileURLWithPath: args[1])) } catch {
        fail("Can't read \(args[1]): \(error.localizedDescription)")
    }
    let target = option("--apply", in: args).map(loadProject)
    let u = target?.displayUnits ?? found.outputUnits ?? .inch
    print("\(found.format.rawValue)\(found.machineName.map { ": \($0)" } ?? "")")
    if let c = found.controller { print("  Controller: \(c.family.label)") }
    if let units = found.outputUnits { print("  G-code units: \(units.symbol)") }
    if found.hasToolChanger == true { print("  Tool changer: yes") }
    for s in found.settings {
        print("  \(s.key.label): \(s.display(u))  (\(s.source.note ?? ""))")
    }
    for n in found.notes { print("  Note: \(n)") }
    if var project = target {
        for s in found.settings where !s.key.applies(to: project.machine) {
            print("  Not applied: \(s.key.label), since the project's machine has no rotary axis")
        }
        found.apply(to: &project.machine, keys: Set(found.settings.map(\.key)))
        let out = option("-o", in: args) ?? option("--apply", in: args)!
        do { try project.encoded().write(to: URL(fileURLWithPath: out)) } catch { fail("Can't write \(out): \(error)") }
        print("Applied to \(out)")
    }

case "tools":
    guard args.count >= 2 else { fail("usage: nativecam-cli tools <library.tools|.vtdb|.json> [-o out.json]") }
    let result: ToolImport
    do { result = try ToolLibraryImporter.load(url: URL(fileURLWithPath: args[1])) } catch {
        fail("Can't import \(args[1]): \(error.localizedDescription)")
    }
    print("\(result.format.rawValue): \(result.tools.count) tools, \(result.skipped.count) skipped")
    for (shape, n) in Dictionary(grouping: result.tools, by: { $0.tool.shape.label }).mapValues(\.count).sorted(by: { $0.key < $1.key }) {
        print("  \(shape): \(n)")
    }
    for (reason, n) in Dictionary(grouping: result.skipped, by: \.reason).mapValues(\.count).sorted(by: { $0.value > $1.value }) {
        print("  skipped \(n): \(reason)")
    }
    let estimatedLength = result.tools.filter { $0.tool.notes.contains("Cutting length estimated") }.count
    let estimatedFeeds = result.tools.filter { $0.tool.notes.contains("feed rate") }.count
    let estimatedSteps = result.tools.filter { $0.tool.notes.contains("conservative defaults") }.count
    print("  estimated: cutting length for \(estimatedLength), feed rate for \(estimatedFeeds), some value for \(estimatedSteps)")
    if let out = option("-o", in: args) {
        var lib = ToolLibrary(tools: result.tools.map(\.tool))
        for i in lib.tools.indices { lib.tools[i].number = i + 1 }
        do { try lib.encoded().write(to: URL(fileURLWithPath: out)) } catch { fail("Can't write \(out): \(error.localizedDescription)") }
        print("Wrote \(lib.tools.count) tools to \(out)")
    }

case "template":
    let usage = "usage: nativecam-cli template save <project> -o <out.nativecamtemplate> [--no-setup]"
        + " | template apply <template> <project> [-o out.nativecam | --in-place] [--setup] [--tools library.json]"
        + " [--create-layers | --skip-missing]"
    switch args.count >= 3 ? args[1] : "" {
    case "save":
        guard let out = option("-o", in: args) else { fail(usage) }
        let project = loadProject(args[2])
        let name = URL(fileURLWithPath: out).deletingPathExtension().lastPathComponent
        let template = ToolpathTemplate(name: name, project: project, includeJobSetup: !args.contains("--no-setup"))
        do { try template.encoded().write(to: URL(fileURLWithPath: out)) } catch { fail("Can't write \(out): \(error.localizedDescription)") }
        print("Saved \(template.operations.count) toolpaths to \(out) (format \(template.formatVersion))")
        for op in template.operations { print("  \(op.name): \(op.vectorSelection?.label(project.displayUnits) ?? "no vectors needed")") }
    case "apply":
        guard args.count >= 4 else { fail(usage) }
        // Bad flags are refused before anything is read, applied or printed.
        if option("-o", in: args) != nil && args.contains("--in-place") { fail("Pass -o or --in-place, not both.\n" + usage) }
        if args.contains("--create-layers") && args.contains("--skip-missing") {
            fail("Pass --create-layers or --skip-missing, not both.\n" + usage)
        }
        let template: ToolpathTemplate
        do { template = try ToolpathTemplate.decode(Data(contentsOf: URL(fileURLWithPath: args[2]))) } catch {
            fail("Can't read template \(args[2]): \(error.localizedDescription)")
        }
        let project = loadProject(args[3])
        var library = ToolLibrary.starter
        if let path = option("--tools", in: args) {
            do { library = try ToolLibrary.decode(Data(contentsOf: URL(fileURLWithPath: path))) } catch {
                fail("Can't read tool library \(path): \(error.localizedDescription)")
            }
        }
        // A template never adds toolpaths for layers the design doesn't have unless told what to do about them.
        let missing = template.missingLayers(in: project)
        let choice: ToolpathTemplate.MissingLayers = args.contains("--create-layers") ? .create : args.contains("--skip-missing") ? .skip : .addEmpty
        let missingList = missing.map { "“\($0)”" }.joined(separator: ", ")
        if !missing.isEmpty && choice == .addEmpty {
            fail("The design has no \(missing.count == 1 ? "layer" : "layers") \(missingList), which the template's toolpaths find their"
                 + " vectors on. Pass --create-layers to make \(missing.count == 1 ? "it" : "them") (empty, so vectors can be put on"
                 + " \(missing.count == 1 ? "it" : "them") later) or --skip-missing to leave out those toolpaths.")
        }
        let result = template.apply(to: project, library: library, useJobSetup: args.contains("--setup"), missingLayers: choice)
        let u = project.displayUnits
        if !result.createdLayers.isEmpty {
            print("Created \(result.createdLayers.count == 1 ? "layer" : "layers") \(result.createdLayers.map { "“\($0)”" }.joined(separator: ", ")) (empty)")
        }
        if choice == .skip && !missing.isEmpty {
            print("Skipped \(counted(result.skippedCount, "toolpath")) on missing \(missing.count == 1 ? "layer" : "layers") \(missingList)")
        }
        for row in result.rows {
            let how = row.skipped ? ", skipped" : row.isEmpty ? ", added empty" : ""
            let found = row.rule.map { "\($0.label(u)): \(counted(row.shapeCount, "vector"))\(how)" } ?? "needs no vectors"
            print("  \(row.name): \(found)")
        }
        for use in result.tools {
            let was = use.templateNumber.map { ", T\($0) in the template" } ?? ""
            print("  T\(use.tool.number) \(use.tool.name): \(use.inLibrary ? "in the library" : "not in the library")\(was)")
        }
        for change in result.setupChanges { print("  \(change.setting): \(change.from) → \(change.to)") }
        if let note = result.machineNote { print("  \(note)") }
        let empty = result.emptyCount == 0 ? "every toolpath found its vectors" : "\(counted(result.emptyCount, "toolpath")) found no vectors"
        print("Material \(u.format(result.project.stock.thickness)) \(u.symbol); \(empty)")
        // Never over the project unless asked: by default a new file beside it, numbered if the name is taken.
        let out = option("-o", in: args) ?? (args.contains("--in-place") ? args[3] : templatedPath(project: args[3], template: args[2]))
        do { try result.project.encoded().write(to: URL(fileURLWithPath: out)) } catch { fail("Can't write \(out): \(error.localizedDescription)") }
        print("Wrote \(out) (format \(result.project.formatVersion))")
    default:
        fail(usage)
    }

case "sim":
    guard args.count >= 2 else { fail("usage: nativecam-cli sim <project|tap|nc|sbp> [--png out.png]") }
    let path = args[1]
    var project: Project
    var toolpaths: [Toolpath]
    // A project's simulation runs at its run-time estimate's pace, as in the app.
    var estimate: CycleTimeEstimate?
    let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
    if ["tap", "nc", "gcode", "ngc", "cnc", "txt", "sbp"].contains(ext) {
        if args.contains("--rebind") { fail("--rebind is for a project: a G-code file has no toolpaths to rebind") }
        project = Project()
        // Files from older CAM programs aren't always UTF-8; Latin-1 reads any bytes.
        guard let text = (try? String(contentsOfFile: path, encoding: .utf8))
            ?? (try? String(contentsOfFile: path, encoding: .isoLatin1)) else {
            fail("Can't read \(path)")
        }
        do {
            let program = ext == "sbp" ? OpenSBPParser.parse(text)
                : try GCodeParser.parse(text, controller: Dialect.for(project.machine))
            program.warnings.forEach { print("[warning] \($0)") }
            toolpaths = program.toolpaths(tools: ToolLibrary.starter.tools, stock: project.stock,
                                          fallback: ToolLibrary.starter.tools[0])
        } catch {
            fail("G-code error: \(error.localizedDescription)")
        }
    } else {
        project = loadProject(path)
        if args.contains("--rebind") { project = rebound(project) }
        if args.contains("--no-arcs") { project.machine.outputArcs = false }
        let job = CAMEngine.generate(project)
        toolpaths = job.toolpaths
        estimate = job.estimate
    }
    let cell = option("--cell", in: args).flatMap(Double.init)
    var session = SimulationSession(toolpaths: toolpaths, stock: project.stock,
                                    rapidRate: project.machine.rapidRateForEstimates, cellSize: cell, estimate: estimate,
                                    turnSpeed: project.machine.rotary?.drivenTurnSpeed)
    let start = Date()
    session.runToEnd()
    let elapsed = Date().timeIntervalSince(start)
    let grid = session.grid
    print(String(format: "Simulated %d steps on a %dx%d grid (%.2f mm cells) in %.2fs",
                 session.timeline.steps.count, grid.columns, grid.rows, grid.cellSize, elapsed))
    if project.stock.rotary == nil {
        print(String(format: "Removed %.1f cm³ of material; job time %@", grid.removedVolume / 1000, formatTime(session.timeline.duration)))
    } else {
        // Each face of a rotary blank is simulated in its own frame; their removals overlap, so they aren't added up.
        print("Rotary blank, job time \(formatTime(session.timeline.duration)):")
        for (i, angle) in session.faceAngles.enumerated() {
            print(String(format: "  Face at %@: removed %.1f cm³ below the face", RotaryIndex.label(angle), session.grid(face: i).removedVolume / 1000))
        }
        if let radial = session.radialGrid {
            print(String(format: "  Wrapped toolpaths: removed %.1f cm³ all the way round (heights and PNG show the sheet unrolled)",
                         radial.removedVolume / 1000))
        }
    }
    if !session.rapidCollisions.isEmpty {
        print("[error] \(session.rapidCollisions.count) rapid move(s) cut through material")
    }
    if let path = option("--heights", in: args) {
        var data = Data()
        func put<T>(_ v: T) { withUnsafeBytes(of: v) { data.append(contentsOf: $0) } }
        put(Int32(grid.columns)); put(Int32(grid.rows)); put(grid.cellSize); put(grid.origin.x); put(grid.origin.y)
        grid.heights.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
        do { try data.write(to: URL(fileURLWithPath: path)); print("Wrote \(path)") } catch { fail("heights: \(error)") }
    }
    if let png = option("--png", in: args) {
        do { try HeightmapImage.writePNG(grid, to: URL(fileURLWithPath: png)); print("Wrote \(png)") } catch { fail("PNG: \(error)") }
    }

case "nest":
    let usage = "usage: nativecam-cli nest <project.nativecam> [-o out.nativecam | --in-place] [--spacing x] [--margin x]"
        + " [--turns none|90|N] [--grain] [--seconds s] [--seed n] [--evaluations n] [--sheets n] [--sheet-size WxH] [--no-holes]"
        + " [--svg preview.svg]"
    guard args.count >= 2 else { fail(usage) }
    if option("-o", in: args) != nil && args.contains("--in-place") { fail("Pass -o or --in-place, not both.\n" + usage) }
    let project = loadProject(args[1])
    let u = project.displayUnits
    func length(_ name: String) -> Double? {
        guard let text = option(name, in: args) else { return nil }
        guard let v = Double(text), v >= 0 else { fail("\(name) takes a length in \(u.symbol)") }
        return u.toMM(v)
    }
    let job: NestJob
    do { job = try NestJob.prepare(project, selection: []) } catch {
        fail(error.localizedDescription)
    }
    var settings = job.defaultSettings
    if let v = length("--spacing") { settings.spacing = v }
    settings.edgeMargin = length("--margin") ?? settings.spacing
    switch option("--turns", in: args) {
    case nil, "90": settings.rotation = .quarterTurns
    case "none", "0": settings.rotation = .none
    case let t?:
        guard let n = Int(t), n >= 1, n <= 72 else { fail("--turns takes none, 90 or a number of steps (1–72)") }
        settings.rotation = .steps(n)
    }
    settings.keepGrain = args.contains("--grain")
    if let t = option("--seconds", in: args) { settings.timeLimit = Double(t) ?? settings.timeLimit }
    if let t = option("--seed", in: args) { settings.seed = UInt64(t) ?? settings.seed }
    if let t = option("--evaluations", in: args) { settings.maxEvaluations = Int(t) }
    // Up to 10 sheets, as Nest Parts in the app starts with, unless the job has more.
    settings.maxSheets = max(settings.maxSheets, NestJob.defaultSheetLimit)
    if let t = option("--sheets", in: args) {
        guard let n = Int(t), n >= 1 else { fail("--sheets takes a number of sheets, 1 or more") }
        settings.maxSheets = n
    }
    if let t = option("--sheet-size", in: args) {
        let parts = t.lowercased().split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2, parts.allSatisfy({ $0 > 0 }) else { fail("--sheet-size takes a width and height, e.g. 48x96, in \(u.symbol)") }
        settings.nextSheetSize = Vec2(u.toMM(parts[0]), u.toMM(parts[1]))
    }
    if args.contains("--no-holes") { settings.partInPart = false }
    let result = job.nest(settings)
    let applied = job.apply(result, to: project, settings: settings)
    print("Nested \(result.placedCount) of \(counted(job.parts.count, "part")) in \(String(format: "%.1f", result.elapsed)) s "
          + "(\(counted(result.evaluations, "layout")) tried), spacing \(u.format(settings.spacing)) \(u.symbol), "
          + "edge margin \(u.format(settings.edgeMargin)) \(u.symbol)")
    if result.sheetCount > 1 {
        print("On \(result.sheetCount) sheets: " + result.sheets.enumerated().map { "sheet \($0 + 1) \(counted($1.partCount, "part"))" }.joined(separator: ", "))
    }
    if !result.inHoles.isEmpty {
        print("In other parts' holes: " + result.inHoles.map { "\(job.parts[$0].name) in \(result.insideOf[$0].map { job.parts[$0].name } ?? "")" }
            .joined(separator: ", "))
    }
    print(String(format: "Parts fill %.0f%% of the %@ %@ of the %@ they use (%.0f%% of %@)", result.utilization * 100,
                 u.format(result.usedLength), u.symbol, result.sheetCount > 1 ? "last sheet" : "sheet", result.sheetUtilization * 100,
                 result.sheetCount > 1 ? "all the sheets' area" : "the sheet"))
    for part in job.parts where part.reach > settings.spacing + 1e-6 {
        print("  \(part.name): “\(part.reachToolpath ?? "")” cuts \(u.format(part.reach)) \(u.symbol) outside it, so it keeps that far from the others")
    }
    for part in job.parts where (part.leadReach ?? 0) > settings.spacing + 1e-6 {
        print("  \(part.name): “\(part.leadToolpath ?? "")” has lead-ins reaching \(u.format(part.leadReach ?? 0)) \(u.symbol); "
              + "nearer another part they're shortened or left off")
    }
    for name in applied.leftInPlace { print("  Didn't fit, stays where it is: \(name)") }
    for name in applied.movedAside { print("  Didn't fit, moved beside the sheet: \(name)") }
    if !result.unplaced.isEmpty, result.sheetCount >= settings.sheetLimit {
        let n = settings.sheetLimit
        print("  \(counted(result.unplaced.count, "part")) didn't fit on \(counted(n, "sheet")); pass --sheets \(n + 1) to use another sheet")
    }
    for note in job.notes { print("  \(note)") }
    if let svg = option("--svg", in: args) {
        // The sheets side by side, left to right.
        let sheets = result.sheets.map(\.sheet)
        let pad = 10.0, gap = 0.05 * (sheets.map(\.width).max() ?? job.sheet.width)
        let top = sheets.map(\.height).max() ?? job.sheet.height
        let offsets = sheets.indices.map { k in sheets[..<k].reduce(0) { $0 + $1.width + gap } }
        func points(_ p: Polyline, _ k: Int) -> String {
            p.points.map { String(format: "%.2f,%.2f", $0.x + offsets[k], top - $0.y) }.joined(separator: " ")
        }
        let width = (offsets.last ?? 0) + (sheets.last?.width ?? job.sheet.width) + 2 * pad
        var out = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"\(-pad) \(-pad) \(width) \(top + 2 * pad)\">\n"
        for (k, sheet) in sheets.enumerated() {
            out += "<rect x=\"\(offsets[k])\" y=\"\(top - sheet.height)\" width=\"\(sheet.width)\" height=\"\(sheet.height)\" fill=\"#f3ead8\" stroke=\"#8a7a5a\"/>\n"
            for o in job.obstacles where o.isOn(sheet: k) {
                for p in o.outlines { out += "<polygon points=\"\(points(p, k))\" fill=\"#bbb\" stroke=\"#777\"/>\n" }
            }
        }
        for (i, part) in job.parts.enumerated() {
            guard let place = result.placements[i], place.sheet < sheets.count else { continue }
            for p in part.outlines {
                out += "<polygon points=\"\(points(place.apply(p), place.sheet))\" fill=\"#7fb0e0\" stroke=\"#2a5d8f\"/>\n"
            }
            for h in part.holes {
                out += "<polygon points=\"\(points(place.apply(h.outline), place.sheet))\" fill=\"#f3ead8\" stroke=\"#2a5d8f\"/>\n"
            }
        }
        // Parts in holes go over the parts they sit in.
        for i in result.inHoles {
            guard let place = result.placements[i], place.sheet < sheets.count else { continue }
            for p in job.parts[i].outlines {
                out += "<polygon points=\"\(points(place.apply(p), place.sheet))\" fill=\"#4f8fd0\" stroke=\"#2a5d8f\"/>\n"
            }
        }
        out += "</svg>\n"
        do { try out.write(toFile: svg, atomically: true, encoding: .utf8) } catch { fail("Can't write \(svg): \(error.localizedDescription)") }
        print("Wrote \(svg)")
    }
    let url = URL(fileURLWithPath: args[1])
    let out = option("-o", in: args) ?? (args.contains("--in-place") ? args[1]
        : url.deletingLastPathComponent().appendingPathComponent(url.deletingPathExtension().lastPathComponent + " nested.nativecam").path)
    do { try applied.project.encoded().write(to: URL(fileURLWithPath: out)) } catch { fail("Can't write \(out): \(error.localizedDescription)") }
    print("Wrote \(out)")

case "import":
    let usage = "usage: nativecam-cli import <project.nativecam> <file>… (-o out.nativecam | --in-place) [--units in|mm] [--layer name]"
        + " [--keep-coords | --center | --at x,y] [--sheet n] [--depth d] [--up z|y]"
    let files = positionals(from: 1, valued: ["-o", "--units", "--layer", "--at", "--sheet", "--depth", "--up"],
                            flags: ["--in-place", "--keep-coords", "--center"], usage: usage)
    guard files.count >= 2 else { fail(usage) }
    let projectPath = files[0]
    // Bad flags are refused before anything is read or imported.
    let out = requiredOutput(project: projectPath, usage: usage)
    let placements = ["--keep-coords", "--center", "--at"].filter { args.contains($0) }
    if placements.count > 1 { fail("Pass one of --keep-coords, --center and --at x,y.\n" + usage) }
    var project = loadProject(projectPath)
    let u = project.displayUnits
    var options = ImportOptions(placement: .keep)
    switch option("--units", in: args)?.lowercased() {
    case nil: break
    case "in", "inch", "inches": options.unit = .inch
    case "mm", "millimetres", "millimeters": options.unit = .mm
    case let other?: fail("--units takes in or mm, not \(other)")
    }
    if let layer = option("--layer", in: args) {
        guard !layer.trimmingCharacters(in: .whitespaces).isEmpty else { fail("--layer needs a layer name") }
        options.layer = layer
    }
    if args.contains("--center") { options.placement = .center }
    if let text = option("--at", in: args) {
        let parts = text.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2, parts.allSatisfy(\.isFinite) else { fail("--at takes x,y in \(u.symbol), e.g. --at 1,1") }
        options.placement = .at(Vec2(u.toMM(parts[0]), u.toMM(parts[1])))
    }
    if let text = option("--sheet", in: args) {
        guard let n = Int(text), n >= 1, n <= project.sheetCount else {
            fail("--sheet takes a sheet from 1 to \(project.sheetCount): the job has \(counted(project.sheetCount, "sheet"))")
        }
        options.sheet = n - 1
    }
    if let text = option("--depth", in: args) {
        let limit = project.stock.thickness - 0.02.inch
        guard let d = Double(text), d > 0 else { fail("--depth takes a depth above zero in \(u.symbol)") }
        guard u.toMM(d) <= limit + 1e-9 else {
            fail("Not written: --depth \(text) \(u.symbol) is too deep: a 3D model is carved no deeper than the material less 0.02 in"
                 + " (\(u.format(limit)) \(u.symbol) here, the material being \(u.format(project.stock.thickness)) \(u.symbol)).")
        }
        options.modelDepth = u.toMM(d)
    }
    switch option("--up", in: args)?.lowercased() {
    case nil: break
    case "z": options.upAxis = .z
    case "y": options.upAxis = .y
    case let other?: fail("--up takes z or y, not \(other)")
    }
    func size(_ r: Rect2) -> String { "\(u.format(r.width)) × \(u.format(r.height)) \(u.symbol)" }
    func point(_ p: Vec2) -> String { "(\(u.format(p.x)), \(u.format(p.y)))" }
    func unitName(_ unit: LengthUnit) -> String { unit == .inch ? "inches" : "millimetres" }
    for path in files.dropFirst() {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        guard VectorImporter.supportedExtensions.contains(ext) || ModelImporter.supportedExtensions.contains(ext) else {
            fail("Not written: \(name) isn't a file NativeCAM imports (.dxf, .svg, .pdf, .ai; .stl, .obj, .3mf, .ply, .usdz, .usd).")
        }
        let file: ImportedFile
        do { file = try project.importFile(at: url, options: options) } catch {
            fail("Not written: can't import \(name): \(error.localizedDescription)")
        }
        let k = file.sheet
        let sheet = project.stock(forSheet: k)
        // The unit the file was read in, and why.
        let read = file.unit.map(unitName) ?? (abs(file.unitScale - 25.4 / 96) < 1e-9 ? "pixels at 96 per inch"
            : abs(file.unitScale - 25.4 / 72) < 1e-9 ? "points (72 per inch)" : "units of \(LengthUnit.mm.format(file.unitScale)) mm")
        switch file.unitSource {
        case .file:
            print("\(name): \(read), as the file says")
            if let given = options.unit, file.kind == .model || ext == "dxf", file.unit != given {
                print("[warning] \(name): the file says it's in \(read), so --units \(given.symbol) doesn't apply to it")
            }
        case .given:
            print("\(name): \(read), from --units (the file carries no unit)")
        case .assumed:
            if ext == "dxf" {
                fail("Not written: \(name) has no $INSUNITS in its header, so its unit is unknown. Pass --units in or --units mm"
                     + " to say what it was drawn in.")
            }
            print("\(name): \(read), assumed (the file carries no unit\(file.kind == .model ? "; pass --units to change it" : ""))")
        }
        for w in file.warnings { print("[warning] \(name): \(w)") }
        guard !file.shapeIDs.isEmpty else { fail("Not written: \(name) has no usable vectors.") }
        let added = project.shapes.filter { file.shapeIDs.contains($0.id) }
        for shape in added {
            if let spec = shape.modelSpec {
                // The mesh's own size, which its toolpaths cut to (the traced outline is up to a grid cell larger).
                print("  Added 3D model “\(shape.name)” on layer “\(shape.layer)”: \(size(shape.modelBounds ?? shape.bounds)) centred at \(point(shape.position)),"
                      + " \(u.format(spec.depth)) \(u.symbol) deep, scale \(String(format: "%.4g", shape.scale))")
            } else {
                let polys = shape.polylines(tolerance: 0.1)
                let open = polys.filter { !$0.isClosed }.count
                let paths = open == 0 ? counted(polys.count, "closed path") : "\(counted(polys.count, "path")), \(open) open"
                print("  Added “\(shape.name)” on layer “\(shape.layer)”: \(size(shape.bounds)) from \(point(shape.bounds.min))"
                      + " to \(point(shape.bounds.max)), \(paths)")
            }
        }
        if project.sheetCount > 1 { print("  On sheet \(k + 1) of \(project.sheetCount)") }
        if file.kind == .vectors {
            switch options.placement {
            case .keep:
                guard file.fitsMaterial else {
                    let b = file.placedBounds
                    fail("Not written: \(name) doesn't fit on the material in the file's coordinates. The drawing runs from \(point(b.min))"
                         + " to \(point(b.max)) \(u.symbol); the material is \(u.format(sheet.width)) × \(u.format(sheet.height)) \(u.symbol)"
                         + " from (0, 0). Pass --center to centre it on the material, or --at x,y to put its lower-left corner there.")
                }
                print("  Kept the file's coordinates")
            case .center: print("  Centred on the material")
            case .at: print("  Lower-left corner placed at \(point(file.placedBounds.min))")
            case .auto: break
            }
            if !file.fitsMaterial {
                print("[warning] \(name): the drawing (\(size(file.placedBounds))) runs off the material"
                      + " (\(u.format(sheet.width)) × \(u.format(sheet.height)) \(u.symbol)); post will warn about cuts beyond its edges")
            }
        }
        // A size that's implausible for the material is usually the wrong unit.
        let b = file.placedBounds
        let ratio = max(b.width / sheet.width, b.height / sheet.height)
        let other: LengthUnit? = file.unitSource == .file ? nil : file.unit == .inch ? .mm : file.unit == .mm ? .inch : nil
        let hint = other.map { " Check its unit: was it drawn in \(unitName($0)) (--units \($0.symbol))?" } ?? ""
        if ratio < 0.01 {
            print("[warning] \(name): the drawing is only \(size(b)), under 1% of the material (\(u.format(sheet.width)) × \(u.format(sheet.height))"
                  + " \(u.symbol)).\(hint)")
        } else if b.width > sheet.width + 1e-6 || b.height > sheet.height + 1e-6 {
            print("[warning] \(name): the drawing is \(size(b)), larger than the material (\(u.format(sheet.width)) × \(u.format(sheet.height))"
                  + " \(u.symbol)).\(hint)")
        }
    }
    printBinding(project.bindVectorChanges(), project: project)
    write(project, to: out)

case "rebind":
    let usage = "usage: nativecam-cli rebind <project.nativecam> (-o out.nativecam | --in-place)"
    let files = positionals(from: 1, valued: ["-o"], flags: ["--in-place"], usage: usage)
    guard files.count == 1 else { fail(usage) }
    let out = requiredOutput(project: files[0], usage: usage)
    var project = loadProject(files[0])
    printBinding(project.bindVectorChanges(), project: project)
    write(project, to: out)

case "save":
    let usage = "usage: nativecam-cli save <project.nativecam> (-o out.nativecam | --in-place) [--rebind]"
    let files = positionals(from: 1, valued: ["-o"], flags: ["--in-place", "--rebind"], usage: usage)
    guard files.count == 1 else { fail(usage) }
    let out = requiredOutput(project: files[0], usage: usage)
    var project = loadProject(files[0])
    if args.contains("--rebind") { printBinding(project.bindVectorChanges(), project: project) }
    let before = savedFormat(files[0]).map(String.init) ?? "?"
    let after = project.formatVersion
    print(before == String(after) ? "Format \(after), unchanged" : "Format \(before) → \(after)")
    write(project, to: out)

default:
    fail("unknown command \(command)")
}
