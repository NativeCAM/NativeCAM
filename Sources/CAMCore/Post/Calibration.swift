import Foundation

/// Ready-to-run programs that turn NativeCAM's untested estimates into numbers measured on the machine, whenever the
/// user chooses to run them. Nothing here changes a machine profile: `CalibrationFit` does that, and only when asked.
///
/// - **Timing suite** (`timing`): an air cut in sections, each long enough (about 40 s) to time with a stopwatch to a few
///   percent, with a stop (`M0`, and Mach4's or LinuxCNC's `(MSG,…)`) before each. It holds straight lines and squares at
///   three feeds, circles at five radii as arcs and as 10° segments, a zig-zag of short segments, long and short X/Y and
///   Z rapids, a helix, and the F-change line (a line split into pieces that alternate between two feeds, next to the
///   same pieces at one feed), which says whether the controller keeps constant-velocity blending through a change of
///   F. Every move stays at or above the air height (never below 25 mm) and inside the window.
/// - **Rotary check** (`rotary`): `G93 G1 A360 F10` (6 s expected), then rapid turns of 360° and 720°, which time the
///   axis's turn speed. Only A moves. Written for controllers that drive A and take `G93`: Avid Mach4, LinuxCNC and
///   grblHAL; refused elsewhere.
/// - **Chip-load ladder** (`ladder`): a real cut in scrap. A row of slots, each entering from the scrap's front edge,
///   steps the chip load from below the chart's range to above it (and, optionally, the spindle speed). It reads
///   `ChipLoad` and never changes it.
///
/// Each program is posted with NativeCAM's own post for the machine's controller (an imported Vectric post can't write
/// the stops), with one change for machines with manual tool changes: there's one bit, so the file asks for it to be
/// loaded before starting rather than calling the tool-change macro. It's checked with `GCodeCheck` and with
/// `Calibration.verify` (the air height and the window).
public enum Calibration {
    /// A program that can't be made, or times that can't be fitted, and why.
    public struct Refused: Error, LocalizedError, Hashable, Sendable {
        public var reason: String
        public init(_ reason: String) { self.reason = reason }
        public var errorDescription: String? { reason }
    }

