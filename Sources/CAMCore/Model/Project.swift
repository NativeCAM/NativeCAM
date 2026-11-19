import Foundation

/// A complete job: material, machine, vectors and operations. Toolpaths are derived, never stored.
public struct Project: Hashable, Sendable {
    /// Newest file format this build reads. Format 2 adds machines with a controller other than Avid's Mach4
    /// profile, rotary axes and rotary stock; flat projects on that profile are still written as format 1 so older
    /// builds keep opening them.
    public static let currentFormatVersion = 2

    /// The format this project is written as: the oldest one that can hold it.
    public var formatVersion: Int { max(machine.requiredFormatVersion, stock.requiredFormatVersion) }

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
