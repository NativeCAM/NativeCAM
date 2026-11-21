import Foundation

/// What a controller accepts and how it reads G-code. Posts write to it; `GCodeCheck` reads exported files back
/// against it. Values marked in comments come from the controller's own source or documentation (see
/// research_notes/Supporting any CNC machine/controller_dialects.md); nothing but Avid Mach4 is tested on hardware.
public struct Dialect: Hashable, Sendable {
    /// What a `G4 P` value means, and how it must be written.
    public enum DwellFormat: Hashable, Sendable {
        /// Seconds, written with a decimal point. Mach4 builds disagree on a bare `P2` (2 s in the manual, 2 ms
        /// under the Fanuc rule MachMotion documents); `P2.00` is 2 s under both.
        case secondsWithDecimal
        /// Seconds, decimals allowed (LinuxCNC, Grbl).
        case seconds
        /// Whole milliseconds (Masso: `G04 P2000` is two seconds).
        case milliseconds

        /// How to read a `P` value back.
        public var parserUnit: GCodeParser.DwellUnit {
            self == .milliseconds ? .milliseconds : .seconds
        }
    }

    /// How strictly a controller checks that an arc's start and end are the same distance from its centre.
    public enum ArcCheck: Hashable, Sendable {
        /// Rejects arcs whose radii differ by more than this (mm).
        case absolute(Double)
        /// Grbl's rule (also FluidNC and LinuxCNC): an error when the radii differ by more than 0.5 mm, or by more
        /// than both 0.005 mm and 0.1% of the radius (Grbl error 33).
        case grbl

        public func rejects(startRadius r1: Double, endRadius r2: Double) -> Bool {
            let d = abs(r1 - r2)
            switch self {
            case let .absolute(tol): return d > tol + 1e-9
            case .grbl: return d > 0.5 || (d > 0.005 && d > 0.001 * max(r1, r2))
            }
        }
    }

    /// What the controller does with `M6`.
    public enum ToolChangeSupport: Hashable, Sendable {
        /// Runs a macro that stops for the change (Mach4's m6, CNC12's mfunc6, Masso).
        case macro
        /// Raises an error on `M6` but keeps running the lines already buffered (stock Grbl, error 20).
        case rejected
        /// Accepts `M6` but only records the tool number, without stopping (FluidNC without a macro).
        case recordsOnly
        /// Depends on the program that streams the file (gSender, CNCjs and Carbide Motion pause on M6; UGS does not).
        case senderDependent
        /// Can't change tools within a file at all (most DSP routers, ShopBot without a tool changer).
        case none
    }

    /// The tapping and boring canned cycles the controller runs, for simulating G-code written for it. Drilling cycles
    /// (G73, G81–G83, G85, G86, G89) mean the same on every controller that has them, so they're always simulated.
    public struct CannedCycles: Hashable, Sendable {
        /// Cycles the controller runs with their usual milling meaning (Fanuc's, which Mach4 follows): 74 and 84
        /// (left- and right-hand tapping), 76 (fine boring), 87 (back boring) and 88 (boring with a stop to retract
        /// by hand). The others are read but not simulated.
        public var expanded: Set<Int> = []
        /// What the controller does with a cycle code it doesn't run that way, for the warning (76: "a lathe threading
        /// cycle").
        public var otherMeanings: [Int: String] = [:]
        /// G84 and G74 feed all the way out to the retract height, G98's starting height included (LinuxCNC);
        /// otherwise they feed out to R and rapid from there (Mach4, CNC12 and Fanuc).
        public var tapFeedsOutToRetract = false
        /// The way a Q word shifts a fine-boring or back-boring tool off the wall; signed I and J words give their own.
        /// The controller's settings decide it: CNC12's parameter 136 starts at +Y; Mach4's manual points to bits of
        /// parameter 5101 without saying what they mean, so +X is assumed. It only moves rapids inside the bore.
        public var shiftDirection = Vec2(1, 0)

