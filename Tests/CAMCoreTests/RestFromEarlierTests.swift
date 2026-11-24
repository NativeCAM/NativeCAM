import Foundation
import Testing
@testable import CAMCore

/// Pocket rest from earlier toolpaths (#83): a 1/8" end mill set to rest from the pocket toolpaths before it cuts only
/// what a larger bit's pocket on the same shapes left: corners and narrow parts.
struct RestFromEarlierTests {
    static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "2E570000-0000-4000-8001-%012d", n))! }
    static var quarter: Tool { ToolLibrary.starter.tool(number: 1)! }
    static var eighth: Tool { ToolLibrary.starter.tool(number: 2)! }

    /// A 60 × 40 mm pocket with a 5 mm slot (too narrow for a 1/4" bit) 20 mm long out of the middle of its top.
    static let slotted = DesignShape(id: id(1), name: "Slotted pocket",
                                     kind: .paths([Polyline([Vec2(70, 50), Vec2(130, 50), Vec2(130, 90), Vec2(102.5, 90), Vec2(102.5, 110),
                                                             Vec2(97.5, 110), Vec2(97.5, 90), Vec2(70, 90)], closed: true)]),
                                     position: .zero)

    static func pocket(_ id: UUID, _ name: String, tool: Tool, depth: Double = 6, rest: Bool = false, shapes: [DesignShape] = [slotted],
                       allowance: Double = 0) -> CAMOperation {
        CAMOperation(id: id, name: name,
                     kind: .pocket(PocketParams(depth: DepthSettings(cutDepth: depth), allowance: allowance, restFromEarlier: rest ? true : nil)),
                     shapeIDs: shapes.map(\.id), tool: tool)
    }

    /// The 1/4" pocket, then the 1/8" resting from it.
    static func project(firstDepth: Double = 6, shapes: [DesignShape] = [slotted], units: LengthUnit = .mm) -> Project {
        var machine = MachineProfile.avidPRO6060
        machine.outputUnits = units
        machine.outputArcs = false
        let ops = [pocket(id(2), "Pocket 1/4\"", tool: quarter, depth: firstDepth, shapes: shapes),
                   pocket(id(3), "Rest 1/8\"", tool: eighth, rest: true, shapes: shapes)]
        return Project(name: "Pocket rest", displayUnits: units, stock: Fixture.stock, machine: machine, shapes: shapes, operations: ops)
    }

    static func regions(_ shapes: [DesignShape]) -> [Region] {
        Region.build(from: shapes.flatMap { $0.polylines(tolerance: 0.01) }.filter(\.isClosed), fill: .evenOdd)
    }

    /// Feed moves below the surface: start and end.
    static func cuts(_ tp: Toolpath) -> [(Vec3, Vec3)] {
        var out: [(Vec3, Vec3)] = []
        tp.forEachMotion { s, m in if m.kind != .rapid, m.kind != .dwell, m.end.z < -1e-6, s.z < -1e-6 { out.append((s, m.end)) } }
        return out
    }

    /// The 1/8" clears the slot and the corners, nowhere else: simulated, everything it removes is in what the 1/4" left
    /// (a cell spare), and afterwards the slot is cut to depth.
    @Test func clearsOnlyTheCornersAndNarrowPartsTheLargerBitMissed() throws {
        let p = Self.project()
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors, "\(job.issues.map(\.message))")
        try #require(job.toolpaths.count == 2)
        let (large, rest) = (job.toolpaths[0], job.toolpaths[1])
        #expect(large.tool.number == 1 && rest.tool.number == 2 && rest.id == Self.id(3))
        #expect(rest.warnings.isEmpty, "\(rest.warnings)")
        let left = Region.nest(try #require(rest.restAreas))
        // The slot (5 × 20 mm, less the 1/8" bit's rounding) and four corners.
        let area = left.reduce(0) { $0 + $1.area }
        #expect(area > 80 && area < 110, "left \(area) mm²")
        #expect(left.contains { $0.contains(Vec2(100, 105)) })
        #expect(!left.contains { $0.contains(Vec2(100, 70)) })

        var sim = MaterialSimulator(stock: p.stock, cellSize: 0.1)
        large.forEachMotion { s, m in sim.apply(m, from: s, tool: large.tool) }
        let afterLarge = sim.grid
        rest.forEachMotion { s, m in sim.apply(m, from: s, tool: rest.tool) }
        let afterRest = sim.grid
        let near = Model3DGenerator.Mask(left.flatMap { $0.offset(by: 0.25) }, pitch: 0.05)
        var stray: [Vec2] = []
        for r in 0..<afterRest.rows {
            for c in 0..<afterRest.columns {
                let i = r * afterRest.columns + c
                guard afterLarge.heights[i] - afterRest.heights[i] > 0.01 else { continue }
                let q = afterRest.origin + Vec2(Double(c), Double(r)) * afterRest.cellSize
                if !near.contains(q) { stray.append(q) }
            }
        }
        #expect(stray.isEmpty, "\(stray.count) cells cut outside what was left, e.g. \(stray.prefix(4))")
        for y in stride(from: 92.0, through: 106, by: 2) {
            #expect(abs(Double(afterRest.height(at: Vec2(100, y)) ?? 0) + 6) < 0.01, "slot at y = \(y)")
        }
        // Much less cutting than clearing the whole pocket with the 1/8".
        var whole = p
        whole.operations.removeFirst()
        whole.operations[0].kind = .pocket(PocketParams(depth: DepthSettings(cutDepth: 6)))
        let full = try #require(CAMEngine.generate(whole).toolpaths.first)
        #expect(rest.cuttingLength < 0.35 * full.cuttingLength, "\(rest.cuttingLength) vs \(full.cuttingLength) mm")
    }

    /// The wall pass runs only next to what's left: no cut along the middle of the long bottom wall.
    @Test func wallPassRunsOnlyNextToWhatsLeft() throws {
        let rest = try #require(CAMEngine.generate(Self.project()).toolpaths.last)
        let bottom = Self.cuts(rest).filter { abs($0.0.y - (50 + Self.eighth.radius)) < 0.01 && abs($0.1.y - (50 + Self.eighth.radius)) < 0.01 }
        #expect(!bottom.isEmpty, "no wall pass along the bottom corners")
        for (s, e) in bottom {
            #expect(max(s.x, e.x) < 70 + 8 || min(s.x, e.x) > 130 - 8, "a wall cut from x = \(s.x) to \(e.x)")
        }
    }

    /// A round pocket the 1/4" reaches everywhere leaves nothing: the rest toolpath is empty, says so, and posts nothing.
    @Test func nothingLeftPostsNothing() throws {
        let circle = DesignShape(id: Self.id(4), name: "Round pocket", kind: .circle(radius: 20), position: Vec2(100, 75))
        let p = Self.project(shapes: [circle])
        let job = CAMEngine.generate(p)
        let rest = try #require(job.toolpaths.first { $0.id == Self.id(3) })
        #expect(rest.isEmpty)
        #expect(rest.restAreas == [])
        #expect(rest.warnings.contains { $0.hasPrefix("Nothing left to cut") })
        #expect(job.issues.contains { $0.operation == "Rest 1/8\"" && $0.message.hasPrefix("Nothing left to cut") })
        let gcode = String(decoding: GoldenPostTests.post(p, job.toolpaths), as: UTF8.self)
        #expect(!gcode.contains("T2M6") && !gcode.contains("Rest 1/8"))
    }

    /// With no larger pocket before it, it clears the whole pocket, and says why.
    @Test func withoutAnEarlierPocketItClearsTheWholePocket() throws {
        var p = Self.project()
        p.operations.removeFirst()
        let job = CAMEngine.generate(p)
        let tp = try #require(job.toolpaths.first)
        #expect(tp.warnings.first?.hasPrefix("No enabled pocket toolpath before this one") == true)
        var plain = p
        plain.operations[0].kind = .pocket(PocketParams(depth: DepthSettings(cutDepth: 6)))
        let full = try #require(CAMEngine.generate(plain).toolpaths.first)
        #expect(tp.motions == full.motions)
        #expect(tp.restAreas == nil)
    }

    /// An earlier pocket that's shallower isn't counted.
    @Test func aShallowerEarlierPocketIsNotCounted() throws {
        let p = Self.project(firstDepth: 3)
        let refs = RestMachining.pocketReferences(for: p.operations[1], in: p)
        #expect(refs.operations.isEmpty)
        #expect(refs.warnings.first?.contains("doesn't cut these shapes as deep") == true)
        let tp = try #require(CAMEngine.generate(p).toolpaths.last)
        #expect(tp.restAreas == nil)
        #expect(tp.cuttingLength > 1000)
    }

    /// Earlier pockets with a bit no larger, off, or after it don't count; one with a larger bit does.
    @Test func referencesAreEarlierEnabledLargerPocketsOnTheSameShapes() {
        var p = Self.project()
        let other = Fixture.rect(20, 20, at: Vec2(30, 30))
        p.shapes.append(other)
        let sameSize = Self.pocket(Self.id(5), "Same size", tool: Self.eighth)
        var off = Self.pocket(Self.id(6), "Off", tool: Self.quarter)
        off.enabled = false
        let elsewhere = Self.pocket(Self.id(7), "Elsewhere", tool: Self.quarter, shapes: [other])
        let after = Self.pocket(Self.id(8), "After", tool: Self.quarter)
        p.operations.insert(contentsOf: [sameSize, off, elsewhere], at: 1)
        p.operations.append(after)
        let refs = RestMachining.pocketReferences(for: p.operations[4], in: p)
        #expect(refs.operations.map(\.id) == [Self.id(2)])
        #expect(RestMachining.dependencies(of: p.operations[4], in: p) == [Self.id(2)])
    }

    /// An earlier pocket that leaves a wall allowance leaves the walls for this one: the wall pass then runs all the way
    /// round.
    @Test func anEarlierAllowanceLeavesTheWholeWallPass() throws {
        var p = Self.project()
        p.operations[0] = Self.pocket(Self.id(2), "Pocket 1/4\"", tool: Self.quarter, allowance: 0.3)
        let rest = try #require(CAMEngine.generate(p).toolpaths.last)
        let bottom = Self.cuts(rest).filter { abs($0.0.y - (50 + Self.eighth.radius)) < 0.01 && abs($0.1.y - (50 + Self.eighth.radius)) < 0.01 }
        #expect(bottom.contains { min($0.0.x, $0.1.x) < 95 && max($0.0.x, $0.1.x) > 105 }, "no wall pass along the middle of the bottom wall")
    }

    /// A clearance tool as well: it clears first, and what it and the earlier pocket reached both count.
    @Test func worksWithAClearanceToolToo() throws {
        var p = Self.project()
        guard case var .pocket(pp) = p.operations[1].kind else { return }
        pp.clearanceTool = RestMachiningTests.half
        p.operations[1].kind = .pocket(pp)
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors)
        #expect(job.toolpaths.map(\.tool.number) == [1, 10, 2])
        #expect(job.toolpaths[2].restAreas?.isEmpty == false)
    }

    @Test func restFromEarlierNeedsNoNewFormatAndSavesOnlyWhenOn() throws {
        let p = Self.project()
        #expect(p.formatVersion < 17)
        #expect(try Project.decode(p.encoded()) == p)
        let off = String(decoding: try JSONEncoder().encode(PocketParams(depth: DepthSettings(cutDepth: 3))), as: UTF8.self)
        #expect(!off.contains("restFromEarlier"))
        let on = String(decoding: try JSONEncoder().encode(PocketParams(depth: DepthSettings(cutDepth: 3), restFromEarlier: true)), as: UTF8.self)
        #expect(on.contains("\"restFromEarlier\":true"))
    }
}
