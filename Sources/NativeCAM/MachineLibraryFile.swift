import CAMCore
import Foundation

/// The machine library, saved to ~/Library/Application Support/NativeCAM/machines.json beside tools.json.
///
/// It replaces the single default machine that `AppDefaults` used to keep in UserDefaults. The first time it's
/// read, it starts from that saved default, so nothing changes for the user. The UserDefaults copy is still
/// written, so an older build keeps finding the same default machine.
enum MachineLibraryFile {
    static let legacyDefaultsKey = "defaultMachine"

    static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NativeCAM", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("machines.json")
    }

    /// The library, and whether it may be written back. A file this build can't read (say, from a newer
    /// NativeCAM) is left alone: the app works from the old default machine instead.
    static func load() -> (library: MachineLibrary, writable: Bool) {
        if let data = try? Data(contentsOf: url) {
            if let lib = try? MachineLibrary.decode(data) { return (lib, true) }
            return (.starter(with: legacyDefault ?? .avidPRO6060), false)
        }
        let lib = MachineLibrary.starter(with: legacyDefault ?? .avidPRO6060)
        save(lib)
        return (lib, true)
    }

    static func save(_ library: MachineLibrary) {
        guard let data = try? library.encoded() else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// The default machine as a new document should store it: a full copy stamped with its library entry.
    static var defaultMachine: MachineProfile {
        load().library.defaultMachine?.snapshot ?? .avidPRO6060
    }

    /// Saves a change to the default machine (from Settings), bumping its revision.
    static func setDefaultMachine(_ profile: MachineProfile) {
        var (lib, writable) = load()
        if writable, let id = lib.defaultMachine?.id {
            lib.update(id, profile: profile)
            save(lib)
        }
        UserDefaults.standard.set(try? JSONEncoder().encode(profile.unstampedForOlderBuilds), forKey: legacyDefaultsKey)
    }

    // MARK: Library management

    static var library: MachineLibrary { load().library }

    /// Adds a machine (replacing one with the same ID), optionally making it the default for new documents.
    static func add(_ setup: MachineSetup, makeDefault: Bool) {
        var (lib, writable) = load()
        guard writable else { return }
        if let i = lib.machines.firstIndex(where: { $0.id == setup.id }) {
            var replaced = setup
            replaced.revision = lib.machines[i].revision + 1
            lib.machines[i] = replaced
        } else {
            lib.machines.append(setup)
        }
        if makeDefault { lib.defaultID = setup.id }
        save(lib)
        if makeDefault {
            UserDefaults.standard.set(try? JSONEncoder().encode(setup.profile.unstampedForOlderBuilds), forKey: legacyDefaultsKey)
        }
    }

    static func remove(_ id: String) {
        var (lib, writable) = load()
        guard writable, lib.machines.count > 1 else { return }
        lib.machines.removeAll { $0.id == id }
        if lib.defaultID == id { lib.defaultID = lib.machines.first?.id }
        save(lib)
    }

    /// Replaces one entry's profile, bumping its revision (Calibration Programs' Apply). Returns the entry as saved.
    @discardableResult
    static func update(_ id: String, profile: MachineProfile) -> MachineSetup? {
        var (lib, writable) = load()
        guard writable, lib.update(id, profile: profile), let saved = lib.machine(id: id) else { return nil }
        save(lib)
        if lib.defaultID == id {
            UserDefaults.standard.set(try? JSONEncoder().encode(saved.profile.unstampedForOlderBuilds), forKey: legacyDefaultsKey)
        }
        return saved
    }

    static func setDefault(_ id: String) {
        var (lib, writable) = load()
        guard writable, let setup = lib.machine(id: id) else { return }
        lib.defaultID = id
        save(lib)
        UserDefaults.standard.set(try? JSONEncoder().encode(setup.profile.unstampedForOlderBuilds), forKey: legacyDefaultsKey)
    }

    private static var legacyDefault: MachineProfile? {
        UserDefaults.standard.data(forKey: legacyDefaultsKey).flatMap { try? JSONDecoder().decode(MachineProfile.self, from: $0) }
    }
}

private extension MachineProfile {
    /// What older builds expect in UserDefaults: the profile without its library stamp.
    var unstampedForOlderBuilds: MachineProfile {
        var p = self
        p.libraryID = nil
        p.libraryRevision = nil
        return p
    }
}