        public init(expanded: Set<Int> = [], otherMeanings: [Int: String] = [:], tapFeedsOutToRetract: Bool = false,
                    shiftDirection: Vec2 = Vec2(1, 0)) {
            self.expanded = expanded
            self.otherMeanings = otherMeanings
            self.tapFeedsOutToRetract = tapFeedsOutToRetract
            self.shiftDirection = shiftDirection
        }
    }

    /// The language the controller reads.
    public enum Language: Hashable, Sendable {
        case gcode
        /// ShopBot's OpenSBP (`M3,x,y,z`, `CG`, `MS` speeds in units per second).
        case openSBP
    }

    /// How the controller plans motion, for run-time estimates.
    public struct Planner: Hashable, Sendable {
        /// Moves the controller looks ahead (Mach4 20 lines, Grbl 16 blocks).
        public var lookahead: Int
        /// Default corner tolerance, mm (Grbl's `$11` is 0.01 mm; 0.05 mm fits Mach4's constant velocity mode).
        public var junctionDeviation: Double
        /// True when rapids stop at each end (Mach4 runs G0 in exact stop); Grbl blends rapids like feeds.
        public var rapidsExactStop: Bool
    }

    public var id: String
    public var name: String
    /// Longest line the controller accepts, not counting the line ending; nil when there's no small limit.
    public var maxLineLength: Int?
    public var lineEnding: String
    /// G codes the controller accepts; nil skips the check.
    public var allowedG: Set<Double>?
    /// M codes the controller accepts; nil skips the check.
    public var allowedM: Set<Int>?
    /// Address letters the controller accepts.
    public var allowedLetters: Set<Character>
    /// True when anything outside the lists stops the controller (Grbl's error 20). Otherwise it's a warning.
    public var strict: Bool
    public var acceptedUnits: Set<LengthUnit>
    public var dwell: DwellFormat
    public var arcCheck: ArcCheck
    public var maxToolNumber: Int?
    public var maxLineNumber: Int?
    public var m6: ToolChangeSupport
    /// Decimal places for coordinates and feeds, per output unit.
    public var coordinateDecimals: [LengthUnit: Int]
    public var feedDecimals: [LengthUnit: Int]
    /// Tested on a real controller.
    public var verified: Bool
    public var planner: Planner = Planner(lookahead: 20, junctionDeviation: 0.05, rapidsExactStop: true)
    /// M code that switches the dust collector (Avid's profile wires it to M7; stock Grbl only has M8).
    public var dustOn: Int = 7
    public var fileExtension: String = "tap"
    /// Restate `G91.1` (incremental I/J) in the safety block. Grbl accepts it only as a no-op.
    public var statesIncrementalArcs: Bool = true
    /// The file can be read back as G-code (false for posts that write another language, such as OpenSBP).
    public var readsBack: Bool = true
    /// Dwells in the file all come from the toolpaths (false when a template post adds its own, say after M3).
    public var comparesDwells: Bool = true
    /// The tapping and boring cycles G-code read for this controller simulates. NativeCAM never writes them.
    public var cannedCycles = CannedCycles()

    /// How the controller is told to blend corners.
    public enum Blending: Hashable, Sendable {
        case none
        /// `G64` (Mach4's constant velocity).
        case g64
        /// `G64 P<tolerance>` (LinuxCNC: blend within the arc-fit tolerance).
        case g64P
    }
    public var blending: Blending = .none

    /// When a tool change is followed by `G43 H#` to apply the tool's length from the controller's tool table.
    public enum LengthOffset: Hashable, Sendable {
        case never
        /// Only with an automatic tool changer.
        case withATC
        /// After every tool change (LinuxCNC and CNC12 don't apply a length on M6; a tool with no length gets 0).
        case always
    }
    public var lengthOffset: LengthOffset = .never
    public var language: Language = .gcode
    /// Feeds are written per second (OpenSBP's MS), so feedDecimals count places of units per second.
    public var feedPerSecond: Bool = false
    /// The controller takes comments (DSP controllers' comment handling isn't documented, so none are written).
    public var writesComments: Bool = true
    /// Arcs are written as arcs; otherwise as short lines (for controllers whose arc handling isn't documented).
    public var writesArcs: Bool = true
    /// The modal codes at the top of the file.
    public var safetyLine: String = "G90 G94 G17"

