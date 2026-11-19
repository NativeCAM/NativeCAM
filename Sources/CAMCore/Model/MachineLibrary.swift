import Foundation

/// One machine in the library: a frame, its controller and its output settings, under a stable ID so re-importing
/// or updating it replaces the entry instead of adding a duplicate.
public struct MachineSetup: Hashable, Codable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// Goes up by one with every change, so a project can tell its copy is older than the library's.
    public var revision: Int
    /// Stored without `libraryID` / `libraryRevision`; `snapshot` adds them.
    public var profile: MachineProfile

    public init(id: String, name: String, revision: Int = 1, profile: MachineProfile) {
        self.id = id
        self.name = name
        self.revision = revision
        self.profile = profile.unstamped
    }

    /// The full copy a new project stores, stamped with this entry's ID and revision.
    public var snapshot: MachineProfile {
        var p = profile
        p.libraryID = id
        p.libraryRevision = revision
        return p
    }
}

/// The app-wide machine library (`machines.json` beside `tools.json`).
public struct MachineLibrary: Hashable, Codable, Sendable {
    public static let currentSchemaVersion = 1
    /// ID of the entry seeded from the original single default machine.
    public static let firstMachineID = "4E415449-5645-4341-4D02-000000000001"

    public var schemaVersion: Int
    public var machines: [MachineSetup]
    /// The machine new documents start with.
    public var defaultID: String?

    public init(machines: [MachineSetup], defaultID: String? = nil) {
        schemaVersion = Self.currentSchemaVersion
        self.machines = machines
        self.defaultID = defaultID ?? machines.first?.id
    }

    /// A library holding one machine: the one the app used as its default before the library existed, or the
    /// PRO6060 on a fresh install.
    public static func starter(with profile: MachineProfile = .avidPRO6060) -> MachineLibrary {
        MachineLibrary(machines: [MachineSetup(id: firstMachineID, name: profile.displayName, profile: profile)])
    }

    public var defaultMachine: MachineSetup? { machines.first { $0.id == defaultID } ?? machines.first }

    public func machine(id: String) -> MachineSetup? { machines.first { $0.id == id } }

    /// Replaces the entry's profile, bumping its revision when anything changed. Returns false for an unknown ID.
    @discardableResult
    public mutating func update(_ id: String, profile: MachineProfile) -> Bool {
        guard let i = machines.firstIndex(where: { $0.id == id }) else { return false }
        let new = profile.unstamped
        guard machines[i].profile != new else { return true }
        machines[i].profile = new
        machines[i].revision += 1
        return true
    }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(self)
    }

    public static func decode(_ data: Data) throws -> MachineLibrary {
        let lib = try JSONDecoder().decode(MachineLibrary.self, from: data)
        guard lib.schemaVersion <= currentSchemaVersion else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey:
                "This machine library was saved by a newer version of NativeCAM (schema \(lib.schemaVersion))."])
        }
        return lib
    }
}

extension MachineProfile {
    /// The profile without the library stamp, as the library itself stores it.
    var unstamped: MachineProfile {
        var p = self
        p.libraryID = nil
        p.libraryRevision = nil
        return p
    }
}