    public enum Kind: String, Codable, Sendable, CaseIterable, Identifiable {
        case timing, rotary, ladder
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .timing: "Timing suite"
            case .rotary: "Rotary check"
            case .ladder: "Chip-load ladder"
            }
        }
        /// The file name each program is saved under, without the extension.
        public var fileStem: String { "calibration-\(rawValue)" }
    }

    /// The lowest the air programs ever go above Z zero, mm.
    public static let minimumAirHeight = 25.0
    /// How long each timed section is made to run on the machine's class defaults, seconds: long enough that a hand on
    /// a stopwatch is good to a few percent, and still over 30 s on a machine a third faster.
    public static let sectionTarget = 40.0
    /// The timed sections, the turn speed and the G93 check are timed from the first move to the stop that follows it.
    public static let timingInstruction = "Time it from the first move until the machine stops."

    // MARK: Programs

    /// One timed stretch of a program, between two stops.
    public struct Section: Hashable, Sendable, Identifiable {
        public var id: String
        /// Short name, as the stop's message gives it.
        public var name: String
        /// What it measures, for the recording sheet.
        public var measures: String
        /// Passes, laps or moves in the program.
        public var count: Int
        /// NativeCAM's estimate on the machine the program was made for, seconds.
        public var estimate: Double
        /// The least time its moves can take, at their programmed feeds and the machine's X/Y rapid rate (Z rapids at
        /// twice the faster of the X/Y and Z rates), seconds: a time well below it can't be right.
        public var minimum: Double
        /// Used to fit the machine's values. The F-change line with alternating feeds isn't: it's judged against the
        /// same line at one feed.
        public var fitted: Bool
    }

    /// A ready-to-run calibration program: the posted file, what it's made of, and what its checks found.
    public struct Program: Sendable {
        public var kind: Kind
        /// The job the file was posted from: its machine (as the post saw it) and stock.
        public var project: Project
        public var toolpaths: [Toolpath]
        /// The timed sections, in order (none on the ladder).
        public var sections: [Section]
        public var gcode: String
        public var dialect: Dialect
        public var fileExtension: String
        /// The timing suite's plan, from which the fit rebuilds exactly the same sections.
        public var plan: TimingPlan?
        /// The rotary check's axis letter.
        public var axisLetter: String?
        /// The ladder's rungs, in cutting order.
        public var rungs: [Rung]
        /// What the program asks of the operator before it starts (also the file's first comments).
        public var setup: [String]
        /// Errors and warnings from `GCodeCheck` and `verify`; empty when the file passed.
        public var issues: [GCodeCheck.Issue]
        /// The area the program stays in, mm, from the XY zero at its front-left corner (nil on the rotary check).
        public var window: Vec2?
        /// Estimated run time of all the moves, seconds, leaving out the stops.
        public var estimatedSeconds: Double

        public var fileName: String { kind.fileStem + "." + fileExtension }
        public var passedChecks: Bool { !issues.contains { $0.severity == .error } }
    }

    /// The machine a calibration program is posted for: NativeCAM's own post for its controller, and with a manual
    /// tool change, no tool-change macro (one bit, loaded before starting).
    static func postingMachine(_ machine: MachineProfile, dustCollection: Bool) -> MachineProfile {
        var m = machine
        m.customPost = nil
        if m.toolChange == .manualM6 { m.toolChange = .manualPause }
        m.dustCollection = dustCollection && machine.dustCollection
        return m
    }

    /// Why NativeCAM can't post for this machine's controller, if it can't.
    static func noPost(_ machine: MachineProfile) -> Refused? {
        var m = machine
        m.customPost = nil
        guard Dialect.for(m) == nil else { return nil }
        return Refused(PostProcessors.unavailableReason(for: m) ?? "NativeCAM has no post for \(m.controllerLabel).")
    }

    /// The post for `project`, with its creation date and time zone pinned.
    static func post(_ project: Project, date: Date, timeZone: TimeZone) -> (any PostProcessor)? {
        guard let post = PostProcessors.post(for: project, date: date) else { return nil }
        if var p = post as? AvidMach4Post { p.timeZone = timeZone; return p }
        if var p = post as? GenericGCodePost { p.timeZone = timeZone; return p }
        if var p = post as? OpenSBPPost { p.timeZone = timeZone; return p }
        return post
    }

    /// Comment lines for the top of a file in the dialect's syntax, wrapped to its line limit; none where the controller
    /// takes no comments.
    static func headerComments(_ lines: [String], dialect: Dialect) -> String {
        guard dialect.writesComments else { return "" }
        let room = (dialect.maxLineLength ?? 200) - 2
        var out = ""
        for text in lines {
            let cleaned = text.replacingOccurrences(of: "(", with: "{").replacingOccurrences(of: ")", with: "}")
                .replacingOccurrences(of: "\"", with: "in").replacingOccurrences(of: "×", with: "x")
                .replacingOccurrences(of: "°", with: "deg").replacingOccurrences(of: "–", with: "-")
                .replacingOccurrences(of: "—", with: "-").replacingOccurrences(of: "’", with: "'")
                .unicodeScalars.filter { $0.isASCII && $0.value >= 32 }.map(String.init).joined()
            var line = ""
            for word in cleaned.split(separator: " ") {
                if !line.isEmpty, line.count + 1 + word.count > min(room, 100) {
                    out += wrap(line, dialect) + dialect.lineEnding
                    line = ""
                }
                line += (line.isEmpty ? "" : " ") + word
            }
            if !line.isEmpty { out += wrap(line, dialect) + dialect.lineEnding }
        }
        return out
    }

    private static func wrap(_ text: String, _ dialect: Dialect) -> String {
        dialect.language == .openSBP ? "'" + text : "(" + text + ")"
    }

    /// The window's size for a sheet or a message: "24 × 24 in".
    public static func size(_ v: Vec2, _ u: LengthUnit) -> String {
        "\(number(u.fromMM(v.x))) × \(number(u.fromMM(v.y))) \(u.symbol)"
    }

    /// A length in the program's units, with as few decimals as it needs: "0.125 in", "2 in", "12.5 mm".
    public static func length(_ mm: Double, _ u: LengthUnit) -> String { "\(number(u.fromMM(mm))) \(u.symbol)" }

    public static func feed(_ mmPerMin: Double, _ u: LengthUnit) -> String { "\(number(u.fromMM(mmPerMin))) \(u.feedSymbol)" }

    public static func number(_ v: Double) -> String {
        v.formatted(.number.precision(.fractionLength(0...3)).grouping(.never))
    }

    /// Rounds a feed to the precision the posts write it at (0.1 in/min, 1 mm/min), in mm/min.
    static func roundedFeed(_ mmPerMin: Double, _ u: LengthUnit) -> Double {
        let p = u == .inch ? 10.0 : 1.0
        return u.toMM((u.fromMM(mmPerMin) * p).rounded() / p)
    }

    // MARK: Timing suite

    /// The window and height the timing suite stays in.
    public struct TimingOptions: Hashable, Sendable {
        /// The area the program stays in, mm, from the XY zero at its front-left corner.
        public var window: Vec2
        /// Height above Z zero that every move stays at or above, mm; never below `minimumAirHeight`.
        public var airHeight: Double

        public init(window: Vec2 = Vec2(24.inch, 24.inch), airHeight: Double = 1.inch) {
            self.window = window
            self.airHeight = airHeight
        }

        /// 24 × 24 in at 1 in for a machine in inches; 600 × 600 mm at 25 mm in millimetres.
        public static func defaults(_ units: LengthUnit) -> TimingOptions {
            units == .inch ? TimingOptions() : TimingOptions(window: Vec2(600, 600), airHeight: 25)
        }
    }

    /// Everything the timing suite's sections are built from, so the fit can rebuild the exact program that was timed
    /// (it's saved with the times). Its repetition counts come from the machine's class defaults, not its fitted values,
    /// so applying a fit doesn't change the program.
    public struct TimingPlan: Hashable, Sendable {
        public var units: LengthUnit
        /// mm.
        public var window: Vec2
        /// mm above Z zero.
        public var airHeight: Double
        /// How far the Z rapids and the helix rise above the air height, mm.
        public var zStroke: Double
        /// Slow, medium and fast feeds, mm/min (a quarter, half and all of the machine's highest feed).
        public var feeds: [Double]
        /// Repetitions of each section, by ID.
        public var counts: [String: Int]
        /// The dialect the program was posted for (`Dialect.id`).
        public var controller: String

        public var topZ: Double { airHeight + zStroke }
    }

    /// The timing suite's sections, in the order they run.
    enum TimingKind: Hashable, CaseIterable {
        case line1, line2, line3, square1, square2, square3
        case arc1, arc2, arc3, arc4, arc5, segments1, segments2, segments3, segments4, segments5
        case zigzag, rapidXY, rapidXYShort, rapidZ, rapidZShort, helix, fChangeSingle, fChangeAlternating

        var id: String {
            switch self {
            case .line1: "line-1"
            case .line2: "line-2"
            case .line3: "line-3"
            case .square1: "square-1"
            case .square2: "square-2"
            case .square3: "square-3"
            case .arc1: "arc-1"
            case .arc2: "arc-2"
            case .arc3: "arc-3"
            case .arc4: "arc-4"
            case .arc5: "arc-5"
            case .segments1: "segments-1"
            case .segments2: "segments-2"
            case .segments3: "segments-3"
            case .segments4: "segments-4"
            case .segments5: "segments-5"
            case .zigzag: "zigzag"
            case .rapidXY: "rapid-xy"
            case .rapidXYShort: "rapid-xy-short"
            case .rapidZ: "rapid-z"
            case .rapidZShort: "rapid-z-short"
            case .helix: "helix"
            case .fChangeSingle: "fchange-single"
            case .fChangeAlternating: "fchange-alternating"
            }
        }

        /// Which of the three feeds a line or square runs at (0 slow, 1 medium, 2 fast).
        var feedIndex: Int? {
            switch self {
            case .line1, .square1: 0
            case .line2, .square2: 1
            case .line3, .square3: 2
            default: nil
            }
        }

        /// Which circle (0 smallest to 4 largest).
        var circleIndex: Int? {
            switch self {
            case .arc1, .segments1: 0
            case .arc2, .segments2: 1
            case .arc3, .segments3: 2
            case .arc4, .segments4: 3
            case .arc5, .segments5: 4
            default: nil
            }
        }

        var isArc: Bool { [.arc1, .arc2, .arc3, .arc4, .arc5].contains(self) }
    }

    /// Circle radii: 1/8 to 2 in, or 3 to 50 mm.
    static func circleRadii(_ u: LengthUnit) -> [Double] {
        let inches: [Double] = [0.125, 0.25, 0.5, 1, 2]
        return u == .inch ? inches.map(\.inch) : [3, 6, 12, 25, 50]
    }
    static func squareSide(_ u: LengthUnit) -> Double { u == .inch ? 2.inch : 50 }
    static func shortRapid(_ u: LengthUnit) -> Double { u == .inch ? 1.inch : 25 }
    /// The zig-zag's step along X and its offset across, chosen to be exact in the file's units.
    static func zigzagStep(_ u: LengthUnit) -> (dx: Double, dy: Double) { u == .inch ? (0.02.inch, 0.001.inch) : (0.5, 0.025) }
    static func fChangePiece(_ u: LengthUnit) -> Double { u == .inch ? 1.inch : 25 }
    static func helixRadius(_ u: LengthUnit) -> Double { u == .inch ? 0.5.inch : 12 }
    static func helixPitch(_ u: LengthUnit) -> Double { u == .inch ? 0.25.inch : 6 }
    /// The smallest window the suite fits in: the 2 in (50 mm) circle with room around it.
    static func minimumWindow(_ u: LengthUnit) -> Double { u == .inch ? 6.inch : 150 }

    /// The F-change line's two feeds (the medium feed and three quarters of it) and the single feed that takes the same
    /// time over the same pieces (their harmonic mean), mm/min, rounded as the posts write them.
    static func fChangeFeeds(_ plan: TimingPlan) -> (high: Double, low: Double, single: Double) {
        let hi = plan.feeds[1]
        let lo = roundedFeed(hi * 0.75, plan.units)
        return (hi, lo, roundedFeed(2 / (1 / hi + 1 / lo), plan.units))
    }

    static func name(_ kind: TimingKind, _ plan: TimingPlan) -> String {
        let u = plan.units
        if let f = kind.feedIndex {
            return kind == .line1 || kind == .line2 || kind == .line3
                ? "Line at \(feed(plan.feeds[f], u))" : "Squares at \(feed(plan.feeds[f], u))"
        }
        if let c = kind.circleIndex {
            return "\(kind.isArc ? "Arcs" : "Segments"), radius \(length(circleRadii(u)[c], u))"
        }
        switch kind {
        case .zigzag: return "Zig-zag of \(length(zigzagStep(u).dx, u)) steps"
        case .rapidXY: return "X/Y rapids, long"
        case .rapidXYShort: return "X/Y rapids, \(length(shortRapid(u), u))"
        case .rapidZ: return "Z rapids, \(length(plan.zStroke, u))"
        case .rapidZShort: return "Z rapids, \(length(plan.zStroke / 4, u))"
        case .helix: return "Helix at \(feed(plan.feeds[1], u))"
        case .fChangeSingle: return "F-change line, one feed"
        case .fChangeAlternating: return "F-change line, two feeds"
        default: return kind.id
        }
    }

    static func measures(_ kind: TimingKind, _ plan: TimingPlan) -> String {
        let u = plan.units
        if let f = kind.feedIndex {
            return kind == .line1 || kind == .line2 || kind == .line3
                ? "Back and forth along X across the window at \(feed(plan.feeds[f], u)): the feed itself, and X/Y acceleration at each end."
                : "\(length(squareSide(u), u)) squares at \(feed(plan.feeds[f], u)): how much each 90° corner costs (acceleration and corner tolerance)."
        }
        if let c = kind.circleIndex {
            let r = length(circleRadii(u)[c], u)
            return kind.isArc
                ? "Circles of \(r) radius as arcs (G2/G3) at \(feed(plan.feeds[2], u)): small arcs are held back by acceleration."
                : "The same circles of \(r) radius as 10° line segments: corner tolerance and look-ahead."
        }
        let ff = fChangeFeeds(plan)
        switch kind {
        case .zigzag:
            return "Back and forth along X in \(length(zigzagStep(u).dx, u)) steps that zig-zag slightly, at \(feed(plan.feeds[2], u)): how far ahead the controller plans."
        case .rapidXY: return "Rapids (G0) across the window in X, then in Y: the X/Y rapid rate."
        case .rapidXYShort: return "Short rapids of \(length(shortRapid(u), u)) in X and Y: X/Y acceleration at rapid speed."
        case .rapidZ: return "Z rapids up \(length(plan.zStroke, u)) and back: the Z rapid rate."
        case .rapidZShort: return "Z rapids of \(length(plan.zStroke / 4, u)): Z acceleration."
        case .helix: return "A helix of \(length(helixRadius(u), u)) radius rising \(length(helixPitch(u), u)) a turn, up and down: helical arcs."
        case .fChangeSingle:
            return "A line of \(length(fChangePiece(u), u)) pieces back and forth, all at \(feed(ff.single, u)): the reference for the next section."
        case .fChangeAlternating:
            return "The same pieces alternating between \(feed(ff.high, u)) and \(feed(ff.low, u)), which take the same time if the controller keeps constant velocity through a change of F."
        default: return ""
        }
    }

    /// One section's moves, `count` times over, starting and ending at the window's corner at the air height.
    static func motions(_ kind: TimingKind, _ plan: TimingPlan, count: Int) -> [Motion] {
        let u = plan.units, z = plan.airHeight, w = plan.window
        let n = max(1, count)
        var m: [Motion] = []
        func p(_ x: Double, _ y: Double, _ h: Double? = nil) -> Vec3 { Vec3(x, y, h ?? z) }
        if let f = kind.feedIndex {
            let feed = plan.feeds[f]
            if kind == .line1 || kind == .line2 || kind == .line3 {
                for _ in 0..<n { m += [.feed(p(w.x, 0), feed), .feed(p(0, 0), feed)] }
            } else {
                let s = squareSide(u)
                for _ in 0..<n { m += [.feed(p(s, 0), feed), .feed(p(s, s), feed), .feed(p(0, s), feed), .feed(p(0, 0), feed)] }
            }
            return m
        }
        if let c = kind.circleIndex {
            let r = circleRadii(u)[c], feed = plan.feeds[2], centre = Vec2(r, r)
            m.append(.feed(p(r, 0), feed))
            for _ in 0..<n {
                if kind.isArc {
                    for q in 1...4 {
                        let a = -Double.pi / 2 + Double(q) * .pi / 2
                        m.append(Motion(kind: .arcCCW, end: p(r + r * cos(a), r + r * sin(a)), center: centre, feed: feed))
                    }
                } else {
                    for k in 1...36 {
                        let a = -Double.pi / 2 + Double(k) * .pi / 18
                        m.append(.feed(k == 36 ? p(r, 0) : p(r + r * cos(a), r + r * sin(a)), feed))
                    }
                }
            }
            m.append(.feed(p(0, 0), feed))
            return m
        }
        switch kind {
        case .zigzag:
            let (dx, dy) = zigzagStep(u), feed = plan.feeds[2]
            var steps = Int((w.x / dx).rounded(.down))
            if steps % 2 == 1 { steps -= 1 }
            let there = (1...steps).map { j in p(Double(j) * dx, j % 2 == 1 ? dy : 0) }
            let back = (0..<steps).reversed().map { j in p(Double(j) * dx, j % 2 == 1 ? dy : 0) }
            for _ in 0..<n { m += there.map { .feed($0, feed) } + back.map { .feed($0, feed) } }
        case .rapidXY:
            for _ in 0..<n { m += [.rapid(p(w.x, 0)), .rapid(p(0, 0)), .rapid(p(0, w.y)), .rapid(p(0, 0))] }
            // A feed move that goes nowhere, so the section counts as a toolpath; it writes nothing.
            m.append(.feed(p(0, 0), plan.feeds[0]))
        case .rapidXYShort:
            let s = shortRapid(u)
            for _ in 0..<n { m += [.rapid(p(s, 0)), .rapid(p(0, 0)), .rapid(p(0, s)), .rapid(p(0, 0))] }
            m.append(.feed(p(0, 0), plan.feeds[0]))
        case .rapidZ, .rapidZShort:
            let top = z + (kind == .rapidZ ? plan.zStroke : plan.zStroke / 4)
            for _ in 0..<n { m += [.rapid(p(0, 0, top)), .rapid(p(0, 0))] }
            m.append(.feed(p(0, 0), plan.feeds[0]))
        case .helix:
            let r = helixRadius(u), pitch = helixPitch(u), feed = plan.feeds[1], centre = Vec2(r, r)
            let turns = max(1, Int((plan.zStroke / pitch + 1e-9).rounded(.down)))
            m.append(.feed(p(r, 0), feed))
            var height = z
            for _ in 0..<n {
                for dir in [1.0, -1.0] {
                    for _ in 0..<turns {
                        for q in 1...4 {
                            let a = -Double.pi / 2 + Double(q) * .pi / 2
                            height += dir * pitch / 4
                            m.append(Motion(kind: .arcCCW, end: p(r + r * cos(a), r + r * sin(a), height), center: centre, feed: feed))
                        }
                    }
                }
            }
            m.append(.feed(p(0, 0), feed))
        case .fChangeSingle, .fChangeAlternating:
            let piece = fChangePiece(u), ff = fChangeFeeds(plan)
            var pieces = Int((w.x / piece + 1e-9).rounded(.down))
            if pieces % 2 == 1 { pieces -= 1 }
            func feed(_ j: Int) -> Double { kind == .fChangeSingle ? ff.single : (j % 2 == 0 ? ff.high : ff.low) }
            for _ in 0..<n {
                for j in 0..<pieces { m.append(.feed(p(Double(j + 1) * piece, 0), feed(j))) }
                for j in (0..<pieces).reversed() { m.append(.feed(p(Double(j) * piece, 0), feed(j))) }
            }
        default:
            break
        }
        return m
    }

    /// The suite's plan for a machine: its feeds, the Z stroke its travel allows, and repetitions that make each section
    /// run about `sectionTarget` seconds on the machine's class defaults.
    public static func timingPlan(machine: MachineProfile, options: TimingOptions) throws -> TimingPlan {
        if let refused = noPost(machine) { throw refused }
        let u = machine.outputUnits
        let m = postingMachine(machine, dustCollection: false)
        guard let dialect = Dialect.for(m) else { throw Refused("NativeCAM has no post for \(machine.controllerLabel).") }
        if options.airHeight < minimumAirHeight - 1e-6 {
            throw Refused("The air height can't be below \(length(minimumAirHeight, u == .inch ? .mm : u))"
                + "\(u == .inch ? " (about 1 in)" : ""): everything in the timing suite runs at least that far above Z zero.")
        }
        let least = minimumWindow(u)
        if options.window.x < least - 1e-6 || options.window.y < least - 1e-6 {
            throw Refused("The window must be at least \(size(Vec2(least, least), u)), for the \(length(circleRadii(u)[4] * 2, u)) circles.")
        }
        let travel = machine.travel
        if options.window.x > travel.x + 1e-6 || options.window.y > travel.y + 1e-6 {
            throw Refused("The \(size(options.window, u)) window is bigger than the machine's \(size(travel.xy, u)) of travel. "
                + "Make it smaller in Calibration Programs (or with --window).")
        }
        let step = u == .inch ? 0.25.inch : 5
        let stroke = max(step, (min(u == .inch ? 2.inch : 50, travel.z / 4) / step).rounded(.down) * step)
        if options.airHeight + stroke > travel.z + 1e-6 {
            throw Refused("A \(length(options.airHeight, u)) air height leaves no room for the Z rapids in the machine's "
                + "\(length(travel.z, u)) of Z travel.")
        }
        let fast = (u.fromMM(machine.maxFeedRate) * (u == .inch ? 1 : 0.1)).rounded(.down) / (u == .inch ? 1 : 0.1)
        let top = u.toMM(max(fast, u == .inch ? 4 : 100))
        var plan = TimingPlan(units: u, window: options.window, airHeight: options.airHeight, zStroke: stroke,
                              feeds: [roundedFeed(top / 4, u), roundedFeed(top / 2, u), top], counts: [:], controller: dialect.id)
        // Repetitions from the class defaults: the program stays the same when fitted values are applied.
        var planning = m
        planning.accelerationXY = nil
        planning.accelerationZ = nil
        planning.rapidRateZ = nil
        planning.junctionDeviation = nil
        let project = timingProject(machine: planning, plan: plan)
        for kind in TimingKind.allCases {
            let one = sectionSeconds(toolpath(kind, plan: plan, count: 1, index: 0), project: project)
            let two = sectionSeconds(toolpath(kind, plan: plan, count: 2, index: 0), project: project)
            let each = max(1e-3, two - one), fixed = max(0, one - each)
            plan.counts[kind.id] = max(1, Int(((sectionTarget - fixed) / each).rounded(.up)))
        }
        return plan
    }

    /// The project a timing program is posted and estimated for: the window as a sheet of no thickness with Z zero on the
    /// spoilboard, safe Z and the park at the air height over the window's corner, so each section starts and ends at
    /// the park position.
    static func timingProject(machine: MachineProfile, plan: TimingPlan) -> Project {
        var m = postingMachine(machine, dustCollection: false)
        m.outputUnits = plan.units
        let stock = Stock(width: plan.window.x, height: plan.window.y, thickness: 0, materialName: "None (air cut)",
                          xyOrigin: .lowerLeft, zZero: .machineBed, clearanceHeight: plan.airHeight,
                          plungeHeight: plan.airHeight, homePosition: Vec3(0, 0, plan.airHeight))
        var p = Project(name: "NativeCAM timing suite", displayUnits: plan.units, stock: stock, machine: m)
        p.notes = "Air cut: time each section from its first move until the machine stops."
        return p
    }

    /// The bit the air programs name: any bit will do.
    static var airTool: Tool {
        var t = ToolLibrary.starter.tool(number: 1)!
        t.name = "Any bit - air cut only"
        return t
    }

    static func toolpath(_ kind: TimingKind, plan: TimingPlan, count: Int, index: Int) -> Toolpath {
        let id = UUID(uuidString: String(format: "CA11B000-0000-0000-0000-%012d", index + 1))!
        return Toolpath(id: id, name: "\(index + 1). \(name(kind, plan))", tool: airTool, spindleRPM: 0,
                        start: Vec3(0, 0, plan.airHeight), motions: motions(kind, plan, count: count))
    }

    /// Seconds for one section on its own, from rest at its start to rest at its end, as `CycleTimeEstimator` plans it.
    static func sectionSeconds(_ toolpath: Toolpath, project: Project) -> Double {
        CycleTimeEstimator.estimate([toolpath], project: project).toolpathSeconds.first ?? 0
    }

    /// The least time a section's moves can take: feeds at their F words, rapids at the rapid rates (see
    /// `Section.minimum`).
    static func minimumSeconds(_ toolpath: Toolpath, machine: MachineProfile) -> Double {
        let xy = max(machine.rapidRateForEstimates, 1), zMax = 2 * max(xy, machine.axisRapid.z)
        var total = 0.0
        toolpath.forEachMotion { start, m in
            switch m.kind {
            case .rapid:
                let d = m.end - start
                total += max(hypot(d.x, d.y) / xy, abs(d.z) / zMax) * 60
            case .dwell: total += max(0, m.feed)
            default: total += m.length(from: start) / max(m.feed, 1) * 60
            }
        }
        return total
    }

    /// The timing suite's sections as `plan` describes them, each with its stop and its estimate on `machine`.
    static func timingSections(plan: TimingPlan, machine: MachineProfile) -> (project: Project, toolpaths: [Toolpath], sections: [Section]) {
        let project = timingProject(machine: machine, plan: plan)
        let m = project.machine
        let rpm = m.clampRPM(m.minRPM)
        var toolpaths: [Toolpath] = []
        var sections: [Section] = []
        let kinds = TimingKind.allCases
        for (i, kind) in kinds.enumerated() {
            var tp = toolpath(kind, plan: plan, count: plan.counts[kind.id] ?? 1, index: i)
            tp.spindleRPM = rpm
            let estimate = sectionSeconds(tp, project: project)
            let title = name(kind, plan)
            tp.stopMessage = "\(i + 1)/\(kinds.count) \(title), about \(Int(estimate.rounded())) s. Time it until it stops."
            toolpaths.append(tp)
            sections.append(Section(id: kind.id, name: title, measures: measures(kind, plan), count: plan.counts[kind.id] ?? 1,
                                    estimate: estimate, minimum: minimumSeconds(tp, machine: m), fitted: kind != .fChangeAlternating))
        }
        return (project, toolpaths, sections)
    }

    /// The timing suite for a machine, ready to run.
    public static func timing(machine: MachineProfile, options: TimingOptions? = nil, date: Date = Date(),
                              timeZone: TimeZone = .current) throws -> Program {
        let plan = try timingPlan(machine: machine, options: options ?? .defaults(machine.outputUnits))
        return try timing(plan: plan, machine: machine, date: date, timeZone: timeZone)
    }

    /// The timing suite exactly as `plan` describes it, with estimates for `machine`.
    public static func timing(plan: TimingPlan, machine: MachineProfile, date: Date = Date(),
                              timeZone: TimeZone = .current) throws -> Program {
        if let refused = noPost(machine) { throw refused }
        let (project, toolpaths, sections) = timingSections(plan: plan, machine: machine)
        let m = project.machine
        guard let post = post(project, date: date, timeZone: timeZone) else {
            throw Refused(PostProcessors.unavailableReason(for: m) ?? "No post for \(m.controllerLabel).")
        }
        let u = plan.units
        let total = sections.map(\.estimate).reduce(0, +)
        let setup = [
            "NATIVECAM TIMING SUITE: an air cut in \(sections.count) timed sections, about \(Int((total / 60).rounded())) min of moves.",
            "Zero X and Y at the front-left corner of a clear \(size(plan.window, u)) window, and Z on the spoilboard.",
            "Every move stays at least \(length(plan.airHeight, u)) above Z zero, rising to \(length(plan.topZ, u)): keep the bit clear "
                + "of the work, clamps and anything else in the window, and make sure Z can rise that far.",
            "At each stop the message names the next section. Press Cycle Start and \(timingInstruction.prefix(1).lowercased() + timingInstruction.dropFirst()) "
                + "Write the time on the recording sheet.",
            "The stops are for timing only: don't change the bit or re-zero at them. Keep the feed and rapid overrides at 100%.",
        ]
        let gcode = headerComments(setup, dialect: post.dialect) + post.post(toolpaths)
        var program = Program(kind: .timing, project: project, toolpaths: toolpaths, sections: sections, gcode: gcode,
                              dialect: post.dialect, fileExtension: post.fileExtension, plan: plan, axisLetter: nil, rungs: [],
                              setup: setup, issues: [], window: plan.window, estimatedSeconds: total)
        program.issues = check(program)
        return program
    }

    // MARK: Rotary check

    /// Why the rotary check can't be written for this machine; nil when it can.
    public static func rotaryRefusal(_ machine: MachineProfile) -> Refused? {
        if let refused = noPost(machine) { return refused }
        var m = machine
        m.customPost = nil
        guard let dialect = Dialect.for(m) else { return Refused("NativeCAM has no post for \(m.controllerLabel).") }
        let letter = Character(machine.rotary?.letter.rawValue ?? "A")
        if dialect.rotaryAxes.isEmpty {
            return Refused("\(dialect.name) can't drive a rotary axis, so there's no turn to time. The rotary check runs on "
                + "Avid Mach4, LinuxCNC and grblHAL.")
        }
        if !dialect.rotaryAxes.contains(letter) {
            return Refused("\(dialect.name) can't drive a rotary \(letter) axis. The rotary check runs on Avid Mach4, LinuxCNC and grblHAL.")
        }
        if !dialect.inverseTime {
            return Refused("\(dialect.name) drives \(letter), but NativeCAM doesn't know that it takes inverse-time feeds (G93), "
                + "which the check times. The rotary check runs on Avid Mach4, LinuxCNC and grblHAL.")
        }
        if machine.rotary?.turnsByHand == true {
            return Refused("This machine's blank is turned by hand, so there's no turn speed to time.")
        }
        return nil
    }

    /// The rotary check's inverse-time F word: one turn in a tenth of a minute.
    public static let rotaryInverseTime = 10.0
    /// What the inverse-time turn should take, seconds.
    public static let rotaryExpectedSeconds = 6.0

    /// The rotary check's sections: one turn in G93, a rapid turn of 360° and one of 720°.
    static func rotarySections(_ axis: RotaryAxis, letter: String) -> [Section] {
        let turn = { (degrees: Double) in axis.turnSeconds(from: 0, to: degrees) }
        let g93 = max(rotaryExpectedSeconds, turn(360))
        return [
            Section(id: "rotary-g93", name: "One turn in inverse time, G93 F\(Int(rotaryInverseTime))",
                    measures: "G93 G1 \(letter)360 F\(Int(rotaryInverseTime)): Mach4's inverse time, which should take \(Int(rotaryExpectedSeconds)) s.",
                    count: 1, estimate: g93, minimum: rotaryExpectedSeconds, fitted: false),
            Section(id: "rotary-360", name: "Rapid turn of 360°", measures: "G0 \(letter) through one turn: the axis's turn speed.",
                    count: 1, estimate: turn(360), minimum: 0, fitted: true),
            Section(id: "rotary-720", name: "Rapid turn of 720° back to \(letter)0",
                    measures: "G0 \(letter) through two turns: the turn speed again, and its start and stop.",
                    count: 1, estimate: turn(720), minimum: 0, fitted: true),
        ]
    }

    /// The rotary check for a machine that drives its A axis, ready to run; refused elsewhere (`rotaryRefusal`).
    public static func rotary(machine: MachineProfile, date: Date = Date(), timeZone: TimeZone = .current) throws -> Program {
        if let refused = rotaryRefusal(machine) { throw refused }
        var m = postingMachine(machine, dustCollection: false)
        let axis = m.rotary ?? RotaryAxis()
        m.rotary = axis
        let dialect = Dialect.for(m)!
        let u = m.outputUnits
        let letter = axis.letter.rawValue
        let avid = m.isLegacyAvidMach4
        var project = Project(name: "NativeCAM rotary check", displayUnits: u, stock: Stock(), machine: m)
        project.notes = "Only the rotary axis moves."
        let sections = rotarySections(axis, letter: letter)
        let setup = [
            "NATIVECAM ROTARY CHECK: times the rotary \(letter) axis. Nothing but \(letter) moves: X, Y and Z stay where they are.",
            "Take any stock out of the chuck. Raise the bit well clear of the chuck and tailstock before starting.",
            "Zero \(letter) where it is now (any angle will do). Keep the overrides at 100%.",
            "At each stop the message names the next turn. Press Cycle Start and \(timingInstruction.prefix(1).lowercased() + timingInstruction.dropFirst()) "
                + "The first turn, in inverse time (G93 F\(Int(rotaryInverseTime))), should take \(Int(rotaryExpectedSeconds)) s.",
        ]
        let g0 = avid ? "G00" : "G0", g1 = avid ? "G01" : "G1", stop = avid ? "M00" : "M0"
        func word(_ v: Double) -> String { "\(letter)\(String(format: "%.3f", v == 0 ? 0 : v))" }
        var lines: [String] = []
        func comment(_ s: String) { lines.append(AvidMach4Post.Writer.comment(s)) }
        comment(project.name)
        comment("Post: \(avid ? "Avid CNC Mach4" : dialect.name) - NativeCAM calibration")
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd HH:mm"
        df.timeZone = timeZone
        comment("Created: \(df.string(from: date))")
        comment("Machine: \(m.displayName), \(m.controllerLabel), rotary axis \(letter)")
        lines.append(avid ? "G00 G94 \(u == .inch ? "G20" : "G21") G17 G90 G40 G49 G80" : dialect.safetyLine)
        if !avid { lines.append(u == .inch ? "G20" : "G21") }
        // Start from A0, untimed, so each timed turn is exactly as long as it says.
        lines.append("\(g0) \(word(0))")
        let f = String(format: "%.\(RotaryWrap.inverseTimeDecimals)f", rotaryInverseTime)
        let moves: [[String]] = [["G93 \(g1) \(word(360)) F\(f)", "G94"], ["\(g0) \(word(720))"], ["\(g0) \(word(0))"]]
        for (i, (section, move)) in zip(sections, moves).enumerated() {
            let message = "\(i + 1)/\(sections.count) \(section.name), about \(number((section.estimate * 10).rounded() / 10)) s. Time it until it stops."
            comment((dialect.showsMessages ? "MSG," : "") + message)
            lines.append(stop)
            lines += move
        }
        lines.append("M30")
        let ending = dialect.lineEnding
        let gcode = headerComments(setup, dialect: dialect) + lines.map { $0 + ending }.joined()
        var program = Program(kind: .rotary, project: project, toolpaths: [], sections: sections, gcode: gcode, dialect: dialect,
                              fileExtension: dialect.fileExtension, plan: nil, axisLetter: letter, rungs: [], setup: setup, issues: [],
                              window: nil, estimatedSeconds: sections.map(\.estimate).reduce(0, +))
        program.issues = check(program)
        return program
    }

    // MARK: Chip-load ladder

    /// The ladder's bit, material and cut.
    public struct LadderOptions: Hashable, Sendable {
        public var tool: Tool
        public var material: MaterialKind
        /// Depth of each slot, mm; nil for half the bit's diameter (a dovetail bit's full height).
        public var depth: Double?
        /// Rungs in each row.
        public var rungs: Int
        /// Three rows at three spindle speeds (three quarters of, all of and a quarter over the chosen speed), each
        /// stepping through the same chip loads.
        public var stepRPM: Bool

        public init(tool: Tool, material: MaterialKind, depth: Double? = nil, rungs: Int = 7, stepRPM: Bool = false) {
            self.tool = tool
            self.material = material
            self.depth = depth
            self.rungs = rungs
            self.stepRPM = stepRPM
        }
    }

    /// One slot of the ladder.
    public struct Rung: Hashable, Sendable, Identifiable {
        public enum Chart: String, Hashable, Sendable {
            case below, inside, above
            public var label: String {
                switch self {
                case .below: "Below the chart"
                case .inside: "In the chart"
                case .above: "Above the chart"
                }
            }
        }
        /// From 1, in cutting order.
        public var number: Int
        /// The row (spindle speed), from 1.
        public var row: Int
        /// The slot's X position, mm from the scrap's left edge.
        public var x: Double
        /// mm/min, as written.
        public var feed: Double
        public var rpm: Double
        /// mm per tooth, from the feed and speed as written.
        public var chipLoad: Double
        public var chart: Chart
        /// The rung nearest the chart's recommended chip.
        public var recommended: Bool
        public var id: Int { number }
    }

    /// The chip loads the ladder steps through, mm per tooth: from 60% of the chart's thinnest to 140% of its thickest,
    /// evenly on a log scale.
    static func ladderChips(_ range: ClosedRange<Double>, rungs: Int) -> [Double] {
        let lo = 0.6 * range.lowerBound, hi = 1.4 * range.upperBound
        guard rungs > 1 else { return [(lo * hi).squareRoot()] }
        let r = pow(hi / lo, 1 / Double(rungs - 1))
        return (0..<rungs).map { lo * pow(r, Double($0)) }
    }

    /// Why the ladder can't be cut with this bit; nil when it can.
    public static func ladderRefusal(_ options: LadderOptions, machine: MachineProfile) -> Refused? {
        if let refused = noPost(machine) { return refused }
        let tool = options.tool
        guard ChipLoad.applies(to: tool) else {
            return Refused("No chip-load chart covers a \(tool.shape.label.lowercased()), so there's nothing for the ladder to step through.")
        }
        if tool.shape == .form {
            return Refused("A form bit cuts an edge, not a slot, so the ladder's slots can't test it. Try it on an edge with a profile toolpath.")
        }
        if options.rungs < 3 || options.rungs > 15 { return Refused("The ladder needs 3 to 15 rungs.") }
        if let d = options.depth, d <= 0 || d > tool.fluteLength + 1e-6 {
            return Refused("The slot depth must be above zero and no deeper than the bit's \(length(tool.fluteLength, machine.outputUnits)) flutes.")
        }
        return nil
    }

    /// The chip-load ladder for a bit and material, ready to cut in scrap.
    public static func ladder(machine: MachineProfile, options: LadderOptions, date: Date = Date(),
                              timeZone: TimeZone = .current) throws -> Program {
        if let refused = ladderRefusal(options, machine: machine) { throw refused }
        let m = postingMachine(machine, dustCollection: true)
        let u = m.outputUnits
        let tool = options.tool
        let depth = options.depth ?? (tool.shape == .dovetail ? tool.fluteLength : tool.diameter / 2)
        let reading = ChipLoad.reading(tool, material: options.material, depth: depth)
        let recommendation = ChipLoad.recommendation(for: tool, material: options.material, machine: m, depth: depth)
        let chips = ladderChips(reading.range, rungs: options.rungs)
        let z = Double(max(1, tool.fluteCount))
        // The chosen speed: the chart's, lowered until the thickest rung fits under the machine's highest feed.
        func speed(_ rpm: Double) -> Double {
            let capped = reading.maxRPM.map { min(rpm, $0) } ?? rpm
            return (m.clampRPM(capped) / 100).rounded(.down) * 100
        }
        let base = speed(min(recommendation.rpm, m.maxFeedRate / (z * chips[chips.count - 1])))
        var rpms = options.stepRPM ? [speed(base * 0.75), base, speed(base * 1.25)] : [base]
        rpms = rpms.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }

        let gap = max(tool.diameter, u == .inch ? 0.375.inch : 10)
        let pitch = tool.diameter + gap, margin = u == .inch ? 1.inch : 25
        let slot = u == .inch ? 4.inch : 100
        let entry = -(tool.diameter / 2 + (u == .inch ? 0.125.inch : 3))
        var rungs: [Rung] = []
        var dropped = 0
        var x = margin
        for (r, rpm) in rpms.enumerated() {
            if r > 0 { x += pitch }
            for chip in chips {
                let feed = roundedFeed(chip * z * rpm, u)
                if feed > m.maxFeedRate + 1e-6 { dropped += 1; continue }
                let written = feed / (z * rpm)
                let chart: Rung.Chart = written < reading.range.lowerBound - 1e-9 ? .below
                    : written > reading.range.upperBound + 1e-9 ? .above : .inside
                rungs.append(Rung(number: rungs.count + 1, row: r + 1, x: x, feed: feed, rpm: rpm, chipLoad: written, chart: chart,
                                  recommended: false))
                x += pitch
            }
        }
        guard !rungs.isEmpty else {
            throw Refused("Every rung would be faster than the machine's highest feed of \(feed(m.maxFeedRate, u)).")
        }
        for row in Set(rungs.map(\.row)) {
            let inRow = rungs.indices.filter { rungs[$0].row == row }
            if let best = inRow.min(by: { abs(log(rungs[$0].chipLoad / reading.target)) < abs(log(rungs[$1].chipLoad / reading.target)) }) {
                rungs[best].recommended = true
            }
        }
        let width = x - pitch + tool.diameter / 2 + margin
        let height = slot + margin
        let thickness = max(depth + (u == .inch ? 0.25.inch : 6), u == .inch ? 0.75.inch : 18)
        let window = Vec2(width, height)
        if width > m.travel.x + 1e-6 || height > m.travel.y + 1e-6 {
            throw Refused("The ladder needs \(size(window, u)) of scrap, more than the machine's \(size(m.travel.xy, u)) of travel. Use fewer rungs.")
        }
        var stock = Stock(width: width, height: height, thickness: thickness,
                          materialName: "Scrap \(options.material.label.lowercased())", xyOrigin: .lowerLeft, zZero: .materialTop,
                          materialKind: options.material)
        stock.homePosition = Vec3(0, 0, max(1.inch, stock.clearanceHeight))
        var project = Project(name: "NativeCAM chip-load ladder", displayUnits: u, stock: stock, machine: m)
        project.notes = "Chip-load ladder for \(tool.name) in \(options.material.label)."
        let plunge = max(1, min(tool.cutting.plungeRate, m.maxFeedRate))
        var toolpaths: [Toolpath] = []
        for rung in rungs {
            let id = UUID(uuidString: String(format: "CA11B000-0000-0000-0001-%012d", rung.number))!
            let chip = chipText(rung.chipLoad, u)
            let motions: [Motion] = [
                .rapid(Vec3(rung.x, entry, stock.plungeHeight)),
                .feed(Vec3(rung.x, entry, -depth), plunge),
                .feed(Vec3(rung.x, slot, -depth), rung.feed),
                .rapid(Vec3(rung.x, slot, stock.clearanceHeight)),
            ]
            toolpaths.append(Toolpath(id: id, name: "Rung \(rung.number): \(chip) at \(Int(rung.rpm)) RPM", tool: tool,
                                      spindleRPM: rung.rpm, start: Vec3(rung.x, entry, stock.clearanceHeight), motions: motions))
        }
        let setup = [
            "NATIVECAM CHIP-LOAD LADDER: \(rungs.count) slots with \(tool.name) in \(options.material.label.lowercased()), "
                + "from below the \(reading.chart.label)'s chip loads to above them. A REAL CUT: use scrap.",
            "Scrap at least \(size(window, u)) and \(length(thickness, u)) thick, clamped clear of the slots, with a straight front edge.",
            "Zero X and Y at the scrap's front-left corner and Z on its top. Each slot plunges in front of the scrap and cuts "
                + "\(length(depth, u)) deep into it from the front edge; rung 1 is on the left.",
            "Listen to each rung and keep its chips: the recording sheet lists each rung's feed, speed and chip load.",
        ] + (dropped > 0 ? ["\(dropped) rung\(dropped == 1 ? " is" : "s are") left out: faster than the machine's highest feed of \(feed(m.maxFeedRate, u))."] : [])
        guard let post = post(project, date: date, timeZone: timeZone) else {
            throw Refused(PostProcessors.unavailableReason(for: m) ?? "No post for \(m.controllerLabel).")
        }
        let estimate = CycleTimeEstimator.estimate(toolpaths, project: project).total
        let gcode = headerComments(setup, dialect: post.dialect) + post.post(toolpaths)
        var program = Program(kind: .ladder, project: project, toolpaths: toolpaths, sections: [], gcode: gcode, dialect: post.dialect,
                              fileExtension: post.fileExtension, plan: nil, axisLetter: nil, rungs: rungs, setup: setup, issues: [],
                              window: window, estimatedSeconds: estimate)
        program.issues = check(program)
        return program
    }

    /// A chip load as the sheet gives it: "0.0086 in/tooth" or "0.22 mm/tooth".
    public static func chipText(_ mm: Double, _ u: LengthUnit) -> String {
        u == .inch ? String(format: "%.4f in/tooth", u.fromMM(mm)) : String(format: "%.3f mm/tooth", mm)
    }

    // MARK: Checks

    /// The file's checks: `GCodeCheck` (on the rotary check, its lint and a read-back of the turns), and `verify`.
    public static func check(_ program: Program) -> [GCodeCheck.Issue] {
        var issues: [GCodeCheck.Issue]
        if program.kind == .rotary {
            issues = GCodeCheck.lint(program.gcode, project: program.project, dialect: program.dialect)
        } else {
            issues = GCodeCheck.run(program.gcode, toolpaths: program.toolpaths, project: program.project, dialect: program.dialect)
        }
        issues += verify(program)
        return issues.filter { $0.severity != .info }
    }

    /// Reads the file back and checks what the brief for each program promises: the air programs never go below the air
    /// height or outside the window, the ladder stays in its scrap's window, and the rotary check moves nothing but its
    /// axis, through exactly its three timed turns.
    public static func verify(_ program: Program) -> [GCodeCheck.Issue] {
        guard program.dialect.readsBack else { return [] }
        let program0: GCodeProgram
        do {
            program0 = try GCodeParser.parse(program.gcode, dwellUnit: program.dialect.dwell.parserUnit)
        } catch {
            return [GCodeCheck.Issue(.error, "The file can't be read back: \(error.localizedDescription)")]
        }
        var issues: [GCodeCheck.Issue] = []
        let stock = program.project.stock
        let tol = 1e-3 + program.project.machine.outputUnits.toMM(pow(10, -Double(program.dialect.coordinateDecimals(program.project.machine.outputUnits))))
        switch program.kind {
        case .rotary:
            let moves = program0.segments.flatMap(\.motions).filter { $0.kind != .dwell }
            let turns = moves.compactMap(\.a)
            if turns != [0, 360, 720, 0] {
                issues.append(GCodeCheck.Issue(.error, "Reads back as turns to \(turns.map { number($0) }) instead of 0, 360, 720 and 0."))
            }
            if let g93 = moves.first(where: { $0.inverseTime != nil }), abs((g93.inverseTime ?? 0) - rotaryInverseTime) > 1e-9 {
                issues.append(GCodeCheck.Issue(.error, "The inverse-time turn reads back as F\(g93.inverseTime ?? 0), not F\(rotaryInverseTime)."))
            }
            let rows = program.gcode.components(separatedBy: "\n")
            for (i, row) in rows.enumerated() {
                let code = GCodeParser.stripComments(row).uppercased()
                if let words = try? GCodeParser.tokenize(code, lineNo: i + 1), words.contains(where: { "XYZ".contains($0.0) }) {
                    issues.append(GCodeCheck.Issue(.error, line: i + 1, "Moves X, Y or Z, where the rotary check only turns its axis."))
                    break
                }
            }
            if program0.pauses.count != 3 {
                issues.append(GCodeCheck.Issue(.error, "Has \(program0.pauses.count) stops, where the rotary check needs one before each turn."))
            }
        case .timing, .ladder:
            guard let window = program.window else { break }
            let air = program.kind == .timing ? (program.plan?.airHeight ?? minimumAirHeight) : nil
            var reportedLow = false, reportedOut = false
            for seg in program0.segments {
                var p = seg.start
                for m in seg.motions where m.kind != .dwell {
                    let points = m.kind.isArc ? m.samples(from: p, maxStep: 0.5) : [m.end]
                    p = m.end
                    for q in points {
                        let design = stock.fromWork(q)
                        if let air, q.z < air - tol, !reportedLow {
                            reportedLow = true
                            issues.append(GCodeCheck.Issue(.error, "Goes below the \(length(air, program.project.displayUnits)) air height."))
                        }
                        // The ladder's slots start in front of the scrap, a bit's width out.
                        let front = program.kind == .ladder ? -(program.toolpaths.first?.tool.diameter ?? 0) - 3.2 : 0
                        if (design.x < -tol || design.x > window.x + tol || design.y < front - tol || design.y > window.y + tol), !reportedOut {
                            reportedOut = true
                            issues.append(GCodeCheck.Issue(.error, "Goes outside the \(size(window, program.project.displayUnits)) window."))
                        }
                    }
                }
            }
            let travel = program.project.machine.travel
            if window.x > travel.x + 1e-6 || window.y > travel.y + 1e-6 {
                issues.append(GCodeCheck.Issue(.error, "The \(size(window, program.project.displayUnits)) window is bigger than the machine's travel."))
            }
            if program.kind == .timing, program0.pauses.count != program.sections.count {
                issues.append(GCodeCheck.Issue(.error, "Has \(program0.pauses.count) stops for \(program.sections.count) sections."))
            }
        }
        return issues
    }
}
