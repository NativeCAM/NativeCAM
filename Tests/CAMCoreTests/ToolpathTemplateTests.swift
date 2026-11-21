import Foundation
import Testing
@testable import CAMCore

/// Toolpath templates: a set of toolpaths saved with their tools and settings, applied to another design.
struct ToolpathTemplateTests {
    /// The demo sign with each part on its own layer, as a template user would draw it.
    static func layeredSign() -> Project {
        var p = Project.demoSign()
        for i in p.shapes.indices {
            switch p.shapes[i].name {
            case "Sign outline": p.shapes[i].layer = "Cut Out"
            case "Title": p.shapes[i].layer = "V-Carve"
            case "Plaque pocket": p.shapes[i].layer = "Pocket"
            default: p.shapes[i].layer = "Holes"
            }
        }
        return p
    }

    static func gcode(_ p: Project) throws -> String {
        let job = CAMEngine.generate(p)
        var post = try #require(PostProcessors.post(for: p, date: GoldenPostTests.date) as? AvidMach4Post)
        post.timeZone = TimeZone(identifier: "UTC")!
        return post.post(job.toolpaths)
    }

    static func roundTrip(_ t: ToolpathTemplate) throws -> ToolpathTemplate {
        try ToolpathTemplate.decode(t.encoded())
    }

    static let quarter = ToolLibrary.starter.tool(number: 1)!

    static func profile(_ depth: DepthSettings, rule: VectorSelection? = nil, tool: Tool = quarter) -> CAMOperation {
        CAMOperation(name: "Cut out", kind: .profile(ProfileParams(depth: depth)), shapeIDs: [], tool: tool, vectorSelection: rule)
    }

    // MARK: Round trip

    @Test func savingAndApplyingToTheSameDesignPostsTheSameGCode() throws {
        let original = Self.layeredSign()
        let template = try Self.roundTrip(ToolpathTemplate(name: "Sign", project: original))
        #expect(template.operations.count == original.operations.count)
        let noShapes = template.operations.allSatisfy { $0.shapeIDs.isEmpty }
        #expect(noShapes)

        var blank = original
        blank.operations = []
        let applied = template.apply(to: blank, library: .starter)
        #expect(applied.emptyCount == 0)
        #expect(applied.newTools.isEmpty)
        #expect(applied.project.operations.map(\.name) == original.operations.map(\.name))
        #expect(applied.project.operations.map(\.shapeIDs) == original.operations.map(\.shapeIDs))

        let before = try Self.gcode(original)
        let after = try Self.gcode(applied.project)
        #expect(!before.isEmpty)
        #expect(before == after)
    }

    @Test func roundTripWithAnEmptyLibraryKeepsTheTemplatesTools() throws {
        let original = Self.layeredSign()
        let template = try Self.roundTrip(ToolpathTemplate(name: "Sign", project: original, includeJobSetup: false))
        #expect(template.jobSetup == nil)
        var blank = original
        blank.operations = []
        let applied = template.apply(to: blank, library: ToolLibrary(tools: []))
        // Not in the (empty) library: offered for adding, each once, with its own number.
        #expect(applied.newTools.map(\.number).sorted() == [1, 5])
        #expect(try Self.gcode(applied.project) == Self.gcode(original))
    }

    // MARK: Finding vectors

