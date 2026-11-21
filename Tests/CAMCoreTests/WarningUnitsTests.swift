import Foundation
import Testing
@testable import CAMCore

/// #46: toolpath generators give lengths and feeds in their warnings in the project's display units, as the job's
/// checks do.
struct WarningUnitsTests {
    static let lib = ToolLibrary.starter

    /// True when `text` names millimetres anywhere ("mm", "mm/min").
    static func saysMillimetres(_ text: String) -> Bool {
        text.range(of: #"\bmm\b"#, options: .regularExpression) != nil
    }

    static func inch(_ p: Project) -> Project {
        var p = p
        p.displayUnits = .inch
        return p
    }

    /// Flat generators that warn with a length: a bevel and a prism deeper than the V-bit's V, flutes deeper than it,
    /// and an inside profile with a bit too big for the shape.
    static func flatJob() -> Project {
        let square = Fixture.rect(40, 40, at: Vec2(50, 50))
        let star = DesignShape(kind: .star(points: 5, outerRadius: 30, innerRadius: 12), position: Vec2(130, 75))
        let line = DesignShape(kind: .paths([Polyline([Vec2(10, 130), Vec2(190, 130)], closed: false)]), position: .zero)
        let tiny = Fixture.rect(2, 2, at: Vec2(180, 20))
        let v90 = lib.tool(number: 6)!
        let ops = [
            CAMOperation(name: "Bevel", kind: .chamfer(ChamferParams(width: 8)), shapeIDs: [square.id], tool: v90),
            CAMOperation(name: "Prism", kind: .prism(PrismParams()), shapeIDs: [star.id], tool: v90),
            CAMOperation(name: "Flutes", kind: .fluting(FlutingParams(depth: 10)), shapeIDs: [line.id], tool: v90),
            CAMOperation(name: "Pocket wall", kind: .profile(ProfileParams(side: .inside, depth: DepthSettings(cutDepth: 3))),
                         shapeIDs: [tiny.id], tool: Fixture.endMill),
        ]
        return Fixture.project(shapes: [square, star, line, tiny], ops: ops)
    }

    /// A round blank rounded to the size it already is.
    static func roundingJob() -> Project {
        var stock = Stock(materialName: "Maple")
        stock.setRotary(RotaryStock(shape: .cylinder, diameter: 2.inch, length: 8.inch))
        var machine = MachineProfile.avidPRO6060
        machine.rotary = RotaryAxis(centerHeight: 4.inch)
        let op = CAMOperation(name: "Round", kind: .rounding(RoundingParams()), shapeIDs: [], tool: lib.tool(number: 1)!)
        return Project(name: "Rounding", displayUnits: .mm, stock: stock, machine: machine, operations: [op])
    }

    @Test func flatGeneratorWarningsFollowTheDisplayUnits() throws {
        let issues = CAMEngine.generate(Self.inch(Self.flatJob())).issues.map(\.message)
        for message in issues {
            #expect(!Self.saysMillimetres(message), "\(message)")
        }
        // The 90° V-bit's V is 1/4 in tall.
        let bevel = try #require(issues.first { $0.contains("The bevel reaches") })
        #expect(bevel.contains("only cuts 0.2500 in down its V"), "\(bevel)")
        let prism = try #require(issues.first { $0.contains("The prism is") })
        #expect(prism.contains("only cuts 0.2500 in"), "\(prism)")
        let flutes = try #require(issues.first { $0.contains("The flutes are") })
        #expect(flutes.contains("0.3937 in deep") && flutes.contains("(0.2500 in)"), "\(flutes)")
        let profile = try #require(issues.first { $0.contains("too large to fit") })
        #expect(profile.contains("(0.2500 in)"), "\(profile)")
        // The same job in millimetres says so.
        let metric = CAMEngine.generate(Self.flatJob()).issues.map(\.message)
        #expect(metric.contains { $0.contains("only cuts 6.350 mm down its V") })
    }

    @Test func roundingSaysTheBlankSizeInTheDisplayUnits() throws {
        let issues = CAMEngine.generate(Self.inch(Self.roundingJob())).issues.map(\.message)
        let round = try #require(issues.first { $0.contains("already no bigger than") })
        #expect(round.contains("2.0000 in round") && !Self.saysMillimetres(round), "\(round)")
    }

    @Test func rotary3DWarningsFollowTheDisplayUnits() throws {
        // The demo pawn is an inch project whose finish slows near the axis.
        let p = Project.demoPawn()
        #expect(p.displayUnits == .inch)
        let issues = CAMEngine.generate(p).issues.map(\.message)
        for message in issues {
            #expect(!Self.saysMillimetres(message), "\(message)")
        }
        let slow = try #require(issues.first { $0.contains("the cut slows to keep up") })
        #expect(slow.contains(" in/min at ") && slow.contains(" in from the axis"), "\(slow)")
        // Moved half off the blank, the model runs past its end and is measured in inches too.
        var off = p
        let i = try #require(off.shapes.firstIndex { $0.modelSpec != nil })
        off.shapes[i].position.x += 3.inch
        let past = try #require(CAMEngine.generate(off).issues.map(\.message).first { $0.contains("runs past the end of the blank") })
        #expect(past.contains("the blank 6.0000 in)") && !Self.saysMillimetres(past), "\(past)")
    }
}
