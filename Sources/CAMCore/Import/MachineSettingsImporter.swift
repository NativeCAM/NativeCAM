import Foundation

/// Machine limits read from a controller's own settings, the only files that hold real per-axis speeds and
/// accelerations: a Grbl or grblHAL `$$` dump, Mach4's `Machine.ini`, a LinuxCNC INI, FluidNC's `config.yaml`, or a
/// Fusion 360 machine definition (`.mch`, travel and speeds but no acceleration). Every value says where it came
/// from and how it was converted, and the user picks which to apply.
public struct MachineImport: Sendable {
    public enum Format: String, Sendable {
        case grbl = "Grbl $$ settings"
        case mach4 = "Mach4 Machine.ini"
        case linuxCNC = "LinuxCNC INI"
        case fluidNC = "FluidNC config"
        case fusion = "Fusion 360 machine"
    }

    /// A value the import can set. Lengths in mm, speeds in mm/min, accelerations in mm/s², times in seconds; the
    /// rotary axis's turn speed in degrees per minute.
    public enum Key: String, CaseIterable, Sendable {
        case travelX, travelY, travelZ, rapidXY, rapidZ, maxFeed, accelerationXY, accelerationZ, junctionDeviation
        case minRPM, maxRPM, toolChangeSeconds, turnSpeed

        public var label: String {
            switch self {
            case .travelX: "X travel"
            case .travelY: "Y travel"
            case .travelZ: "Z travel"
            case .rapidXY: "Rapid X/Y"
            case .rapidZ: "Rapid Z"
            case .maxFeed: "Max cutting feed"
            case .accelerationXY: "Acceleration X/Y"
            case .accelerationZ: "Acceleration Z"
            case .junctionDeviation: "Corner tolerance"
            case .minRPM: "Min RPM"
            case .maxRPM: "Max RPM"
            case .toolChangeSeconds: "Tool change time"
            case .turnSpeed: "Rotary turn speed"
            }
        }

        var field: MachineProfile.Field {
            switch self {
            case .travelX, .travelY, .travelZ: .travel
            case .rapidXY: .rapidRateForEstimates
            case .rapidZ: .rapidRateZ
            case .maxFeed: .maxFeedRate
            case .accelerationXY: .accelerationXY
            case .accelerationZ: .accelerationZ
            case .junctionDeviation: .junctionDeviation
            case .minRPM: .minRPM
            case .maxRPM: .maxRPM
            case .toolChangeSeconds: .toolChangeSeconds
            case .turnSpeed: .turnSpeed
            }
        }

        /// Whether `machine` has somewhere to put it: the turn speed needs a rotary axis.
        public func applies(to machine: MachineProfile) -> Bool { self != .turnSpeed || machine.rotary != nil }
    }

    public struct Setting: Sendable, Identifiable {
        public var key: Key
        public var value: Double
        public var source: ValueSource
        public var id: Key { key }

        /// The value in the user's units, with its unit.
        public func display(_ u: LengthUnit) -> String {
            switch key {
            case .travelX, .travelY, .travelZ, .junctionDeviation: "\(u.format(value, decimals: u == .inch ? 3 : 2)) \(u.symbol)"
            case .rapidXY, .rapidZ, .maxFeed: "\(u.format(value, decimals: 0)) \(u.feedSymbol)"
            case .accelerationXY, .accelerationZ: "\(u.format(value, decimals: u == .inch ? 1 : 0)) \(u.symbol)/s²"
            case .minRPM, .maxRPM: "\(Int(value.rounded())) RPM"
            case .toolChangeSeconds: "\(Int(value.rounded())) s"
            case .turnSpeed: "\(Int(value.rounded()).formatted())°/min"
            }
        }

        /// The current value of the same setting on a machine, for comparison; nil when it has none (no turn speed set).
        public func current(_ m: MachineProfile) -> Double? {
            switch key {
            case .travelX: m.travel.x
            case .travelY: m.travel.y
            case .travelZ: m.travel.z
            case .rapidXY: m.rapidRateForEstimates
            case .rapidZ: m.axisRapid.z
            case .maxFeed: m.maxFeedRate
            case .accelerationXY: m.axisAcceleration.x
            case .accelerationZ: m.axisAcceleration.z
            case .junctionDeviation: m.cornerDeviation
            case .minRPM: m.minRPM
            case .maxRPM: m.maxRPM
            case .toolChangeSeconds: m.toolChangeTime
            case .turnSpeed: m.rotary?.turnSpeed
            }
        }
    }

