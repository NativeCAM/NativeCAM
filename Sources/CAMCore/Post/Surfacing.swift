import Foundation

/// File ▸ Surface Spoilboard… and `nativecam-cli surface`: a standalone program that flattens the spoilboard, with an
/// air-cut copy. It never touches the open project, so it has no saved fields and no format version.
///
/// The program is a straight raster built from raw motions, like `Calibration`'s programs, rather than a pocket: a
/// pocket keeps the bit inside its boundary and adds a clean-up lap, which leaves rounded corners and lips at the edges,
/// and a boundary drawn bigger to avoid them can run past the travel. Here each line runs past the area's edges by the
/// overshoot, the first and last lines sit on the area's edges, and lines between are evenly spaced at no more than the
/// stepover, so the bit covers the whole area.
///
/// - **Z zero is the top of the spoilboard** (`.materialTop`, never `.machineBed`, whose "Spoilboard" label means the
///   board's bottom). The file's first line says so, and every cut reads back at exactly −k × the pass depth.
/// - **XY zero is the area's front-left corner.** No `G53`: NativeCAM knows the travel's size, not where the work zero sits
///   in it, so whole-bed mode tells the operator to back off the front-left limit of travel by the inset.
/// - **Margin:** every move (lines, overshoot, ramps and links) keeps at least the inset (1/4 in or 6 mm) clear of the
///   travel's ends, so a pull-off, a jog or soft-limit rounding can't trip a limit with the bit in the board. On the whole
///   bed the lines stop on the area's edges (no overshoot); the bit still sweeps its radius past them.
/// - **Entry:** on a custom area (taken to be the board) the bit plunges in free air past the edge, then feeds in; on the
///   whole bed (no room past the edges) it ramps along the first line over at least twice its diameter, then goes back
///   along the ramp at depth.
/// - **Spin-up:** the file dwells at least `minimumSpinUpDwell` after the spindle starts, whatever the machine's own
///   spin-up dwell, without changing the machine profile.
/// - **Links:** zig-zag lines are joined at depth on the overshoot; one-way lines (all climb, for reading tram) retract to
///   the clearance height and come back. No rapid goes below the clearance height.
public enum Surfacing {
    public struct Refused: Error, LocalizedError, Hashable, Sendable {
        public var reason: String
        public init(_ reason: String) { self.reason = reason }
        public var errorDescription: String? { reason }
    }

    public enum Area: Hashable, Sendable {
        /// The machine's travel less `inset` on every side.
        case wholeBed
        /// A board this size, mm, from the XY zero at its front-left corner.
        case custom(Vec2)
    }

    public enum Along: String, Codable, Sendable, CaseIterable, Identifiable {
        case x, y
        public var id: String { rawValue }
        public var label: String { self == .x ? "Along X" : "Along Y" }
    }

    public enum Direction: String, Codable, Sendable, CaseIterable, Identifiable {
        /// Back and forth, joined at depth.
        case zigZag
        /// Every line the same way, climb cutting, with a retract between: for reading the spindle's tram.
        case oneWay
        public var id: String { rawValue }
        public var label: String { self == .zigZag ? "Both ways (zig-zag)" : "One way (climb)" }
    }

    /// How the bit gets down to depth at the start of a pass (and, one way, of every line).
    public enum Entry: String, Sendable {
        /// Plunged in free air past the area's edge.
        case offEdge
        /// Ramped along the first line, then back along the ramp at depth.
        case ramp
    }