    // Rotary axes (research_notes/Rotary milling/rotary_milling.md §3.4). NativeCAM doesn't write rotary moves
    // yet; these say what a post may write and what `GCodeCheck` accepts.

    /// What F means on an ordinary (G94, units per minute) move that turns a rotary axis.
    public enum RotaryFeed: Hashable, Sendable {
        /// F is spread over the whole move, counting degrees as if they were millimetres (Grbl's planner).
        case allAxes
        /// F applies to X, Y and Z only; a move that only turns the rotary axis runs in degrees per minute (NIST
        /// and LinuxCNC).
        case linearAxesOnly
        /// F is degrees per minute on the rotary axis, and a combined move runs at the pace of its slowest axis
        /// (Masso).
        case degreesPerMinute
        /// Not documented (Mach4). Rotary moves should use G93 inverse time, where F means the same everywhere.
        case unknown
    }

    /// Rotary axis letters the controller can drive (A turns about X, B about Y, C about Z); empty when it has none.
    /// Always a subset of `allowedLetters`.
    public var rotaryAxes: Set<Character> = []
    /// What F means when a rotary axis moves in G94 mode.
    public var rotaryFeed: RotaryFeed = .unknown
    /// Accepts G93 inverse-time feeds, where F is one over the move's time in minutes. It's the one way to give a
    /// rotary move an exact feed on every controller that has it.
    public var inverseTime: Bool = false
    /// The machine axes a driven rotary axis may run along for NativeCAM to write its moves (`RotaryFrame`): along X
    /// everywhere, and along Y where Avid's "Wrap X2A" mounting is written and checked (Avid Mach4, LinuxCNC and
    /// grblHAL).
    public var rotaryAlignments: Set<RotaryAxis.Alignment> = [.x]

    public var hasAAxis: Bool { rotaryAxes.contains("A") }

    public func coordinateDecimals(_ u: LengthUnit) -> Int { coordinateDecimals[u] ?? (u == .inch ? 4 : 3) }
    public func feedDecimals(_ u: LengthUnit) -> Int { feedDecimals[u] ?? (u == .inch ? 1 : 0) }

    /// A comment line in this dialect.
    public func comment(_ text: String) -> String { "(\(text))" }

    /// Avid CNC's Mach4 profile, as `AvidMach4Post` writes for it. Mach4 accepts much more than these lists; they
    /// hold what Mach4's Mill reference documents, so a typo or a code from another dialect stands out.
    ///
    /// Rotary: Mach4 drives A, B and C in any motion command and documents G93. Avid's own rotary posts all feed in
    /// G93, and nothing documents how Mach4 applies F to a G94 move that turns A, so `rotaryFeed` is unknown.
    ///
    /// Canned cycles: the Mach4 Mill G-code manual documents all five tapping and boring cycles with Fanuc's meaning
    /// (G74, G76 and G87 marked as depending on the machine's configuration).
    public static let avidMach4 = Dialect(
        id: "avid-mach4", name: "Avid Mach4", maxLineLength: nil, lineEnding: "\r\n",
        allowedG: Set([0, 1, 2, 3, 4, 9, 10, 12, 13, 15, 16, 17, 18, 19, 20, 21, 28, 28.1, 30, 31, 32, 40, 41, 42, 43, 49,
                       50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 64, 65, 66, 67, 68, 69, 73, 74, 76, 80, 81, 82, 83,
                       84, 85, 86, 87, 88, 89, 90, 91, 90.1, 91.1, 92, 93, 94, 95, 96, 97, 98, 99]),
        allowedM: Set([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 19, 30, 47, 48, 49, 98, 99]),
        allowedLetters: Set("ABCDFGHIJKLMNPQRSTUVWXYZ"), strict: false, acceptedUnits: [.inch, .mm],
        dwell: .secondsWithDecimal, arcCheck: .absolute(0.0127), maxToolNumber: nil, maxLineNumber: nil, m6: .macro,
        coordinateDecimals: [.inch: 4, .mm: 3], feedDecimals: [.inch: 1, .mm: 0], verified: true,
        cannedCycles: CannedCycles(expanded: [74, 76, 84, 87, 88]), rotaryAxes: Set("ABC"), inverseTime: true,
        rotaryAlignments: [.x, .y])

