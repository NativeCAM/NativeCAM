import Foundation

/// A named collection of tools, persisted as JSON.
public struct ToolLibrary: Codable, Sendable, Hashable {
    public var tools: [Tool]

    public init(tools: [Tool]) { self.tools = tools }

    public func tool(id: UUID) -> Tool? { tools.first { $0.id == id } }
    public func tool(number: Int) -> Tool? { tools.first { $0.number == number } }

    /// Next unused tool number.
    public var nextToolNumber: Int { (tools.map(\.number).max() ?? 0) + 1 }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(self)
    }

    public static func decode(_ data: Data) throws -> ToolLibrary {
        try JSONDecoder().decode(ToolLibrary.self, from: data)
    }

    /// The end mill to clear a pocket with before `tool` cuts what it leaves (rest machining): the smallest end mill at
    /// least half as big again as `tool` (a 1/4" for a 1/8", a 1/2" for a 1/4"), else the largest one that's still
    /// larger, since a bit barely bigger saves little. Among bits of the same size an upcut comes first, as it lifts the
    /// chips out of the pocket, then the lowest tool number. nil when the library has no end mill larger than `tool`.
    public func clearanceTool(for tool: Tool) -> Tool? {
        let larger = tools.filter { $0.shape == .flatEndMill && $0.diameter > tool.diameter + 1e-6 }
        func before(_ a: Tool, _ b: Tool) -> Bool {
            if abs(a.diameter - b.diameter) > 1e-6 { return a.diameter < b.diameter }
            if (a.fluteDirection == .upcut) != (b.fluteDirection == .upcut) { return a.fluteDirection == .upcut }
            return a.number < b.number
        }
        if let pick = larger.filter({ $0.diameter >= 1.5 * tool.diameter - 1e-6 }).min(by: before) { return pick }
        return larger.min { abs($0.diameter - $1.diameter) > 1e-6 ? $0.diameter > $1.diameter : before($0, $1) }
    }

    /// A typical bit of `shape` to start a new tool from: the starter library's, or for a shape it has none of, a
    /// common size (a 1/32" tip radius, 1.79° per side tapered ball nose; a 1/4" roundover with a 1/2" pilot; a 1/2",
    /// 14° dovetail), all on 1/4" shanks. Their feeds and speeds put the chip load inside the chart for plywood (at the
    /// diameter they cut with at a typical depth): the tapered ball nose's from the end-mill chart, the roundover's
    /// and dovetail's at the thin end of the router-bit chart, as its recommendation gives, at 16,000 RPM (within the
    /// 24,000 RPM speed limit for bits up to 1"). Starting points: cut-test them.
    public static func template(for shape: ToolShape) -> Tool {
        if let t = starter.tools.first(where: { $0.shape == shape }) { return t }
        var c = CuttingData(spindleRPM: 16000, feedRate: 100.inch, plungeRate: 30.inch, stepdown: 0.125.inch, stepoverFraction: 0.4)
        var t: Tool
        switch shape {
        case .taperedBallNose:
            c.feedRate = 150.inch
            c.stepdown = 0.0625.inch
            c.stepoverFraction = 0.1
            t = Tool(number: 0, name: "Tapered Ball Nose", shape: .taperedBallNose, fluteCount: 3, diameter: 0.25.inch,
                     shankDiameter: 0.25.inch, fluteLength: 1.inch, includedAngle: 3.58, tipDiameter: 0.0625.inch, cutting: c)
        case .form:
            // 0.0047" a tooth: the plywood router-bit chart's thin end for a 1" bit (its 3/4" row) is 0.0045".
            c.feedRate = 150.inch
            c.stepdown = 0.25.inch
            t = Tool(number: 0, name: "Roundover", shape: .form, fluteDirection: .straight, diameter: 1.inch, shankDiameter: 0.25.inch,
                     fluteLength: 0.375.inch, cutting: c, form: FormProfile(kind: .roundover, radius: 0.25.inch, pilotDiameter: 0.5.inch))
        case .dovetail:
            // 0.0038" a tooth: the plywood router-bit chart's thin end for a 1/2" bit is 0.0035".
            c.feedRate = 120.inch
            c.stepdown = 0.5.inch
            t = Tool(number: 0, name: "Dovetail", shape: .dovetail, fluteDirection: .straight, diameter: 0.5.inch, shankDiameter: 0.25.inch,
                     fluteLength: 0.5.inch, includedAngle: 28, cutting: c)
        default:
            t = starter.tools[0]
            t.shape = shape
        }
        t.fitDiameterToShape()
        return t
    }

    /// The materials the starter end mills' and ball nose's feeds and speeds suit: their chip load is inside the chart
    /// (`ChipLoad`) for each of these.
    public static let starterMaterials: [MaterialKind] = [.plywood, .hardwood]

    /// Starter library of common router bits. The end mills' and ball nose's feeds and speeds put the chip load inside
    /// Freud's chart (`ChipLoad`) for both plywood and hardwood (`starterMaterials`); softwood, MDF and particleboard want
    /// a thicker chip, which the chip-load row's recommendation gives. The chip is thickened by running the spindle
    /// slower rather than feeding faster: every feed is within 250 in/min, the cutting cap of Avid's slowest drives, and
    /// every speed within a VFD spindle's 6,000–24,000 RPM. The 1/2" end mill runs near the bottom of that range; on a
    /// spindle or router that can't go that slow, raise the speed and the feed together if the machine allows.
    /// Stepdowns are about 0.75×D for the 1/4" bits and 0.5×D for the 1/8" and 1/2" ones. They are starting points:
    /// cut-test and tune for your material, bits and spindle.
    public static let starter: ToolLibrary = {
        func ipm(_ v: Double) -> Double { v.inch }
        // Fixed IDs: a starter tool copied into a project still matches the library entry later.
        func starterID(_ n: Int) -> UUID { UUID(uuidString: String(format: "4E415449-5645-4341-4D00-%012d", n))! }
        return ToolLibrary(tools: [
            Tool(id: starterID(1), number: 1, name: "1/4\" Upcut End Mill", shape: .flatEndMill, fluteDirection: .upcut, fluteCount: 2,
                 diameter: 0.25.inch, fluteLength: 1.0.inch,
                 cutting: CuttingData(spindleRPM: 13000, feedRate: ipm(220), plungeRate: ipm(50),
                                      stepdown: 0.1875.inch, stepoverFraction: 0.4)),
            Tool(id: starterID(2), number: 2, name: "1/8\" Upcut End Mill", shape: .flatEndMill, fluteDirection: .upcut, fluteCount: 2,
                 diameter: 0.125.inch, shankDiameter: 0.125.inch, fluteLength: 0.5.inch,
                 cutting: CuttingData(spindleRPM: 18000, feedRate: ipm(120), plungeRate: ipm(25),
                                      stepdown: 0.0625.inch, stepoverFraction: 0.4)),
            Tool(id: starterID(3), number: 3, name: "1/4\" Downcut End Mill", shape: .flatEndMill, fluteDirection: .downcut, fluteCount: 2,
                 diameter: 0.25.inch, fluteLength: 1.0.inch,
                 cutting: CuttingData(spindleRPM: 13000, feedRate: ipm(220), plungeRate: ipm(40),
                                      stepdown: 0.1875.inch, stepoverFraction: 0.4)),
            Tool(id: starterID(4), number: 4, name: "1/4\" Compression End Mill", shape: .flatEndMill, fluteDirection: .compression, fluteCount: 2,
                 diameter: 0.25.inch, fluteLength: 0.875.inch,
                 cutting: CuttingData(spindleRPM: 13000, feedRate: ipm(220), plungeRate: ipm(50),
                                      stepdown: 0.25.inch, stepoverFraction: 0.4),
                 upcutLength: 0.25.inch),
            Tool(id: starterID(5), number: 5, name: "60° V-Bit 1/2\"", shape: .vBit, fluteDirection: .straight, fluteCount: 2,
                 diameter: 0.5.inch, shankDiameter: 0.25.inch, fluteLength: 0.433.inch, includedAngle: 60,
                 cutting: CuttingData(spindleRPM: 18000, feedRate: ipm(80), plungeRate: ipm(30),
                                      stepdown: 0.125.inch, stepoverFraction: 0.1)),
            Tool(id: starterID(6), number: 6, name: "90° V-Bit 1/2\"", shape: .vBit, fluteDirection: .straight, fluteCount: 2,
                 diameter: 0.5.inch, shankDiameter: 0.25.inch, fluteLength: 0.25.inch, includedAngle: 90,
                 cutting: CuttingData(spindleRPM: 18000, feedRate: ipm(80), plungeRate: ipm(30),
                                      stepdown: 0.125.inch, stepoverFraction: 0.1)),
            Tool(id: starterID(7), number: 7, name: "1/4\" Ball Nose", shape: .ballNose, fluteDirection: .upcut, fluteCount: 2,
                 diameter: 0.25.inch, fluteLength: 0.75.inch,
                 cutting: CuttingData(spindleRPM: 15000, feedRate: ipm(250), plungeRate: ipm(40),
                                      stepdown: 0.125.inch, stepoverFraction: 0.1)),
            Tool(id: starterID(8), number: 8, name: "1-1/4\" Surfacing Bit", shape: .surfacing, fluteDirection: .straight, fluteCount: 3,
                 diameter: 1.25.inch, shankDiameter: 0.5.inch, fluteLength: 0.25.inch,
                 cutting: CuttingData(spindleRPM: 12000, feedRate: ipm(150), plungeRate: ipm(20),
                                      stepdown: 0.03.inch, stepoverFraction: 0.5)),
            Tool(id: starterID(9), number: 9, name: "30° Engraving 0.010\" Tip", shape: .engraving, fluteDirection: .straight, fluteCount: 1,
                 diameter: 0.125.inch, shankDiameter: 0.125.inch, fluteLength: 0.2.inch, includedAngle: 30,
                 tipDiameter: 0.010.inch,
                 cutting: CuttingData(spindleRPM: 18000, feedRate: ipm(40), plungeRate: ipm(15),
                                      stepdown: 0.03.inch, stepoverFraction: 0.1)),
            Tool(id: starterID(10), number: 10, name: "1/2\" Upcut End Mill", shape: .flatEndMill, fluteDirection: .upcut, fluteCount: 2,
                 diameter: 0.5.inch, fluteLength: 1.25.inch,
                 cutting: CuttingData(spindleRPM: 6500, feedRate: ipm(250), plungeRate: ipm(40),
                                      stepdown: 0.25.inch, stepoverFraction: 0.4)),
        ])
    }()
}