    /// The least spin-up dwell before the bit touches the board, seconds: a big surfacing bit takes time to come up to
    /// speed. The machine's own dwell is used when it's longer. (A guess: no maker publishes one for a VFD.)
    public static let minimumSpinUpDwell = 3.0
    /// The most a pass may take off: an eighth of an inch (3 mm), or the bit's flute length if that's less.
    public static func maximumPass(_ tool: Tool, _ u: LengthUnit) -> Double { min(tool.fluteLength, u == .inch ? 0.125.inch : 3) }
    /// Passes deeper than this are outside common practice for surfacing: warned.
    public static func deepPass(_ u: LengthUnit) -> Double { u == .inch ? 0.0625.inch : 1.5 }
    /// The least board left under the cut, when the board's thickness is given (a rule of thumb, not a sourced figure).
    public static func minimumBoard(_ u: LengthUnit) -> Double { u == .inch ? 0.5.inch : 12 }
    /// The whole bed's inset from the travel on each side.
    public static func defaultInset(_ u: LengthUnit) -> Double { u == .inch ? 0.25.inch : 6 }
    /// The overshoot past the bit's radius, so the bit leaves the edge cleanly.
    public static func defaultOvershootMargin(_ u: LengthUnit) -> Double { u == .inch ? 0.125.inch : 3 }
    /// Clearance past the bit's edge for an off-edge plunge.
    static func plungeClearance(_ u: LengthUnit) -> Double { u == .inch ? 0.0625.inch : 1.5 }
    /// How high the air-cut copy runs above the real one, mm.
    public static func airHeight(_ u: LengthUnit) -> Double { u == .inch ? 1.inch : 25 }

    public static let zeroLine = "Z ZERO: TOP OF THE SPOILBOARD (touch plate on the board)"

    public struct Options: Hashable, Sendable {
        public var area: Area
        public var tool: Tool
        /// Line spacing as a fraction of the bit's diameter: 0.1 to 0.9.
        public var stepover: Double
        /// Depth of each pass, mm.
        public var depth: Double
        public var passes: Int
        public var along: Along
        public var direction: Direction
        /// How far each line runs past the area's edge, mm; nil for the bit's radius + 1/8 in (3 mm).
        public var overshoot: Double?
        /// The margin kept clear of the travel's ends on every side, mm; nil for 1/4 in (6 mm). The whole bed is the
        /// travel less this on each side.
        public var inset: Double?
        /// Shorten the overshoot to fit the travel, rather than refusing a custom area that's too long with it.
        public var clampOvershoot: Bool
        /// Height of rapids above Z zero, mm.
        public var clearance: Double
        /// The spoilboard's thickness, mm, when known: refused when too little would be left.
        public var boardThickness: Double?

        public init(area: Area = .wholeBed, tool: Tool = Surfacing.starterBit, stepover: Double = 0.5, depth: Double = 0.02.inch,
                    passes: Int = 1, along: Along = .x, direction: Direction = .zigZag, overshoot: Double? = nil,
                    inset: Double? = nil, clampOvershoot: Bool = false, clearance: Double = 0.5.inch, boardThickness: Double? = nil) {
            self.area = area
            self.tool = tool
            self.stepover = stepover
            self.depth = depth
            self.passes = passes
            self.along = along
            self.direction = direction
            self.overshoot = overshoot
            self.inset = inset
            self.clampOvershoot = clampOvershoot
            self.clearance = clearance
            self.boardThickness = boardThickness
        }

        /// The defaults in the machine's units: 0.02 in or 0.5 mm a pass, 0.5 in or 12 mm clearance.
        public static func defaults(_ u: LengthUnit, tool: Tool = Surfacing.starterBit) -> Options {
            Options(tool: tool, depth: u == .inch ? 0.02.inch : 0.5, clearance: u == .inch ? 0.5.inch : 12)
        }
    }

    /// The starter library's 1-1/4" surfacing bit (T8).
    public static var starterBit: Tool {
        ToolLibrary.starter.tools.first { $0.shape == .surfacing }!
    }

    /// Bits that can surface: surfacing bits first, then flat end mills.
    public static func bits(_ tools: [Tool]) -> [Tool] {
        let usable = tools.filter { $0.shape == .surfacing } + tools.filter { $0.shape == .flatEndMill }
        return usable.isEmpty ? [starterBit] : usable
    }

    /// The program's layout, worked out from the options and the machine before anything is posted.
    public struct Plan: Hashable, Sendable {
        /// The area surfaced, mm, from the XY zero at its front-left corner.
        public var area: Vec2
        public var overshoot: Double
        /// Line spacing, mm (at most the stepover).
        public var spacing: Double
        /// Line positions across the area, mm, from 0 to its far edge.
        public var lines: [Double]
        public var entry: Entry
        public var feed: Double
        public var plunge: Double
        public var rpm: Double
        public var totalDepth: Double
        /// Warnings the sheet shows and the file's checks list.
        public var warnings: [String]
        /// The whole bed's inset from the travel, mm (nil for a custom area).
        public var inset: Double?
        /// The margin every move keeps from the travel's ends, mm.
        public var margin: Double
        /// The ramp's length, mm.
        public var rampLength: Double
    }