    @Test func toolpathsBindByLayerAndAnEmptyLayerIsWarnedAbout() throws {
        var design = Project(stock: Stock(thickness: 0.75.inch))
        design.shapes = [
            DesignShape(name: "Board", kind: .rectangle(width: 12.inch, height: 8.inch, cornerRadius: 0.5.inch), position: Vec2(8.inch, 6.inch),
                        layer: "cut out"),
            DesignShape(name: "Hole", kind: .circle(radius: 0.25.inch), position: Vec2(4.inch, 4.inch), layer: "Holes"),
        ]
        let template = ToolpathTemplate(name: "Board", operations: [
            CAMOperation(name: "Drill", kind: .drill(DrillParams(depth: 0.5.inch)), shapeIDs: [], tool: Self.quarter,
                         vectorSelection: .layers(["Holes"])),
            CAMOperation(name: "Juice groove", kind: .pocket(PocketParams(depth: DepthSettings(cutDepth: 0.125.inch))), shapeIDs: [],
                         tool: Self.quarter, vectorSelection: .layers(["Groove"])),
            Self.profile(.through(0.75.inch), rule: .layers(["Cut Out"])),
        ])
        let applied = try Self.roundTrip(template).apply(to: design, library: .starter)
        let ops = applied.project.operations
        let bound: [[UUID]] = [[design.shapes[1].id], [], [design.shapes[0].id]]
        #expect(ops.map(\.shapeIDs) == bound) // letter case doesn't matter
        #expect(applied.rows.map(\.isEmpty) == [false, true, false])
        #expect(applied.emptyCount == 1)

        // The empty one is added anyway, still bound to its layer, and Checks says why.
        #expect(ops[1].vectorSelection == .layers(["Groove"]))
        let issues = CAMEngine.generate(applied.project).issues.filter { $0.operation == "Juice groove" }
        #expect(issues.contains { $0.message.contains("No vectors on layer “Groove”") })

        // Putting a vector on that layer later binds it.
        var p = applied.project
        let groove = DesignShape(name: "Groove", kind: .rectangle(width: 10.inch, height: 6.inch, cornerRadius: 0.5.inch), position: Vec2(8.inch, 6.inch))
        p.shapes.append(groove)
        p.setLayer("Groove", of: [groove.id])
        #expect(p.operations[1].shapeIDs == [groove.id])
        #expect(!CAMEngine.generate(p).issues.contains { $0.message.contains("No vectors on layer") })
        // Moving the board off its layer drops it from the cut-out.
        p.setLayer("Spare", of: [design.shapes[0].id])
        #expect(p.operations[2].shapeIDs.isEmpty)
    }

    @Test func toolpathsBindByKindOrTheCurrentSelection() {
        let design = Project.demoSign()
        let pocket = design.shapes.first { $0.name == "Plaque pocket" }!
        let template = ToolpathTemplate(name: "Mixed", operations: [
            CAMOperation(name: "Holes", kind: .drill(DrillParams(depth: 0.5.inch)), shapeIDs: [], tool: Self.quarter, vectorSelection: .kind(.circles)),
            CAMOperation(name: "Carve", kind: .vcarve(VCarveParams()), shapeIDs: [], tool: ToolLibrary.starter.tool(number: 5)!,
                         vectorSelection: .kind(.text)),
            CAMOperation(name: "Picked", kind: .pocket(PocketParams(depth: DepthSettings(cutDepth: 0.1.inch))), shapeIDs: [],
                         tool: Self.quarter, vectorSelection: .selection),
        ])
        let applied = template.apply(to: design, library: .starter, selection: [pocket.id])
        let ops = applied.project.operations.suffix(3).map { $0 }
        #expect(ops[0].shapeIDs == design.shapes.filter { $0.name.hasPrefix("Mounting hole") }.map(\.id))
        #expect(ops[1].shapeIDs == design.shapes.filter { $0.name == "Title" }.map(\.id))
        #expect(ops[2].shapeIDs == [pocket.id])
        // A toolpath given the selection is then chosen by hand, like any other.
        #expect(ops[2].vectorSelection == nil)
        // With nothing selected it's added empty.
        let unselected = template.apply(to: design, library: .starter)
        #expect(unselected.rows.map(\.isEmpty) == [false, false, true])
    }

    @Test func savingInfersHowEachToolpathFindsItsVectors() {
        // Everything on one layer: the text and the holes are found by kind, the rest take the selection.
        let sign = Project.demoSign()
        let rules = ToolpathTemplate(name: "Sign", project: sign).operations.map(\.vectorSelection)
        let byKind: [VectorSelection?] = [.kind(.text), .selection, .kind(.circles), .selection]
        #expect(rules == byKind)
        // On their own layers, by layer.
        let layered = ToolpathTemplate(name: "Sign", project: Self.layeredSign()).operations.map(\.vectorSelection)
        let byLayer: [VectorSelection?] = [.layers(["V-Carve"]), .layers(["Pocket"]), .layers(["Holes"]), .layers(["Cut Out"])]
        #expect(layered == byLayer)
        // A 3D toolpath on a model and its outline finds both layers; rounding needs no shapes.
        var relief = Project.demoRelief()
        for i in relief.shapes.indices { relief.shapes[i].layer = relief.shapes[i].modelSpec == nil ? "Outline" : "Model" }
        let rough = ToolpathTemplate(name: "Relief", project: relief).operations[0]
        #expect(rough.vectorSelection == .layers(["Model", "Outline"]))
        // A rule set on the toolpath wins over the inferred one.
        var picked = sign
        picked.operations[1].vectorSelection = .layers(["Default"])
        #expect(ToolpathTemplate(name: "Sign", project: picked).operations[1].vectorSelection == .layers(["Default"]))
    }

