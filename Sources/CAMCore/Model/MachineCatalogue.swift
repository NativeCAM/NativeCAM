import Foundation

/// Machines NativeCAM knows out of the box: vendor, model and size, the controllers each ships with, travel,
/// speeds, spindle and defaults, every value with its source. Acceleration is almost never published, so most of
/// it is a labelled class default. The data lives in `MachineCatalogueData.swift`.
public struct MachineCatalogue: Codable, Sendable {
    public var schemaVersion: Int
    public var entries: [Entry]

    /// One controller a machine can run, as the setup flow offers it.
    public struct ControllerOption: Codable, Sendable, Hashable {
        /// A `ControllerFamily` raw value ("mach4" for Avid's Mach4 profile, "grbl", "centroid", …).
        public var family: String
        /// The program that sends files, for Grbl-family machines ("gSender", "Carbide Motion").
        public var sender: String?
        /// What the vendor calls it ("SuperLongBoard", "Avid EX (CNC12)").
        public var label: String?
        public var isDefault: Bool?

        public init(family: String, sender: String? = nil, label: String? = nil, isDefault: Bool? = nil) {
            self.family = family
            self.sender = sender
            self.label = label
            self.isDefault = isDefault
        }

        /// The controller a project stores. Avid's Mach4 profile is no controller at all (format 1).
        public func profile(avid: Bool) -> ControllerProfile? {
            if avid && family == "mach4" { return nil }
            return ControllerProfile(family: ControllerFamily(rawValue: family), sender: sender)
        }

        public var displayName: String {
            label ?? ControllerFamily(rawValue: family).label + (sender.map { " via \($0)" } ?? "")
        }
    }

    /// Where a value came from, as stored in the catalogue.
    public struct Source: Codable, Sendable, Hashable {
        /// "vendor", "controllerSettings", "measured", "estimated" or "user".
        public var kind: String
        public var note: String?
        public var url: String?

        public var valueSource: ValueSource { ValueSource(ValueSource.Kind(rawValue: kind), note: note, url: url) }
    }

    public struct Entry: Codable, Sendable, Identifiable, Hashable {
        /// Stable across catalogue updates, e.g. "sienci-altmill-4x4".
        public var id: String
        public var vendor: String
        /// The product line, e.g. "AltMill".
        public var family: String
        /// Size or variant, e.g. "4×4"; empty when there's only one.
        public var model: String
        /// X, Y, Z travel in mm.
        public var travel: [Double]
        public var controllers: [ControllerOption]
        /// "router" (switched by relay, speed on a dial) or "vfdSpindle".
        public var spindle: String
        public var minRPM: Double?
        public var maxRPM: Double?
        /// mm/min.
        public var rapidXY: Double?
        public var rapidZ: Double?
        public var maxFeed: Double?
        /// mm/s².
        public var accelerationXY: Double?
        public var accelerationZ: Double?
        /// mm.
        public var junctionDeviation: Double?
        /// "inch" or "mm": the units the vendor's own posts write.
        public var units: String?
        /// "manualM6", "manualPause" or "atc".
        public var toolChange: String?
        /// Whether the vendor wires a dust-collector or accessory output by default.
        public var dustCollection: Bool?
        /// Sources keyed by field name: travel, minRPM, maxRPM, rapidXY, rapidZ, maxFeed, accelerationXY,
        /// accelerationZ, junctionDeviation, controllers.
        public var sources: [String: Source]
        /// Anything the user should know (a discontinued model, an unusual default).
        public var notes: String?
        /// Checked against a real machine by someone.
        public var verified: Bool

        public var displayName: String { model.isEmpty ? "\(vendor) \(family)" : "\(vendor) \(family) \(model)" }

        public var defaultController: ControllerOption? { controllers.first { $0.isDefault == true } ?? controllers.first }

        /// An Avid PRO preset, when this entry is one of them.
        public var avidModel: AvidModel? {
            guard vendor == "Avid CNC" else { return nil }
            return AvidModel.allCases.first { $0 != .custom && $0.shortName == family + model }
                ?? AvidModel.allCases.first { $0 != .custom && displayName.contains($0.shortName) }
        }

        /// A machine profile for this entry and controller, with every catalogue value's source recorded. Values
        /// the catalogue doesn't have keep NativeCAM's defaults.
        public func profile(controller option: ControllerOption? = nil) -> MachineProfile {
            var m = MachineProfile()
            let avid = avidModel
            m.model = avid ?? .custom
            if travel.count == 3 { m.travel = Vec3(travel[0], travel[1], travel[2]) }
            m.spindle = spindle == "router" ? .router : .vfdSpindle
            if let v = minRPM { m.minRPM = v }
            if let v = maxRPM { m.maxRPM = v }
            if let v = maxFeed { m.maxFeedRate = v } else if let v = rapidXY { m.maxFeedRate = v }
            // Without a published rapid, the maximum feed is a far better guess than NativeCAM's 800 in/min.
            m.rapidRateForEstimates = rapidXY ?? maxFeed ?? m.rapidRateForEstimates
            m.rapidRateZ = rapidZ ?? maxFeed.map { min($0, 400.inch) }
            m.accelerationXY = accelerationXY
            m.accelerationZ = accelerationZ
            m.junctionDeviation = junctionDeviation
            if let u = units { m.outputUnits = u == "mm" ? .mm : .inch }
            if let t = toolChange, let mode = ToolChangeMode(rawValue: t) { m.toolChange = mode }
            // Only switch an output the maker says is wired for a dust collector.
            m.dustCollection = dustCollection ?? false
            m.controller = (option ?? defaultController)?.profile(avid: avid != nil || vendor == "Avid CNC")
            m.libraryID = id
            for field in MachineProfile.Field.allCases {
                let key: String
                switch field {
                case .rapidRateForEstimates: key = "rapidXY"
                case .rapidRateZ: key = "rapidZ"
                case .maxFeedRate: key = "maxFeed"
                default: key = field.rawValue
                }
                if let s = sources[key] { m.setSource(s.valueSource, for: field) }
            }
            if rapidXY == nil, maxFeed != nil {
                m.setSource(ValueSource(.estimated, note: "no published rapid speed; using the maximum feed"), for: .rapidRateForEstimates)
            }
            if rapidZ == nil, maxFeed != nil {
                m.setSource(ValueSource(.estimated, note: "no published Z rapid; the maximum feed, capped at 400 in/min"), for: .rapidRateZ)
            }
            return m
        }
    }

    /// The catalogue that ships with NativeCAM.
    public static let builtIn: MachineCatalogue = {
        do {
            return try JSONDecoder().decode(MachineCatalogue.self, from: Data(MachineCatalogueData.json.utf8))
        } catch {
            assertionFailure("Machine catalogue doesn't decode: \(error)")
            return MachineCatalogue(schemaVersion: 1, entries: [])
        }
    }()

    /// Entries grouped by vendor, vendors in alphabetical order.
    public var byVendor: [(vendor: String, entries: [Entry])] {
        Dictionary(grouping: entries, by: \.vendor).map { ($0.key, $0.value) }.sorted { $0.vendor < $1.vendor }
    }
}
