import Foundation
import Testing
@testable import CAMCore

/// Toolpath templates' size filter (circles by diameter, closed shapes by bounding box) and the choice a template
/// whose layers the design doesn't have offers: create them, or skip those toolpaths (#94).
struct TemplateFilterTests {
    static let fixtures = GoldenPostTests.fixtures
    static let edgeCases = fixtures.appendingPathComponent("template-filters")
    static let quarter = ToolLibrary.starter.tool(number: 1)!
    static let vBit = ToolLibrary.starter.tool(number: 5)!

    static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "7E3F0000-0000-4000-8094-%012d", n))! }

    static func hole(_ diameter: Double, at p: Vec2, id n: Int? = nil, layer: String = "Default") -> DesignShape {
        DesignShape(id: n.map(id) ?? UUID(), name: "Hole \(diameter) mm", kind: .circle(radius: diameter / 2), position: p, layer: layer)
    }

    static func op(_ name: String, _ kind: OperationKind, rule: VectorSelection?, tool: Tool = quarter, id n: Int? = nil) -> CAMOperation {
        CAMOperation(id: n.map(id) ?? UUID(), name: name, kind: kind, shapeIDs: [], tool: tool, vectorSelection: rule)
    }

    static func drill(_ name: String = "Drill 8 mm", rule: VectorSelection?, id n: Int? = nil) -> CAMOperation {
        op(name, .drill(DrillParams(depth: 12)), rule: rule, id: n)
    }

    /// 18 mm material, 330 × 230 mm, in millimetres, on Avid's Mach4 profile.
    static func mmProject(_ name: String, shapes: [DesignShape] = [], ops: [CAMOperation] = []) -> Project {
        Project(name: name, displayUnits: .mm, stock: Stock(width: 330, height: 230, thickness: 18), machine: .avidPRO6060,
                shapes: shapes, operations: ops)
    }

    /// `mixed_holes_mm.dxf` imported as File ▸ Import does: one shape on layer "Default" holding a 300 × 200 mm panel,
    /// four 8 mm holes, a 7.9 mm and a 6 mm hole, two 10 mm holes and a 30 mm circle.
    static func importedPanel(id n: Int? = nil) throws -> Project {
        let result = try DXFImportTests.load("mixed_holes_mm")
        var p = mmProject("Panel")
        p.shapes = result.shapes(name: "mixed_holes_mm", stock: p.stock)
        if let n { p.shapes[0].id = id(n) }
        return p
    }

    static let eightMM = SizeFilter.circles(7.5, 8.5)

    static func template(_ name: String, make: () -> ToolpathTemplate) throws -> ToolpathTemplate {
        let url = fixtures.appendingPathComponent("templates/\(name).nativecamtemplate")
        if GoldenPostTests.updating, !FileManager.default.fileExists(atPath: url.path) {
            try make().encoded().write(to: url)
        }
        return try ToolpathTemplate.decode(Data(contentsOf: url))
    }

    static func edgeCase(_ name: String, make: () -> Project) throws -> Project {
        let url = edgeCases.appendingPathComponent(name + ".nativecam")
        if GoldenPostTests.updating, !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: edgeCases, withIntermediateDirectories: true)
            try make().encoded().write(to: url)
        }
        return try Project.decode(Data(contentsOf: url))
    }

    static func holeCount(_ p: Project, _ op: CAMOperation) -> Int {
        DrillGenerator.holeCentres(p.shapes(for: op), tolerance: 0.01).count
    }

    static func checkGolden(_ p: Project, _ name: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors, "\(job.issues.map(\.message))", sourceLocation: sourceLocation)
        let data = GoldenPostTests.post(p, job.toolpaths)
        try GoldenPostTests.check(data, golden: name, sourceLocation: sourceLocation)
        let issues = GCodeCheck.run(String(decoding: data, as: UTF8.self), toolpaths: job.toolpaths, project: p, dialect: .avidMach4)
        #expect(issues.filter { $0.severity != .info }.isEmpty, "\(issues.map(\.text))", sourceLocation: sourceLocation)
    }

    // MARK: Size filter

    /// The brief's case: "circles 7.5–8.5 mm → drill" on a design with 8 mm and 10 mm holes drills only the 8 mm ones.
    @Test func circlesOfOneSizeAreTheOnlyOnesDrilled() throws {
        let design = Self.mmProject("Holes", shapes: [
            Self.hole(8, at: Vec2(40, 40)), Self.hole(10, at: Vec2(80, 40)), Self.hole(8, at: Vec2(120, 40)), Self.hole(10, at: Vec2(160, 40)),
        ])
        let template = ToolpathTemplate(name: "Holes", operations: [Self.drill(rule: .kind(.circles, size: Self.eightMM))])
        let applied = try ToolpathTemplateTests.roundTrip(template).apply(to: design, library: .starter)
        let eights = [design.shapes[0].id, design.shapes[2].id]
        #expect(applied.project.operations[0].shapeIDs == eights)
        #expect(applied.rows[0].shapeCount == 2)
        #expect(applied.rows[0].rule?.label(.mm) == "Circles 7.5–8.5 mm across")
    }

    /// Within the tolerance counts; past it doesn't.
    @Test func theToleranceWidensTheRange() {
        let filter = SizeFilter.circles(8, 8, tolerance: 0.05)
        #expect(filter.matches(Self.hole(8.04, at: .zero)))
        #expect(filter.matches(Self.hole(7.96, at: .zero)))
        #expect(!filter.matches(Self.hole(8.1, at: .zero)))
        // A scaled circle is measured as drawn.
        var scaled = Self.hole(4, at: .zero)
        scaled.scale = 2
        #expect(filter.matches(scaled))
        // An open end takes any size that side.
        #expect(SizeFilter.circles(20, nil).matches(Self.hole(300, at: .zero)))
        #expect(!SizeFilter.circles(20, nil).matches(Self.hole(19, at: .zero)))
    }

    /// Bounding-box rules take closed shapes only, measured as placed.
    @Test func closedShapesByBoundingBox() {
        let wide = SizeFilter.box(width: SizeRange(min: 50), height: nil)
        let board = DesignShape(name: "Board", kind: .rectangle(width: 120, height: 40, cornerRadius: 0), position: Vec2(100, 100))
        #expect(wide.matches(board))
        var turned = board
        turned.rotation = 90
        #expect(!wide.matches(turned)) // now 40 wide, 120 tall
        let tall = SizeFilter.box(width: nil, height: SizeRange(min: 100, max: 130))
        #expect(tall.matches(turned))
        let line = DesignShape(name: "Line", kind: .paths([Polyline([Vec2(0, 0), Vec2(200, 0)], closed: false)]), position: Vec2(100, 100))
        #expect(!wide.matches(line))
        // A circle is a closed shape too: its box is its diameter.
        #expect(wide.matches(Self.hole(60, at: Vec2(50, 50))))
        // Diameter rules never take a non-circle.
        #expect(!SizeFilter.circles(0, 1000).matches(board))
    }

    /// Imported vectors are one shape per layer: the filter measures each outline, and the toolpath cuts only the
    /// outlines of the size.
    @Test func importedHolesAreMeasuredOneByOne() throws {
        let p = try Self.importedPanel()
        #expect(p.shapes.count == 1)
        guard case let .paths(all)? = p.shapes.first?.kind else { Issue.record("not imported paths"); return }
        #expect(all.count == 10)
        var drill = Self.drill(rule: .layers(["Default"], size: Self.eightMM))
        drill.shapeIDs = p.shapeIDs(matching: drill.vectorSelection!)
        #expect(drill.shapeIDs == [p.shapes[0].id])
        // Four 8 mm holes and the 7.9 mm one; not the 6, 10 or 30 mm ones or the panel.
        #expect(Self.holeCount(p, drill) == 5)
        // By kind, a diameter rule finds imported circles too.
        var byKind = Self.drill(rule: .kind(.circles, size: Self.eightMM))
        byKind.shapeIDs = p.shapeIDs(matching: byKind.vectorSelection!)
        #expect(Self.holeCount(p, byKind) == 5)
        // Without a size, a circles rule still finds only drawn circles, as before.
        #expect(p.shapeIDs(matching: .kind(.circles)).isEmpty)
        // Nothing of the size: not found.
        #expect(p.shapeIDs(matching: .layers(["Default"], size: .circles(50, 60))).isEmpty)
    }

    /// A committed template drills the 8 mm holes, pockets the 30 mm circle and cuts out the panel by its size, from
    /// one imported DXF layer. The applied job is pinned as a golden on Avid's Mach4 profile.
    @Test func aSizeFilterTemplateAppliedToMixedHoles() throws {
        let template = try Self.template("size-filter-v20") {
            ToolpathTemplate(name: "Panel holes", operations: [
                Self.drill(rule: .kind(.circles, size: Self.eightMM)),
                Self.op("Pocket 30 mm", .pocket(PocketParams(depth: DepthSettings(cutDepth: 6))), rule: .kind(.circles, size: .circles(29, 31))),
                Self.op("Cut out panel", .profile(ProfileParams(depth: DepthSettings(cutDepth: 18.5))),
                        rule: .kind(.closed, size: .box(width: SizeRange(min: 250), height: SizeRange(min: 150)))),
            ])
        }
        #expect(template.formatVersion == 20)
        let design = try Self.importedPanel(id: 1)
        let applied = template.apply(to: design, library: .starter)
        #expect(applied.emptyCount == 0)
        let ops = applied.project.operations
        #expect(ops.count == 3)
        #expect(Self.holeCount(applied.project, ops[0]) == 5)
        let pocketed = applied.project.shapes(for: ops[1]).flatMap { $0.polylines(tolerance: 0.01) }
        #expect(pocketed.count == 1)
        #expect(abs((pocketed.first.flatMap(SizeFilter.circleDiameter) ?? 0) - 30) < 0.05)
        let cut = applied.project.shapes(for: ops[2]).flatMap { $0.polylines(tolerance: 0.01) }
        #expect(cut.count == 1)
        #expect(abs(cut.first!.bounds.max.x - cut.first!.bounds.min.x - 300) < 0.01)
        try Self.checkGolden(applied.project, "template-size-filter-mach4")
    }

    /// The rule is used wherever toolpaths look again: a new shape, a layer change and Recalculate All.
    @Test func theFilterHoldsWhenToolpathsLookAgain() {
        var p = Self.mmProject("Holes", shapes: [Self.hole(8, at: Vec2(40, 40), layer: "Holes")])
        var drill = Self.drill(rule: .layers(["Holes"], size: Self.eightMM))
        drill.shapeIDs = p.shapeIDs(matching: drill.vectorSelection!)
        p.operations = [drill]
        let big = Self.hole(10, at: Vec2(80, 40))
        let small = Self.hole(8, at: Vec2(120, 40))
        p.shapes += [big, small]
        p.setLayer("Holes", of: [big.id, small.id])
        #expect(p.operations[0].shapeIDs == [p.shapes[0].id, small.id])
        p.shapes[0].kind = .circle(radius: 6)
        let changed = p.bindVectors()
        #expect(changed)
        #expect(p.operations[0].shapeIDs == [small.id])
    }

    /// A rule that finds nothing of its size is warned about, with the size in the message.
    @Test func aSizeThatFindsNothingIsWarnedAbout() throws {
        let p = try Self.edgeCase("size-finds-nothing") {
            var p = Self.mmProject("No 8 mm holes", shapes: [Self.hole(10, at: Vec2(40, 40), id: 30)])
            p.operations = [Self.drill(rule: .kind(.circles, size: Self.eightMM), id: 31)]
            p.bindVectors()
            return p
        }
        #expect(p.operations[0].shapeIDs.isEmpty)
        let issues = CAMEngine.generate(p).issues.filter { $0.operation == "Drill 8 mm" }
        let warned = issues.contains { $0.severity == .warning && $0.message.contains("The design has no circles 7.5–8.5 mm across.") }
        #expect(warned, "\(issues.map(\.message))")
    }

    // MARK: Saving

    /// Saving infers a diameter rule for a toolpath on some of the circles, when they're every circle of that size.
    @Test func savingInfersADiameterRule() {
        var p = Self.mmProject("Holes", shapes: [Self.hole(8, at: Vec2(40, 40)), Self.hole(10, at: Vec2(80, 40)), Self.hole(8, at: Vec2(120, 40))])
        var drill = Self.drill(rule: nil)
        drill.shapeIDs = [p.shapes[0].id, p.shapes[2].id]
        p.operations = [drill]
        let rule = ToolpathTemplate(name: "Holes", project: p).operations[0].vectorSelection
        #expect(rule == .layers(["Default"], size: .circles(8, 8)))
        // Not every 8 mm circle: chosen when applied, as before.
        p.operations[0].shapeIDs = [p.shapes[0].id]
        #expect(ToolpathTemplate(name: "Holes", project: p).operations[0].vectorSelection == .selection)
    }

    /// A size rule saves under "size", is format 20 in templates and projects, and only when used; an empty one is none.
    @Test func theFormatRisesOnlyWhenTheFilterIsUsed() throws {
        let sized = VectorSelection.layers(["Holes"], size: Self.eightMM)
        let json = String(data: try JSONEncoder().encode(sized), encoding: .utf8) ?? ""
        #expect(json.contains(#""size":"#))
        #expect(try JSONDecoder().decode(VectorSelection.self, from: JSONEncoder().encode(sized)) == sized)
        let plain = String(data: try JSONEncoder().encode(VectorSelection.layers(["A"])), encoding: .utf8)
        #expect(plain == #"{"layers":["A"]}"#)
        #expect(VectorSelection.kind(.circles).sized(SizeFilter()) == .kind(.circles))

        let without = ToolpathTemplate(name: "Plain", operations: [Self.drill(rule: .layers(["Holes"]))])
        #expect(without.formatVersion == 1)
        let with = ToolpathTemplate(name: "Sized", operations: [Self.drill(rule: sized)])
        #expect(with.formatVersion == 20)
        #expect(try ToolpathTemplate.decode(with.encoded()) == with)

        var p = Self.mmProject("Holes", shapes: [Self.hole(8, at: Vec2(40, 40))])
        p.operations = [Self.drill(rule: .layers(["Default"]))]
        #expect(p.formatVersion == 1)
        p.operations[0].vectorSelection = sized
        #expect(p.formatVersion == 20)
        // Made layers don't raise it: an older build drops them and cuts the same.
        p.operations[0].vectorSelection = nil
        p.addLayers(["Groove"])
        #expect(p.formatVersion == 1)
        #expect(try Project.decode(p.encoded()).namedLayers == ["Groove"])
    }

    /// A project saved by format 20 with a size filter: an imported layer's 8 mm holes drilled by diameter, a drawn
    /// 30 mm circle pocketed, the panel cut out by its bounding box, and an empty layer made by a template.
    static func savedProject() -> Project {
        let result = try! DXFImportTests.load("mixed_holes_mm")
        var p = mmProject("Template filters (format 20)")
        p.shapes = result.shapes(name: "mixed_holes_mm", stock: p.stock)
        p.shapes[0].id = id(40)
        p.shapes[0].layer = "Panel"
        p.shapes.append(hole(30, at: Vec2(260, 160), id: 41, layer: "Panel"))
        p.operations = [
            drill(rule: .layers(["Panel"], size: eightMM), id: 42),
            op("Pocket 30 mm", .pocket(PocketParams(depth: DepthSettings(cutDepth: 6))), rule: .kind(.circles, size: .circles(29, 31)), id: 43),
            op("Cut out panel", .profile(ProfileParams(depth: DepthSettings(cutDepth: 18.5))),
               rule: .layers(["Panel"], size: .box(width: SizeRange(min: 250), height: nil)), id: 44),
        ]
        p.addLayers(["Groove"])
        p.bindVectors()
        p.notes = "Saved by format 20 to pin size filters on toolpaths that find their vectors."
        return p
    }

    @Test func savedTemplateFilterProjectDecodesAndPosts() throws {
        let p = try GoldenPostTests.savedProject("template-filters-v20", make: Self.savedProject)
        #expect(p.formatVersion == 20)
        #expect(p == Self.savedProject())
        #expect(try Project.decode(p.encoded()) == p)
        #expect(p.layerNames == ["Panel", "Groove"])
        #expect(Self.holeCount(p, p.operations[0]) == 5)
        // The drawn 30 mm circle and the imported one.
        #expect(p.operations[1].shapeIDs.count == 2)
        try Self.checkGolden(p, "decoded-template-filters-v20")
    }

    // MARK: Missing layers

    /// A template for a sign whose groove and engraving layers a plain board doesn't have.
    static func missingLayersTemplate() throws -> ToolpathTemplate {
        try template("missing-layers-v1") {
            ToolpathTemplate(name: "Board with groove", operations: [
                drill("Drill", rule: .layers(["Holes"])),
                op("Juice groove", .pocket(PocketParams(depth: DepthSettings(cutDepth: 3))), rule: .layers(["Groove"])),
                op("Engrave", .vcarve(VCarveParams()), rule: .layers(["Engrave", "Text"]), tool: vBit),
                op("Mark holes", .pocket(PocketParams(depth: DepthSettings(cutDepth: 1))), rule: .layers(["Holes", "Groove"])),
                op("Cut out", .profile(ProfileParams(depth: DepthSettings(cutDepth: 18.5))), rule: .layers(["Cut Out"])),
            ])
        }
    }

    static func plainBoard() -> Project {
        mmProject("Board", shapes: [
            DesignShape(name: "Board", kind: .rectangle(width: 300, height: 200, cornerRadius: 10), position: Vec2(165, 115), layer: "cut out"),
            hole(8, at: Vec2(40, 40), layer: "Holes"),
        ])
    }

    @Test func missingLayersAreListedInTheTemplatesOrder() throws {
        let template = try Self.missingLayersTemplate()
        #expect(template.formatVersion == 1)
        #expect(template.missingLayers(in: Self.plainBoard()) == ["Groove", "Engrave", "Text"])
        #expect(template.missingLayers(in: ToolpathTemplateTests.layeredSign()) == ["Groove", "Engrave", "Text"])
    }

    /// Create: the layers are made, empty and named; the toolpaths are added bound to them, and pick up vectors put on
    /// them later.
    @Test func creatingTheMissingLayers() throws {
        let template = try Self.missingLayersTemplate()
        let board = Self.plainBoard()
        let applied = template.apply(to: board, library: .starter, missingLayers: .create)
        #expect(applied.createdLayers == ["Groove", "Engrave", "Text"])
        #expect(applied.project.layerNames == ["cut out", "Holes", "Groove", "Engrave", "Text"])
        #expect(applied.project.operations.count == 5)
        #expect(applied.skippedCount == 0)
        #expect(applied.rows.map(\.isEmpty) == [false, true, true, false, false])
        // Saved with the project, and the format stays 1.
        let saved = try Project.decode(applied.project.encoded())
        #expect(saved.namedLayers == ["Groove", "Engrave", "Text"])
        #expect(saved.formatVersion == 1)
        // A vector put on a made layer is picked up.
        var p = saved
        let groove = DesignShape(name: "Groove", kind: .rectangle(width: 260, height: 160, cornerRadius: 10), position: Vec2(165, 115))
        p.shapes.append(groove)
        p.setLayer("groove", of: [groove.id])
        #expect(p.operations[1].shapeIDs == [groove.id])
        #expect(p.layerNames.filter { VectorSelection.sameLayer($0, "Groove") }.count == 1)
    }

    /// Skip: toolpaths whose layers are all missing are left out, with their tools; one that has a layer the design
    /// has is kept.
    @Test func skippingTheMissingLayersToolpaths() throws {
        let template = try Self.missingLayersTemplate()
        let applied = template.apply(to: Self.plainBoard(), library: .starter, missingLayers: .skip)
        #expect(applied.project.operations.map(\.name) == ["Drill", "Mark holes", "Cut out"])
        #expect(applied.skippedCount == 2)
        #expect(applied.rows.filter(\.skipped).map(\.name) == ["Juice groove", "Engrave"])
        #expect(applied.emptyCount == 0)
        #expect(applied.createdLayers.isEmpty)
        #expect(applied.project.namedLayers.isEmpty)
        #expect(!applied.tools.contains { $0.tool.sameGeometry(as: Self.vBit) })
        #expect(applied.addedOperationIDs == applied.project.operations.map(\.id))
    }

    // MARK: Command line

    @Test func theCommandLineAsksAboutMissingLayers() throws {
        let dir = try CommandLineTests.folder()
        let template = Self.fixtures.appendingPathComponent("templates/missing-layers-v1.nativecamtemplate").path
        let board = dir.appendingPathComponent("board.nativecam")
        try Self.plainBoard().encoded().write(to: board)
        let out = dir.appendingPathComponent("out.nativecam")

        let refused = try CommandLineTests.run(["template", "apply", template, board.path, "-o", out.path])
        #expect(refused.status != 0)
        #expect(refused.output.contains("The design has no layers “Groove”, “Engrave”, “Text”"), "\(refused.output)")
        #expect(refused.output.contains("--create-layers"))
        #expect(!FileManager.default.fileExists(atPath: out.path))

        let both = try CommandLineTests.run(["template", "apply", template, board.path, "-o", out.path, "--create-layers", "--skip-missing"])
        #expect(both.status != 0)
        #expect(both.output.contains("not both"))

        let created = try CommandLineTests.run(["template", "apply", template, board.path, "-o", out.path, "--create-layers"])
        #expect(created.status == 0, "\(created.output)")
        #expect(created.output.contains("Created layers “Groove”, “Engrave”, “Text” (empty)"), "\(created.output)")
        let made = try Project.decode(Data(contentsOf: out))
        #expect(made.operations.count == 5)
        #expect(made.namedLayers == ["Groove", "Engrave", "Text"])

        let skipped = try CommandLineTests.run(["template", "apply", template, board.path, "-o", out.path, "--skip-missing"])
        #expect(skipped.status == 0, "\(skipped.output)")
        #expect(skipped.output.contains("Skipped 2 toolpaths on missing layers"), "\(skipped.output)")
        #expect(skipped.output.contains("Juice groove: Layer “Groove”: 0 vectors, skipped"), "\(skipped.output)")
        let left = try Project.decode(Data(contentsOf: out))
        #expect(left.operations.map(\.name) == ["Drill", "Mark holes", "Cut out"])
    }

    /// The size filter template applies from the command line too, and names the size it looked for.
    @Test func theCommandLineAppliesASizeFilter() throws {
        let dir = try CommandLineTests.folder()
        let template = Self.fixtures.appendingPathComponent("templates/size-filter-v20.nativecamtemplate").path
        let panel = dir.appendingPathComponent("panel.nativecam")
        try Self.importedPanel().encoded().write(to: panel)
        let out = dir.appendingPathComponent("out.nativecam")
        let run = try CommandLineTests.run(["template", "apply", template, panel.path, "-o", out.path])
        #expect(run.status == 0, "\(run.output)")
        #expect(run.output.contains("Drill 8 mm: Circles 7.5–8.5 mm across: 1 vector"), "\(run.output)")
        #expect(run.output.contains("every toolpath found its vectors"), "\(run.output)")

        // On an inch design the rule still reads in the mm it was made in, not as 0.2953–0.3346 in (#123).
        var inch = try Self.importedPanel()
        inch.displayUnits = .inch
        try inch.encoded().write(to: panel)
        let onInch = try CommandLineTests.run(["template", "apply", template, panel.path, "-o", out.path])
        #expect(onInch.status == 0, "\(onInch.output)")
        #expect(onInch.output.contains("Drill 8 mm: Circles 7.5–8.5 mm across: 1 vector"), "\(onInch.output)")
        #expect(!onInch.output.contains("0.2953"), "\(onInch.output)")
    }

    /// A size rule reads in the units it was made in when its lengths are round there, else in the design's, rounded (#123).
    @Test func sizeRulesReadInTheUnitsTheyWereMadeIn() {
        let mmCircles = SizeFilter.circles(7.5, 8.5)
        #expect(mmCircles.label(.inch) == "circles 7.5–8.5 mm across")
        #expect(mmCircles.label(.mm) == "circles 7.5–8.5 mm across")
        #expect(VectorSelection.kind(.circles, size: mmCircles).label(.inch) == "Circles 7.5–8.5 mm across")
        let wide = SizeFilter.box(width: SizeRange(min: 250), height: SizeRange(max: 120))
        #expect(wide.label(.inch) == "at least 250 mm wide, up to 120 mm tall")
        #expect(VectorSelection.layers(["Pockets"], size: wide).label(.inch) == "Layer “Pockets” (at least 250 mm wide, up to 120 mm tall)")
        // Made in inches: inches on a mm design too, fractions exactly.
        let inchBox = SizeFilter.box(width: SizeRange(min: 0.5.inch, max: 2.inch), height: SizeRange(min: (1.0 / 64).inch))
        #expect(inchBox.label(.mm) == "0.5–2 in wide, at least 0.015625 in tall")
        #expect(inchBox.label(.inch) == "0.5–2 in wide, at least 0.015625 in tall")
        // A rule mixing both stays in the design's units.
        let mixed = SizeFilter.box(width: SizeRange(min: 2.inch, max: 250), height: nil)
        #expect(mixed.label(.inch) == "2–9.843 in wide")
        #expect(mixed.label(.mm) == "50.8–250 mm wide")
        // Round in neither: the design's units, rounded rather than to four places.
        let measured = SizeFilter.circles(7.4937, 8.5063)
        #expect(measured.label(.inch) == "circles 0.295–0.335 in across")
        #expect(measured.label(.mm) == "circles 7.49–8.51 mm across")
    }
}