    public struct Program: Sendable {
        public var options: Options
        public var plan: Plan
        /// The job the file was posted from: its machine (as the post saw it) and stock.
        public var project: Project
        public var toolpaths: [Toolpath]
        public var gcode: String
        /// The same program raised by `airHeight` for a dry run.
        public var airGCode: String
        public var airProject: Project
        public var airToolpaths: [Toolpath]
        public var dialect: Dialect
        public var fileExtension: String
        /// What the operator must do before starting (also the file's first comments).
        public var setup: [String]
        /// Errors and warnings from `GCodeCheck` and `verify`, then the plan's warnings; no errors when it passed.
        public var issues: [GCodeCheck.Issue]
        /// Issues found in the air-cut copy.
        public var airIssues: [GCodeCheck.Issue]
        /// Estimated run time, seconds, the tool change included.
        public var estimatedSeconds: Double

        public var passedChecks: Bool { !(issues + airIssues).contains { $0.severity == .error } }
        /// "surface-spoilboard-61x61in.tap".
        public var fileName: String { Surfacing.fileStem(plan.area, project.machine.outputUnits) + "." + fileExtension }
        /// "surface-spoilboard-61x61in (air cut).tap", named as every air cut is (`Surfacing.paths`).
        public var airFileName: String { Surfacing.paths(fileName, fileExtension: fileExtension).airCut }
    }

    public static func fileStem(_ area: Vec2, _ u: LengthUnit) -> String {
        "surface-spoilboard-\(Int(u.fromMM(area.x).rounded()))x\(Int(u.fromMM(area.y).rounded()))\(u.symbol)"
    }

    // MARK: File names (#200)

    /// Where the program and its air cut go, from the path chosen for the program: `board.tap` and `board (air cut).tap`,
    /// named by `AirCut.paths` as every other air cut is. A path without an extension takes `fileExtension`; a path with
    /// one keeps it.
    public static func paths(_ path: String, fileExtension: String) -> (program: String, airCut: String) {
        let ns = path as NSString
        let ext = ns.pathExtension.isEmpty ? fileExtension : ns.pathExtension
        let stem = ns.deletingPathExtension
        let program = AirCut.paths(suffixes: [nil], stem: stem, airCut: false, fileExtension: ext)[0]
        let air = AirCut.paths(suffixes: [nil], stem: stem, airCut: true, fileExtension: ext)[0]
        return (program, air)
    }

    /// Why the program, and when `airCut` its air cut, can't be written at `paths`, or nil when they can: the rules of
    /// `AirCut.namingProblem`. The program's name mustn't say "air cut" (with or without the air cut, since someone would
    /// run it believing the bit stays in the air), and the air cut never overwrites a file that isn't one. `existing`
    /// reads a file already at a path (nil when there's none).
    public static func namingProblem(_ paths: (program: String, airCut: String), airCut: Bool,
                                     existing: (String) -> String?) -> String? {
        if let problem = AirCut.namingProblem([paths.program], airCut: false, existing: existing) { return problem }
        guard airCut else { return nil }
        return AirCut.namingProblem([paths.airCut], airCut: true, existing: existing)
    }

    /// `namingProblem` against the files on disk.
    public static func namingProblemOnDisk(_ paths: (program: String, airCut: String), airCut: Bool) -> String? {
        namingProblem(paths, airCut: airCut, existing: AirCut.onDisk)
    }

    // MARK: Plan and refusals

