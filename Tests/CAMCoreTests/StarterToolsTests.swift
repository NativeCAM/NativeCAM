import Foundation
import Testing
@testable import CAMCore

/// Tool Library ▸ Add Missing Starter Tools and Reset to Starter Library: what's missing, how it's numbered, what a reset
/// would lose, and the backup kept before it.
struct StarterToolsTests {
    static let starter = ToolLibrary.starter
    static var halfInch: Tool { starter.tool(number: 10)! }
    static var quarter: Tool { starter.tool(number: 1)! }

    /// A library saved before the 1/2" end mill (T10) joined the starter library.
    static func beforeT10() -> ToolLibrary {
        ToolLibrary(tools: starter.tools.filter { $0.number != 10 })
    }

    @Test func aLibrarySavedBeforeT10GainsItAndNothingElseChanges() {
        var library = Self.beforeT10()
        let before = library.tools
        #expect(library.clearanceTool(for: Self.quarter) == nil) // rest machining has no larger end mill yet
        let addition = library.addMissingStarterTools()
        #expect(addition.added.map(\.id) == [Self.halfInch.id])
        #expect(addition.added.first?.number == 10)
        #expect(addition.alreadyHave.isEmpty)
        #expect(Array(library.tools.prefix(before.count)) == before)
        // A 1/4" pocket's Clear with a larger tool first now finds it.
        #expect(library.clearanceTool(for: Self.quarter)?.id == Self.halfInch.id)
    }

    @Test func aTakenStarterNumberMovesToTheNextFreeOne() {
        // The user's own T10 (a 3/8" ball nose) stays T10; the starter 1/2" end mill comes in after the highest number.
        var own = Self.starter.tool(number: 7)!
        own.id = UUID()
        own.number = 10
        own.diameter = 0.375.inch
        own.name = "3/8\" Ball Nose"
        var library = Self.beforeT10()
        library.tools.append(own)
        let addition = library.addMissingStarterTools()
        #expect(addition.added.map(\.number) == [11])
        #expect(library.tool(number: 10) == own)
    }

    @Test func aLibraryWithEveryStarterToolGetsNothing() {
        var library = Self.starter
        library.tools[0].cutting.feedRate = 150.inch // edited, still there: never touched
        let edited = library.tools[0]
        let addition = library.addMissingStarterTools()
        #expect(addition.added.isEmpty)
        #expect(addition.alreadyHave.isEmpty)
        #expect(library.tools[0] == edited)
        #expect(library.tools.count == Self.starter.tools.count)
    }

    @Test func aBitTheLibraryAlreadyHasIsNotAddedAgain() {
        // The user's own 1/2" upcut under its own entry: the starter one would be a duplicate.
        var mine = Self.halfInch
        mine.id = UUID()
        mine.number = 3
        mine.name = "Half inch upcut"
        var library = ToolLibrary(tools: [mine])
        let addition = library.addMissingStarterTools()
        #expect(!addition.added.contains { $0.id == Self.halfInch.id })
        #expect(addition.alreadyHave.map(\.starter.id) == [Self.halfInch.id])
        #expect(addition.alreadyHave.first?.existing == mine)
        // Everything else arrives, none of it on the user's T3.
        #expect(addition.added.count == Self.starter.tools.count - 1)
        #expect(library.tools.filter { $0.number == 3 }.count == 1)
        #expect(Set(library.tools.map(\.number)).count == library.tools.count)
    }

    @Test func resettingSaysWhatWouldBeLost() {
        var library = Self.starter
        library.tools.removeAll { $0.number == 9 } // a starter bit deleted
        library.tools[1].name = "My 1/8\"" // a starter bit edited
        var own = Self.quarter
        own.id = UUID()
        own.number = 20
        library.tools += [own, { var t = own; t.id = UUID(); t.number = 21; return t }()]
        let reset = library.starterReset
        #expect(reset == ToolLibrary.StarterReset(count: 11, removed: 2, reverted: 1, restored: 1))
        #expect(Self.starter.starterReset == ToolLibrary.StarterReset(count: 10, removed: 0, reverted: 0, restored: 0))
    }

    @Test func theLibraryFileIsBackedUpBeforeItsReplaced() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("StarterToolsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("tools.json")
        // Nothing saved yet: nothing to keep.
        #expect(try ToolLibrary.backUpFile(at: file) == nil)

        try Self.beforeT10().encoded().write(to: file)
        let backup = try #require(try ToolLibrary.backUpFile(at: file))
        #expect(backup.lastPathComponent == "tools.json.bak")
        #expect(try ToolLibrary.decode(Data(contentsOf: backup)) == Self.beforeT10())

        // One level: the next backup replaces it.
        try Self.starter.encoded().write(to: file)
        try ToolLibrary.backUpFile(at: file)
        #expect(try ToolLibrary.decode(Data(contentsOf: backup)) == Self.starter)
    }
}