    public var format: Format
    /// The machine's name, when the file has one.
    public var machineName: String?
    public var settings: [Setting]
    /// The controller the file came from (Grbl, grblHAL, FluidNC, LinuxCNC); nil for Mach4, which stays on the
    /// machine's current profile.
    public var controller: ControllerProfile?
    /// The controller's G-code units, when the file says.
    public var outputUnits: LengthUnit?
    /// True when the file says the machine has a tool changer.
    public var hasToolChanger: Bool?
    /// Things worth knowing that aren't settings (laser mode on, M6 ignored, soft limits off).
    public var notes: [String]

    public func setting(_ key: Key) -> Setting? { settings.first { $0.key == key } }

    /// Applies the chosen settings (and, if asked, the controller, units and tool changer), recording each value's
    /// source. A travel that no longer matches an Avid preset makes the machine custom. The turn speed goes to the
    /// machine's rotary axis, and only when it has one: an A motor in the controller's settings doesn't mean the rotary
    /// is fitted, so the import never turns one on.
    public func apply(to m: inout MachineProfile, keys: Set<Key>, controller useController: Bool = true,
                      units useUnits: Bool = true, toolChanger useToolChanger: Bool = true) {
        for s in settings where keys.contains(s.key) && s.key.applies(to: m) {
            switch s.key {
            case .travelX: m.travel.x = s.value
            case .travelY: m.travel.y = s.value
            case .travelZ: m.travel.z = s.value
            case .rapidXY: m.rapidRateForEstimates = s.value
            case .rapidZ: m.rapidRateZ = s.value
            case .maxFeed: m.maxFeedRate = s.value
            case .accelerationXY: m.accelerationXY = s.value
            case .accelerationZ: m.accelerationZ = s.value
            case .junctionDeviation: m.junctionDeviation = s.value
            case .minRPM: m.minRPM = s.value
            case .maxRPM: m.maxRPM = s.value
            case .toolChangeSeconds: m.toolChangeSeconds = s.value
            case .turnSpeed: m.rotary?.turnSpeed = s.value
            }
            m.setSource(s.source, for: s.key.field)
        }
        if let area = m.model.workArea,
           abs(area.x - m.travel.x) > 1 || abs(area.y - m.travel.y) > 1 || abs(area.z - m.travel.z) > 1 {
            m.model = .custom
        }
        if useController, let c = controller { m.controller = c }
        if useUnits, let u = outputUnits { m.outputUnits = u }
        if useToolChanger, hasToolChanger == true { m.toolChange = .atc }
    }
}

public enum MachineImportError: Error, LocalizedError {
    case unreadable
    case unrecognised
    case unsupported(String)
    case empty(MachineImport.Format)

    public var errorDescription: String? {
        switch self {
        case .unreadable: "The file can't be read as text."
        case .unrecognised: "This doesn't look like Grbl $$ settings, a Mach4 Machine.ini, a LinuxCNC INI, a FluidNC config or a Fusion 360 machine (.mch)."
        case let .unsupported(why): why
        case let .empty(format): "The \(format.rawValue) has no machine limits NativeCAM can use."
        }
    }
}

public enum MachineSettingsImporter {
    public static let fileExtensions = ["txt", "ini", "yaml", "yml", "mch", "json"]

    public static func load(url: URL) throws -> MachineImport {
        let ext = url.pathExtension.lowercased()
        if ext == "htg" {
            throw MachineImportError.unsupported("Masso saves its settings in a format other programs can't read. Enter the speeds and accelerations from Masso's setup screens instead.")
        }
        guard let data = try? Data(contentsOf: url) else { throw MachineImportError.unreadable }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { throw MachineImportError.unreadable }
        return try read(text)
    }