    /// The dialect a machine's post writes; nil when NativeCAM has no post for its controller yet.
    public static func `for`(_ machine: MachineProfile) -> Dialect? {
        if let pp = machine.customPost { return template(pp, machine: machine) }
        guard let controller = machine.controller else { return .avidMach4 }
        switch controller.family {
        case .grbl, .grblHAL, .fluidNC, .carbideMotion:
            return grblFamily(controller, toolChange: machine.toolChange)
        case .linuxCNC: return .linuxCNC
        case .masso: return .masso
        case .centroid: return .centroid
        case .buildbotics: return .buildbotics
        case .openSBP: return .openSBP(toolChange: machine.toolChange)
        case .richAuto: return .richAuto
        default:
            return nil
        }
    }

    // MARK: Long tail (from documentation and vendor posts; none tested on hardware)

    /// ShopBot's OpenSBP: `'` comments, `SA` absolute moves, `MS`/`JS` speeds in units per second, `M2`/`M3`/`MZ`
    /// feeds and `J2`/`J3`/`JZ` jogs, `CG` arcs from the current point, `PAUSE n` in seconds, `END`, and a units
    /// check on system variable 25 (ShopBot Command Reference V3 and Programming Handbook). Spindle `TR`/`C6`/`C7` and
    /// tool change `&Tool`/`C9` follow vendor posts. Without a tool changer, each tool gets its own file.
    public static func openSBP(toolChange: ToolChangeMode) -> Dialect {
        var d = Dialect(
            id: "opensbp", name: "ShopBot (OpenSBP)", maxLineLength: nil, lineEnding: "\r\n", allowedG: nil, allowedM: nil,
            allowedLetters: [], strict: false, acceptedUnits: [.inch, .mm], dwell: .seconds, arcCheck: .absolute(0.0127),
            maxToolNumber: nil, maxLineNumber: nil, m6: toolChange == .atc ? .macro : .none,
            coordinateDecimals: [.inch: 4, .mm: 3], feedDecimals: [.inch: 3, .mm: 2], verified: false)
        d.language = .openSBP
        d.feedPerSecond = true
        d.planner = Planner(lookahead: 10, junctionDeviation: 0.05, rapidsExactStop: true)
        d.fileExtension = "sbp"
        d.statesIncrementalArcs = false
        return d
    }

    /// RichAuto DSP controllers (Axiom and many 1325-class routers): metric only, one tool per file, and arcs and
    /// comments left out because their handling isn't documented.
    public static let richAuto: Dialect = {
        var d = Dialect(
            id: "richauto", name: "RichAuto DSP", maxLineLength: nil, lineEnding: "\r\n", allowedG: nil, allowedM: nil,
            allowedLetters: Set("FGIJMNPSTXYZ"), strict: false, acceptedUnits: [.mm], dwell: .seconds, arcCheck: .absolute(0.0127),
            maxToolNumber: nil, maxLineNumber: nil, m6: .none,
            coordinateDecimals: [.mm: 3], feedDecimals: [.mm: 0], verified: false)
        d.planner = Planner(lookahead: 20, junctionDeviation: 0.05, rapidsExactStop: true)
        d.fileExtension = "nc"
        d.statesIncrementalArcs = false
        d.writesComments = false
        d.writesArcs = false
        d.safetyLine = "G90"
        d.dustOn = 8
        return d
    }()

    // MARK: Second-wave controllers (from documentation only; none tested on hardware)