    /// The layout for `options` on `machine`, or why it can't be cut.
    public static func plan(_ options: Options, machine: MachineProfile) throws -> Plan {
        if let refused = Calibration.noPost(machine) { throw Refused(refused.reason) }
        let u = machine.outputUnits
        let tool = options.tool
        let len = { (mm: Double) in Calibration.length(mm, u) }
        var warnings: [String] = []
        guard tool.shape == .surfacing || tool.shape == .flatEndMill else {
            throw Refused("A \(tool.shape.label.lowercased()) can't surface a board: pick a surfacing bit or a flat end mill.")
        }
        guard tool.diameter > 0 else { throw Refused("The bit has no diameter.") }
        if tool.shape == .flatEndMill {
            warnings.append("\(tool.name) is an end mill: a wide surfacing bit does this in far fewer lines.")
        }
        let stepPct = Int((options.stepover * 100).rounded())
        if options.stepover < 0.1 - 1e-9 { throw Refused("A stepover of \(stepPct)% is below 10%: use 10% to 90% of the bit.") }
        if options.stepover > 0.9 + 1e-9 {
            throw Refused("A stepover of \(stepPct)% is above 90% and can leave ridges or uncut strips: use 10% to 90% of the bit.")
        }
        if options.stepover > 0.8 + 1e-9 {
            warnings.append("A stepover of \(stepPct)% is above 80%: fine for reading tram, but it can leave ridges.")
        }
        guard options.depth > 0 else { throw Refused("The depth per pass must be above zero.") }
        let maxPass = maximumPass(tool, u)
        if options.depth > maxPass + 1e-6 {
            throw Refused("\(len(options.depth)) a pass is too deep for surfacing: at most \(len(maxPass))"
                + (tool.fluteLength < (u == .inch ? 0.125.inch : 3) ? ", the bit's flute length." : "."))
        }
        if options.depth > deepPass(u) + 1e-6 {
            warnings.append("\(len(options.depth)) a pass is deeper than the usual \(len(deepPass(u))) or less: listen for the spindle loading up.")
        }
        guard (1...20).contains(options.passes) else { throw Refused("Use 1 to 20 passes.") }
        let total = options.depth * Double(options.passes)
        if total > tool.fluteLength + 1e-6 {
            throw Refused("\(options.passes) passes of \(len(options.depth)) take off \(len(total)), more than the bit's \(len(tool.fluteLength)) flutes.")
        }
        if total > (u == .inch ? 0.125.inch : 3) + 1e-6 {
            warnings.append("\(len(total)) in all is a lot to take off a spoilboard: check the screw heads are deeper than that.")
        }
        if let t = options.boardThickness {
            guard t > 0 else { throw Refused("The board's thickness must be above zero.") }
            if t - total < minimumBoard(u) - 1e-6 {
                throw Refused("Surfacing \(len(total)) off a \(len(t)) board leaves \(len(max(0, t - total))), less than \(len(minimumBoard(u))): "
                    + "time for a new spoilboard.")
            }
        }
        guard options.clearance > 0 else { throw Refused("The clearance height must be above zero.") }
        let feed = Calibration.roundedFeed(tool.cutting.feedRate, u)
        if feed > machine.maxFeedRate + 1e-6 {
            throw Refused("The bit's feed of \(Calibration.feed(feed, u)) is above the machine's highest feed of "
                + "\(Calibration.feed(machine.maxFeedRate, u)): lower it in the tool library.")
        }
        guard feed > 0 else { throw Refused("The bit has no feed rate: set one in the tool library.") }
        let plunge = max(1, min(tool.cutting.plungeRate > 0 ? tool.cutting.plungeRate : feed / 4, machine.maxFeedRate))
        let rpm = machine.clampRPM(tool.cutting.spindleRPM)
        if abs(rpm - tool.cutting.spindleRPM) > 0.5 {
            warnings.append("The bit's \(Int(tool.cutting.spindleRPM)) RPM is outside the spindle's range: run at \(Int(rpm)) RPM.")
        }

        let r = tool.diameter / 2
        let travel = machine.travel.xy
        let along = options.along
        func lengthwise(_ v: Vec2) -> Double { along == .x ? v.x : v.y }
        func across(_ v: Vec2) -> Double { along == .x ? v.y : v.x }
        let axis = along == .x ? "X" : "Y"
        let wanted = options.overshoot ?? (r + defaultOvershootMargin(u))
        guard wanted >= 0 else { throw Refused("The overshoot can't be negative.") }
        var area: Vec2, overshoot: Double, inset: Double?
        let margin = options.inset ?? defaultInset(u)
        guard margin >= 0 else { throw Refused("The inset can't be negative.") }
        // The room the program's moves may span: the travel less the margin at each end.
        let usable = Vec2(travel.x - 2 * margin, travel.y - 2 * margin)
        switch options.area {
        case .wholeBed:
            area = usable
            guard area.x > 0, area.y > 0 else { throw Refused("The inset leaves nothing of the \(Calibration.size(travel, u)) travel.") }
            // No room past the area: the lines stop on its edges, so every move stays the margin inside the travel.
            overshoot = 0
            inset = margin
        case .custom(let size):
            guard size.x > 0, size.y > 0 else { throw Refused("The area needs a width and a height.") }
            area = size
            inset = nil
            if size.x > usable.x + 1e-6 || size.y > usable.y + 1e-6 {
                throw Refused("The \(Calibration.size(size, u)) area doesn't fit in the machine's \(Calibration.size(travel, u)) travel with "
                    + "\(len(margin)) kept clear of the limits on every side: at most \(Calibration.size(usable, u)).")
            }
            let room = (lengthwise(usable) - lengthwise(size)) / 2
            if wanted > room + 1e-6 {
                guard options.clampOvershoot else {
                    throw Refused("With the \(len(wanted)) overshoot at each end, the lines run \(len(lengthwise(size) + 2 * wanted)) in \(axis), "
                        + "more than the \(len(lengthwise(usable))) of travel left with \(len(margin)) kept clear of each limit. "
                        + "Shorten the overshoot to \(len(room)) or make the area smaller.")
                }
                overshoot = room
                warnings.append("The overshoot is shortened to \(len(room)) to keep \(len(margin)) clear of the travel's limits"
                    + (room < r ? ": the bit doesn't clear the board's \(axis) ends." : "."))
            } else {
                overshoot = wanted
            }
        }
        // Lines evenly spaced at no more than the stepover, the first and last on the area's edges.
        let width = across(area)
        let step = options.stepover * tool.diameter
        let gaps = max(1, Int((width / step - 1e-9).rounded(.up)))
        let spacing = width / Double(gaps)
        let lines = (0...gaps).map { Double($0) * spacing }
        let entry: Entry = overshoot >= r + plungeClearance(u) - 1e-6 ? .offEdge : .ramp
        let rampLength = min(2 * tool.diameter, lengthwise(area) + 2 * overshoot)
        return Plan(area: area, overshoot: overshoot, spacing: spacing, lines: lines, entry: entry, feed: feed, plunge: plunge,
                    rpm: rpm, totalDepth: total, warnings: warnings, inset: inset, margin: margin, rampLength: rampLength)
    }