    /// Recognises the format from the text itself, so a pasted `$$` dump works as well as a file.
    public static func read(_ text: String) throws -> MachineImport {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") { return try fusion(trimmed) }
        if trimmed.hasPrefix("<") {
            throw MachineImportError.unsupported("Mach3 XML profiles aren't supported yet: the units of their speed and acceleration values aren't confirmed.")
        }
        let lines = trimmed.components(separatedBy: .newlines)
        if lines.filter({ $0.range(of: #"^\s*\$\d+\s*=\s*-?[0-9.]+"#, options: .regularExpression) != nil }).count >= 3 {
            return try grbl(lines)
        }
        let ini = INI(lines)
        if ini.sections["Motor0"]?["countsperunit"] != nil { return try mach4(ini) }
        if ini.sections.keys.contains(where: { $0 == "TRAJ" || $0.hasPrefix("AXIS_") }) { return try linuxCNC(ini) }
        if lines.contains(where: { $0.hasPrefix("axes:") }) { return try fluidNC(lines) }
        throw MachineImportError.unrecognised
    }

    // MARK: Grbl

    static func grbl(_ lines: [String]) throws -> MachineImport {
        var v: [Int: Double] = [:]
        for line in lines {
            guard let m = line.range(of: #"^\s*\$(\d+)\s*=\s*(-?[0-9.]+)"#, options: .regularExpression) else { continue }
            let parts = line[m].trimmingCharacters(in: .whitespaces).dropFirst().split(separator: "=")
            if parts.count == 2, let n = Int(parts[0].trimmingCharacters(in: .whitespaces)),
               let x = Double(parts[1].trimmingCharacters(in: .whitespaces)) { v[n] = x }
        }
        guard v[100] != nil || v[110] != nil || v[120] != nil else {
            throw MachineImportError.unsupported("These look like settings from Grbl 0.8 or earlier, which numbered them differently. Update Grbl, or enter the values by hand.")
        }
        let hal = v.keys.contains { $0 > 132 && $0 != 0 }
        var out = MachineImport(format: .grbl, settings: [], controller: ControllerProfile(family: hal ? .grblHAL : .grbl), notes: [])
        func add(_ key: MachineImport.Key, _ n: Int, _ note: String, transform: (Double) -> Double = { $0 }) {
            guard let x = v[n], x > 0 else { return }
            out.settings.append(.init(key: key, value: transform(x), source: ValueSource(.controllerSettings, note: "$\(n) \(note)")))
        }
        func minimum(_ key: MachineImport.Key, _ a: Int, _ b: Int, _ note: String) {
            let values = [a, b].compactMap { v[$0] }.filter { $0 > 0 }
            guard let x = values.min() else { return }
            out.settings.append(.init(key: key, value: x, source: ValueSource(.controllerSettings, note: "the lower of $\(a) and $\(b) \(note)")))
        }
        add(.travelX, 130, "X max travel (mm)")
        add(.travelY, 131, "Y max travel (mm)")
        add(.travelZ, 132, "Z max travel (mm)")
        minimum(.rapidXY, 110, 111, "max rate (mm/min)")
        add(.rapidZ, 112, "Z max rate (mm/min)")
        minimum(.maxFeed, 110, 111, "max rate (mm/min), which caps cutting feeds too")
        minimum(.accelerationXY, 120, 121, "acceleration (mm/s²)")
        add(.accelerationZ, 122, "Z acceleration (mm/s²)")
        add(.junctionDeviation, 11, "junction deviation (mm)")
        add(.maxRPM, 30, "max spindle speed")
        add(.minRPM, 31, "min spindle speed")
        if v[32] == 1 { out.notes.append("Laser mode is on ($32=1): Grbl keeps moving through spindle changes, which a router spindle can't follow. Turn it off for routing.") }
        if v[20] == 0 { out.notes.append("Soft limits are off ($20=0), so Grbl won't stop a move past the travel. NativeCAM's export check still compares the job with the travel.") }
        if let mode = v[341] {
            switch Int(mode) {
            case 4: out.notes.append("$341=4: grblHAL records the tool number and ignores M6, so NativeCAM saves one file per tool.")
            case 1, 2, 3: out.notes.append("$341=\(Int(mode)): grblHAL stops for manual tool changes on M6 with a sender that supports it, such as gSender.")
            default: break
            }
        }
        guard !out.settings.isEmpty else { throw MachineImportError.empty(.grbl) }
        return out
    }

    // MARK: Mach4

    /// Mach4's Machine.ini stores motor speeds and accelerations in counts (steps) per second; dividing by
    /// CountsPerUnit gives machine units. Axes map to motors through ChildMotorN, which includes a slaved gantry
    /// motor, so each axis takes the slowest of its motors. A rotary axis (A is Axis3) counts per degree, whatever the
    /// linear units: its motor's MaxVelocity gives the rotary axis's turn speed. Avid publishes none for its rotary; its
    /// Mach4 setup writes the A motor's tuning when the rotary is chosen, so a machine's own Machine.ini is the source.
    static func mach4(_ ini: INI) throws -> MachineImport {
        let prefs = ini.sections["Preferences"] ?? [:]
        // setupunits 200 / 210 match G20 / G21; [DefaultMode] unitsmode is the G-code units Mach4 starts in.
        let mode = (ini.sections["DefaultMode"]?["unitsmode"] ?? prefs["unitsmode"])?.uppercased()
        let setup = prefs["setupunits"].flatMap(Double.init)
        let u: LengthUnit = setup == 210 ? .mm : (setup == 200 ? .inch : (mode == "G21" ? .mm : .inch))
        var out = MachineImport(format: .mach4, settings: [], controller: nil, notes: [
            "Mach4 stores motor values in counts; NativeCAM divides by CountsPerUnit. Check the results against Configure ▸ Control ▸ Motors.",
        ])
        if let mode, mode == "G20" || mode == "G21" { out.outputUnits = mode == "G20" ? .inch : .mm }

        /// A motor's velocity (mm/min) and acceleration (mm/s²) on a linear axis, and `perSecond` and `perSecond2` in
        /// the units it counts in (degrees on a rotary axis).
        struct Motor {
            var velocity: Double, accel: Double, travel: Double?, name: String
            var perSecond: Double, perSecond2: Double
        }
        func motor(_ name: String) -> Motor? {
            guard let s = ini.sections[name], s["enabled"].map({ $0 != "0" }) ?? true,
                  let cpu = s["countsperunit"].flatMap(Double.init), cpu > 0 else { return nil }
            let vel = (s["maxvelocity"].flatMap(Double.init) ?? 0) / cpu    // units/s
            let acc = (s["maxaccel"].flatMap(Double.init) ?? 0) / cpu       // units/s²
            let hi = (s["softmaxlimit"].flatMap(Double.init) ?? 0) / cpu, lo = (s["softminlimit"].flatMap(Double.init) ?? 0) / cpu
            return Motor(velocity: u.toMM(vel * 60), accel: u.toMM(acc), travel: hi - lo > 0 ? u.toMM(hi - lo) : nil, name: name,
                         perSecond: vel, perSecond2: acc)
        }
        func axis(_ n: Int) -> [Motor] {
            guard let s = ini.sections["Axis\(n)"], s["enabled"].map({ $0 != "0" }) ?? true else { return [] }
            return s.filter { $0.key.hasPrefix("childmotor") }.sorted { $0.key < $1.key }.compactMap { motor($0.value) }
        }
        let x = axis(0), y = axis(1), z = axis(2)
        func note(_ motors: [Motor], _ what: String) -> String {
            "Machine.ini \(motors.map(\.name).joined(separator: "/")) \(what) ÷ CountsPerUnit (\(u == .inch ? "inches" : "mm"))"
        }
        func add(_ key: MachineImport.Key, _ value: Double?, _ note: String) {
            guard let value, value > 0 else { return }
            out.settings.append(.init(key: key, value: value, source: ValueSource(.controllerSettings, note: note)))
        }
        add(.travelX, x.compactMap(\.travel).min(), note(x, "soft limits"))
        add(.travelY, y.compactMap(\.travel).min(), note(y, "soft limits"))
        add(.travelZ, z.compactMap(\.travel).min(), note(z, "soft limits"))
        let xy = x + y
        add(.rapidXY, xy.map(\.velocity).filter { $0 > 0 }.min(), note(xy, "MaxVelocity"))
        add(.maxFeed, xy.map(\.velocity).filter { $0 > 0 }.min(), note(xy, "MaxVelocity"))
        add(.rapidZ, z.map(\.velocity).filter { $0 > 0 }.min(), note(z, "MaxVelocity"))
        add(.accelerationXY, xy.map(\.accel).filter { $0 > 0 }.min(), note(xy, "MaxAccel"))
        add(.accelerationZ, z.map(\.accel).filter { $0 > 0 }.min(), note(z, "MaxAccel"))
        if let range = ini.sections["SpindleRange0"] {
            add(.maxRPM, range["maxrpm"].flatMap(Double.init), "Machine.ini SpindleRange0 maxrpm")
            add(.minRPM, range["minrpm"].flatMap(Double.init), "Machine.ini SpindleRange0 minrpm")
        }
        // The A axis: its slowest motor's velocity, in degrees, is the turn speed.
        let a = axis(3).filter { $0.perSecond > 0 }
        if let slowest = a.min(by: { $0.perSecond < $1.perSecond }) {
            let speed = slowest.perSecond * 60
            add(.turnSpeed, speed, "Machine.ini \(a.map(\.name).joined(separator: "/")) MaxVelocity ÷ CountsPerUnit (degrees) × 60")
            let accel = a.map(\.perSecond2).filter { $0 > 0 }.min()
            out.notes.append("The A axis (\(slowest.name)) turns at up to \(Int(speed.rounded()).formatted())°/min"
                + (accel.map { " and accelerates at \(Int($0.rounded()).formatted())°/s²" } ?? "")
                + ". NativeCAM takes that as the rotary axis's Turn speed (Material & Machine ▸ Rotary Axis), which the feeds near "
                + "the axis, the run-time estimate and the simulation keep to; it doesn't model A's acceleration, so short turns "
                + "take a little longer than estimated. It applies only to a machine whose rotary axis is turned on.")
        }
        guard !out.settings.isEmpty else { throw MachineImportError.empty(.mach4) }
        return out
    }

    // MARK: LinuxCNC

    /// LinuxCNC INI values are per second (the AXIS GUI shows per minute), in LINEAR_UNITS.
    static func linuxCNC(_ ini: INI) throws -> MachineImport {
        let traj = ini.sections["TRAJ"] ?? [:]
        let unitsText = (traj["linear_units"] ?? "mm").lowercased()
        let u: LengthUnit = unitsText.hasPrefix("in") || unitsText == "imperial" ? .inch : .mm
        var out = MachineImport(format: .linuxCNC, machineName: ini.sections["EMC"]?["machine"], settings: [],
                                controller: ControllerProfile(family: .linuxCNC), outputUnits: nil, notes: [])
        func axis(_ letter: String, _ index: Int) -> [String: String]? { ini.sections["AXIS_\(letter)"] ?? ini.sections["AXIS_\(index)"] }
        func add(_ key: MachineImport.Key, _ value: Double?, _ note: String) {
            guard let value, value > 0 else { return }
            out.settings.append(.init(key: key, value: value, source: ValueSource(.controllerSettings, note: note)))
        }
        func num(_ s: [String: String]?, _ k: String) -> Double? { s?[k].flatMap(Double.init) }
        for (i, letter) in ["X", "Y", "Z"].enumerated() {
            guard let s = axis(letter, i), let lo = num(s, "min_limit"), let hi = num(s, "max_limit") else { continue }
            add([.travelX, .travelY, .travelZ][i], u.toMM(hi - lo), "[AXIS_\(letter)] MAX_LIMIT − MIN_LIMIT")
        }
        let x = axis("X", 0), y = axis("Y", 1), z = axis("Z", 2)
        let vxy = [num(x, "max_velocity"), num(y, "max_velocity")].compactMap { $0 }.min()
        add(.rapidXY, vxy.map { u.toMM($0 * 60) }, "[AXIS_X/Y] MAX_VELOCITY (per second) × 60")
        add(.maxFeed, vxy.map { u.toMM($0 * 60) } ?? num(traj, "max_linear_velocity").map { u.toMM($0 * 60) },
            "[AXIS_X/Y] MAX_VELOCITY (per second) × 60")
        add(.rapidZ, num(z, "max_velocity").map { u.toMM($0 * 60) }, "[AXIS_Z] MAX_VELOCITY (per second) × 60")
        let axy = [num(x, "max_acceleration"), num(y, "max_acceleration")].compactMap { $0 }.min()
        add(.accelerationXY, axy.map { u.toMM($0) }, "[AXIS_X/Y] MAX_ACCELERATION")
        add(.accelerationZ, num(z, "max_acceleration").map { u.toMM($0) }, "[AXIS_Z] MAX_ACCELERATION")
        let spindle = ini.sections["SPINDLE_0"]
        add(.maxRPM, num(spindle, "max_forward_velocity"), "[SPINDLE_0] MAX_FORWARD_VELOCITY")
        add(.minRPM, num(spindle, "min_forward_velocity"), "[SPINDLE_0] MIN_FORWARD_VELOCITY")
        guard !out.settings.isEmpty else { throw MachineImportError.empty(.linuxCNC) }
        return out
    }

    // MARK: FluidNC

    static func fluidNC(_ lines: [String]) throws -> MachineImport {
        let yaml = SimpleYAML(lines)
        var out = MachineImport(format: .fluidNC, machineName: yaml["name"], settings: [],
                                controller: ControllerProfile(family: .fluidNC), notes: [])
        func add(_ key: MachineImport.Key, _ value: Double?, _ note: String) {
            guard let value, value > 0 else { return }
            out.settings.append(.init(key: key, value: value, source: ValueSource(.controllerSettings, note: note)))
        }
        func num(_ path: String) -> Double? { yaml[path].flatMap(Double.init) }
        add(.travelX, num("axes/x/max_travel_mm"), "axes x max_travel_mm")
        add(.travelY, num("axes/y/max_travel_mm"), "axes y max_travel_mm")
        add(.travelZ, num("axes/z/max_travel_mm"), "axes z max_travel_mm")
        let rxy = [num("axes/x/max_rate_mm_per_min"), num("axes/y/max_rate_mm_per_min")].compactMap { $0 }.min()
        add(.rapidXY, rxy, "the lower of axes x/y max_rate_mm_per_min")
        add(.maxFeed, rxy, "the lower of axes x/y max_rate_mm_per_min")
        add(.rapidZ, num("axes/z/max_rate_mm_per_min"), "axes z max_rate_mm_per_min")
        add(.accelerationXY, [num("axes/x/acceleration_mm_per_sec2"), num("axes/y/acceleration_mm_per_sec2")].compactMap { $0 }.min(),
            "the lower of axes x/y acceleration_mm_per_sec2")
        add(.accelerationZ, num("axes/z/acceleration_mm_per_sec2"), "axes z acceleration_mm_per_sec2")
        // Spindle speed maps look like "speed_map: 0=0% 1000=0% 24000=100%".
        if let map = yaml.values.first(where: { $0.key.hasSuffix("/speed_map") }) {
            let speeds = map.value.split(separator: " ").compactMap { Double($0.split(separator: "=").first ?? "") }
            if let top = speeds.max() { add(.maxRPM, top, "\(map.key.replacingOccurrences(of: "/", with: " ")) top speed") }
        }
        if yaml.values.keys.contains(where: { $0.hasPrefix("atc") || $0.contains("/atc") }) { out.hasToolChanger = true }
        guard !out.settings.isEmpty else { throw MachineImportError.empty(.fluidNC) }
        return out
    }

    // MARK: Fusion

    /// Fusion's `.mch` JSON: axis limits in the kinematics tree, speeds under controller, the spindle's range and
    /// tool-change time. It has no acceleration.
    static func fusion(_ text: String) throws -> MachineImport {
        guard let root = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], root["kinematics"] != nil else {
            throw MachineImportError.unrecognised
        }
        let general = root["general"] as? [String: Any]
        let name = [general?["vendor"] as? String, general?["model"] as? String].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        var out = MachineImport(format: .fusion, machineName: name.isEmpty ? nil : name, settings: [], controller: nil,
                                notes: ["Fusion machine definitions have no acceleration; keep NativeCAM's estimate or import your controller's settings."])
        let kinematics = (root["kinematics"] as? [String: Any])?["default"] as? [String: Any]
        let lengthUnit = ((kinematics?["units"] as? [String: Any])?["length"] as? String ?? "mm").lowercased()
        let u: LengthUnit = lengthUnit.hasPrefix("in") ? .inch : .mm
        func add(_ key: MachineImport.Key, _ value: Double?, _ note: String) {
            guard let value, value > 0 else { return }
            out.settings.append(.init(key: key, value: value, source: ValueSource(.vendor, note: note)))
        }
        func number(_ any: Any?) -> Double? { (any as? NSNumber)?.doubleValue ?? (any as? String).flatMap(Double.init) }
        // Walk the parts tree for linear axes and the spindle.
        var limits: [String: Double] = [:]
        var spindle: [String: Any]?
        func walk(_ any: Any) {
            if let d = any as? [String: Any] {
                if let id = (d["id"] as? String)?.uppercased(), ["X", "Y", "Z"].contains(id), let lo = number(d["min"]), let hi = number(d["max"]) {
                    limits[id] = hi - lo
                }
                if let s = d["spindle"] as? [String: Any] { spindle = s }
                for v in d.values { walk(v) }
            } else if let a = any as? [Any] {
                for v in a { walk(v) }
            }
        }
        walk(kinematics ?? [:])
        add(.travelX, limits["X"].map(u.toMM), "kinematics X max − min")
        add(.travelY, limits["Y"].map(u.toMM), "kinematics Y max − min")
        add(.travelZ, limits["Z"].map(u.toMM), "kinematics Z max − min")
        add(.maxRPM, number(spindle?["max_speed"]), "spindle max_speed")
        add(.minRPM, number(spindle?["min_speed"]), "spindle min_speed")
        let axes = ((root["controller"] as? [String: Any])?["synced_configuration"] as? [String: Any])?["parts"] as? [String: Any] ?? [:]
        func speed(_ axis: String, _ key: String) -> Double? {
            let entry = axes.first { $0.key.uppercased() == axis }?.value as? [String: Any]
            return number(entry?[key]).flatMap { $0 > 0 ? u.toMM($0) : nil }
        }
        add(.rapidXY, [speed("X", "max_rapid_speed"), speed("Y", "max_rapid_speed")].compactMap { $0 }.min(), "controller X/Y max_rapid_speed")
        add(.rapidZ, speed("Z", "max_rapid_speed"), "controller Z max_rapid_speed")
        add(.maxFeed, [speed("X", "max_normal_speed"), speed("Y", "max_normal_speed")].compactMap { $0 }.min(), "controller X/Y max_normal_speed")
        let machining = (root["machining"] as? [String: Any])?["default"] as? [String: Any]
        add(.toolChangeSeconds, number(machining?["tool_change_time"]), "machining tool_change_time")
        let tooling = (root["tooling"] as? [String: Any])?["default"] as? [String: Any]
        if let atc = tooling?["has_tool_changer"] as? Bool { out.hasToolChanger = atc }
        guard !out.settings.isEmpty else { throw MachineImportError.empty(.fusion) }
        return out
    }
}

/// A small INI reader: sections keep their case, keys are lowercased, `;` and `#` start comments.
struct INI {
    var sections: [String: [String: String]] = [:]

    init(_ lines: [String]) {
        var current = ""
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("#") { continue }
            if line.hasPrefix("["), let end = line.firstIndex(of: "]") {
                current = String(line[line.index(after: line.startIndex)..<end]).trimmingCharacters(in: .whitespaces)
                if sections[current] == nil { sections[current] = [:] }
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if let hash = value.range(of: " #") { value = String(value[..<hash.lowerBound]).trimmingCharacters(in: .whitespaces) }
            sections[current, default: [:]][key] = value
        }
    }
}

/// Just enough YAML for FluidNC configs: nested maps by indentation, `key: value` scalars, comments. Values are
/// keyed by their path, e.g. `axes/x/max_rate_mm_per_min`. Lists are skipped.
struct SimpleYAML {
    var values: [String: String] = [:]

    init(_ lines: [String]) {
        var stack: [(indent: Int, key: String)] = []
        for raw in lines {
            var line = raw
            if let hash = line.range(of: " #") { line = String(line[..<hash.lowerBound]) }
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("#") { continue }
            let content = line.trimmingCharacters(in: .whitespaces)
            guard !content.isEmpty, !content.hasPrefix("-"), let colon = content.firstIndex(of: ":") else { continue }
            let indent = line.prefix { $0 == " " }.count
            while let last = stack.last, last.indent >= indent { stack.removeLast() }
            let key = content[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = content[content.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            let path = (stack.map(\.key) + [key]).joined(separator: "/")
            if value.isEmpty { stack.append((indent, key)) } else { values[path] = value }
        }
    }

    subscript(path: String) -> String? { values[path] }
}