    @Test func templatesLeaveOutThisDesignsCornerOverrides() {
        var sign = Self.layeredSign()
        let outline = sign.shapes[0]
        guard case var .profile(p) = sign.operations[3].kind else { Issue.record("not a profile"); return }
        p.side = .inside
        p.cornerRelief = CornerReliefSettings(overrides: [CornerOverride(shapeID: outline.id, point: Vec2(1, 1), choice: .asCut)])
        sign.operations[3].kind = .profile(p)
        guard case let .profile(saved) = ToolpathTemplate(name: "Sign", project: sign).operations[3].kind else { Issue.record("not a profile"); return }
        #expect(saved.cornerRelief != nil)
        #expect(saved.cornerRelief?.overrides == nil)
    }

    // MARK: Depths

    @Test func depthsTiedToTheThicknessFollowAThinnerBoard() throws {
        // Made on 3/4" stock: a cut-out typed as 0.77" (through), a pocket leaving 1/8", a plain 1/4" pocket and a
        // hole through.
        var source = Project(stock: Stock(thickness: 0.75.inch))
        source.shapes = [DesignShape(name: "Part", kind: .rectangle(width: 6.inch, height: 4.inch, cornerRadius: 0), position: Vec2(6.inch, 6.inch),
                                     layer: "Part")]
        let id = source.shapes[0].id
        source.operations = [
            CAMOperation(name: "Floor", kind: .pocket(PocketParams(depth: DepthSettings(cutDepth: 0, fromBottom: 0.125.inch))), shapeIDs: [id], tool: Self.quarter),
            CAMOperation(name: "Plain", kind: .pocket(PocketParams(depth: DepthSettings(cutDepth: 0.25.inch))), shapeIDs: [id], tool: Self.quarter),
            CAMOperation(name: "Hole", kind: .drill(DrillParams(depth: 0, fromBottom: -0.02.inch)), shapeIDs: [id], tool: Self.quarter),
            CAMOperation(name: "Cut out", kind: .profile(ProfileParams(depth: DepthSettings(cutDepth: 0.77.inch))), shapeIDs: [id], tool: Self.quarter),
        ]
        // Fitted on creation: thickness − 1/8", and 0.02" through.
        guard case let .pocket(floor) = source.operations[0].kind, case let .drill(hole) = source.operations[2].kind else { Issue.record("kinds"); return }
        #expect(abs(floor.depth.cutDepth - 0.625.inch) < 1e-9)
        #expect(abs(hole.depth - 0.77.inch) < 1e-9)

        let template = try Self.roundTrip(ToolpathTemplate(name: "Part", project: source))
        var thinner = source
        thinner.operations = []
        thinner.stock.thickness = 0.5.inch
        let applied = template.apply(to: thinner, library: .starter)
        func depths(_ p: Project) -> [Double] {
            p.operations.map { op in
                switch op.kind {
                case let .pocket(q): q.depth.cutDepth
                case let .profile(q): q.depth.cutDepth
                case let .drill(q): q.depth
                default: -1
                }
            }
        }
        let expected = [0.375, 0.25, 0.52, 0.52].map(\.inch)
        let got = depths(applied.project)
        let fits = zip(got, expected).allSatisfy { abs($0 - $1) < 1e-9 }
        #expect(fits, "\(got.map { $0 / 25.4 })")

        // The cut-out really stops 0.02" below the thinner board.
        let job = CAMEngine.generate(applied.project)
        let cutOut = try #require(job.toolpaths.first { $0.name == "Cut out" }?.cuttingExtents)
        #expect(abs(cutOut.min.z + 0.52.inch) < 1e-6)

        // Changing the thickness afterwards keeps them tied; the plain depth stays put.
        var thicker = applied.project
        thicker.stock.thickness = 1.inch
        let refit = depths(thicker)
        let expectedThicker = [0.875, 0.25, 1.02, 1.02].map(\.inch)
        let refits = zip(refit, expectedThicker).allSatisfy { abs($0 - $1) < 1e-9 }
        #expect(refits, "\(refit.map { $0 / 25.4 })")

        // Saved fitted, so a build that doesn't know the setting cuts the same depth.
        let reread = try JSONSerialization.jsonObject(with: thicker.encoded()) as? [String: Any]
        let ops = try #require(reread?["operations"] as? [[String: Any]])
        let kind = try #require(ops[0]["kind"] as? [String: Any])
        let pocket = try #require(kind["pocket"] as? [String: Any])
        let params = try #require(pocket["_0"] as? [String: Any])
        let depth = try #require(params["depth"] as? [String: Any])
        #expect(abs((depth["cutDepth"] as? Double ?? 0) - 0.875.inch) < 1e-9)
    }

