import Foundation

/// A short program that exercises everything a post writes, for trying a new controller safely: run it first in
/// the controller's check mode (Grbl's `$C`), then as an air cut, then 0.5 mm deep in scrap. Measuring the circles
/// shows unit and arc errors, and the depth after each tool change shows re-zero errors.
///
/// It holds a 40 mm square; circles of 1, 5, 10, 25 and 50 mm radius, each as four quarter arcs starting in a
/// different quadrant; a helix; a three-second dwell; two tool changes (T1, T2, back to T1) with the dust collector
/// on after each; a toolpath whose name fills a comment to the line-length limit; and the park and program end.
public enum AcceptanceTest {
    public static func job(machine: MachineProfile) -> (Project, [Toolpath]) {
        let lib = ToolLibrary.starter
        let quarter = lib.tool(number: 1)!, eighth = lib.tool(number: 2)!
        let stock = Stock(width: 300, height: 200, thickness: 19, materialName: "Scrap for testing",
                          clearanceHeight: 10, plungeHeight: 2, homePosition: Vec3(0, 0, 25))
        var project = Project(name: "NativeCAM acceptance test", displayUnits: machine.outputUnits, stock: stock, machine: machine)
        project.notes = "Run in check mode, then as an air cut, then 0.5 mm deep in scrap."
        let depth = -0.5, feed = 1000.0, plunge = 300.0
        func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "AC0E0000-0000-0000-0000-%012d", n))! }

        // Square, then the circles.
        var motions: [Motion] = [.rapid(Vec3(20, 20, 2)), .feed(Vec3(20, 20, depth), plunge)]
        for p in [Vec3(60, 20, depth), Vec3(60, 60, depth), Vec3(20, 60, depth), Vec3(20, 20, depth)] { motions.append(.feed(p, feed)) }
        motions.append(.rapid(Vec3(20, 20, 2)))
        let circles: [(r: Double, c: Vec2)] = [(1, Vec2(90, 30)), (5, Vec2(110, 30)), (10, Vec2(140, 30)), (25, Vec2(200, 40)),
                                               (50, Vec2(110, 120))]
        for (k, circle) in circles.enumerated() {
            // Start in a different quadrant each time, so every quadrant change is crossed both ways.
            let start = Double(k % 4) * .pi / 2 + .pi / 4
            func point(_ a: Double) -> Vec3 { Vec3(circle.c.x + circle.r * cos(a), circle.c.y + circle.r * sin(a), depth) }
            let s = point(start)
            motions += [.rapid(Vec3(s.x, s.y, 2)), .feed(s, plunge)]
            for q in 1...4 {
                let a = k % 2 == 0 ? start + Double(q) * .pi / 2 : start - Double(q) * .pi / 2
                motions.append(Motion(kind: k % 2 == 0 ? .arcCCW : .arcCW, end: point(a), center: circle.c, feed: feed))
            }
            motions.append(.rapid(Vec3(s.x, s.y, 2)))
        }
        let shapes = Toolpath(id: id(1), name: "Square and circles 1-50 mm", tool: quarter, spindleRPM: 18000,
                              start: Vec3(20, 20, stock.clearanceHeight), motions: motions)

        // Helix: three turns of quarter arcs down to the test depth, then a three-second dwell.
        let hc = Vec2(250, 140), hr = 15.0
        var helix: [Motion] = [.rapid(Vec3(hc.x + hr, hc.y, 2)), .feed(Vec3(hc.x + hr, hc.y, 0), plunge)]
        for q in 1...12 {
            let a = Double(q) * .pi / 2
            helix.append(Motion(kind: .arcCCW, end: Vec3(hc.x + hr * cos(a), hc.y + hr * sin(a), depth * Double(q) / 12),
                                center: hc, feed: feed))
        }
        helix += [Motion(kind: .dwell, end: Vec3(hc.x + hr, hc.y, depth), feed: 3), .rapid(Vec3(hc.x + hr, hc.y, 2))]
        let helixPath = Toolpath(id: id(2), name: "Helix and 3 s dwell", tool: eighth, spindleRPM: 18000,
                                 start: Vec3(hc.x + hr, hc.y, stock.clearanceHeight), motions: helix)

        // Back to the first tool: a line whose comment fills the controller's line limit.
        let long = Toolpath(id: id(3), name: "Second change back to T1 with a long toolpath name to fill the comment to the line limit",
                            tool: quarter, spindleRPM: 16000, start: Vec3(270, 20, stock.clearanceHeight),
                            motions: [.rapid(Vec3(270, 20, 2)), .feed(Vec3(270, 20, depth), plunge), .feed(Vec3(290, 20, depth), feed),
                                      .rapid(Vec3(290, 20, 2))])
        return (project, [shapes, helixPath, long])
    }
}
