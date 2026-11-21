import Foundation

/// Where a rotary job's blank lies on the machine: the one mapping between the blank's own frame, in which every
/// rotary toolpath is generated, simulated and checked, and the machine's, in which the posts write X and Y.
///
/// The blank's frame is the design sheet's, and `Stock.toWork` gives work coordinates in it: X along the rotation
/// axis from the chosen end of the blank, Y across a face (around the blank, on a wrapped job) from the axis
/// centreline, Z from the axis, and A turning about +X by the right-hand rule. Indexing, wrapping, rounding and 3D
/// rotary roughing and finishing all work there, whichever way the axis is mounted.
///
/// - Along X (Avid's chuck on the left; Vectric's "Wrap Y2A" post): the machine's frame is the blank's.
/// - Along Y (Avid's chuck at the front; "Wrap X2A"): the whole setup turned a quarter turn anticlockwise, seen from
///   above. The blank's X runs along machine +Y from the front end, its Y along machine −X (so X zero is on the
///   centreline), and A turns about +Y by the right-hand rule, as Avid's Wrap X to A post defines it.
///
/// A turn about Z is a rotation, not a mirror: an along-Y job is the along-X job turned in machine space, with the
/// same A and Z words, X and Y swapped (X negated), arcs turning the same way, and a design reading the same way
/// round from above.
public struct RotaryFrame: Sendable {
    public var stock: Stock
    public var alignment: RotaryAxis.Alignment

    public init(stock: Stock, alignment: RotaryAxis.Alignment) {
        self.stock = stock
        self.alignment = alignment
    }

    /// The frame `machine` cuts `stock` in: its rotary axis's on a rotary blank, along X on a flat sheet.
    public init(stock: Stock, machine: MachineProfile) {
        self.init(stock: stock, alignment: stock.rotary == nil ? .x : machine.rotary?.alignment ?? .x)
    }

    public init(_ project: Project) { self.init(stock: project.stock, machine: project.machine) }

    /// Machine work coordinates (G54) of a toolpath point (design XY, Z from the material top).
    public func toWork(_ p: Vec3) -> Vec3 { alignment.machine(stock.toWork(p)) }

    /// Inverse of `toWork`.
    public func fromWork(_ p: Vec3) -> Vec3 { stock.fromWork(alignment.blank(p)) }

    /// Where the tool is for a point of a wrapped toolpath, in machine work coordinates: over the axis centreline at
    /// the point's station along the blank and its height. Its sheet Y is an angle of the blank, not a move.
    public func overAxis(_ p: Vec3) -> Vec3 { toWork(Vec3(p.x, stock.originPoint.y, p.z)) }

    /// The machine box (work coordinates) a box of toolpath points covers.
    public func workBox(min lo: Vec3, max hi: Vec3) -> (min: Vec3, max: Vec3) {
        let a = toWork(lo), b = toWork(hi)
        return (Vec3(Swift.min(a.x, b.x), Swift.min(a.y, b.y), Swift.min(a.z, b.z)),
                Vec3(Swift.max(a.x, b.x), Swift.max(a.y, b.y), Swift.max(a.z, b.z)))
    }

    /// The machine's travel in the blank's frame: along the blank, across it, Z.
    public func blankTravel(_ travel: Vec3) -> Vec3 { alignment == .x ? travel : Vec3(travel.y, travel.x, travel.z) }

    /// A machine point's distance along the axis (its X along X, its Y along Y).
    public func along(_ p: Vec3) -> Double { alignment == .x ? p.x : p.y }
}

public extension RotaryAxis.Alignment {
    /// Machine coordinates of a vector or point in the blank's frame: unchanged along X; along Y, turned a quarter
    /// turn anticlockwise about Z (X → +Y, Y → −X). Never −0, so a value on the centreline writes as 0.
    func machine(_ p: Vec3) -> Vec3 { self == .x ? p : Vec3(-p.y + 0, p.x, p.z) }

    /// Inverse of `machine`.
    func blank(_ p: Vec3) -> Vec3 { self == .x ? p : Vec3(p.y, -p.x + 0, p.z) }

    /// The machine axis the blank runs along, "X" or "Y".
    var axisName: String { self == .x ? "X" : "Y" }
    /// The machine axis across the blank: its zero is on the centreline.
    var acrossName: String { self == .x ? "Y" : "X" }

    /// Which way the top of the blank rolls when A turns positive, by the right-hand rule about the axis: toward −Y
    /// along X, toward +X along Y; the other way on a `reversed` axis. ASCII signs for G-code comments.
    func topRolls(reversed: Bool, ascii: Bool = false) -> String {
        let minus = ascii ? "-" : "−"
        let negative = (self == .x) != reversed
        return (negative ? minus : "+") + acrossName
    }

    /// The end of the blank at design X = 0 (`start`) or at its length: left and right along X, front and back
    /// along Y (Avid's chuck is at the left end, or at the front).
    func endName(start: Bool) -> String {
        switch self {
        case .x: start ? "left" : "right"
        case .y: start ? "front" : "back"
        }
    }
}
