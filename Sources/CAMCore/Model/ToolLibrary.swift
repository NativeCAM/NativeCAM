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

    /// Starter library of common router bits. Feeds and speeds put the chip load at the low end of Freud's (end mills)
    /// and Amana's (ball nose) charts for plywood/hardwood, with stepdowns of about 0.75×D, within a NEMA 34 Avid
    /// PRO's 400 IPM cutting cap. They are starting points: cut-test and tune for your material, bits and spindle.
    public static let starter: ToolLibrary = {
        func ipm(_ v: Double) -> Double { v.inch }
        // Fixed IDs: a starter tool copied into a project still matches the library entry later.
        func starterID(_ n: Int) -> UUID { UUID(uuidString: String(format: "4E415449-5645-4341-4D00-%012d", n))! }
        return ToolLibrary(tools: [
            Tool(id: starterID(1), number: 1, name: "1/4\" Upcut End Mill", shape: .flatEndMill, fluteDirection: .upcut, fluteCount: 2,
                 diameter: 0.25.inch, fluteLength: 1.0.inch,
                 cutting: CuttingData(spindleRPM: 18000, feedRate: ipm(220), plungeRate: ipm(50),
                                      stepdown: 0.1875.inch, stepoverFraction: 0.4)),
            Tool(id: starterID(2), number: 2, name: "1/8\" Upcut End Mill", shape: .flatEndMill, fluteDirection: .upcut, fluteCount: 2,
                 diameter: 0.125.inch, shankDiameter: 0.125.inch, fluteLength: 0.5.inch,
                 cutting: CuttingData(spindleRPM: 18000, feedRate: ipm(120), plungeRate: ipm(25),
                                      stepdown: 0.0625.inch, stepoverFraction: 0.4)),
            Tool(id: starterID(3), number: 3, name: "1/4\" Downcut End Mill", shape: .flatEndMill, fluteDirection: .downcut, fluteCount: 2,
                 diameter: 0.25.inch, fluteLength: 1.0.inch,
                 cutting: CuttingData(spindleRPM: 18000, feedRate: ipm(220), plungeRate: ipm(40),
                                      stepdown: 0.1875.inch, stepoverFraction: 0.4)),
            Tool(id: starterID(4), number: 4, name: "1/4\" Compression End Mill", shape: .flatEndMill, fluteDirection: .compression, fluteCount: 2,
                 diameter: 0.25.inch, fluteLength: 0.875.inch,
                 cutting: CuttingData(spindleRPM: 18000, feedRate: ipm(220), plungeRate: ipm(50),
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
                 cutting: CuttingData(spindleRPM: 18000, feedRate: ipm(250), plungeRate: ipm(40),
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
        ])
    }()
}
