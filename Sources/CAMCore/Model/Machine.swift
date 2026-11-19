import Foundation

/// Avid CNC router models with factory work-area presets.
/// Work areas are from Avid's published PRO-series specs (standard 8" Z); verify against your build.
public enum AvidModel: String, Codable, Sendable, CaseIterable, Identifiable {
    case pro4848
    case pro4896
    case pro6060
    case custom

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .pro4848: "PRO4848 (4 × 4 ft)"
        case .pro4896: "PRO4896 (4 × 8 ft)"
        case .pro6060: "PRO6060 (5 × 5 ft)"
        case .custom: "Custom"
        }
    }

    /// Model number alone, for title bars and summaries.
    public var shortName: String {
        switch self {
        case .pro4848: "PRO4848"
        case .pro4896: "PRO4896"
        case .pro6060: "PRO6060"
        case .custom: "Custom machine"
        }
    }

    /// Nominal X/Y/Z work area in mm.
    public var workArea: Vec3? {
        switch self {
        case .pro4848: Vec3(49.5.inch, 49.5.inch, 8.inch)
        case .pro4896: Vec3(49.5.inch, 98.75.inch, 8.inch)
        case .pro6060: Vec3(61.375.inch, 61.375.inch, 8.inch)
        case .custom: nil
        }
    }
}

public enum SpindleKind: String, Codable, Sendable, CaseIterable, Identifiable {
    /// VFD-controlled spindle: speed set by the S word.
    case vfdSpindle
    /// Trim router switched by relay: speed set by hand on the dial.
    case router
    public var id: String { rawValue }
    public var label: String { self == .vfdSpindle ? "VFD spindle" : "Router" }
    public var detail: String {
        self == .vfdSpindle ? "Speed is set by the S word through the VFD." : "Switched on and off by relay; set the speed dial by hand."
    }
}

public enum ToolChangeMode: String, Codable, Sendable, CaseIterable, Identifiable {
    /// `T#M6`, handled by Avid's Mach4 M6 macro (move to change position, prompt, touch plate / tool setter).
    case manualM6
    /// Automatic tool changer: `T#M6` followed by `G43 H#` to apply the measured tool length offset.
    case atc
    /// No M6: stop the spindle and pause with `M0` so the operator can swap tools and re-zero Z.
    case manualPause

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .manualM6: "Manual (M6)"
        case .atc: "ATC (M6 + G43)"
        case .manualPause: "Manual (M0 pause)"
        }
    }

    public var detail: String {
        switch self {
        case .manualM6: "Avid's Mach4 M6 macro prompts for the change; re-zero Z with the touch plate."
        case .atc: "Tool changer picks the tool; G43 H# applies its measured length."
        case .manualPause: "Program stops with M0 for you to swap the bit and re-zero, then Cycle Start."
        }
    }
}

/// Avid PRO drive packages, with the cutting and rapid speeds Avid publishes for each (in/min).
public enum DriveTier: String, Codable, Sendable, CaseIterable, Identifiable {
    case nema23, nema34, clearPath
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .nema23: "NEMA 23 steppers"
        case .nema34: "NEMA 34 steppers"
        case .clearPath: "ClearPath servos"
        }
    }
    public var cutSpeed: Double {
        switch self {
        case .nema23: 250.inch
        case .nema34: 400.inch
        case .clearPath: 600.inch
        }
    }
    public var rapidSpeed: Double {
        switch self {
        case .nema23: 500.inch
        case .nema34: 800.inch
        case .clearPath: 1200.inch
        }
    }
}

/// Everything the post processor and validators need to know about the machine.
public struct MachineProfile: Hashable, Codable, Sendable {
    public var model: AvidModel
    /// Work area (mm).
    public var travel: Vec3
    public var spindle: SpindleKind
    public var minRPM: Double
    public var maxRPM: Double
    public var toolChange: ToolChangeMode
    /// Emit M7 at start / M9 at end (Avid's profile maps M7 to the dust collector relay).
    public var dustCollection: Bool
    /// Seconds to dwell (G4) after M3 before cutting. 0 lets Mach4's own spin-up delay handle it.
    public var spindleSpinUpDwell: Double
    /// Feed used for rapid moves when estimating cycle time (mm/min).
    public var rapidRateForEstimates: Double
    /// Highest feed the machine should be asked for (mm/min); used for warnings.
    public var maxFeedRate: Double
    public var outputUnits: LengthUnit
    /// Fit arcs (G2/G3) into the output where the toolpath allows.
    public var outputArcs: Bool
    /// Maximum deviation of fitted arcs and simplified segments (mm).
    public var arcFitTolerance: Double
    public var lineNumbers: Bool