    @Test func theTemplatesJobSetupIsUsedOnlyWhenAskedFor() throws {
        var source = Self.layeredSign()
        source.stock.zZero = .machineBed
        source.stock.clearanceHeight = 0.75.inch
        let template = try Self.roundTrip(ToolpathTemplate(name: "Sign", project: source))
        var target = Self.layeredSign()
        target.operations = []
        target.stock.thickness = 0.5.inch

        let without = template.apply(to: target, library: .starter)
        #expect(without.setupChanges.isEmpty)
        #expect(without.project.stock == target.stock)

        let with = template.apply(to: target, library: .starter, useJobSetup: true)
        #expect(with.project.stock.thickness == 0.75.inch)
        #expect(with.project.stock.zZero == .machineBed)
        #expect(with.project.stock.width == target.stock.width)
        let changed = with.setupChanges.map(\.setting)
        #expect(changed == ["Thickness", "Z zero", "Safe Z"])
        #expect(with.setupChanges.filter(\.movesZero).map(\.setting) == ["Z zero"])
        // And the cut-out goes through the template's thickness.
        guard case let .profile(cut) = with.project.operations[3].kind else { Issue.record("not a profile"); return }
        #expect(abs(cut.depth.cutDepth - 0.77.inch) < 1e-9)

        // Made for another machine: said, not changed.
        #expect(with.machineNote == nil)
        var grbl = target
        grbl.machine.model = .custom
        grbl.machine.controller = ControllerProfile(family: .grbl)
        let other = template.apply(to: grbl, library: .starter, useJobSetup: true)
        #expect(other.machineNote?.contains("PRO6060") == true)
        #expect(other.project.machine == grbl.machine)
    }

    // MARK: Tools

    @Test func toolsAreMatchedToTheLibraryByGeometry() {
        let starter = ToolLibrary.starter
        // Someone else's 1/4" upcut: another number, name and ID, its own feeds.
        var theirs = Self.quarter
        theirs.id = UUID()
        theirs.number = 7
        theirs.name = "Quarter inch two flute"
        theirs.cutting.feedRate = 150.inch
        // A bit the library doesn't have, numbered as the library's 1/4" upcut.
        var threeEighths = Self.quarter
        threeEighths.id = UUID()
        threeEighths.diameter = 0.375.inch
        threeEighths.name = "3/8\" Upcut"
        // Same size as the 1/4" upcut but a downcut, and a 60° V-bit numbered as the 90° one.
        var downcut = Self.quarter
        downcut.id = UUID()
        downcut.fluteDirection = .downcut
        var vee = starter.tool(number: 5)!
        vee.id = UUID()
        vee.number = 6

        func op(_ tool: Tool) -> CAMOperation { Self.profile(DepthSettings(cutDepth: 0.1.inch), rule: .kind(.all), tool: tool) }
        let template = ToolpathTemplate(name: "Tools", operations: [op(theirs), op(threeEighths), op(theirs), op(downcut), op(vee)])
        let applied = template.apply(to: Project(), library: starter)
        let used = applied.project.operations.map(\.tool)

        #expect(used[0].id == Self.quarter.id)
        #expect(used[0].number == 1)
        #expect(used[0].name == Self.quarter.name)
        #expect(used[0].cutting.feedRate == 150.inch) // the template's feeds
        #expect(used[2] == used[0])
        #expect(used[3].number == 3) // the library's downcut
        #expect(used[4].number == 5) // the library's 60° V-bit
        // The new bit keeps its geometry but not the number another bit has.
        #expect(used[1].diameter == 0.375.inch)
        #expect(used[1].number == 11)
        #expect(applied.newTools.map(\.id) == [threeEighths.id])

        let quarterUse = applied.tools.first { $0.tool.id == Self.quarter.id }
        #expect(quarterUse?.inLibrary == true)
        #expect(quarterUse?.feedsDiffer == true)
        #expect(quarterUse?.templateNumber == 7)
        #expect(applied.tools.count == 4)

        // A bit the project already uses (but the library doesn't) keeps the project's number.
        var project = Project()
        var mine = threeEighths
        mine.id = UUID()
        mine.number = 12
        project.operations = [op(mine)]
        let again = template.apply(to: project, library: starter)
        #expect(again.project.operations[2].tool.number == 12)
    }