    /// The machine the program is posted for: NativeCAM's own post, and a spin-up dwell of at least
    /// `minimumSpinUpDwell`. The tool change stays the machine's own (on the Avid, the M6 macro and the touch plate).
    static func postingMachine(_ machine: MachineProfile) -> MachineProfile {
        var m = Calibration.postingMachine(machine, air: false)
        m.spindleSpinUpDwell = max(m.spindleSpinUpDwell, minimumSpinUpDwell)
        return m
    }

    // MARK: Program

    /// The surfacing program for `options` on `machine`, posted and checked. Throws `Refused` when it can't be cut.
    public static func program(machine: MachineProfile, options: Options, date: Date = Date(), timeZone: TimeZone = .current) throws -> Program {
        let plan = try plan(options, machine: machine)
        let m = postingMachine(machine)
        let u = m.outputUnits
        let tool = options.tool
        let thickness = options.boardThickness ?? (u == .inch ? 0.75.inch : 19)
        var stock = Stock(width: plan.area.x, height: plan.area.y, thickness: thickness, materialName: "Spoilboard",
                          xyOrigin: .lowerLeft, zZero: .materialTop, clearanceHeight: options.clearance,
                          plungeHeight: options.clearance, materialKind: .mdf)
        stock.homePosition = Vec3(0, 0, max(options.clearance, u == .inch ? 1.inch : 25))
        var project = Project(name: "NativeCAM spoilboard surfacing", displayUnits: u, stock: stock, machine: m)
        project.notes = "Surfacing \(Calibration.size(plan.area, u)) of spoilboard with \(tool.name)."
        let toolpaths = (1...options.passes).map { k in
            let motions = passMotions(k, plan: plan, options: options)
            let id = UUID(uuidString: String(format: "5F0A0000-0000-0000-0000-%012d", k))!
            let name = options.passes == 1 ? "Surface spoilboard" : "Surface spoilboard, pass \(k) of \(options.passes)"
            return Toolpath(id: id, name: name, tool: tool, spindleRPM: plan.rpm,
                            start: Vec3(motions[0].end.x, motions[0].end.y, options.clearance), motions: motions)
        }
        let estimate = CycleTimeEstimator.estimate(toolpaths, project: project).total
        let setup = setupLines(plan: plan, options: options, machine: m, estimate: estimate)
        guard let post = Calibration.post(project, date: date, timeZone: timeZone) else {
            throw Refused(PostProcessors.unavailableReason(for: m) ?? "No post for \(m.controllerLabel).")
        }
        let gcode = Calibration.headerComments(setup, dialect: post.dialect) + post.post(toolpaths)
        let air = airHeight(u)
        let (airProject, airToolpaths) = AirCut.raise(project, toolpaths, by: air)
        guard let airPost = Calibration.post(airProject, date: date, timeZone: timeZone) else {
            throw Refused(PostProcessors.unavailableReason(for: m) ?? "No post for \(m.controllerLabel).")
        }
        var airSetup = setup
        airSetup.insert("AIR CUT: Z raised \(Calibration.length(air, u)), X and Y unchanged. Zero exactly as for the real cut; "
            + "the bit should stay \(Calibration.length(air - plan.totalDepth, u)) or more above the board.", at: 1)
        let airGCode = Calibration.headerComments(airSetup, dialect: airPost.dialect) + airPost.post(airToolpaths)
        var program = Program(options: options, plan: plan, project: project, toolpaths: toolpaths, gcode: gcode, airGCode: airGCode,
                              airProject: airProject, airToolpaths: airToolpaths, dialect: post.dialect,
                              fileExtension: post.fileExtension, setup: setup, issues: [], airIssues: [], estimatedSeconds: estimate)
        program.issues = check(program, air: false) + plan.warnings.map { GCodeCheck.Issue(.warning, $0) }
        program.airIssues = check(program, air: true)
        return program
    }

