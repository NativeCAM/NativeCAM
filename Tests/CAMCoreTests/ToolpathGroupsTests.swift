import Foundation
import Testing
@testable import CAMCore

/// #174: toolpath groups, hiding toolpaths in the view, and exporting part of a job (`JobSubset`). The inputs are in
/// `Fixtures/toolpath-groups` (see its README), the saved project is `projects/toolpath-groups-v1.nativecam`, and the
/// goldens are `golden/toolpath-groups-*.tap`. #150's signed run-time difference is at the end.
struct ToolpathGroupsTests {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures").appendingPathComponent("toolpath-groups")

    /// Loads a fixture. Update mode creates a missing one from `make`, but never replaces one.
    static func fixture(_ name: String, make: () -> Project) throws -> Project {
        let url = fixtures.appendingPathComponent(name + ".nativecam")
        if GoldenPostTests.updating, !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
            try make().encoded().write(to: url)
        }
        return try Project.decode(Data(contentsOf: url))
    }

    static func gid(_ n: Int) -> UUID { UUID(uuidString: String(format: "6E0C0000-0000-4000-8000-%012d", n))! }

    /// The demo sign with its toolpaths arranged by name: a string is an ungrouped toolpath, a `(name, [toolpaths])` a group.
    static func sign(_ name: String, _ layout: [Any], hidden: Set<String> = [], disabled: Set<String> = [], collapsed: Set<String> = []) -> Project {
        var p = Project.demoSign()
        p.name = name
        let byName = Dictionary(p.operations.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var ops: [CAMOperation] = []
        var groups: [ToolpathGroup] = []
        for item in layout {
            if let op = item as? String {
                ops.append(byName[op]!)
            } else if let (group, members) = item as? (String, [String]) {
                let g = ToolpathGroup(id: gid(groups.count + 1), name: group, isCollapsed: collapsed.contains(group) ? true : nil)
                groups.append(g)
                for m in members {
                    var op = byName[m]!
                    op.groupID = g.id
                    ops.append(op)
                }
            }
        }
        for i in ops.indices {
            if hidden.contains(ops[i].name) { ops[i].hidden = true }
            if disabled.contains(ops[i].name) { ops[i].enabled = false }
        }
        p.toolpathGroups = groups
        p.operations = ops
        return p
    }

    /// "Clear" (the plaque's pocket), then "Finish" (the title's V-carve, folded), then the drill (hidden) and the cut-out,
    /// ungrouped.
    static func grouped() -> Project {
        sign("Grouped sign", [("Clear", ["Pocket plaque"]), ("Finish", ["V-carve title"]), "Drill mounting holes", "Cut out sign"],
             hidden: ["Drill mounting holes"], collapsed: ["Finish"])
    }

    /// The project without groups or hiding, as an older build reads it.
    static func stripped(_ p: Project) -> Project {
        var s = p
        s.toolpathGroups = []
        var ops = s.operations
        for i in ops.indices {
            ops[i].groupID = nil
            ops[i].hidden = nil
        }
        s.operations = ops
        return s
    }

    static func subset(_ p: Project, _ request: JobSubset.Request) throws -> JobSubset.Output {
        try JobSubset.make(p, job: CAMEngine.generate(p), request: request, date: GoldenPostTests.date)
    }

    static func golden(_ gcode: String, _ name: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        try GoldenPostTests.check(RestartTests.pinned(gcode).data(using: .ascii, allowLossyConversion: true)!, golden: name,
                                  sourceLocation: sourceLocation)
    }

    static func lines(_ gcode: String) -> [String] { RestartTests.lines(gcode) }

    /// A toolpath's lines in a file, from its "(Toolpath: name" comment to the next tool change or the program's end,
    /// less the rapids after its last cut (the retract before the change, or the park).
    static func section(_ name: String, in gcode: String) -> [String] {
        let l = lines(gcode)
        guard let start = l.firstIndex(where: { $0.hasPrefix("(Toolpath: \(name) ") }) else { return [] }
        var end = l[start...].dropFirst().firstIndex { $0.hasPrefix("(Change to Tool") || $0.hasPrefix("(Toolpath:") || $0 == "M05" || $0 == "M09" } ?? l.count
        while end > start, l[end - 1].hasPrefix("G00") { end -= 1 }
        return Array(l[start..<end])
    }

    static func groupNames(_ p: Project) -> [String?] {
        p.operations.map { op in op.groupID.flatMap { p.toolpathGroup(id: $0)?.name } }
    }

    // MARK: The saved project

    /// Groups, hiding and a folded group change no cut: the project saves as the format it had (1, the demo sign's),
    /// reads back the same, and posts the same bytes as without them, which is what an older build cuts.
    @Test func savedProjectKeepsItsFormatAndCutsAsWithoutGroups() throws {
        let p = try GoldenPostTests.savedProject("toolpath-groups-v1") { Self.grouped() }
        #expect(p.formatVersion == 1)
        #expect(p.toolpathGroups.map(\.name) == ["Clear", "Finish"])
        #expect(p.toolpathGroups[1].collapsed && !p.toolpathGroups[0].collapsed)
        #expect(Self.groupNames(p) == ["Clear", "Finish", nil, nil])
        #expect(p.operations.map(\.isHidden) == [false, false, true, false])
        #expect(try Project.decode(p.encoded()) == p)
        #expect(Self.stripped(p).formatVersion == p.formatVersion)
        let posted = GoldenPostTests.post(p)
        #expect(posted == GoldenPostTests.post(Self.stripped(p)))
        try GoldenPostTests.check(posted, golden: "decoded-toolpath-groups-v1")
        // The keys are only written when they aren't the default.
        let plain = String(decoding: try Self.stripped(p).encoded(), as: UTF8.self)
        #expect(!plain.contains("toolpathGroups") && !plain.contains("groupID") && !plain.contains("\"hidden\""))
    }

    // MARK: Export Group…

    /// The second group alone: the full job cut down. It opens with its own tool change, its header says what it assumes
    /// was cut, and the V-carve's lines are exactly the full file's.
    @Test func groupExportIsTheFullFilesMovesForThoseToolpaths() throws {
        let p = try GoldenPostTests.savedProject("toolpath-groups-v1") { Self.grouped() }
        let finish = try #require(p.toolpathGroups.first { $0.name == "Finish" })
        let out = try Self.subset(p, try #require(JobSubset.Request.group(finish.id, in: p)))
        #expect(out.files.count == 1)
        let gcode = out.files[0].gcode
        #expect(out.included.map(\.name) == ["V-carve title"])
        #expect(out.assumedCut.map(\.name) == ["Pocket plaque"])
        #expect(out.offersFullRetract)
        let l = Self.lines(gcode)
        #expect(l.first == "(PART OF Grouped sign: group 'Finish')")
        #expect(l.contains("(Assumes already cut: 1 Pocket plaque {T1})"))
        #expect(l.filter { $0.hasSuffix("M6") } == ["T5M6"])
        #expect(out.issues.contains { $0.severity == .warning && $0.message.hasPrefix("This file assumes these were already cut: 1 Pocket plaque (T1).") })
        #expect(!out.issues.contains { $0.severity == .error }, "\(out.issues.map(\.text))")
        let full = try #require(JobExport.files(p, job: CAMEngine.generate(p), date: GoldenPostTests.date)).files[0].gcode
        let mine = Self.section("V-carve title", in: gcode)
        #expect(mine.count > 50)
        #expect(mine == Self.section("V-carve title", in: full))
        // The toolpaths themselves are the full job's.
        let job = CAMEngine.generate(p)
        #expect(out.job.toolpaths.map(\.motions) == job.toolpaths.filter { $0.name == "V-carve title" }.map(\.motions))
        try Self.golden(gcode, "toolpath-groups-export-finish")
    }

    /// A group at the start of the job assumes nothing and offers no full retract.
    @Test func theFirstGroupAssumesNothing() throws {
        let p = try GoldenPostTests.savedProject("toolpath-groups-v1") { Self.grouped() }
        let out = try Self.subset(p, try #require(JobSubset.Request.group(p.toolpathGroups[0].id, in: p)))
        #expect(out.assumedCut.isEmpty && !out.offersFullRetract)
        #expect(out.header.contains("Starts at the job's first toolpath"))
        #expect(!out.issues.contains { $0.severity != .info }, "\(out.issues.map(\.text))")
    }

    /// The second group alone, after the group that clears the pocket: a rest pass resting on the first group's pocket,
    /// then the pocket taken deeper with the same bit, whose links rapid down to the floor the first pocket cleared. It
    /// warns that it assumes that was cut and that the rest pass's reference isn't in the file. With "Retract fully
    /// between cuts" the job is generated again with full retracts, and no rapid goes below the material top.
    @Test func restGroupExportWithAndWithoutFullRetract() throws {
        let p = try Self.fixture("rest-across-groups") {
            var p = RestFromEarlierTests.project(units: .inch)
            p.name = "Rest across groups"
            p.toolpathGroups = [ToolpathGroup(id: Self.gid(1), name: "Rough"), ToolpathGroup(id: Self.gid(2), name: "Rest")]
            var ops = p.operations
            ops[0].groupID = Self.gid(1)
            ops[1].groupID = Self.gid(2)
            var deeper = RestFromEarlierTests.pocket(Self.gid(10), "Deepen 1/4\"", tool: ops[0].tool, depth: 10)
            deeper.groupID = Self.gid(2)
            ops.append(deeper)
            p.operations = ops
            return p
        }
        let rest = try #require(JobSubset.Request.group(Self.gid(2), in: p))
        let low = try Self.subset(p, rest)
        #expect(low.assumedCut.map(\.name) == ["Pocket 1/4\""])
        #expect(low.issues.contains { $0.severity == .warning && $0.message.contains("cuts only what “Pocket 1/4\"” left, which isn't in this file") })
        func lowestRapid(_ tps: [Toolpath]) -> Double {
            var z = Double.infinity
            for tp in tps { tp.forEachMotion { _, m in if m.kind == .rapid { z = min(z, m.end.z) } } }
            return z
        }
        // The links the full job made: down into the cleared pocket.
        #expect(lowestRapid(low.job.toolpaths) < -1)
        #expect(!low.issues.contains { $0.severity == .error }, "\(low.issues.map(\.text))")
        try Self.golden(low.files[0].gcode, "toolpath-groups-export-rest")

        var retract = rest
        retract.fullRetract = true
        let full = try Self.subset(p, retract)
        #expect(full.project.stock.retract == .full && p.stock.retract != .full)
        #expect(lowestRapid(full.job.toolpaths) >= -1e-9)
        #expect(full.issues.contains { $0.severity == .info && $0.message.contains("retracts fully between cuts") })
        #expect(Self.lines(full.files[0].gcode).contains("(Retracts fully between cuts)"))
        #expect(!full.issues.contains { $0.severity == .error }, "\(full.issues.map(\.text))")
        try Self.golden(full.files[0].gcode, "toolpath-groups-export-rest-full-retract")
    }

    /// Hidden is display only: a hidden toolpath still generates, simulates, exports and checks; the file is the same.
    @Test func hiddenToolpathsAreStillCutSimulatedAndExported() throws {
        let p = try Self.fixture("hidden-included") {
            Self.sign("Hidden but included", ["V-carve title", "Pocket plaque", "Drill mounting holes", "Cut out sign"],
                      hidden: ["Pocket plaque", "Cut out sign"])
        }
        #expect(p.operations.filter(\.isHidden).map(\.name) == ["Pocket plaque", "Cut out sign"])
        let job = CAMEngine.generate(p)
        let plain = CAMEngine.generate(Self.stripped(p))
        #expect(job.toolpaths.map(\.motions) == plain.toolpaths.map(\.motions))
        #expect(job.issues.map(\.message) == plain.issues.map(\.message))
        let files = try #require(JobExport.files(p, job: job, date: GoldenPostTests.date))
        let exported = Set(files.files.flatMap(\.toolpaths).map(\.sourceOperationID))
        #expect(p.operations.filter(\.isHidden).allSatisfy { exported.contains($0.id) })
        let session = SimulationSession(toolpaths: job.toolpaths, stock: p.stock, rapidRate: p.machine.rapidRateForEstimates, cellSize: 1)
        let simulated = Set(session.timeline.toolpaths.map(\.sourceOperationID))
        #expect(p.operations.allSatisfy { simulated.contains($0.id) })
        #expect(GoldenPostTests.post(p) == GoldenPostTests.post(Self.stripped(p)))
        // Hidden members of an exported selection are in the file too.
        let out = try Self.subset(p, .toolpaths(Set(p.operations.filter(\.isHidden).map(\.id)), in: p))
        #expect(out.included.map(\.name) == ["Pocket plaque", "Cut out sign"])
    }

    /// The group checkbox turns each member's "Include in output" off: the checks see them exactly as toolpaths turned
    /// off one by one (round 3's note on a turned-off group holding work before a cut-out).
    @Test func aGroupTurnedOffIsItsMembersTurnedOff() throws {
        let p = try Self.fixture("group-off") {
            var p = Self.sign("Group turned off", [("Inside", ["V-carve title", "Pocket plaque"]), "Drill mounting holes", "Cut out sign"])
            p.setGroupIncluded(Self.gid(1), false)
            return p
        }
        #expect(p.inclusion(ofGroup: Self.gid(1)) == .none)
        #expect(p.operations.filter { !$0.enabled }.map(\.name) == ["V-carve title", "Pocket plaque"])
        let byHand = Self.stripped(p)
        #expect(byHand.operations.filter { !$0.enabled }.count == 2)
        let job = CAMEngine.generate(p), plain = CAMEngine.generate(byHand)
        #expect(job.issues.map(\.message) == plain.issues.map(\.message))
        #expect(job.toolpaths.map(\.motions) == plain.toolpaths.map(\.motions))
        // Exporting the turned-off group is refused; one member back on makes the checkbox mixed.
        let off = try #require(JobSubset.Request.group(Self.gid(1), in: p))
        #expect(throws: JobSubset.Refusal.self) { try Self.subset(p, off) }
        var mixed = p
        mixed.operations[0].enabled = true
        #expect(mixed.inclusion(ofGroup: Self.gid(1)) == .mixed)
        let out = try Self.subset(mixed, try #require(JobSubset.Request.group(Self.gid(1), in: mixed)))
        #expect(out.included.map(\.name) == ["V-carve title"] && out.skipped.map(\.name) == ["Pocket plaque"])
        #expect(out.issues.contains { $0.message == "Left out, not included in the output: Pocket plaque." })
    }

    // MARK: Optimize Run Order

    /// The cut-out's group runs before the group with the work inside the sign: Optimize keeps the groups in the user's
    /// order, and the checks say to move the group, without reordering across it.
    @Test func aDependencyAcrossGroupsIsACheckNotAMove() throws {
        let p = try Self.fixture("cross-group") {
            Self.sign("Cross-group dependency", [("Outline", ["Cut out sign"]), ("Detail", ["V-carve title", "Pocket plaque"]),
                                                 "Drill mounting holes"])
        }
        let r = OperationScheduler.optimize(p)
        var q = p
        q.applyRunOrder(r.order)
        #expect(Self.groupNames(q) == Self.groupNames(p))
        #expect(q.operations.first?.name == "Cut out sign")
        let cut = try #require(p.operations.first { $0.name == "Cut out sign" })
        let before = Set(r.crossGroup.filter { $0.mustPrecede == cut.id }.compactMap { l in p.operations.first { $0.id == l.operation }?.name })
        #expect(before.isSuperset(of: ["V-carve title", "Pocket plaque", "Drill mounting holes"]))
        #expect(r.outOfOrder.isEmpty)
        let job = CAMEngine.generate(p)
        let warnings = job.issues.filter { $0.message.contains("move group “Detail” before group “Outline”") }
        #expect(warnings.map(\.operation) == ["V-carve title", "Pocket plaque"], "\(job.issues.map(\.message))")
        #expect(job.issues.contains { $0.operation == "Drill mounting holes"
                && $0.message.contains("move the ungrouped toolpaths before group “Outline”") })
    }

    /// Inside a group Optimize still saves tool changes; the groups stay whole and in order. Without groups it's as before.
    @Test func optimizeReordersInsideGroupsAndKeepsThemWhole() throws {
        let p = try Self.fixture("optimize-within") {
            Self.sign("Optimize inside groups", [("Lettering", ["Drill mounting holes", "V-carve title", "Pocket plaque"]), ("Cut", ["Cut out sign"])])
        }
        let r = OperationScheduler.optimize(p)
        var q = p
        q.applyRunOrder(r.order)
        #expect(Self.groupNames(q) == ["Lettering", "Lettering", "Lettering", "Cut"])
        #expect(r.crossGroup.isEmpty)
        #expect(r.toolChangesAfter <= r.toolChangesBefore)
        #expect(OperationScheduler.optimize(Self.stripped(p)).crossGroup.isEmpty)
        // A turned-off member keeps its place in its group.
        var off = p
        off.operations[0].enabled = false
        var o = off
        o.applyRunOrder(OperationScheduler.optimize(off).order)
        #expect(Self.groupNames(o) == ["Lettering", "Lettering", "Lettering", "Cut"])
    }

    // MARK: Keeping groups whole

    @Test func normalizeGroupsPullsStraysBackAndDropsWhatsEmpty() throws {
        var p = Self.grouped()
        let clear = p.toolpathGroups[0].id
        // A stray member (the cut-out tagged "Clear" at the end) is pulled back next to the group's first member.
        var ops = p.operations
        ops[3].groupID = clear
        p.operations = ops
        #expect(p.operations.map(\.name) == ["Pocket plaque", "Cut out sign", "V-carve title", "Drill mounting holes"])
        // A dangling id is cleared; a group with no members goes.
        p.operations[2].groupID = UUID()
        p.toolpathGroups.append(ToolpathGroup(name: "Empty"))
        p.normalizeGroups()
        #expect(p.operations[2].groupID == nil)
        #expect(p.toolpathGroups.map(\.name) == ["Clear"])
        // The groups are listed in run order.
        var q = Self.grouped()
        q.toolpathGroups.reverse()
        q.normalizeGroups()
        #expect(q.toolpathGroups.map(\.name) == ["Clear", "Finish"])
    }

    @Test func groupingMovingAndUngrouping() throws {
        var p = Self.sign("Edits", ["V-carve title", "Pocket plaque", "Drill mounting holes", "Cut out sign"])
        let ids = p.operations.map(\.id)
        // Group the first and third: they come together at the first one's place.
        let gMade = p.groupOperations([ids[0], ids[2]], name: "Holes and title")
        let g = try #require(gMade)
        #expect(p.operations.map(\.name) == ["V-carve title", "Drill mounting holes", "Pocket plaque", "Cut out sign"])
        #expect(p.toolpathGroups.map(\.name) == ["Holes and title"])
        // Move the cut-out in, then out again: it goes to the group's end, then just after it.
        p.moveOperations([ids[3]], toGroup: g)
        #expect(p.operations.map(\.name) == ["V-carve title", "Drill mounting holes", "Cut out sign", "Pocket plaque"])
        p.removeFromGroup([ids[3]])
        #expect(p.operations.map(\.name) == ["V-carve title", "Drill mounting holes", "Cut out sign", "Pocket plaque"])
        #expect(p.operations[2].groupID == nil)
        // Duplicate: a copy of the group, with new ids, just after it.
        let copyMade = p.duplicateGroup(g)
        let copy = try #require(copyMade)
        #expect(p.toolpathGroups.map(\.name) == ["Holes and title", "Holes and title copy"])
        #expect(Self.groupNames(p) == ["Holes and title", "Holes and title", "Holes and title copy", "Holes and title copy", nil, nil])
        #expect(Set(p.operations.map(\.id)).count == 6)
        // Delete the copy with its toolpaths; ungroup the first, keeping them in place.
        p.deleteGroup(copy, keepToolpaths: false)
        #expect(p.operations.count == 4)
        p.ungroup(g)
        #expect(p.toolpathGroups.isEmpty && p.operations.allSatisfy { $0.groupID == nil })
        #expect(p.operations.map(\.name) == ["V-carve title", "Drill mounting holes", "Cut out sign", "Pocket plaque"])
        // Deleting a group but keeping its toolpaths ungroups them.
        let hMade = p.groupOperations([ids[1]])
        let h = try #require(hMade)
        #expect(p.toolpathGroup(id: h)?.name == "Group 1")
        p.deleteGroup(h, keepToolpaths: true)
        #expect(p.operations.count == 4 && p.toolpathGroups.isEmpty)
        // Deleting a group's last member drops the group.
        let kMade = p.groupOperations([ids[1]])
        let k = try #require(kMade)
        p.operations.removeAll { $0.id == ids[1] }
        p.normalizeGroups()
        #expect(p.toolpathGroup(id: k) == nil)
    }

    /// The sidebar's drag: toolpaths join the group of the rows they land among; a header moves its whole group, never
    /// into another; a folded group moves as one row.
    @Test func draggingRowsKeepsGroupsWhole() throws {
        var p = Self.sign("Drag", [("A", ["V-carve title", "Pocket plaque"]), "Drill mounting holes", ("B", ["Cut out sign"])])
        #expect(p.runOrderRows().count == 6)  // A, V, P, D, B, C
        // Drop the drill (row 3) just under A's header (row 1): it joins A as its first member.
        p.moveRows(fromOffsets: [3], toOffset: 1)
        #expect(p.operations.map(\.name) == ["Drill mounting holes", "V-carve title", "Pocket plaque", "Cut out sign"])
        #expect(Self.groupNames(p) == ["A", "A", "A", "B"])
        // Drop the cut-out (row 5) between A's members: it leaves B (left empty, so B goes) and joins A.
        p.moveRows(fromOffsets: [5], toOffset: 2)
        #expect(Self.groupNames(p) == ["A", "A", "A", "A"])
        #expect(p.toolpathGroups.map(\.name) == ["A"])
        #expect(p.operations.map(\.name) == ["Drill mounting holes", "Cut out sign", "V-carve title", "Pocket plaque"])
        // Drag the last member below the group's end: it stays in its group (it was in it already).
        let rows = p.runOrderRows()
        p.moveRows(fromOffsets: [rows.count - 1], toOffset: rows.count)
        #expect(Self.groupNames(p) == ["A", "A", "A", "A"])

        var q = Self.sign("Drag groups", [("A", ["V-carve title", "Pocket plaque"]), ("B", ["Drill mounting holes", "Cut out sign"])])
        // Drag B's header (row 3) to the top: the whole group moves.
        q.moveRows(fromOffsets: [3], toOffset: 0)
        #expect(q.operations.map(\.name) == ["Drill mounting holes", "Cut out sign", "V-carve title", "Pocket plaque"])
        #expect(q.toolpathGroups.map(\.name) == ["B", "A"])
        // Drag A's header (row 3) into the middle of B: it goes after B, not into it.
        q.moveRows(fromOffsets: [3], toOffset: 2)
        #expect(Self.groupNames(q) == ["B", "B", "A", "A"])
        // Fold A, then drag a toolpath of B below it: it leaves B and goes after A's members, ungrouped.
        q.setGroupCollapsed(q.toolpathGroups[1].id, true)
        #expect(q.runOrderRows().count == 4)  // B, D, C, A
        q.moveRows(fromOffsets: [1], toOffset: 4)
        #expect(q.operations.map(\.name) == ["Cut out sign", "V-carve title", "Pocket plaque", "Drill mounting holes"])
        #expect(Self.groupNames(q) == ["B", "A", "A", nil])
    }

    /// A template keeps its toolpaths' groups; applying it twice makes two sets, with new ids.
    @Test func templatesKeepGroups() throws {
        let source = Self.grouped()
        let template = ToolpathTemplate(name: "Grouped", project: source, includeJobSetup: false)
        #expect(template.toolpathGroups.map(\.name) == ["Clear", "Finish"])
        #expect(template.formatVersion == 1)
        let reread = try ToolpathTemplate.decode(template.encoded())
        #expect(reread.toolpathGroups == template.toolpathGroups)
        var target = Project.demoSign()
        target.operations = []
        let once = reread.apply(to: target, library: .starter).project
        let twice = reread.apply(to: once, library: .starter).project
        #expect(twice.toolpathGroups.map(\.name) == ["Clear", "Finish", "Clear", "Finish"])
        #expect(Set(twice.toolpathGroups.map(\.id)).count == 4)
        #expect(Set(twice.toolpathGroups.map(\.id)).isDisjoint(with: source.toolpathGroups.map(\.id)))
        #expect(Self.groupNames(twice) == ["Clear", "Finish", nil, nil, "Clear", "Finish", nil, nil])
        // Only the groups of the toolpaths saved go into a template of some of them.
        let some = ToolpathTemplate(name: "Some", project: source, operationIDs: [source.operations[0].id])
        #expect(some.toolpathGroups.map(\.name) == ["Clear"])
    }

    // MARK: Tiles, the setup sheet and the command line

    /// On a tiled job each tile's file holds only the group's toolpaths, and a tile with none of them gets no file.
    @Test func groupExportOnATiledJob() throws {
        var p = try RestartTests.fixture("tiled")
        let last = try #require(p.operations.last)
        let gMade = p.groupOperations([last.id], name: "Last")
        let g = try #require(gMade)
        let job = CAMEngine.generate(p)
        let out = try JobSubset.make(p, job: job, request: try #require(JobSubset.Request.group(g, in: p)), date: GoldenPostTests.date)
        let full = try #require(JobExport.files(p, job: job, date: GoldenPostTests.date))
        #expect(!out.files.isEmpty && out.files.count <= full.files.count)
        for file in out.files {
            #expect(file.toolpaths.allSatisfy { $0.sourceOperationID == last.id })
            #expect(file.toolpaths.contains { !$0.isEmpty })
        }
        let tilesCut = Set(job.tiling!.tiles.enumerated().filter { $0.element.contains { $0.sourceOperationID == last.id && !$0.isEmpty } }.map(\.offset))
        #expect(Set(out.files.compactMap(\.tile)) == tilesCut)
        #expect(!out.issues.contains { $0.severity == .error }, "\(out.issues.map(\.text))")
    }

    /// The setup sheet for part of a job lists the file's toolpaths in its run order, the tool to load first and what it
    /// assumes was cut.
    @Test func setupSheetForAGroup() throws {
        let p = try GoldenPostTests.savedProject("toolpath-groups-v1") { Self.grouped() }
        let out = try Self.subset(p, try #require(JobSubset.Request.group(p.toolpathGroups[1].id, in: p)))
        let html = SetupSheet.html(project: out.project, job: out.job, gcodeFile: "Grouped sign - Finish.tap", checks: out.issues,
                                   date: GoldenPostTests.date, part: out.setupSheetLines)
        #expect(html.contains("<h2>Part of the job</h2>"))
        #expect(html.contains("Load T5 60° V-Bit 1/2&quot; first.") || html.contains("Load T5 60° V-Bit 1/2\" first."))
        #expect(html.contains("It assumes these were already cut: 1 Pocket plaque (T1)."))
        let run = try #require(html.range(of: "<h2>Run order</h2>"))
        let table = String(html[run.upperBound...]).components(separatedBy: "</table>")[0]
        #expect(table.contains("V-carve title"))
        #expect(!table.contains("Pocket plaque") && !table.contains("Cut out sign") && !table.contains("Drill mounting holes"))
    }

    /// `post --group` writes "<project> - <group>.tap" by default, its golden, and the checks; `--toolpaths` takes run-order
    /// numbers and names; a group that isn't there exits 1.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: CommandLineTests.cli.path)))
    func commandLineExportsAGroup() throws {
        let dir = try CommandLineTests.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let project = dir.appendingPathComponent("Grouped sign.nativecam")
        try FileManager.default.copyItem(at: GoldenPostTests.projects.appendingPathComponent("toolpath-groups-v1.nativecam"), to: project)
        let run = try CommandLineTests.run(["post", project.path, "--group", "Finish"])
        #expect(run.status == 0, "\(run.output)")
        #expect(run.output.contains("  Assumes already cut: 1 Pocket plaque (T1)"), "\(run.output)")
        #expect(run.output.contains("[warning] Part of the job: This file assumes these were already cut"), "\(run.output)")
        let written = dir.appendingPathComponent("Grouped sign - Finish.tap")
        let gcode = try String(contentsOf: written, encoding: .ascii)
        try Self.golden(gcode, "toolpath-groups-cli-group")
        // The same file as Export Group… writes.
        let p = try Project.decode(Data(contentsOf: project))
        let app = try Self.subset(p, try #require(JobSubset.Request.group(p.toolpathGroups[1].id, in: p)))
        #expect(RestartTests.pinned(app.files[0].gcode) == RestartTests.pinned(gcode))

        let some = try CommandLineTests.run(["post", project.path, "--toolpaths", "1,Cut out sign", "--full-retract",
                                            "-o", dir.appendingPathComponent("some.tap").path, "--sheet", dir.appendingPathComponent("some.html").path])
        #expect(some.status == 0, "\(some.output)")
        #expect(some.output.contains("PART OF Grouped sign: 2 selected toolpaths"), "\(some.output)")
        #expect(some.output.contains("Retracts fully between cuts"), "\(some.output)")
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("some.html").path))
        let missing = try CommandLineTests.run(["post", project.path, "--group", "Nope"])
        #expect(missing.status == 1)
        #expect(missing.output.contains("No group “Nope” in the project; its groups are “Clear”, “Finish”"), "\(missing.output)")
    }

    // MARK: #150

    /// The difference shown against Both ways is rounded first: equal times read "0:00", with no sign.
    @Test func signedDurationDeltaHasNoSignAtZero() {
        #expect(DurationFormat.signedDelta(-0.3) == "0:00")
        #expect(DurationFormat.signedDelta(0) == "0:00")
        #expect(DurationFormat.signedDelta(0.6) == "+0:01")
        #expect(DurationFormat.signedDelta(-61.4) == "−1:01")
        #expect(DurationFormat.signedDelta(3725) == "+1:02:05")
        // The Demo Pawn's case: both estimates show 17:31.
        #expect(DurationFormat.signedDelta(1051.4.rounded() - 1051.2.rounded()) == "0:00")
        #expect(DurationFormat.duration(1051.4) == "17:31")
    }
}
