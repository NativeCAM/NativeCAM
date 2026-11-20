import CAMCore
import Foundation

// nativecam-cli: generate G-code for a project's machine and simulate jobs without the UI.
//
//   nativecam-cli demo <out.nativecam>                       write the demo sign project
//   nativecam-cli demo3d <out.nativecam>                     write the 3D relief demo project
//   nativecam-cli new <out.nativecam>                        write an empty project (default PRO6060 setup)
//   nativecam-cli post <project.nativecam> [-o out.tap] [--air-cut height] [--sheet out.html] [--force]
//                                                      generate toolpaths + G-code, check the file against the
//                                                      controller and the toolpaths, print issues. Refuses to write a
//                                                      file that fails the checks unless --force. --air-cut raises
//                                                      every Z by height (in the G-code's units); --sheet writes a
//                                                      printable setup sheet
//   nativecam-cli sim  <project.nativecam|file.tap> [--png out.png] [--cell mm] [--heights out.bin]
//                                                      (--heights: little-endian header Int32 cols, Int32 rows,
//                                                       Float64 cell, origin x, origin y, then Float32 heights)
//                                                      simulate material removal, print stats
//   nativecam-cli acceptance [machine.nativecam] [--controller grbl|grblHAL|fluidNC|carbideMotion] [--sender gSender]
//                     [--units inch|mm] [--tool-change m6|pause|atc] [-o out]
//                                                      write the acceptance test program for a controller: run it in
//                                                      check mode, then as an air cut, then 0.5 mm deep in scrap
//   nativecam-cli machine <settings> [--apply project.nativecam [-o out.nativecam]]
//                                                      read machine limits from Grbl $$, Mach4 Machine.ini, LinuxCNC
//                                                      INI, FluidNC YAML or Fusion .mch; optionally apply to a project
//   nativecam-cli tools <library.tools|.vtdb|.json> [-o out.json]
//                                                      read a Fusion 360, Vectric or NativeCAM tool library, print what
//                                                      came across, optionally save it as a NativeCAM library (T1, T2, …)

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
case "demo", "demo3d", "new":
    guard args.count >= 2 else { fail("usage: nativecam-cli \(command) <out.nativecam>") }
    let project = command == "demo3d" ? Project.demoRelief() : command == "new" ? Project() : Project.demoSign()
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
    let output: (files: [PostedFile], project: Project, post: any PostProcessor)
    if let text = option("--air-cut", in: args) {
        guard let h = Double(text), h > 0 else { fail("--air-cut needs a height above zero") }
        guard let air = AirCut.files(project, toolpaths: job.toolpaths, height: project.machine.outputUnits.toMM(h)) else { fail(noPost) }
        output = air
    } else {
        guard let post = PostProcessors.post(for: project) else { fail(noPost) }
        output = (post.files(job.toolpaths), project, post)
    }
    let post = output.post
    var checks: [GCodeCheck.Issue] = []
    for file in output.files {
        let found = GCodeCheck.run(file.gcode, toolpaths: file.toolpaths, project: output.project, dialect: post.dialect)
        for issue in found { print("[\(issue.severity.rawValue)] G-code\(output.files.count > 1 ? file.suffix ?? "" : ""): \(issue.text)") }
        checks += found
    }
    if let sheet = option("--sheet", in: args) {
        let html = SetupSheet.html(project: project, job: job, gcodeFile: nil, checks: checks)
        do { try html.write(toFile: sheet, atomically: true, encoding: .utf8) } catch { fail("Can't write \(sheet): \(error)") }
        print("Setup sheet -> \(sheet)")
    }
    if checks.contains(where: { $0.severity == .error }) && !args.contains("--force") {
        fail("The G-code failed its checks, so it wasn't written. Fix the errors above, or pass --force to write it anyway.")
    }
    let stem = option("-o", in: args).map { ($0 as NSString).deletingPathExtension } ?? (args[1] as NSString).deletingPathExtension
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

case "sim":
    guard args.count >= 2 else { fail("usage: nativecam-cli sim <project|tap|nc|sbp> [--png out.png]") }
    let path = args[1]
    var project: Project
    var toolpaths: [Toolpath]
    let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
    if ["tap", "nc", "gcode", "ngc", "cnc", "txt", "sbp"].contains(ext) {
        project = Project()
        // Files from older CAM programs aren't always UTF-8; Latin-1 reads any bytes.
        guard let text = (try? String(contentsOfFile: path, encoding: .utf8))
            ?? (try? String(contentsOfFile: path, encoding: .isoLatin1)) else {
            fail("Can't read \(path)")
        }
        do {
            let program = ext == "sbp" ? OpenSBPParser.parse(text) : try GCodeParser.parse(text)
            program.warnings.forEach { print("[warning] \($0)") }
            toolpaths = program.toolpaths(tools: ToolLibrary.starter.tools, stock: project.stock,
                                          fallback: ToolLibrary.starter.tools[0])
        } catch {
            fail("G-code error: \(error.localizedDescription)")
        }
    } else {
        project = loadProject(path)
        if args.contains("--no-arcs") { project.machine.outputArcs = false }
        toolpaths = CAMEngine.generate(project).toolpaths
    }
    let cell = option("--cell", in: args).flatMap(Double.init)
    var session = SimulationSession(toolpaths: toolpaths, stock: project.stock,
                                    rapidRate: project.machine.rapidRateForEstimates, cellSize: cell)
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

default:
    fail("unknown command \(command)")
}