    /// The motions of pass `k` (from 1), from the clearance height over its start back to the clearance height.
    static func passMotions(_ k: Int, plan: Plan, options: Options) -> [Motion] {
        let z = -Double(k) * options.depth
        let above = -Double(k - 1) * options.depth
        let clear = options.clearance
        let length = options.along == .x ? plan.area.x : plan.area.y
        let lo = -plan.overshoot, hi = length + plan.overshoot
        func point(_ s: Double, _ t: Double, _ z: Double) -> Vec3 {
            options.along == .x ? Vec3(s, t, z) : Vec3(t, s, z)
        }
        // The lines step +Y along X and +X along Y, so the board still to cut is always on the stepping side. Climb with an
        // M3 (clockwise) spindle keeps the material the bit engages on its right, as OperationInspector's help says:
        // along X that means cutting towards −X, along Y towards +Y.
        // (Zig-zag only picks which way its first line goes; it alternates, so it keeps its old start.)
        let climbForward = options.along == .x
        let oneWayForward = options.along == .y
        var out: [Motion] = []
        func enter(at start: Double, towards end: Double, across t: Double) {
            out.append(.rapid(point(start, t, clear)))
            switch plan.entry {
            case .offEdge:
                out.append(.feed(point(start, t, z), plan.plunge))
            case .ramp:
                // Down to the surface the last pass left (the board's top on the first) at the plunge rate, then a ramp
                // along the line to depth, and back along it at depth so the ramped stretch is cut to depth too.
                out.append(.feed(point(start, t, above), plan.plunge))
                let dir: Double = end > start ? 1 : -1
                let rampEnd = start + dir * plan.rampLength
                out.append(.feed(point(rampEnd, t, z), plan.feed))
                out.append(.feed(point(start, t, z), plan.feed))
            }
        }
        switch options.direction {
        case .zigZag:
            var forward = climbForward
            for (i, t) in plan.lines.enumerated() {
                let (a, b) = forward ? (lo, hi) : (hi, lo)
                if i == 0 { enter(at: a, towards: b, across: t) } else { out.append(.feed(point(a, t, z), plan.feed)) }
                out.append(.feed(point(b, t, z), plan.feed))
                forward.toggle()
            }
        case .oneWay:
            let (a, b) = oneWayForward ? (lo, hi) : (hi, lo)
            for t in plan.lines {
                enter(at: a, towards: b, across: t)
                out.append(.feed(point(b, t, z), plan.feed))
                out.append(.rapid(point(b, t, clear)))
            }
        }
        if out.last?.kind != .rapid, let last = out.last { out.append(.rapid(Vec3(last.end.x, last.end.y, clear))) }
        return out
    }

