import Foundation

/// A moulding: an open profile vector (a cross-section, its width across and its height up as drawn) swept along one or
/// more rail vectors, open or closed, into a 3D surface (see `MouldingSweep`), which an optional roughing pass and a 3D
/// finish then cut with the 3D strategies (`MouldingGenerator`). The profile's start sits on the rail and its highest
/// point at the material top; at sharp rail corners the surface meets in a mitre, as a picture frame's does. Format 22.
///
/// The operation's shapes are the profile (`profileID`) and the rails (every other shape).
public struct MouldingParams: Hashable, Codable, Sendable {
    /// Which side of the rail the profile lies on, looking along the rail. A closed rail is read counter-clockwise, so
    /// left is inside it.
    public enum Side: String, Codable, Sendable, CaseIterable, Identifiable {
        case left, right
        public var id: String { rawValue }
        /// The label for a rail that's `closed` or open.
        public func label(closed: Bool) -> String {
            switch self {
            case .left: closed ? "Inside" : "Left"
            case .right: closed ? "Outside" : "Right"
            }
        }
    }

    /// The shape drawn as the cross-section.
    public var profileID: UUID
    public var side: Side
    /// Upside down: the profile's high points become its low points.
    public var flipped: Bool
    /// End for end: the profile's end sits on the rail instead of its start.
    public var mirrored: Bool
    /// The 3D finish (its boundary is always the swept surface).
    public var finish: Finish3DParams
    /// A layered roughing pass with its own bit (an end mill) before the finish; nil = none.
    public var roughing: MouldingRoughing?

    public init(profileID: UUID, side: Side = .left, flipped: Bool = false, mirrored: Bool = false,
                finish: Finish3DParams = Finish3DParams(), roughing: MouldingRoughing? = nil) {
        self.profileID = profileID
        self.side = side
        self.flipped = flipped
        self.mirrored = mirrored
        self.finish = finish
        self.roughing = roughing
    }

    /// The project file format a moulding needs: an older build can't read it.
    public static let formatVersion = 22

    /// The finish a new moulding starts with: rows along the rail where they can run along all of it (one open rail
    /// that doesn't turn more than 20° from its general direction), otherwise passes that follow the rail round its
    /// turns at a constant scallop.
    public static func suggestedFinish(rails: [Polyline]) -> Finish3DParams {
        if rails.count == 1, let rail = rails.first, !rail.isClosed, rail.count >= 2 {
            let chord = rail.points[rail.count - 1] - rail.points[0]
            if chord.length > 1e-6 {
                let dir = chord.normalized
                let straight = (0..<rail.segmentCount).allSatisfy { i in
                    let (a, b) = rail.segment(i)
                    let d = b - a
                    return d.length < 1e-9 || d.normalized.dot(dir) >= cos(20 * Double.pi / 180)
                }
                if straight {
                    var angle = chord.angle * 180 / .pi
                    if angle < 0 { angle += 180 }
                    if angle >= 180 { angle -= 180 }
                    return Finish3DParams(stepoverFraction: 0.1, rasterAngle: (angle * 100).rounded() / 100, boundary: .model)
                }
            }
        }
        return Finish3DParams(stepoverFraction: 0.1, boundary: .model, strategy: .constantScallop)
    }
}

/// A moulding's roughing pass: layers cleared with an end mill, leaving an allowance for the finish.
public struct MouldingRoughing: Hashable, Codable, Sendable {
    public var tool: Tool
    /// Material left on the surface for the finish, mm.
    public var allowance: Double
    /// Max depth per layer; nil uses the tool's stepdown.
    public var passDepth: Double?
    /// Stepover as a fraction of the tool diameter; nil uses the tool's.
    public var stepoverFraction: Double?
    /// The offset rings' cut direction; nil = climb, as they always have. Conventional is format 27.
    public var cutDirection: PassDirection?

    public init(tool: Tool, allowance: Double = 0.02.inch, passDepth: Double? = nil, stepoverFraction: Double? = nil,
                cutDirection: PassDirection? = nil) {
        self.tool = tool
        self.allowance = allowance
        self.passDepth = passDepth
        self.stepoverFraction = stepoverFraction
        self.cutDirection = cutDirection
    }

    /// The 3D roughing settings this pass cuts with, over the swept surface.
    public var rough3D: Rough3DParams {
        Rough3DParams(allowance: allowance, passDepth: passDepth, stepoverFraction: stepoverFraction, boundary: .model,
                      cutDirection: cutDirection)
    }
}
