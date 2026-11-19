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

    public func coordinateDecimals(_ u: LengthUnit) -> Int { coordinateDecimals[u] ?? (u == .inch ? 4 : 3) }
    public func feedDecimals(_ u: LengthUnit) -> Int { feedDecimals[u] ?? (u == .inch ? 1 : 0) }

    /// A comment line in this dialect.
    public func comment(_ text: String) -> String { "(\(text))" }

    /// Avid CNC's Mach4 profile, as `AvidMach4Post` writes for it. Mach4 accepts much more than these lists; they
    /// hold what Mach4's Mill reference documents, so a typo or a code from another dialect stands out.
    public static let avidMach4 = Dialect(
        id: "avid-mach4", name: "Avid Mach4", maxLineLength: nil, lineEnding: "\r\n",
        allowedG: Set([0, 1, 2, 3, 4, 9, 10, 12, 13, 15, 16, 17, 18, 19, 20, 21, 28, 28.1, 30, 31, 32, 40, 41, 42, 43, 49,
                       50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 64, 65, 66, 67, 68, 69, 73, 74, 76, 80, 81, 82, 83,
                       84, 85, 86, 87, 88, 89, 90, 91, 90.1, 91.1, 92, 93, 94, 95, 96, 97, 98, 99]),
        allowedM: Set([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 19, 30, 47, 48, 49, 98, 99]),
        allowedLetters: Set("ABCDFGHIJKLMNPQRSTUVWXYZ"), strict: false, acceptedUnits: [.inch, .mm],
        dwell: .secondsWithDecimal, arcCheck: .absolute(0.0127), maxToolNumber: nil, maxLineNumber: nil, m6: .macro,
        coordinateDecimals: [.inch: 4, .mm: 3], feedDecimals: [.inch: 1, .mm: 0], verified: true)

    /// The dialect a machine's post writes; nil when NativeCAM has no post for its controller yet.
    public static func `for`(_ machine: MachineProfile) -> Dialect? {
        machine.isLegacyAvidMach4 ? .avidMach4 : nil
    }
}