    /// LinuxCNC 2.9 (and PathPilot's base): strict ("any input not explicitly allowed is illegal"), 256-character
    /// lines, G4 P in seconds, incremental I/J, Grbl's arc rule, G64 P blending, M6 that prompts but leaves the tool
    /// length alone (so G43 H# follows), M7 mist and M8 flood.
    public static let linuxCNC: Dialect = {
        var d = Dialect(
            id: "linuxcnc", name: "LinuxCNC", maxLineLength: 255, lineEnding: "\n",
            allowedG: Set([0, 1, 2, 3, 4, 5, 5.1, 5.2, 5.3, 7, 8, 10, 17, 17.1, 18, 18.1, 19, 19.1, 20, 21, 28, 28.1, 30, 30.1, 33,
                           33.1, 38.2, 38.3, 38.4, 38.5, 40, 41, 41.1, 42, 42.1, 43, 43.1, 43.2, 49, 52, 53, 54, 55, 56, 57, 58, 59,
                           59.1, 59.2, 59.3, 61, 61.1, 64, 73, 74, 76, 80, 81, 82, 83, 84, 85, 86, 89, 90, 90.1, 91, 91.1, 92,
                           92.1, 92.2, 92.3, 93, 94, 95, 96, 97, 98, 99]),
            allowedM: Set([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 30, 48, 49, 50, 51, 52, 53, 60, 61, 62, 63, 64, 65, 66, 67, 68, 70, 71, 72, 73]
                          + Array(100...199)),
            allowedLetters: Set("ABCDFGHIJKLMNPQRSTUVWXYZ"), strict: true, acceptedUnits: [.inch, .mm], dwell: .seconds,
            arcCheck: .grbl, maxToolNumber: nil, maxLineNumber: nil, m6: .macro,
            coordinateDecimals: [.inch: 4, .mm: 3], feedDecimals: [.inch: 1, .mm: 0], verified: false)
        d.planner = Planner(lookahead: 50, junctionDeviation: 0.02, rapidsExactStop: false)
        d.dustOn = 8
        d.fileExtension = "ngc"
        d.blending = .g64P
        d.lengthOffset = .always
        // "If any of XYZ are moving, F is in units per minute in the XYZ cartesian system" (machining-center docs).
        d.rotaryAxes = Set("ABC")
        d.rotaryFeed = .linearAxesOnly
        d.inverseTime = true
        d.rotaryAlignments = [.x, .y]
        // G74 and G84 tap with a floating holder (since 2.8) and feed out to the retract height; G76 threads on a lathe,
        // and G87 and G88 are "accepted, but the behavior is undefined".
        d.cannedCycles = CannedCycles(expanded: [74, 84],
                                      otherMeanings: [76: "a lathe threading cycle", 87: "accepted but not implemented",
                                                      88: "accepted but not implemented"],
                                      tapFeedsOutToRetract: true)
        return d
    }()

    /// Masso G3: G4 P in whole milliseconds (`G04 P2000` is two seconds), M06 runs Masso's own tool change (and
    /// applies the tool length itself), M07/M08 outputs. G43, G64 and G90.1/G91.1 aren't in its documentation, so
    /// none are written.
    public static let masso: Dialect = {
        var d = Dialect(
            id: "masso", name: "Masso", maxLineLength: nil, lineEnding: "\n",
            allowedG: Set([0, 1, 2, 3, 4, 10, 17, 18, 19, 20, 21, 28, 30, 40, 49, 53, 54, 55, 56, 57, 58, 59, 80, 81, 82, 83, 90, 91, 94]),
            allowedM: Set([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 30, 98, 99]),
            allowedLetters: Set("FGHIJKLMNPQRSTXYZ"), strict: false, acceptedUnits: [.inch, .mm], dwell: .milliseconds,
            arcCheck: .grbl, maxToolNumber: nil, maxLineNumber: nil, m6: .macro,
            coordinateDecimals: [.inch: 4, .mm: 3], feedDecimals: [.inch: 1, .mm: 0], verified: false)
        d.planner = Planner(lookahead: 20, junctionDeviation: 0.05, rapidsExactStop: false)
        d.dustOn = 8
        d.fileExtension = "nc"
        d.statesIncrementalArcs = false
        // Masso drives an A axis ("on a rotary axis, F is in degrees per minute"), but A stays out of its letters
        // until NativeCAM writes rotary moves for it. G93 isn't in its documented codes.
        d.rotaryFeed = .degreesPerMinute
        return d
    }()