    // Motion model for run-time estimates (optional so older project files still load; nil = default).
    // Avid publishes no acceleration figures; 50 in/s² is the X/Y value Avid owners report Mach4 ships with.
    // Read the real values from Mach4's Configure > Control > Motors.
    public var drive: DriveTier?
    /// X/Y acceleration, mm/s².
    public var accelerationXY: Double?
    /// Z acceleration, mm/s².
    public var accelerationZ: Double?
    /// Z rapid speed, mm/min.
    public var rapidRateZ: Double?
    /// Corner tolerance of the motion planner (Grbl-style junction deviation), mm.
    public var junctionDeviation: Double?
    /// Lines of G-code the controller plans ahead (Mach4 default 20).
    public var lookaheadLines: Int?
    /// Seconds for one tool change including touch-off and spin-up.
    public var toolChangeSeconds: Double?
    /// How far roughing passes may round off corners so the machine keeps moving (mm); finished walls stay exact.
    public var roughingSmoothing: Double?

    // Controller and machine library (optional so older project files still load).
    /// The controller that reads the G-code. nil is Avid's Mach4 profile, which every format 1 project assumes.
    public var controller: ControllerProfile?
    /// The machine library entry this profile was copied from, and that entry's revision at the time. The project
    /// keeps its own full copy either way, so it posts the same G-code whatever happens to the library later.
    public var libraryID: String?
    public var libraryRevision: Int?
    /// Where values came from, keyed by `Field` name. A value with no entry was typed in or is NativeCAM's default.
    public var provenance: [String: ValueSource]?

    public var driveTier: DriveTier { drive ?? .nema34 }
    public var axisAcceleration: Vec3 {
        let xy = accelerationXY ?? 50.inch
        return Vec3(xy, xy, accelerationZ ?? 25.inch)
    }
    /// Rapid speed per axis, mm/min.
    public var axisRapid: Vec3 { Vec3(rapidRateForEstimates, rapidRateForEstimates, rapidRateZ ?? 400.inch) }
    /// The controller's planner, for estimates: its own corner tolerance and look-ahead unless set here.
    public var planner: Dialect.Planner {
        var p = Dialect.for(self)?.planner ?? Dialect.avidMach4.planner
        if let d = junctionDeviation { p.junctionDeviation = d }
        if let n = lookaheadLines { p.lookahead = max(1, n) }
        return p
    }
    public var cornerDeviation: Double { planner.junctionDeviation }
    public var plannerLookahead: Int { planner.lookahead }
    public var cornerSmoothing: Double { max(0, roughingSmoothing ?? 0.25) }
    public var toolChangeTime: Double {
        toolChangeSeconds ?? (toolChange == .atc ? 15 : 60)
    }

    public init(model: AvidModel = .pro6060, travel: Vec3? = nil, spindle: SpindleKind = .vfdSpindle,
                minRPM: Double = 6000, maxRPM: Double = 24000, toolChange: ToolChangeMode = .manualM6,
                dustCollection: Bool = true, spindleSpinUpDwell: Double = 0,
                rapidRateForEstimates: Double = 800.inch, maxFeedRate: Double = 400.inch,
                outputUnits: LengthUnit = .inch, outputArcs: Bool = true, arcFitTolerance: Double = 0.01,
                lineNumbers: Bool = false) {
        self.model = model
        self.travel = travel ?? model.workArea ?? Vec3(48.inch, 48.inch, 8.inch)
        self.spindle = spindle
        self.minRPM = minRPM
        self.maxRPM = maxRPM
        self.toolChange = toolChange
        self.dustCollection = dustCollection
        self.spindleSpinUpDwell = spindleSpinUpDwell
        self.rapidRateForEstimates = rapidRateForEstimates
        self.maxFeedRate = maxFeedRate
        self.outputUnits = outputUnits
        self.outputArcs = outputArcs
        self.arcFitTolerance = arcFitTolerance
        self.lineNumbers = lineNumbers
    }

    /// Default profile: PRO6060 with a VFD spindle and manual tool changes using a touch plate.
    public static let avidPRO6060 = MachineProfile()

    public var displayName: String { model.label }

    public func clampRPM(_ rpm: Double) -> Double { min(max(rpm, minRPM), maxRPM) }
}