    @Test func theLibraryMatchesTheSameBitOnly() {
        let lib = ToolLibrary.starter
        var v = lib.tool(number: 6)!
        v.id = UUID()
        #expect(lib.matching(v)?.number == 6)
        v.includedAngle = 45
        #expect(lib.matching(v) == nil)
        var engraving = lib.tool(number: 9)!
        engraving.id = UUID()
        engraving.tipDiameter = 0.02.inch
        #expect(lib.matching(engraving) == nil)
        var ball = lib.tool(number: 7)!
        ball.id = UUID()
        ball.fluteLength = 2.inch // lengths don't make another bit
        ball.cutting.spindleRPM = 9000
        #expect(lib.matching(ball)?.number == 7)
    }

    // MARK: File format

    @Test func aTemplateFromANewerBuildIsRefused() throws {
        let data = try ToolpathTemplate(name: "Sign", project: Self.layeredSign()).encoded()
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["type"] as? String == "NativeCAM toolpath template")
        #expect(json["formatVersion"] as? Int == 1)
        json["formatVersion"] = Project.currentFormatVersion + 1
        let newer = try JSONSerialization.data(withJSONObject: json)
        do {
            _ = try ToolpathTemplate.decode(newer)
            Issue.record("a newer template was read")
        } catch {
            #expect(error.localizedDescription.contains("newer version of NativeCAM"))
        }
        // A project file isn't a template.
        do {
            _ = try ToolpathTemplate.decode(Project.demoSign().encoded())
            Issue.record("a project was read as a template")
        } catch {
            #expect(error.localizedDescription.contains("isn't a NativeCAM toolpath template"))
        }
    }

    @Test func aTemplateNeedsTheFormatItsToolpathsNeed() throws {
        let chamfer = CAMOperation(name: "Chamfer", kind: .chamfer(ChamferParams()), shapeIDs: [], tool: ToolLibrary.starter.tool(number: 6)!,
                                   vectorSelection: .kind(.closed))
        let template = ToolpathTemplate(name: "Bevel", operations: [Self.profile(.through(0.75.inch), rule: .kind(.closed)), chamfer])
        #expect(template.formatVersion == 8)
        let json = try #require(JSONSerialization.jsonObject(with: template.encoded()) as? [String: Any])
        #expect(json["formatVersion"] as? Int == 8)
        #expect(try ToolpathTemplate.decode(template.encoded()) == template)
    }

    /// A template saved by the first build with templates (the layered demo sign's toolpaths, from `nativecam-cli
    /// template save`) keeps applying to the same toolpaths and G-code. Never regenerated: add a new one when the
    /// format changes.
    @Test func aSavedTemplateKeepsPostingTheSameGCode() throws {
        let url = GoldenPostTests.fixtures.appendingPathComponent("templates/sign-layers-v1.nativecamtemplate")
        let template = try ToolpathTemplate.decode(Data(contentsOf: url))
        #expect(template.name == "Sign blank")
        #expect(template.jobSetup?.thickness == 0.75.inch)
        let original = Self.layeredSign()
        var blank = original
        blank.operations = []
        let applied = template.apply(to: blank, library: .starter)
        #expect(applied.emptyCount == 0)
        #expect(try Self.gcode(applied.project) == Self.gcode(original))
    }

    @Test func rulesSaveCompactly() throws {
        for rule in [VectorSelection.layers(["Cut Out", "Holes"]), .kind(.text), .selection] {
            let data = try JSONEncoder().encode(rule)
            #expect(try JSONDecoder().decode(VectorSelection.self, from: data) == rule)
        }
        let layers = String(data: try JSONEncoder().encode(VectorSelection.layers(["A"])), encoding: .utf8)
        #expect(layers == #"{"layers":["A"]}"#)
    }
}
