import CAMCore
import Foundation

// nativecam-cli: generate Avid Mach4 G-code and simulate jobs without the UI.
//
//   nativecam-cli demo <out.nativecam>                       write the demo sign project
//   nativecam-cli demo3d <out.nativecam>                     write the 3D relief demo project
//   nativecam-cli new <out.nativecam>                        write an empty project (default PRO6060 setup)
//   nativecam-cli post <project.nativecam> [-o out.tap]      generate toolpaths + G-code, print issues
//   nativecam-cli sim  <project.nativecam|file.tap> [--png out.png] [--cell mm]
//                                                      simulate material removal, print stats

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
    print("usage: nativecam-cli demo <out.nativecam> | post <project> [-o out.tap] | sim <project|tap> [--png out.png] [--cell mm]")
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
    guard args.count >= 2 else { fail("usage: nativecam-cli post <project.nativecam> [-o out.tap]") }
    let project = loadProject(args[1])
    let start = Date()
    let job = CAMEngine.generate(project)
    let elapsed = Date().timeIntervalSince(start)
    for issue in job.issues {
        print("[\(issue.severity.rawValue)] \(issue.operation.map { "\($0): " } ?? "")\(issue.message)")
    }
    let gcode = AvidMach4Post(project: project).post(job.toolpaths)
    let out = option("-o", in: args) ?? (args[1] as NSString).deletingPathExtension + ".tap"
    do { try gcode.write(toFile: out, atomically: true, encoding: .ascii) } catch { fail("Can't write \(out): \(error)") }
    let lines = gcode.components(separatedBy: "\r\n").count - 1
    print(String(format: "Generated %d toolpaths in %.2fs, %d lines -> %@", job.toolpaths.count, elapsed, lines, out))
    print("Estimated run time: \(formatTime(job.estimatedSeconds(rapidRate: project.machine.rapidRateForEstimates)))")

case "sim":
    guard args.count >= 2 else { fail("usage: nativecam-cli sim <project|tap> [--png out.png]") }
    let path = args[1]
    var project: Project
    var toolpaths: [Toolpath]
    if path.hasSuffix(".tap") || path.hasSuffix(".nc") || path.hasSuffix(".gcode") {
        project = Project()
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) ?? String(contentsOfFile: path, encoding: .ascii) else {
            fail("Can't read \(path)")
        }
        do {
            let program = try GCodeParser.parse(text)
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
    print(String(format: "Removed %.1f cm³ of material; job time %@", grid.removedVolume / 1000, formatTime(session.timeline.duration)))
    if !session.rapidCollisions.isEmpty {
        print("[error] \(session.rapidCollisions.count) rapid move(s) cut through material")
    }
    if let png = option("--png", in: args) {
        do { try HeightmapImage.writePNG(grid, to: URL(fileURLWithPath: png)); print("Wrote \(png)") } catch { fail("PNG: \(error)") }
    }

default:
    fail("unknown command \(command)")
}
