import Foundation

/// Bringing a saved tool library up to date with the starter library, and what resetting to it would lose.
extension ToolLibrary {
    /// True for the starter library's fixed IDs (`4E415449-5645-4341-4D00-…`), which a starter tool keeps when it's
    /// copied into a library or a project.
    public static func isStarterID(_ id: UUID) -> Bool { starter.tools.contains { $0.id == id } }

    /// What Add Missing Starter Tools does to a library.
    public struct StarterAddition: Sendable {
        public struct Match: Sendable, Hashable {
            /// The starter tool that wasn't added.
            public var starter: Tool
            /// The library's tool that is the same bit (`Tool.sameGeometry`).
            public var existing: Tool
        }

        /// The tools added, numbered as they now are.
        public var added: [Tool]
        /// Starter tools left out because the library already has the same bit under its own entry.
        public var alreadyHave: [Match]
    }

    /// The starter tools this library is missing, numbered to fit it, without changing any tool it has. A starter tool
    /// is missing when its fixed ID isn't in the library and no tool there is the same bit. Each keeps its starter T
    /// number when no tool has it, otherwise takes the next after the highest in use.
    public func missingStarterTools() -> StarterAddition {
        var numbers = Set(tools.map(\.number))
        var added: [Tool] = []
        var alreadyHave: [StarterAddition.Match] = []
        for var tool in Self.starter.tools where !tools.contains(where: { $0.id == tool.id }) {
            if let same = tools.first(where: { $0.sameGeometry(as: tool) }) {
                alreadyHave.append(StarterAddition.Match(starter: tool, existing: same))
                continue
            }
            if numbers.contains(tool.number) { tool.number = (numbers.max() ?? 0) + 1 }
            numbers.insert(tool.number)
            added.append(tool)
        }
        return StarterAddition(added: added, alreadyHave: alreadyHave)
    }

    /// Adds the starter tools the library is missing (`missingStarterTools()`) after its own, and returns what it did.
    @discardableResult
    public mutating func addMissingStarterTools() -> StarterAddition {
        let addition = missingStarterTools()
        tools += addition.added
        return addition
    }

    /// What replacing this library with the starter library would do.
    public struct StarterReset: Sendable, Hashable {
        /// Tools in the library now.
        public var count: Int
        /// The user's own and imported tools, which would be removed.
        public var removed: Int
        /// Starter tools changed since they were added, which would go back to their starting values.
        public var reverted: Int
        /// Starter tools deleted from the library, which would come back.
        public var restored: Int
    }

    public var starterReset: StarterReset {
        let starter = Self.starter.tools
        let own = tools.filter { !Self.isStarterID($0.id) }.count
        let edited = tools.filter { t in starter.first { $0.id == t.id }.map { $0 != t } ?? false }.count
        let gone = starter.filter { s in !tools.contains { $0.id == s.id } }.count
        return StarterReset(count: tools.count, removed: own, reverted: edited, restored: gone)
    }

    /// Copies the library file at `url` to `url` + ".bak" (replacing an older copy), before it's overwritten.
    /// Returns the copy's URL, or nil when there's no file to copy.
    @discardableResult
    public static func backUpFile(at url: URL) throws -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }
        let backup = url.appendingPathExtension("bak")
        if fm.fileExists(atPath: backup.path) { try fm.removeItem(at: backup) }
        try fm.copyItem(at: url, to: backup)
        return backup
    }
}
