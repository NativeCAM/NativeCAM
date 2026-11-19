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