    /// Centroid CNC12 (Acorn, Oak, and Avid's EX controller): M6 runs the mfunc6 macro and G43 H# applies the
    /// length from CNC12's tool library, as Avid's own EX posts do. Seconds for G4 P and .cnc files follow Avid's EX
    /// posts; CNC12's own manuals weren't available, so the code lists aren't checked.
    public static let centroid: Dialect = {
        var d = Dialect(
            id: "centroid", name: "Centroid CNC12", maxLineLength: nil, lineEnding: "\r\n", allowedG: nil, allowedM: nil,
            allowedLetters: Set("ABCDFGHIJKLMNOPQRSTUVWXYZ"), strict: false, acceptedUnits: [.inch, .mm], dwell: .secondsWithDecimal,
            arcCheck: .absolute(0.0127), maxToolNumber: nil, maxLineNumber: nil, m6: .macro,
            coordinateDecimals: [.inch: 4, .mm: 3], feedDecimals: [.inch: 1, .mm: 0], verified: false)
        d.planner = Planner(lookahead: 20, junctionDeviation: 0.05, rapidsExactStop: true)
        d.dustOn = 7
        d.fileExtension = "cnc"
        d.statesIncrementalArcs = false
        d.lengthOffset = .always
        // Avid's EX rotary runs on A. Whether CNC12 itself takes G93 isn't confirmed.
        d.rotaryAxes = ["A"]
        // CNC12's Mill operator's manual (v4.20) documents G74, G76 and G84, with G76's Q shift toward +Y by default;
        // it doesn't list G87 or G88.
        d.cannedCycles = CannedCycles(expanded: [74, 76, 84], shiftDirection: Vec2(0, 1))
        return d
    }()

    /// Buildbotics (and Onefinity's BB controller), which follows LinuxCNC's conventions through the CAMotics
    /// interpreter: G4 P in seconds, G91.1, M6 pausing for the change by default. Its canned-cycle support is
    /// documented inconsistently, so drilling stays as plain moves and the code lists aren't checked.
    public static let buildbotics: Dialect = {
        var d = Dialect(
            id: "buildbotics", name: "Buildbotics", maxLineLength: nil, lineEnding: "\n", allowedG: nil, allowedM: nil,
            allowedLetters: Set("ABCDFGHIJKLMNPQRSTUVWXYZ"), strict: false, acceptedUnits: [.inch, .mm], dwell: .seconds,
            arcCheck: .grbl, maxToolNumber: nil, maxLineNumber: nil, m6: .macro,
            coordinateDecimals: [.inch: 4, .mm: 3], feedDecimals: [.inch: 1, .mm: 0], verified: false)
        d.planner = Planner(lookahead: 20, junctionDeviation: 0.05, rapidsExactStop: false)
        d.dustOn = 8
        d.fileExtension = "nc"
        // A fourth motor channel can drive A (Buildbotics publishes a 4-axis Fusion post); its G93 and rotary feed
        // handling aren't documented.
        d.rotaryAxes = ["A"]
        return d
    }()

    // MARK: Grbl family

    /// G codes stock Grbl 1.1 accepts (gnea/grbl README and gcode.c). G61 is accepted but does nothing; G64,
    /// G90.1 and canned cycles raise error 20.
    static let grblG: Set<Double> = [0, 1, 2, 3, 4, 10, 17, 18, 19, 20, 21, 28, 28.1, 30, 30.1, 38.2, 38.3, 38.4, 38.5,
                                     40, 43.1, 49, 53, 54, 55, 56, 57, 58, 59, 61, 80, 90, 91, 91.1, 92, 92.1, 93, 94]

    /// Senders known to pause a Grbl job on M6 (when set up to): gSender (Config ▸ Tool Changing ▸ Pause or a
    /// wizard) and CNCjs from 1.9.11. Others, UGS included, pass M6 to Grbl, which rejects it.
    public static func senderPausesOnM6(_ sender: String?) -> Bool {
        guard let s = sender?.lowercased() else { return false }
        return s.contains("gsender") || s.contains("cncjs")
    }