    /// The file's first comments: Z zero first, then XY zero, the bed, the cut and the time.
    static func setupLines(plan: Plan, options: Options, machine: MachineProfile, estimate: Double) -> [String] {
        let u = machine.outputUnits
        let len = { (mm: Double) in Calibration.length(mm, u) }
        var lines = [zeroLine]
        if let inset = plan.inset {
            lines.append("XY ZERO: the front-left corner of the area, \(len(inset)) in from the front-left limits of travel: jog to the "
                + "front-left limit of X and Y travel, move \(len(inset)) towards the back and \(len(inset)) to the right, then zero X and Y.")
            let swept = Vec2(plan.area.x + options.tool.diameter, plan.area.y + options.tool.diameter)
            lines.append("WHOLE BED: the bit's centre stays \(len(inset)) inside the travel's limits on every side, so it surfaces "
                + "\(Calibration.size(swept, u)): the area plus the bit's radius all round. Any of the board beyond that isn't surfaced.")
        } else {
            lines.append("XY ZERO: the front-left corner of the \(Calibration.size(plan.area, u)) board.")
        }
        lines += [
            "NATIVECAM SPOILBOARD SURFACING: \(Calibration.size(plan.area, u)), \(options.passes) pass\(options.passes == 1 ? "" : "es") of "
                + "\(len(options.depth)) (\(len(plan.totalDepth)) in all) with \(options.tool.name), \(plan.lines.count) lines "
                + "\(options.along == .x ? "along X" : "along Y") \(len(plan.spacing)) apart, \(options.direction == .zigZag ? "both ways" : "one way").",
            "BED CLEAR: remove every clamp. Every screw head and T-nut must sit at least \(len(u == .inch ? 0.125.inch : 3)) below the cut.",
            "Set the dust shoe high enough for the surfacing bit's collet and the \(len(options.clearance)) clearance.",
            "Re-zero Z on the board before every run: each run takes \(len(plan.totalDepth)) off the surface it is zeroed on.",
            "Runs about \(Surfacing.time(estimate)).",
        ]
        return lines
    }

