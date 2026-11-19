import Foundation

/// The control software that reads the G-code. It decides the dialect a post must write: what `M6` does, which
/// G-codes are legal, what a `G4 P` value means, how arcs are checked.
///
/// Decodes names it doesn't know to `unknown`, keeping the raw value, so a file from a newer NativeCAM that knows
/// more controllers still opens (and is refused for posting rather than misread).
public enum ControllerFamily: Hashable, Sendable {
    case mach4, mach3
    case grbl, grblHAL, fluidNC, carbideMotion
    case linuxCNC, uccnc, masso, centroid, planetCNC, buildbotics
    case openSBP, richAuto, winCNC
    case unknown(String)

    public static let known: [ControllerFamily] = [
        .mach4, .mach3, .grbl, .grblHAL, .fluidNC, .carbideMotion, .linuxCNC, .uccnc, .masso, .centroid, .planetCNC,
        .buildbotics, .openSBP, .richAuto, .winCNC,
    ]

    public init(rawValue: String) {
        self = Self.known.first { $0.rawValue == rawValue } ?? .unknown(rawValue)
    }

    public var rawValue: String {
        switch self {
        case .mach4: "mach4"
        case .mach3: "mach3"
        case .grbl: "grbl"
        case .grblHAL: "grblHAL"
        case .fluidNC: "fluidNC"
        case .carbideMotion: "carbideMotion"
        case .linuxCNC: "linuxCNC"
        case .uccnc: "uccnc"
        case .masso: "masso"
        case .centroid: "centroid"
        case .planetCNC: "planetCNC"
        case .buildbotics: "buildbotics"
        case .openSBP: "openSBP"
        case .richAuto: "richAuto"
        case .winCNC: "winCNC"
        case let .unknown(raw): raw
        }
    }

    public var label: String {
        switch self {
        case .mach4: "Mach4"
        case .mach3: "Mach3"
        case .grbl: "Grbl"
        case .grblHAL: "grblHAL"
        case .fluidNC: "FluidNC"
        case .carbideMotion: "Carbide Motion"
        case .linuxCNC: "LinuxCNC"
        case .uccnc: "UCCNC"
        case .masso: "Masso"
        case .centroid: "Centroid CNC12"
        case .planetCNC: "PlanetCNC"
        case .buildbotics: "Buildbotics"
        case .openSBP: "ShopBot (OpenSBP)"
        case .richAuto: "RichAuto DSP"
        case .winCNC: "WinCNC"
        case let .unknown(raw): raw.isEmpty ? "Unknown controller" : raw
        }
    }
}

extension ControllerFamily: Codable {
    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

/// The controller a machine runs, as a project stores it. A project without one (every format 1 file) runs Avid's
/// Mach4 profile.
public struct ControllerProfile: Hashable, Codable, Sendable {
    public var family: ControllerFamily
    /// Firmware or software version as the controller reports it ("1.1h", "Build 6050"); nil if not known. Grbl's
    /// setting numbers and Mach4's dwell rules both changed between versions.
    public var firmware: String?
    /// The program that streams files to a Grbl-family controller (gSender, Carbide Motion, UGS), which decides
    /// what `M6` does there.
    public var sender: String?

    public init(family: ControllerFamily, firmware: String? = nil, sender: String? = nil) {
        self.family = family
        self.firmware = firmware
        self.sender = sender
    }
}

/// Where a machine value came from, so the app can show which numbers are the user's own and which are guesses.
public struct ValueSource: Hashable, Codable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// Published by the machine's maker.
        case vendor
        /// Read from the controller's own settings (`$$`, `Machine.ini`, a LinuxCNC INI, FluidNC YAML).
        case controllerSettings
        /// Timed or measured on the machine.
        case measured
        /// A class default or a conversion with assumptions; treat as a guess.
        case estimated
        /// Typed in by the user.
        case user
        case unknown(String)

        public static let known: [Kind] = [.vendor, .controllerSettings, .measured, .estimated, .user]

        public init(rawValue: String) {
            self = Self.known.first { $0.rawValue == rawValue } ?? .unknown(rawValue)
        }

        public var rawValue: String {
            switch self {
            case .vendor: "vendor"
            case .controllerSettings: "controllerSettings"
            case .measured: "measured"
            case .estimated: "estimated"
            case .user: "user"
            case let .unknown(raw): raw
            }
        }
    }

    public var kind: Kind
    /// How the value was found or converted, e.g. "Machine.ini MaxAccel ÷ CountsPerUnit".
    public var note: String?
    /// Where to check it.
    public var url: String?

    public init(_ kind: Kind, note: String? = nil, url: String? = nil) {
        self.kind = kind
        self.note = note
        self.url = url
    }
}

extension ValueSource.Kind: Codable {
    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

public extension MachineProfile {
    /// Machine values that can carry a `ValueSource`, named as the properties they describe.
    enum Field: String, CaseIterable, Sendable {
        case travel, minRPM, maxRPM, maxFeedRate, rapidRateForEstimates, rapidRateZ
        case accelerationXY, accelerationZ, junctionDeviation, lookaheadLines, toolChangeSeconds
    }

    /// True for Avid's Mach4 profile, the controller every project assumed before format 2.
    var isLegacyAvidMach4: Bool { controller == nil }

    /// Name of the controller, for summaries and messages.
    var controllerLabel: String { controller?.family.label ?? "Avid Mach4" }

    /// What writes the G-code: an imported post's name, or the controller.
    var postLabel: String { customPost.map { $0.name.isEmpty ? "Imported Vectric post" : $0.name } ?? controllerLabel }

    /// The project file format this machine needs. Format 1 builds would ignore `controller` and post Mach4 code
    /// for any machine, so anything but Avid's Mach4 profile is written as format 2, which they refuse to open.
    var requiredFormatVersion: Int { isLegacyAvidMach4 && customPost == nil ? 1 : 2 }

    func source(of field: Field) -> ValueSource? { provenance?[field.rawValue] }

    mutating func setSource(_ source: ValueSource?, for field: Field) {
        var p = provenance ?? [:]
        p[field.rawValue] = source
        provenance = p.isEmpty ? nil : p
    }
}