    /// Grbl 1.1, grblHAL, FluidNC and Carbide Motion: strict parsers that stop on anything they don't know
    /// (error 20), with incremental I/J only, Grbl's arc check, G4 P in seconds, M8 for the dust collector and a
    /// 16-block planner. What M6 does depends on the firmware and the program sending the file.
    public static func grblFamily(_ controller: ControllerProfile, toolChange: ToolChangeMode) -> Dialect {
        var d = Dialect(
            id: "grbl", name: "Grbl", maxLineLength: 79, lineEnding: "\n", allowedG: grblG,
            allowedM: [0, 1, 2, 3, 4, 5, 8, 9, 30], allowedLetters: Set("FGIJKLMNPRSTXYZ"), strict: true,
            acceptedUnits: [.inch, .mm], dwell: .seconds, arcCheck: .grbl, maxToolNumber: 255, maxLineNumber: 9_999_999,
            m6: senderPausesOnM6(controller.sender) ? .senderDependent : .rejected,
            coordinateDecimals: [.inch: 4, .mm: 3], feedDecimals: [.inch: 1, .mm: 0], verified: false)
        d.planner = Planner(lookahead: 16, junctionDeviation: 0.01, rapidsExactStop: false)
        d.dustOn = 8
        d.fileExtension = "nc"
        d.statesIncrementalArcs = false
        // Stock Grbl has three axes (gSender's rotary mode drives the rotary from the Y port, with Y words). The whole
        // family takes G93, and its planner counts rotary degrees as millimetres. FluidNC can drive A–C when
        // configured, but A stays out of its letters until NativeCAM writes rotary moves for it.
        d.rotaryFeed = .allAxes
        d.inverseTime = true
        switch controller.family {
        case .grblHAL:
            // Adds canned cycles, G43 (configuration-dependent), letters A–Z, and A–C when the build has them
            // ($376 marks them rotary).
            d.id = "grblhal"
            d.name = "grblHAL"
            d.allowedG = grblG.union([43, 73, 81, 82, 83, 85, 86, 89, 98, 99])
            d.allowedM = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 30, 56, 62, 63, 64, 65, 66, 67, 68]
            d.allowedLetters = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
            d.rotaryAxes = Set("ABC")
            d.rotaryAlignments = [.x, .y]
            // Its README lists only the drilling cycles and lathe G76; the core parses an experimental G84.
            let rejected = "rejected as unsupported (error 20)"
            d.cannedCycles = CannedCycles(otherMeanings: [74: rejected, 76: "a lathe threading cycle",
                                                          84: "experimental and not in its documentation",
                                                          87: rejected, 88: rejected])
            // Without an ATC, M6 depends on $341: modes 1–3 stop with a compatible sender, mode 4 ignores it.
            d.m6 = toolChange == .atc ? .macro : (senderPausesOnM6(controller.sender) ? .senderDependent : .recordsOnly)
        case .fluidNC:
            // 127-character lines, G59.1–G59.3, M6 only acts with a configured ATC or M6 macro.
            d.id = "fluidnc"
            d.name = "FluidNC"
            d.maxLineLength = 126
            d.maxLineNumber = 10_000_000
            d.allowedG = grblG.union([59.1, 59.2, 59.3])
            d.allowedM = Set([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 30, 56, 62, 63, 64, 65, 66, 67, 68, 70, 71, 72, 73])
            d.m6 = toolChange == .atc ? .macro : .recordsOnly
        case .carbideMotion:
            // Carbide Motion runs M6 itself (prompts for the change, then probes with a BitSetter or sensor) and
            // ignores G54–G59.
            d.id = "carbide-motion"
            d.name = "Carbide Motion"
            d.allowedM = [0, 1, 2, 3, 4, 5, 6, 8, 9, 30]
            d.m6 = .macro
        default:
            break
        }
        if let sender = controller.sender, !sender.isEmpty, controller.family != .carbideMotion {
            d.name += " via \(sender)"
        }
        return d
    }
}
