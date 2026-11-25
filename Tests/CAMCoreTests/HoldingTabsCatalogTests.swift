import Foundation
import Testing
@testable import CAMCore

/// The CAM test catalog for holding tabs on 3D cut-outs (#173): a medallion as deep as the board, cut round by 3D
/// roughing and finishing with Selected vectors and cut out with a tabbed profile, leaves strips under the cut-out's
/// tabs instead of holding its whole floor (#155). Goldens on Avid's Mach4 default, a saved format-30 project with its
/// decoded golden, and a saved project for each case handled (`Fixtures/3d-tabs`, listed in its README): the fallbacks
/// to the whole-floor hold, the warnings, the plateau check and the cases where nothing is held.
struct HoldingTabsCatalogTests {
    static let dir = GoldenPostTests.fixtures.appendingPathComponent("3d-tabs")

    static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "173AB000-0000-4000-8000-%012d", n))! }

    /// Loads a fixture. Update mode writes a missing one from `make`, but never replaces one.
    static func fixture(_ name: String, make: () -> Project) throws -> Project {
        let url = dir.appendingPathComponent(name + ".nativecam")
        if GoldenPostTests.updating, !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try make().encoded().write(to: url, options: .atomic) // the tests run in parallel
        }
        return try Project.decode(Data(contentsOf: url))
    }

    // MARK: Builders

    static let endMill = ToolLibrary.starter.tool(number: 1)!   // 1/4" upcut
    static let ball = ToolLibrary.starter.tool(number: 7)!      // 1/4" ball nose
    static let thickness = 0.75.inch
    static let centre = Vec2(75, 75)

    /// A solid round (or oval) model, `rx` × `ry` mm from its middle: a heightfield top `edge` mm high at its rim rising
    /// as a dome to `peak` mm, straight walls down to its flat bottom at 0. Polar, so its rim is a smooth outline.
    /// `dome` false makes it a paraboloid instead, which falls away gently to its rim (a thin appliqué's edge).
    static func medallionMesh(rx: Double = 45, ry: Double = 45, edge: Double, peak: Double, dome: Bool = true, rings: Int = 24,
                              sectors: Int = 96, meshID: UUID = id(900)) -> MeshModel {
        var pos: [Float] = []
        var idx: [UInt32] = []
        func add(_ x: Double, _ y: Double, _ z: Double) -> UInt32 {
            pos += [Float(x), Float(y), Float(z)]
            return UInt32(pos.count / 3 - 1)
        }
        func height(_ r: Double) -> Double {
            let f = max(0, 1 - r * r)
            return edge + (peak - edge) * (dome ? f.squareRoot() : f)
        }
        let top = add(0, 0, height(0))
        var ring: [[UInt32]] = []
        for k in 1...rings {
            let r = Double(k) / Double(rings)
            ring.append((0..<sectors).map { j in
                let a = 2 * Double.pi * Double(j) / Double(sectors)
                return add(rx * r * cos(a), ry * r * sin(a), height(r))
            })
        }
        let bottom = (0..<sectors).map { j in
            let a = 2 * Double.pi * Double(j) / Double(sectors)
            return add(rx * cos(a), ry * sin(a), 0)
        }
        let floor = add(0, 0, 0)
        for j in 0..<sectors {
            let n = (j + 1) % sectors
            idx += [top, ring[0][j], ring[0][n]]
            for k in 1..<rings { idx += [ring[k - 1][j], ring[k][j], ring[k][n], ring[k - 1][j], ring[k][n], ring[k - 1][n]] }
            let rim = ring[rings - 1]
            idx += [rim[j], bottom[j], bottom[n], rim[j], bottom[n], rim[n]]
            idx += [floor, bottom[n], bottom[j]]
        }
        return MeshModel(id: meshID, name: "Medallion", positions: pos, indices: idx)
    }

    /// The medallion job: a model `depth` deep (the board's thickness by default), a round outline `gap` outside it, 3D
    /// roughing (offset, 1/4" end mill) and raster finishing (1/4" ball) with Selected vectors, and an outside profile
    /// through the board with four tabs 3/8" long and 1/8" thick.
    static func medallion(_ name: String, units: LengthUnit = .inch, edge: Double = 8, depth: Double = thickness, rx: Double = 45,
                          ry: Double = 45, gap: Double = 3, tabs: TabSettings = TabSettings(enabled: true),
                          rough: Rough3DParams = Rough3DParams(boundary: .vectors),
                          finish: Finish3DParams? = Finish3DParams(stepoverFraction: 0.15, rasterAngle: 45, boundary: .vectors),
                          cutOut: Bool = true, leads: LeadSettings? = nil, dome: Bool = true) -> Project {
        // Each shape of model its own mesh ID: meshes are cached by ID.
        let shape = "\(rx) \(ry) \(edge) \(depth) \(dome)".unicodeScalars.reduce(0) { ($0 * 31 + Int($1.value)) % 1_000_000 }
        let mesh = medallionMesh(rx: rx, ry: ry, edge: edge * 19.05 / depth, peak: 19.05, dome: dome, meshID: id(100_000_000 + shape))
        let model = DesignShape(id: id(1), name: "Medallion", kind: .model(ModelSpec(mesh: mesh, upAxis: .z, depth: depth)), position: centre)
        let outline = DesignShape(id: id(2), name: "Outline", kind: rx == ry ? .circle(radius: rx + gap) : .ellipse(radiusX: rx + gap, radiusY: ry + gap),
                                  position: centre)
        var ops = [CAMOperation(id: id(11), name: "Rough medallion", kind: .rough3D(rough), shapeIDs: [model.id, outline.id], tool: endMill)]
        if let finish {
            ops.append(CAMOperation(id: id(12), name: "Finish medallion", kind: .finish3D(finish), shapeIDs: [model.id, outline.id], tool: ball))
        }
        if cutOut {
            ops.append(CAMOperation(id: id(13), name: "Cut out medallion",
                                    kind: .profile(ProfileParams(side: .outside, direction: .climb, depth: DepthSettings(cutDepth: thickness),
                                                                 tabs: tabs, leads: leads)),
                                    shapeIDs: [outline.id], tool: endMill))
        }
        var machine = MachineProfile.avidPRO6060
        machine.outputUnits = units
        let stock = Stock(width: 150, height: 150, thickness: thickness, materialName: "MDF", clearanceHeight: 10, plungeHeight: 2,
                          materialKind: .mdf)
        return Project(name: name, displayUnits: units, stock: stock, machine: machine, shapes: [model, outline], operations: ops)
    }

    static func op(_ p: Project, _ name: String) -> CAMOperation { p.operations.first { $0.name == name }! }

    static func strips(_ p: Project, _ name: String = "Rough medallion") -> HoldingTabs.Strips? {
        HoldingTabs.decide(op(p, name), in: p).strips
    }

    // MARK: Measuring

    /// Points of a toolpath whose tool cuts into a strip below its top: the centre inside it (a ball rolls over it), or
    /// for a flat-bottomed bit any part of its flat bottom over it (less a grid cell). Collected inside `forEachMotion`
    /// and asserted after (an `#expect` inside it crashes swiftc).
    static func intrusions(_ tp: Toolpath, strips: [HoldingTabs.Strip]) -> Int {
        var n = HoldingTabs.intrusions(tp, strips: strips, shrink: 0.3)
        if tp.tool.shape.hasFlatBottom {
            n += HoldingTabs.intrusions(tp, strips: strips, shrink: -(tp.tool.radius - 1.0))
        }
        return n
    }

    /// Whether the simulated material still joins the model's middle to the board's rim above the floor (+0.05 mm): a
    /// flood fill over the cells standing above it, from the rim.
    static func connected(_ g: HeightGrid, to p: Vec2) -> Bool {
        let level = g.floorZ + 0.05
        var seen = [Bool](repeating: false, count: g.heights.count)
        var stack: [Int] = []
        for c in 0..<g.columns { stack += [g.index(c, 0), g.index(c, g.rows - 1)] }
        for r in 0..<g.rows { stack += [g.index(0, r), g.index(g.columns - 1, r)] }
        while let i = stack.popLast() {
            guard !seen[i], g.heights[i] > level else { continue }
            seen[i] = true
            let c = i % g.columns, r = i / g.columns
            if c > 0 { stack.append(i - 1) }
            if c < g.columns - 1 { stack.append(i + 1) }
            if r > 0 { stack.append(i - g.columns) }
            if r < g.rows - 1 { stack.append(i + g.columns) }
        }
        let c = Int(((p.x - g.origin.x) / g.cellSize).rounded()), r = Int(((p.y - g.origin.y) / g.cellSize).rounded())
        return seen[g.index(c, r)]
    }

    /// The job simulated toolpath by toolpath: after each, whether the model's still joined to the rim; and at the end,
    /// the material left at each strip's middle, half way across the cut-out's kerf (above the board's bottom).
    ///
    /// `footprint`: over each tab's footprint (its length less a cell, across the cut-out's kerf less a cell each side;
    /// `onlyMiddle` just its centre line, for triangular tabs: their sides ramp, so the cut-out itself leaves them full height
    /// only there), the most the material falls short
    /// of the tabs' top. A ball rolling down a strip's ends mustn't round the tab the cut-out leaves.
    static func simulate(_ p: Project, job: JobResult, strips: HoldingTabs.Strips, onlyMiddle: Bool = false)
        -> (joined: [Bool], tabs: [Double], cell: Double, footprint: Double) {
        var sim = MaterialSimulator(stock: p.stock, cellSize: 0.25)
        var joined: [Bool] = []
        for tp in job.toolpaths {
            tp.forEachMotion { s, m in sim.apply(m, from: s, tool: tp.tool) }
            joined.append(connected(sim.grid, to: centre))
        }
        let r = endMill.radius
        let tabs = strips.strips.map { st -> Double in
            Double(sim.grid.height(at: st.centre + st.normal * r) ?? -.infinity) - Double(sim.grid.floorZ)
        }
        let cell = sim.grid.cellSize
        var short = 0.0
        for st in strips.strips {
            let half = onlyMiddle ? 0 : st.width / 2 - cell
            for u in stride(from: -half, through: half + 1e-9, by: cell) {
                for v in stride(from: cell, through: 2 * r - cell + 1e-9, by: cell) {
                    let h = Double(sim.grid.height(at: st.centre + st.tangent * u + st.normal * v) ?? -.infinity)
                    short = max(short, strips.top - h)
                }
            }
        }
        return (joined, tabs, cell, short)
    }

    static func checkGolden(_ p: Project, _ name: String, only: [String]? = nil, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors, "\(job.issues.filter { $0.severity == .error }.map(\.message))", sourceLocation: sourceLocation)
        let toolpaths = only.map { names in job.toolpaths.filter { names.contains($0.name) } } ?? job.toolpaths
        #expect(!toolpaths.isEmpty && toolpaths.allSatisfy { !$0.isEmpty }, sourceLocation: sourceLocation)
        let data = GoldenPostTests.post(p, toolpaths)
        try GoldenPostTests.check(data, golden: name, sourceLocation: sourceLocation)
        let issues = GCodeCheck.run(String(decoding: data, as: UTF8.self), toolpaths: toolpaths, project: p, dialect: .avidMach4)
        #expect(issues.filter { $0.severity != .info }.isEmpty, "\(issues.map(\.text))", sourceLocation: sourceLocation)
    }

    // MARK: The medallion

    static func through() -> Project { medallion("Medallion through") }

    @Test func throughMedallionLeavesStripsUnderTheCutOutsTabs() throws {
        let p = try Self.fixture("medallion-through", make: Self.through)
        let s = try #require(Self.strips(p))
        #expect(s.strips.count == 4)
        #expect(s.warnings.isEmpty, "\(s.warnings)")
        // Each strip reaches past the tab's ends by the ball's radius and a millimetre.
        #expect(s.strips.allSatisfy { abs($0.flank - (Self.ball.radius + 1)) < 1e-9 })
        #expect(abs(s.top - (-Self.thickness + 0.125.inch)) < 1e-9)
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors, "\(job.issues.filter { $0.severity == .error }.map(\.message))")
        for name in ["Rough medallion", "Finish medallion"] {
            let tp = try #require(job.toolpaths.first { $0.name == name })
            let mine = job.issues.filter { $0.operation == name }
            #expect(mine.contains { $0.severity == .info && $0.message.hasPrefix("Leaves a strip under each of the 4 tabs") }, "\(mine.map(\.message))")
            #expect(!mine.contains { $0.message.hasPrefix("Holds its floor") })
            #expect(!mine.contains { $0.message.contains("3D toolpaths leave no tabs") })
            // Full depth elsewhere: the finish reaches the board's bottom, the roughing its allowance above it.
            #expect(PartHoldTests.deepest(tp) < -Self.thickness + 0.6, "\(name) only reaches \(PartHoldTests.deepest(tp))")
            #expect(Self.intrusions(tp, strips: s.strips) == 0, "\(name) cuts into the strips")
        }
        let finish = try #require(job.toolpaths.first { $0.name == "Finish medallion" })
        #expect(abs(PartHoldTests.deepest(finish) + Self.thickness) < 0.01)
        // The cut-out lines up with the strips, and its tabs aren't shown as placed by hand.
        let cut = try #require(job.toolpaths.first { $0.name == "Cut out medallion" })
        #expect(HoldingTabs.mismatches(cut, strips: s, tool: Self.endMill) == 0)
        let marks = try #require(cut.tabMarks)
        #expect(marks.count == 4 && marks.allSatisfy { !$0.placed })
        #expect(job.reorder?.outOfOrder.isEmpty ?? true)
    }

    /// The part stays on the board after every toolpath, and the tabs it's left on are as thick as set, to within a cell.
    @Test func simulatedPartStaysJoinedWithTabsAsThickAsSet() throws {
        let p = try Self.fixture("medallion-through", make: Self.through)
        let s = try #require(Self.strips(p))
        let job = CAMEngine.generate(p)
        let sim = Self.simulate(p, job: job, strips: s)
        #expect(sim.joined == [true, true, true], "\(sim.joined)")
        for t in sim.tabs { #expect(abs(t - 0.125.inch) <= sim.cell + 0.01, "tab \(t) mm thick") }
        // The whole tab, not only its middle: the finishing ball doesn't round its ends.
        #expect(sim.footprint <= sim.cell + 0.01, "a tab falls \(sim.footprint) mm short of its top")
        // Without the strips (the cut-out run first, its tabs alone hold the part) it's held too; with no cut-out the
        // finish frees it.
        var free = p
        free.operations.removeAll { $0.name == "Cut out medallion" }
        let loose = Self.simulate(free, job: CAMEngine.generate(free), strips: s)
        #expect(loose.joined.last == false)
    }

    /// The whole-floor hold this replaces: the same strips raise exactly the cells under them.
    @Test func stripsRaiseOnlyTheirCellsInTheTargets() throws {
        let p = try Self.fixture("medallion-through", make: Self.through)
        let s = try #require(Self.strips(p))
        let rough = Self.op(p, "Rough medallion")
        guard case let .rough3D(r) = rough.kind else { Issue.record("no rough"); return }
        var warnings: [String] = []
        let shapes = p.shapes(for: rough)
        let plain = try #require(Model3DGenerator.setup(shapes: shapes, boundary: .vectors, margin: Rough3DParams.autoMargin(tool: Self.endMill),
                                                        tool: Self.endMill, stock: p.stock, preferredCell: 0.5, warnings: &warnings))
        let held = try #require(Model3DGenerator.setup(shapes: shapes, boundary: .vectors, margin: Rough3DParams.autoMargin(tool: Self.endMill),
                                                       tool: Self.endMill, stock: p.stock, preferredCell: 0.5, strips: s.strips, warnings: &warnings))
        let a = Model3DGenerator.targets(plain, allowance: r.allowance), b = Model3DGenerator.targets(held, allowance: r.allowance)
        let g = held.surface
        var changed = 0, outside = 0
        for i in a.indices where a[i] != b[i] {
            changed += 1
            let q = g.center(i % g.columns, i / g.columns)
            if !s.strips.contains(where: { $0.contains(q, shrink: -0.01) }) { outside += 1 }
            if b[i] < Float(s.top + r.allowance) - 1e-4 { outside += 1 }
        }
        #expect(changed > 100)
        #expect(outside == 0)
    }

    // MARK: Goldens

    @Test func roughOffsetGolden() throws {
        try Self.checkGolden(try Self.fixture("medallion-through", make: Self.through), "rough3d-tabs-offset-inch", only: ["Rough medallion"])
    }

    @Test func cutOutGolden() throws {
        try Self.checkGolden(try Self.fixture("medallion-through", make: Self.through), "profile-3d-cutout-tabs-inch", only: ["Cut out medallion"])
    }

    static func adaptive() -> Project {
        medallion("Medallion adaptive", rough: Rough3DParams(boundary: .vectors, clearing: .adaptive), finish: nil)
    }

    @Test func roughAdaptiveGolden() throws {
        let p = try Self.fixture("medallion-adaptive", make: Self.adaptive)
        let s = try #require(Self.strips(p))
        let job = CAMEngine.generate(p)
        let tp = try #require(job.toolpaths.first { $0.name == "Rough medallion" })
        #expect(Self.intrusions(tp, strips: s.strips) == 0)
        try Self.checkGolden(p, "rough3d-tabs-adaptive-inch", only: ["Rough medallion"])
    }

    static func rasterMM() -> Project { medallion("Medallion raster (mm)", units: .mm) }

    @Test func finishRasterGolden() throws {
        try Self.checkGolden(try Self.fixture("medallion-raster-mm", make: Self.rasterMM), "finish3d-tabs-raster-mm", only: ["Finish medallion"])
    }

    static func waterlineMM() -> Project {
        medallion("Medallion waterline (mm)", units: .mm, finish: Finish3DParams(stepoverFraction: 0.15, boundary: .vectors, strategy: .waterline))
    }

    @Test func finishWaterlineGolden() throws {
        let p = try Self.fixture("medallion-waterline-mm", make: Self.waterlineMM)
        let s = try #require(Self.strips(p, "Finish medallion"))
        let job = CAMEngine.generate(p)
        let tp = try #require(job.toolpaths.first { $0.name == "Finish medallion" })
        #expect(Self.intrusions(tp, strips: s.strips) == 0)
        try Self.checkGolden(p, "finish3d-tabs-waterline-mm", only: ["Finish medallion"])
    }

    /// Tabs placed by hand: the strips are where they are, three of them.
    static func placed() -> Project {
        let marks = [30.0, 150, 260].map { a in
            ContourMark(shapeID: id(2), point: Vec2.fromAngle(a * .pi / 180, length: 48))
        }
        return medallion("Medallion placed tabs", tabs: TabSettings(enabled: true, placed: marks))
    }

    @Test func placedTabsGetStripsWhereTheyAre() throws {
        let p = try Self.fixture("medallion-placed", make: Self.placed)
        let s = try #require(Self.strips(p))
        #expect(s.strips.count == 3)
        for (st, a) in zip(s.strips, [30.0, 150, 260]) {
            #expect(st.centre.distance(to: Self.centre + Vec2.fromAngle(a * .pi / 180, length: 48)) < 0.05)
        }
        let job = CAMEngine.generate(p)
        let cut = try #require(job.toolpaths.first { $0.name == "Cut out medallion" })
        #expect(HoldingTabs.mismatches(cut, strips: s, tool: Self.endMill) == 0)
        #expect(cut.tabMarks?.allSatisfy(\.placed) == true)
        let sim = Self.simulate(p, job: job, strips: s)
        #expect(sim.joined.allSatisfy { $0 })
        #expect(sim.footprint <= sim.cell + 0.01, "a tab falls \(sim.footprint) mm short of its top")
        try Self.checkGolden(p, "3d-tabs-placed-inch")
    }

    /// Triangular tabs: a flat strip at their full height across their whole base.
    static func triangular() -> Project {
        medallion("Medallion triangular tabs", tabs: TabSettings(enabled: true, count: 3, width: 0.5.inch, shape: .triangular))
    }

    @Test func triangularTabsGetFlatStripsAtFullHeight() throws {
        let p = try Self.fixture("medallion-triangular", make: Self.triangular)
        let s = try #require(Self.strips(p))
        #expect(s.strips.count == 3)
        #expect(s.strips.allSatisfy { abs($0.width - 0.5.inch) < 1e-9 && abs($0.top - s.top) < 1e-9 })
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors, "\(job.issues.filter { $0.severity == .error }.map(\.message))")
        #expect(job.issues.contains { $0.operation == "Rough medallion" && $0.message.contains("triangular tabs get flat strips") })
        let cut = try #require(job.toolpaths.first { $0.name == "Cut out medallion" })
        #expect(HoldingTabs.mismatches(cut, strips: s, tool: Self.endMill) == 0)
        let sim = Self.simulate(p, job: job, strips: s, onlyMiddle: true)
        #expect(sim.joined.allSatisfy { $0 })
        #expect(sim.footprint <= sim.cell + 0.01, "a tab falls \(sim.footprint) mm short of its top")
        try Self.checkGolden(p, "3d-tabs-triangular-inch")
    }

    /// Arc leads on the cut-out: its entries land between the tabs, and the tabs still line up.
    static func leads() -> Project { medallion("Medallion with leads", leads: LeadSettings(kind: .arc, radius: 0.25.inch)) }

    @Test func leadsEnterBetweenTheTabs() throws {
        let p = try Self.fixture("leads-tabs", make: Self.leads)
        let s = try #require(Self.strips(p))
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors, "\(job.issues.filter { $0.severity == .error }.map(\.message))")
        let cut = try #require(job.toolpaths.first { $0.name == "Cut out medallion" })
        #expect(HoldingTabs.mismatches(cut, strips: s, tool: Self.endMill) == 0)
    }

    /// 3D rest finishing after the finish inherits the strips.
    @Test func restFinishingStaysOutOfTheStrips() throws {
        var p = try Self.fixture("medallion-through", make: Self.through)
        var small = ToolLibrary.starter.tool(number: 7)!
        small.diameter = 0.125.inch
        small.number = 8
        var rest = Finish3DParams(stepoverFraction: 0.2, boundary: .vectors, strategy: .rest)
        rest.rest = .defaults(for: .inch)
        p.operations.insert(CAMOperation(id: Self.id(14), name: "Rest medallion", kind: .finish3D(rest), shapeIDs: [Self.id(1), Self.id(2)],
                                         tool: small), at: 2)
        let s = try #require(Self.strips(p, "Rest medallion"))
        let job = CAMEngine.generate(p)
        let tp = try #require(job.toolpaths.first { $0.name == "Rest medallion" })
        #expect(Self.intrusions(tp, strips: s.strips) == 0)
        #expect(!job.issues.contains { $0.severity == .error && $0.operation == "Rest medallion" })
    }

    // MARK: The saved project

    static func savedProject() -> Project {
        var p = medallion("Holding tabs (format 30)", tabs: TabSettings(enabled: true, count: 3))
        p.notes = "Saved by the first build with strips under a 3D cut-out's tabs, as format 30."
        return p
    }

    @Test func savedProjectDecodesAndPosts() throws {
        let p = try GoldenPostTests.savedProject("3d-tabs-v30", make: Self.savedProject)
        #expect(p.formatVersion == 30)
        #expect(p == Self.savedProject())
        #expect(try Project.decode(p.encoded()) == p)
        try Self.checkGolden(p, "decoded-3d-tabs-v30")
    }

    @Test func theMarkerIsWrittenOnlyWithStrips() throws {
        let p = Self.savedProject()
        let json = String(decoding: try p.encoded(), as: UTF8.self)
        #expect(json.components(separatedBy: "\"holdsTabs\" : true").count == 3, "rough and finish are marked")
        // The marker is read back as nothing: the strips come from the job.
        let decoded = try Project.decode(p.encoded())
        #expect(decoded == p)
        // Without strips (Whole material: the whole floor's held) there's no marker and no format 30.
        var q = p
        for i in q.operations.indices {
            switch q.operations[i].kind {
            case var .rough3D(r): r.boundary = .material; q.operations[i].kind = .rough3D(r)
            case var .finish3D(f): f.boundary = .material; q.operations[i].kind = .finish3D(f)
            default: break
            }
        }
        #expect(!String(decoding: try q.encoded(), as: UTF8.self).contains("holdsTabs"))
        #expect(q.formatVersion < 30)
        // A format-29 build refuses the file.
        #expect(Project.currentFormatVersion >= 30)
    }

    /// Rotary jobs and the Model outline boundary are untouched: nothing to decide.
    @Test func rotaryAndModelOutlineAreUnchanged() throws {
        let pawn = Project.demoPawn()
        #expect(!HoldingTabs.Job(pawn).hasStrips)
        #expect(HoldingTabs.Job(pawn).decisions.isEmpty)
        var p = Self.through()
        for i in p.operations.indices {
            switch p.operations[i].kind {
            case var .rough3D(r): r.boundary = .model; p.operations[i].kind = .rough3D(r)
            case var .finish3D(f): f.boundary = .model; p.operations[i].kind = .finish3D(f)
            default: break
            }
        }
        // Model outline keeps #166's whole-floor hold as it was, with no reason added.
        guard case .hold(_, nil) = HoldingTabs.decide(Self.op(p, "Rough medallion"), in: p) else {
            Issue.record("\(HoldingTabs.decide(Self.op(p, "Rough medallion"), in: p))")
            return
        }
        #expect(!HoldingTabs.Job(p).hasStrips)
    }

    // MARK: Fallbacks to the whole-floor hold

    static func checkFallback(_ p: Project, _ reason: String, sourceLocation: SourceLocation = #_sourceLocation) {
        for name in ["Rough medallion", "Finish medallion"] where p.operations.contains(where: { $0.name == name }) {
            let d = HoldingTabs.decide(Self.op(p, name), in: p)
            guard case let .hold(h, why) = d else { Issue.record("\(name): \(d)", sourceLocation: sourceLocation); continue }
            #expect(h.possible, sourceLocation: sourceLocation)
            #expect(why?.contains(reason) == true, "\(why ?? "nil")", sourceLocation: sourceLocation)
        }
        let job = CAMEngine.generate(p)
        for name in ["Rough medallion", "Finish medallion"] where p.operations.contains(where: { $0.name == name }) {
            #expect(job.issues.contains { $0.severity == .info && $0.operation == name && $0.message.hasPrefix("Holds its floor")
                && $0.message.contains("rather than leaving strips under the tabs") && $0.message.contains(reason) },
                    "\(job.issues.filter { $0.operation == name }.map(\.message))", sourceLocation: sourceLocation)
            #expect(!job.issues.contains { $0.operation == name && $0.message.hasPrefix("Leaves a strip") }, sourceLocation: sourceLocation)
            let tp = job.toolpaths.first { $0.name == name }
            let held = -(p.stock.thickness - 0.125.inch)
            #expect(tp.map { PartHoldTests.deepest($0) >= held - 1e-6 } == true, sourceLocation: sourceLocation)
        }
        #expect(!job.issues.contains { $0.message.contains("line up with the strips") }, sourceLocation: sourceLocation)
        #expect(!HoldingTabs.Job(p).hasStrips, sourceLocation: sourceLocation)
        #expect(p.formatVersion < 30, sourceLocation: sourceLocation)
    }

    static func material() -> Project {
        medallion("Whole material", rough: Rough3DParams(boundary: .material),
                  finish: Finish3DParams(stepoverFraction: 0.15, rasterAngle: 45, boundary: .material))
    }

    @Test func wholeMaterialHoldsTheFloor() throws {
        Self.checkFallback(try Self.fixture("material-boundary", make: Self.material), "Whole material")
    }

    /// A model whose edge is only 0.3 mm high and rises gently, much thinner than the 1/8" tab where it joins it.
    static func thin() -> Project { medallion("Thin appliqué", edge: 0.3, finish: nil, dome: false) }

    @Test func aModelThinnerThanTheTabHoldsTheFloor() throws {
        Self.checkFallback(try Self.fixture("applique-thin", make: Self.thin), "thick where")
    }

    /// An oval model 100 × 14 mm with a tab placed on its narrow end.
    static func spike() -> Project {
        medallion("Spike tab", rx: 50, ry: 7, tabs: TabSettings(enabled: true, placed: [ContourMark(shapeID: id(2), point: Vec2(53, 0)),
                                                                                        ContourMark(shapeID: id(2), point: Vec2(0, 10))]),
                  finish: nil)
    }

    @Test func aTabOnANarrowPartHoldsTheFloor() throws {
        Self.checkFallback(try Self.fixture("spike-tab", make: Self.spike), "narrow part of the model")
    }

    /// A second tabbed part next to the medallion, cut out by its own profile, within the 3D toolpath's reach.
    static func twoCutOuts() -> Project {
        var p = medallion("Two cut-outs", finish: nil)
        let square = DesignShape(id: id(3), name: "Square", kind: .rectangle(width: 20, height: 20, cornerRadius: 0), position: Vec2(137, 75))
        p.shapes.append(square)
        p.operations.append(CAMOperation(id: id(15), name: "Cut out square",
                                         kind: .profile(ProfileParams(side: .outside, direction: .climb, depth: DepthSettings(cutDepth: thickness),
                                                                      tabs: TabSettings(enabled: true, count: 2))),
                                         shapeIDs: [square.id], tool: endMill))
        return p
    }

    @Test func twoTabbedCutOutsHoldTheFloor() throws {
        Self.checkFallback(try Self.fixture("two-cut-outs", make: Self.twoCutOuts), "2 tabbed cut-outs")
    }

    /// A cut-out with a dovetail bit, which leaves its tabs off.
    static func undercut() -> Project {
        var p = medallion("Dovetail cut-out", finish: nil)
        let k = p.operations.firstIndex { $0.name == "Cut out medallion" }!
        p.operations[k].tool = Tool(id: id(901), number: 9, name: "1/2\" dovetail", shape: .dovetail, fluteDirection: .straight,
                                    diameter: 0.5.inch, shankDiameter: 0.25.inch, fluteLength: 0.875.inch, includedAngle: 28,
                                    cutting: endMill.cutting)
        return p
    }

    @Test func aCutOutThatLeavesItsTabsOffHoldsTheFloor() throws {
        Self.checkFallback(try Self.fixture("undercut-cut-out", make: Self.undercut), "leaves its tabs off")
    }

    // MARK: Warnings and nothing to hold

    /// The model's edge 2 mm high, rising gently, below the tab's 3.2 mm top: strips, with a warning that the tabs stand
    /// proud.
    static func proud() -> Project { medallion("Proud tabs", edge: 2, finish: nil, dome: false) }

    @Test func aTabAboveTheModelsEdgeWarns() throws {
        let p = try Self.fixture("tab-above-edge", make: Self.proud)
        let s = try #require(Self.strips(p))
        #expect(s.warnings.count == 1, "\(s.warnings)")
        #expect(s.warnings.first?.contains("proud of the model's edge") == true, "\(s.warnings)")
        let job = CAMEngine.generate(p)
        #expect(job.issues.contains { $0.severity == .warning && $0.operation == "Rough medallion" && $0.message.contains("proud of the model's edge") })
        #expect(!job.hasErrors)
    }

    /// The model's base above the tabs' tops: nothing to hold, no strips, no note.
    static func shallow() -> Project { medallion("Shallow medallion", depth: 10) }

    @Test func aShallowModelNeedsNothing() throws {
        let p = try Self.fixture("medallion-shallow", make: Self.shallow)
        #expect(HoldingTabs.decide(Self.op(p, "Rough medallion"), in: p) == .none)
        let job = CAMEngine.generate(p)
        #expect(!job.issues.contains { $0.message.hasPrefix("Leaves a strip") || $0.message.hasPrefix("Holds its floor") })
        #expect(p.formatVersion < 30)
    }

    /// No cut-out: the 3D finish frees the part, which stays #166's warning.
    static func noTabs() -> Project { medallion("No cut-out", cutOut: false) }

    @Test func noCutOutStillWarns() throws {
        let p = try Self.fixture("no-tabs-through", make: Self.noTabs)
        #expect(HoldingTabs.decide(Self.op(p, "Finish medallion"), in: p) == .none)
        let job = CAMEngine.generate(p)
        #expect(job.issues.contains { $0.severity == .warning && $0.operation == "Finish medallion" && $0.message.contains("3D toolpaths leave no tabs") })
    }

    // MARK: The plateau check

    /// The cut-out cut with its evenly spaced tabs measured from its entry (as a plain 2D profile is), not at the fixed
    /// places the strips are: they don't line up, which is an error.
    @Test func tabsOffTheStripsAreAnError() throws {
        let p = try Self.fixture("mismatch-entry-relative", make: { Self.medallion("Entry-relative tabs", tabs: TabSettings(enabled: true, count: 3)) })
        let s = try #require(Self.strips(p))
        let cutOut = Self.op(p, "Cut out medallion")
        guard case let .profile(c) = cutOut.kind else { Issue.record("no cut-out"); return }
        var ctx = GenerationContext(stock: p.stock, machine: p.machine, units: p.displayUnits)
        ctx.project = p
        let loose = ProfileGenerator.generate(op: cutOut, params: c, shapes: p.shapes(for: cutOut), context: ctx)
        let n = HoldingTabs.mismatches(loose, strips: s, tool: Self.endMill)
        #expect(n > 0)
        let checked = CAMEngine.withStripCheck(loose, strips: s, tool: Self.endMill)
        #expect(checked.errors?.contains { $0.contains("line up with the strips") } == true, "\(checked.errors ?? [])")
        // The job itself cuts them at the strips' places.
        let job = CAMEngine.generate(p)
        #expect(!job.issues.contains { $0.message.contains("line up with the strips") })
    }

    // MARK: Words

    @Test func inspectorAndSetupSheetSayWhatHoldsThePart() throws {
        let p = try Self.fixture("medallion-through", make: Self.through)
        let line = try #require(HoldingTabs.summary(for: Self.op(p, "Finish medallion"), in: p))
        #expect(line.hasPrefix("Leaves the 4 tabs of “Cut out medallion”"), "\(line)")
        #expect(HoldingTabs.leftBy(Self.op(p, "Cut out medallion"), in: p) == ["Medallion"])
        let held = try Self.fixture("material-boundary", make: Self.material)
        let why = try #require(HoldingTabs.summary(for: Self.op(held, "Rough medallion"), in: held))
        #expect(why.hasPrefix("Holds the whole floor") && why.contains("Whole material"), "\(why)")
        let sheet = SetupSheet.html(project: p, job: CAMEngine.generate(p), date: GoldenPostTests.date)
        #expect(sheet.contains("caliper the material"), "setup sheet")
        #expect(sheet.contains("re-zero Z carefully"))
    }
}
