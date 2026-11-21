import Foundation
import Testing
@testable import CAMCore

/// R1, indexed rotary: the blank turns to a fixed angle, ordinary toolpaths cut the face under the spindle, then it
/// turns to the next. The design sheet is one face; Z zero is on the rotation axis; every turn happens at safe Z,
/// over the start of the next cut.
struct RotaryIndexTests {
    static let lib = ToolLibrary.starter
    static let bar = RotaryStock(shape: .squareBar, diameter: 2.inch, length: 12.inch)
    static let pocketID = UUID(uuidString: "0A0A0000-0000-0000-0000-000000000001")!
    static let drillID = UUID(uuidString: "0A0A0000-0000-0000-0000-000000000002")!

    /// A table leg from a 2" square bar: a mortise pocket on all four faces and four radial holes, with two tools.
    static func leg(_ configure: (inout Project) -> Void = { _ in }) -> Project {
        var stock = Stock(materialName: "Maple")
        stock.setRotary(bar)
        var machine = MachineProfile.avidPRO6060
        machine.rotary = RotaryAxis(centerHeight: 4.inch)
        let mortise = DesignShape(kind: .rectangle(width: 1.inch, height: 0.75.inch, cornerRadius: 0), position: Vec2(6.inch, 1.inch))
        let t2 = lib.tool(number: 2)!
        let hole = DesignShape(kind: .circle(radius: t2.radius), position: Vec2(9.inch, 1.inch))
        let pocket = CAMOperation(id: pocketID, name: "Mortise", kind: .pocket(PocketParams(depth: DepthSettings(cutDepth: 0.25.inch))),
                                  shapeIDs: [mortise.id], tool: lib.tool(number: 1)!, indexAngles: [0, 90, 180, 270])
        let drill = CAMOperation(id: drillID, name: "Pin holes", kind: .drill(DrillParams(depth: 0.5.inch)), shapeIDs: [hole.id],
                                 tool: t2, indexAngles: [0, 90, 180, 270])
        var p = Project(name: "Leg", displayUnits: .inch, stock: stock, machine: machine, shapes: [mortise, hole],
                        operations: [pocket, drill])
        configure(&p)
        return p
    }

    func errors(_ p: Project) -> [String] { CAMEngine.generate(p).issues.filter { $0.severity == .error }.map(\.message) }
    func problems(_ issues: [GCodeCheck.Issue]) -> [String] { issues.filter { $0.severity != .info }.map(\.text) }

    // MARK: Frame

    @Test func theDesignSheetIsOneFaceWithZZeroOnTheAxis() {
        var s = Stock(clearanceHeight: 0.5.inch)
        s.setRotary(Self.bar)
        #expect(s.width == 12.inch && s.height == 2.inch && s.thickness == 1.inch && s.matchesRotaryBlank)
        // Safe Z rose to clear the bar's corners by the link safe distance.
        #expect(abs(s.clearanceHeight - (1.inch * (2.0.squareRoot() - 1) + s.safeDistance)) < 1e-9)
        #expect(s.minimumRotaryClearance == s.clearanceHeight)
        // The top of the face over the axis is work (0, 0, radius).
        #expect(s.toWork(Vec3(0, 1.inch, 0)) == Vec3(0, 0, 1.inch))
        #expect(s.toWork(Vec3(3, 1.inch - 2, -5)) == Vec3(3, -2, 1.inch - 5))
        let p = Vec3(123.4, 5.6, -7.8)
        #expect((s.fromWork(s.toWork(p)) - p).length < 1e-12)
        // Z zero is on the axis whatever the flat setting says; X zero follows the XY origin's side.
        s.zZero = .machineBed
        s.xyOrigin = .lowerRight
        #expect(s.toWork(Vec3(12.inch, 1.inch, 0)) == Vec3(0, 0, 1.inch))
        s.xyOrigin = .center
        #expect(s.originPoint == Vec2(6.inch, 1.inch))
        // A round blank only needs the safe distance.
        var round = Stock(clearanceHeight: 1)
        round.setRotary(RotaryStock(shape: .cylinder, diameter: 40, length: 200))
        #expect(round.clearanceHeight == round.safeDistance)
        // Back to flat leaves the sheet alone and the flat frame unchanged.
        round.setRotary(nil)
        #expect(round.toWork(Vec3(1, 2, -3)) == Vec3(1, 2, -3))
    }

