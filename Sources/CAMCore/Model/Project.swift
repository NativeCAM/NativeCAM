import Foundation

/// A complete job: material, machine, vectors and operations. Toolpaths are derived, never stored.
public struct Project: Hashable, Sendable {
    /// Newest file format this build reads. Format 2 adds machines with a controller other than Avid's Mach4
    /// profile, or with a rotary axis. Format 3 adds rotary stock and index angles: builds that read format 2 would drop the blank and
    /// post the job as a flat sheet, which with Z zeroed on the rotation axis drives the tool into the blank. Flat
    /// projects on Avid's Mach4 profile are still written as format 1 so older builds keep opening them. Format 4 adds
    /// a rotary axis turned by hand, where builds that read format 3 would write A moves the machine can't make. Format 5
    /// adds wrapped rotary jobs: a format-4 build would read the unrolled sheet as one face and cut it indexed.
    public static let currentFormatVersion = 5

    /// The format this project is written as: the oldest one that can hold it.
    public var formatVersion: Int {
        let byHand = stock.rotary != nil && machine.rotary?.turnsByHand == true ? 4 : 1
        let parts = operations.map(\.requiredFormatVersion) + shapes.map(\.kind.requiredFormatVersion)
        return parts.reduce(max(machine.requiredFormatVersion, stock.requiredFormatVersion, byHand), max)
    }

    /// Keeps every spiral climbing exactly once around the blank per pitch: on a wrapped job, a spiral's turn is the
    /// sheet's height, which changes with the wrap diameter. Call it after changing the blank.
    public mutating func fitSpiralsToSheet() {
        guard stock.rotary?.isWrapped == true else { return }
        for i in shapes.indices {
            guard case var .spiral(spec) = shapes[i].kind, abs(spec.around - stock.height) > 1e-9 else { continue }
            spec.around = stock.height
            shapes[i].kind = .spiral(spec)
        }
    }

    public var name: String
    public var displayUnits: LengthUnit
    public var stock: Stock
    public var machine: MachineProfile
    public var shapes: [DesignShape]
    public var operations: [CAMOperation]
    public var notes: String

    public init(name: String = "Untitled", displayUnits: LengthUnit = .inch, stock: Stock = Stock(),
                machine: MachineProfile = .avidPRO6060, shapes: [DesignShape] = [], operations: [CAMOperation] = [],
                notes: String = "") {
        self.name = name
        self.displayUnits = displayUnits
        self.stock = stock
        self.machine = machine
        self.shapes = shapes
        self.operations = operations
        self.notes = notes
    }

    public func shape(id: UUID) -> DesignShape? { shapes.first { $0.id == id } }

    public func shapes(for op: CAMOperation) -> [DesignShape] {
        op.shapeIDs.compactMap { shape(id: $0) }
    }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(self)
    }

    public static func decode(_ data: Data) throws -> Project {
        try JSONDecoder().decode(Project.self, from: data)
    }
}

extension Project: Codable {
    private enum CodingKeys: String, CodingKey {
        case formatVersion, name, displayUnits, stock, machine, shapes, operations, notes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .formatVersion)
        guard version <= Project.currentFormatVersion else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey:
                "This project was saved by a newer version of NativeCAM (format \(version))."])
        }
        name = try c.decode(String.self, forKey: .name)
        displayUnits = try c.decode(LengthUnit.self, forKey: .displayUnits)
        stock = try c.decode(Stock.self, forKey: .stock)
        machine = try c.decode(MachineProfile.self, forKey: .machine)
        shapes = try c.decode([DesignShape].self, forKey: .shapes)
        operations = try c.decode([CAMOperation].self, forKey: .operations)
        notes = try c.decode(String.self, forKey: .notes)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(formatVersion, forKey: .formatVersion)
        try c.encode(name, forKey: .name)
        try c.encode(displayUnits, forKey: .displayUnits)
        try c.encode(stock, forKey: .stock)
        try c.encode(machine, forKey: .machine)
        try c.encode(shapes, forKey: .shapes)
        try c.encode(operations, forKey: .operations)
        try c.encode(notes, forKey: .notes)
    }
}
