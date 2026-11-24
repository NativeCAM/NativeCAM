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
//                                                      the cut-out bit plus 1/8 in or 3 mm); prints the utilization and
//                                                      what didn't fit. Writes "<project> nested.nativecam" beside the
//                                                      project unless -o or --in-place

func fail(_ message: String) -> Never {
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

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    print("usage: nativecam-cli demo <out.nativecam> | post <project> [-o out.tap] | sim <project|tap> [--png out.png] [--cell mm]"
          + " | tools <library> [-o out.json]")
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
    guard args.count >= 2 else { fail("usage: nativecam-cli post <project.nativecam> [-o out.tap] [--air-cut height] [--sheet out.html] [--force]") }
    let project = loadProject(args[1])
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
        print("Wrote \(out)")
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

default:
    fail("unknown command \(command)")
}