    @Test func indexAnglesAreFormatThree() throws {
        let p = Self.leg()
        #expect(p.formatVersion == 3)
        #expect(try Project.decode(p.encoded()) == p)
        var flat = Project.demoSign()
        flat.operations[0].indexAngles = [0, 180]
        #expect(flat.formatVersion == 3)
    }

    // MARK: Toolpaths per angle

    @Test func eachAngleGetsItsOwnToolpath() throws {
        let job = CAMEngine.generate(Self.leg())
        #expect(job.issues.filter { $0.severity == .error }.isEmpty, "\(job.issues.map(\.message))")
        let tps = job.toolpaths
        #expect(tps.map(\.name) == ["Mortise @ 0°", "Mortise @ 90°", "Mortise @ 180°", "Mortise @ 270°",
                                    "Pin holes @ 0°", "Pin holes @ 90°", "Pin holes @ 180°", "Pin holes @ 270°"])
        #expect(tps.map(\.indexAngle) == [0, 90, 180, 270, 0, 90, 180, 270])
        #expect(tps.prefix(4).allSatisfy { $0.sourceOperationID == Self.pocketID })
        // The first angle keeps the operation's ID; the rest are new, stable and unique.
        #expect(tps[0].id == Self.pocketID && tps[4].id == Self.drillID)
        #expect(Set(tps.map(\.id)).count == tps.count)
        #expect(CAMEngine.generate(Self.leg()).toolpaths.map(\.id) == tps.map(\.id))
        // Every face is cut the same in its own frame.
        #expect(tps[1].motions == tps[0].motions && tps[3].motions == tps[0].motions)
        #expect(job.estimatedSeconds(toolpath: tps[2].id) != nil)
    }

    @Test func derivedIDsCantCollideWithFixtureOrSaltedIDs() {
        let fixture = (1...8).map { UUID(uuidString: String(format: "60D0E000-0000-0000-0000-%012d", $0))! }
        var salted = fixture
        for id in fixture { for s: UInt8 in 1...16 { salted.append(VCarveGenerator.deterministicID(id, salt: s)) } }
        let derived = fixture.flatMap { id in (0..<2).flatMap { role in (1..<6).map { RotaryIndex.toolpathID(operation: id, role: role, position: $0) } } }
        #expect(Set(derived).count == derived.count)
        #expect(Set(derived).isDisjoint(with: salted))
        #expect(derived.allSatisfy { $0.uuid.6 >> 4 == 8 })
    }

    @Test func eachFaceKeepsItsOwnMaterialModel() {
        // A second pocket at 90° over the same sheet area must link as if face 0 had never been cut: a shared
        // top-down model would think its material was already gone and stay down through it.
        func secondFace(first: Double?) -> Toolpath? {
            let p = Self.leg { p in
                p.operations.removeLast()
                p.operations[0].indexAngles = first.map { [$0] } ?? []
                var again = p.operations[0]
                again.id = UUID(uuidString: "0A0A0000-0000-0000-0000-000000000003")!
                again.indexAngles = [90]
                p.operations.append(again)
                if first == nil { p.operations.removeFirst() }
            }
            return CAMEngine.generate(p).toolpaths.last
        }
        let alone = secondFace(first: nil), afterFace0 = secondFace(first: 0), afterSameFace = secondFace(first: 90)
        #expect(alone?.motions == afterFace0?.motions)
        // On the same face the first cut does count.
        #expect(alone?.motions != afterSameFace?.motions)
    }

    // MARK: Job checks

    @Test func whatCantBeCutIsAnError() {
        func has(_ text: String, _ configure: (inout Project) -> Void) {
            let e = errors(Self.leg(configure))
            #expect(e.contains { $0.contains(text) }, "\(text): \(e)")
        }
        has("doesn't match the rotary blank") { $0.stock.width = 10.inch }
        has("no rotary axis set up") { $0.machine.rotary = nil }
        has("along Y only for Avid Mach4, LinuxCNC and grblHAL") { p in
            p.machine.controller = ControllerProfile(family: .centroid)
            p.machine.rotary?.alignment = .y
        }
        has("driven by A words") { $0.machine.rotary?.letter = .b }
        has("Grbl has no A axis") { $0.machine.controller = ControllerProfile(family: .grbl) }
        has("turn on Turn by hand") { $0.machine.controller = ControllerProfile(family: .fluidNC) }
        has("clear its corners") { $0.stock.clearanceHeight = 0.5.inch }
        has("keep-out") { p in p.shapes[0].keepOutHeight = 10 }
        has("same face twice") { $0.operations[0].indexAngles = [0, 360] }
        has("only be cut at multiples of 90°") { $0.operations[1].indexAngles = [0, 60, 120] }
        has("past an end of the blank") { $0.shapes[1].position = Vec2(0.02.inch, 1.inch) }
        has("3D Roughing and 3D Finishing cut flat sheets") { p in
            p.operations.append(CAMOperation(kind: .rough3D(Rough3DParams()), shapeIDs: [p.shapes[0].id], tool: Self.lib.tool(number: 1)!))
        }
        // Index angles need rotary stock.
        var flat = Project.demoSign()
        flat.operations[0].indexAngles = [0, 90]
        #expect(errors(flat).contains { $0.contains("isn't a rotary blank") })
        // A round blank indexes to any angle, and LinuxCNC can turn it.
        let round = Self.leg { p in
            p.stock.setRotary(RotaryStock(shape: .cylinder, diameter: 2.inch, length: 12.inch))
            p.operations[1].indexAngles = [0, 60, 120, 180, 240, 300]
            p.machine.model = .custom
            p.machine.controller = ControllerProfile(family: .linuxCNC)
        }
        #expect(errors(round).isEmpty, "\(errors(round))")
    }

    @Test func aRoundBlankWarnsWhereItsSurfaceFallsAway() {
        let p = Self.leg { p in
            p.stock.setRotary(RotaryStock(shape: .cylinder, diameter: 2.inch, length: 12.inch))
            p.shapes[0].kind = .rectangle(width: 1.inch, height: 1.5.inch, cornerRadius: 0)
        }
        let warnings = CAMEngine.generate(p).issues.filter { $0.severity == .warning }.map(\.message)
        #expect(warnings.contains { $0.contains("top line of the round blank") })
        // The square bar's faces are flat, so nothing to say there.
        #expect(!CAMEngine.generate(Self.leg()).issues.contains { $0.message.contains("top line") })
    }

    // MARK: V-carve

    static let carveID = UUID(uuidString: "0A0A0000-0000-0000-0000-000000000004")!

    /// The leg with a V-carved panel on every face, its flat floor cleared first with the 1/8" end mill.
    static func carvedLeg(_ configure: (inout Project) -> Void = { _ in }) -> Project {
        leg { p in
            let panel = DesignShape(kind: .rectangle(width: 1.5.inch, height: 0.6.inch, cornerRadius: 0), position: Vec2(3.inch, 1.inch))
            p.shapes.append(panel)
            p.operations.append(CAMOperation(id: carveID, name: "Panel",
                                             kind: .vcarve(VCarveParams(flatDepth: 0.1.inch, clearanceTool: lib.tool(number: 2)!)),
                                             shapeIDs: [panel.id], tool: lib.tool(number: 5)!, indexAngles: [0, 90, 180, 270]))
            configure(&p)
        }
    }

    @Test func vCarveCutsAtEachAngleWithItsClearingFirst() throws {
        let p = Self.carvedLeg()
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors, "\(job.issues.filter { $0.severity == .error }.map(\.message))")
        let carve = job.toolpaths.filter { $0.sourceOperationID == Self.carveID }
        #expect(carve.map(\.name) == ["Panel – flat clearing @ 0°", "Panel – flat clearing @ 90°", "Panel – flat clearing @ 180°",
                                      "Panel – flat clearing @ 270°", "Panel @ 0°", "Panel @ 90°", "Panel @ 180°", "Panel @ 270°"])
        // The clearing at every face, then the V-bit at every face: one tool change, not one per face.
        #expect(carve.map(\.tool.number) == [2, 2, 2, 2, 5, 5, 5, 5])
        #expect(carve.map(\.indexAngle) == [0, 90, 180, 270, 0, 90, 180, 270])
        // The first angle keeps the generator's IDs (the operation's own, and its salt-1 ID for the clearing); later
        // angles derive theirs by role, so neither can take the other's.
        #expect(carve[4].id == Self.carveID && carve[0].id == VCarveGenerator.deterministicID(Self.carveID, salt: 1))
        #expect(carve[5].id == RotaryIndex.toolpathID(operation: Self.carveID, role: 0, position: 1))
        #expect(carve[1].id == RotaryIndex.toolpathID(operation: Self.carveID, role: 1, position: 1))
        let ids = job.toolpaths.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(CAMEngine.generate(p).toolpaths.map(\.id) == ids)
        // Without the clearing, the V-bit's toolpaths keep their IDs.
        let bare = CAMEngine.generate(Self.carvedLeg { $0.operations[2].kind = .vcarve(VCarveParams()) }).toolpaths
            .filter { $0.sourceOperationID == Self.carveID }
        #expect(bare.map(\.id) == carve.suffix(4).map(\.id))
        // Every face is carved the same in its own frame.
        #expect(carve[5].motions == carve[4].motions && carve[7].motions == carve[4].motions)
        #expect(carve[1].motions == carve[0].motions)
        // It posts and reads back clean.
        let (g, tps) = avid(p)
        #expect(g.contains("(Toolpath: Panel @ 90deg  Tool: T5"))
        let issues = GCodeCheck.run(g, toolpaths: tps, project: p, dialect: .avidMach4)
        #expect(problems(issues).isEmpty, "\(problems(issues))")
    }

    @Test func aRoundBlankWarnsWhereAVCarveComesOutNarrower() {
        func warnings(height: Double) -> [JobIssue] {
            let p = Self.carvedLeg { p in
                p.stock.setRotary(RotaryStock(shape: .cylinder, diameter: 2.inch, length: 12.inch))
                p.operations.removeFirst(2)
                p.operations[0].kind = .vcarve(VCarveParams())
                p.shapes[2].kind = .rectangle(width: 1.5.inch, height: height, cornerRadius: 0)
            }
            return CAMEngine.generate(p).issues.filter { $0.severity == .warning && $0.message.contains("top line") }
        }
        let wide = warnings(height: 1.2.inch)
        #expect(wide.count == 1 && wide[0].message.contains("narrower than drawn"), "\(wide.map(\.message))")
        // A thin line of lettering only reaches as far as the V is wide, not the bit's full diameter.
        #expect(warnings(height: 0.1.inch).isEmpty)
    }

    // MARK: Posts

    func avid(_ p: Project) -> (String, [Toolpath]) {
        let tps = CAMEngine.generate(p).toolpaths
        var post = AvidMach4Post(project: p, date: GoldenPostTests.date)
        post.timeZone = TimeZone(identifier: "UTC")!
        return (post.post(tps), tps)
    }

    @Test func theBlankTurnsAtSafeZOverTheNextCut() throws {
        let p = Self.leg()
        let (g, tps) = avid(p)
        let lines = g.components(separatedBy: "\r\n")
        let safe = String(format: "G00 Z%.4f", (p.stock.thickness + p.stock.clearanceHeight) / 25.4)
        let turns = lines.indices.filter { lines[$0].hasPrefix("G00 A") }
        // One turn per face per tool (restated after the tool change), plus the unwind at the end.
        #expect(turns.map { lines[$0] } == ["G00 A0.000", "G00 A90.000", "G00 A180.000", "G00 A270.000",
                                           "G00 A0.000", "G00 A90.000", "G00 A180.000", "G00 A270.000", "G00 A0.000"])
        for i in turns.dropLast() {
            #expect(lines[i - 2] == safe, "\(lines[i - 2])")
            #expect(lines[i - 1].hasPrefix("G00 X"))
        }
        // The unwind comes after the final retract and before the park.
        let last = try #require(turns.last)
        #expect(lines[last - 1].hasPrefix("G00 Z") && lines[last + 1].hasPrefix("G00 X"))
        // It parks over the middle of the blank, away from the chuck jaws and the tailstock at its ends.
        #expect(lines[last + 1] == "G00 X6.0000 Y0.0000")
        #expect(g.contains("(Z ZERO = CENTRE OF ROTATION {Avid: Rotary tab > Z Axis Touch})"))
        #expect(!g.contains("Z zero: Material top"))
        #expect(g.contains("re-zero Z on the rotation axis"))
        // Work Z is measured from the axis: the mortise floor is 1 - 0.25 in from it.
        #expect(g.contains(" Z0.7500"))
        // The export checks pass it clean.
        let issues = GCodeCheck.run(g, toolpaths: tps, project: p, dialect: .avidMach4)
        #expect(problems(issues).isEmpty, "\(problems(issues))")
    }

    @Test func aReversedRotaryWritesTheOtherSign() {
        let (g, _) = avid(Self.leg { $0.machine.rotary?.reversed = true })
        #expect(g.contains("G00 A-90.000") && g.contains("G00 A-270.000") && !g.contains("G00 A90.000"))
    }

    @Test func flatJobsWriteNoAWords() {
        var p = Project.demoSign()
        p.machine.rotary = RotaryAxis()
        let g = AvidMach4Post(project: p, date: GoldenPostTests.date).post(CAMEngine.generate(p).toolpaths)
        #expect(!g.components(separatedBy: "\r\n").contains { $0.hasPrefix("G00 A") } && !g.contains("ROTATION"))
    }

    @Test func linuxCNCPostsAndChecksARoundBlank() throws {
        let p = Self.leg { p in
            p.stock.setRotary(RotaryStock(shape: .cylinder, diameter: 50, length: 300))
            p.shapes[0].position = Vec2(150, 25)
            p.shapes[1].position = Vec2(230, 25)
            p.operations[1].indexAngles = [0, 60, 120, 180, 240, 300]
            p.machine.model = .custom
            p.machine.controller = ControllerProfile(family: .linuxCNC)
            p.machine.outputUnits = .mm
        }
        let tps = CAMEngine.generate(p).toolpaths
        var post = try #require(PostProcessors.post(for: p, date: GoldenPostTests.date) as? GenericGCodePost)
        post.timeZone = TimeZone(identifier: "UTC")!
        let g = post.post(tps)
        #expect(g.contains("G0 A300.000") && g.contains("(Z ZERO = CENTRE OF ROTATION)"))
        let issues = GCodeCheck.run(g, toolpaths: tps, project: p, dialect: post.dialect)
        #expect(problems(issues).isEmpty, "\(problems(issues))")
    }

    // MARK: Export checks

    @Test func readBackCatchesAMissingTurn() throws {
        let p = Self.leg()
        let (g, tps) = avid(p)
        var lines = g.components(separatedBy: "\r\n")
        lines.remove(at: try #require(lines.firstIndex(of: "G00 A90.000")))
        let text = problems(GCodeCheck.run(lines.joined(separator: "\r\n"), toolpaths: tps, project: p, dialect: .avidMach4)).joined()
        #expect(text.contains("is turned to A90.000"))
    }

    @Test func turningBelowSafeZIsAnError() throws {
        let p = Self.leg()
        let (g, tps) = avid(p)
        var lines = g.components(separatedBy: "\r\n")
        // Turn the blank again in the middle of the first face, with the tool down in the mortise.
        let i = try #require(lines.firstIndex { $0.hasPrefix("G01 X") })
        lines.insert("G00 A45.000", at: i)
        let text = problems(GCodeCheck.run(lines.joined(separator: "\r\n"), toolpaths: tps, project: p, dialect: .avidMach4)).joined()
        #expect(text.contains("Turns the rotary axis below safe Z"))
        // Turning straight after a tool change, before the lift to safe Z, is caught too.
        var early = g.components(separatedBy: "\r\n")
        let change = try #require(early.firstIndex(of: "T2M6"))
        early.insert("G00 A90.000", at: change + 1)
        #expect(problems(GCodeCheck.lint(early.joined(separator: "\r\n"), project: p, dialect: .avidMach4)).joined()
            .contains("below safe Z"))
    }

    @Test func setupSheetGivesTheRotaryZeros() {
        let p = Self.leg()
        let html = SetupSheet.html(project: p, job: CAMEngine.generate(p))
        #expect(html.contains("On the rotation axis (Avid: Rotary tab ▸ Z Axis Touch), not the top of the blank"))
        #expect(html.contains("square bar, 2.000 in across, 12.000 in long"))
        #expect(html.contains("<th class=\"num\">Angle</th>") && html.contains("<td class=\"num\">270°</td>"))
        #expect(html.contains("zero Z on the rotation axis"))
        #expect(!SetupSheet.html(project: Project.demoSign(), job: CAMEngine.generate(Project.demoSign())).contains(">Angle</th>"))
    }
}