    /// "45 min", "1 h 5 min", "40 s".
    public static func time(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s) s" }
        let minutes = (s + 30) / 60
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
    }

    // MARK: Checks

    /// `GCodeCheck` and `verify`, on the real file or its air-cut copy.
    public static func check(_ program: Program, air: Bool) -> [GCodeCheck.Issue] {
        let project = air ? program.airProject : program.project
        let toolpaths = air ? program.airToolpaths : program.toolpaths
        let gcode = air ? program.airGCode : program.gcode
        var issues = GCodeCheck.run(gcode, toolpaths: toolpaths, project: project, dialect: program.dialect)
        issues += verify(gcode, program: program, raised: air ? airHeight(program.project.machine.outputUnits) : 0)
        return issues.filter { $0.severity != .info }
    }

    /// Reads the file back and checks what the program promises: the Z-zero line first, every cut at the board's top or
    /// at −k × the pass depth (ramps between them), the lowest point at −the total depth, no rapid below the clearance
    /// height, and nothing outside the area plus the overshoot, or past the travel.
    public static func verify(_ gcode: String, program: Program, raised: Double = 0) -> [GCodeCheck.Issue] {
        var issues: [GCodeCheck.Issue] = []
        let firstLine = gcode.components(separatedBy: .newlines).first ?? ""
        if program.dialect.writesComments, !firstLine.uppercased().contains("Z ZERO: TOP OF THE SPOILBOARD") {
            issues.append(GCodeCheck.Issue(.error, line: 1, "The first line doesn't say Z zero is the top of the spoilboard."))
        }
        guard program.dialect.readsBack else { return issues }
        let read: GCodeProgram
        if program.dialect.language == .openSBP {
            read = OpenSBPParser.parse(gcode, units: program.project.machine.outputUnits)
        } else {
            do {
                read = try GCodeParser.parse(gcode, dwellUnit: program.dialect.dwell.parserUnit)
            } catch {
                return issues + [GCodeCheck.Issue(.error, "The file can't be read back: \(error.localizedDescription)")]
            }
        }
        let u = program.project.machine.outputUnits
        let tol = 1e-3 + u.toMM(pow(10, -Double(program.dialect.coordinateDecimals(u))))
        let depth = program.options.depth, passes = program.options.passes
        let stock = program.project.stock
        let clear = program.options.clearance + raised
        let plan = program.plan
        let lo = Vec2(program.options.along == .x ? -plan.overshoot : 0, program.options.along == .y ? -plan.overshoot : 0)
        let hi = Vec2(plan.area.x + (program.options.along == .x ? plan.overshoot : 0),
                      plan.area.y + (program.options.along == .y ? plan.overshoot : 0))
        if stock.zZero != .materialTop || stock.rotary != nil {
            issues.append(GCodeCheck.Issue(.error, "Z zero isn't the top of the spoilboard."))
        }
        var minZ = Double.infinity
        var ext = (lo: Vec2(.infinity, .infinity), hi: Vec2(-.infinity, -.infinity))
        var lowRapid = false, offLevel = false, outside = false
        for seg in read.segments {
            for m in seg.motions where m.kind != .dwell {
                let e = stock.fromWork(m.end)
                let z = e.z - raised
                ext = (Vec2(min(ext.lo.x, e.x), min(ext.lo.y, e.y)), Vec2(max(ext.hi.x, e.x), max(ext.hi.y, e.y)))
                minZ = min(minZ, z)
                if m.kind == .rapid, e.z < clear - tol, !lowRapid {
                    lowRapid = true
                    issues.append(GCodeCheck.Issue(.error, "A rapid goes below the \(Calibration.length(clear, u)) clearance height."))
                }
                if m.kind != .rapid, z < -tol {
                    // Every cutting move ends on a level (the board's top or −k × depth); a level move stays on one.
                    let k = (-z / depth).rounded()
                    let onLevel = abs(z + k * depth) <= tol && k >= 1 && Int(k) <= passes
                    if !onLevel, !offLevel {
                        offLevel = true
                        issues.append(GCodeCheck.Issue(.error, "A cut reads back at Z \(Calibration.length(z, u)), not at a multiple of the "
                            + "\(Calibration.length(depth, u)) pass depth."))
                    }
                }
                if (e.x < lo.x - tol || e.x > hi.x + tol || e.y < lo.y - tol || e.y > hi.y + tol), !outside {
                    outside = true
                    issues.append(GCodeCheck.Issue(.error, "Goes outside the area and its overshoot."))
                }
            }
        }
        let total = depth * Double(passes)
        if abs(minZ + total) > tol {
            issues.append(GCodeCheck.Issue(.error, "Reads back \(Calibration.length(-minZ, u)) deep at most, where the program "
                + "takes off \(Calibration.length(total, u))."))
        }
        // The program's whole extent, park and links included, keeps the margin clear of the travel's ends: its span
        // within the travel less two margins and, on the whole bed (zeroed the inset in from the front-left limits),
        // its position too.
        let travel = program.project.machine.travel
        let m = plan.margin
        if ext.hi.x - ext.lo.x > travel.x - 2 * m + tol || ext.hi.y - ext.lo.y > travel.y - 2 * m + tol {
            issues.append(GCodeCheck.Issue(.error, "The program spans \(Calibration.size(Vec2(ext.hi.x - ext.lo.x, ext.hi.y - ext.lo.y), u)), "
                + "more than the machine's travel less \(Calibration.length(m, u)) at each end."))
        } else if plan.inset != nil, ext.lo.x < -tol || ext.lo.y < -tol || ext.hi.x > travel.x - 2 * m + tol || ext.hi.y > travel.y - 2 * m + tol {
            issues.append(GCodeCheck.Issue(.error, "The program comes within \(Calibration.length(m, u)) of the travel's limits."))
        }
        return issues
    }
}
