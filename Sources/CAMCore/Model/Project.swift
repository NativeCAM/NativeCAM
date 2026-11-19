import Foundation

/// A complete job: material, machine, vectors and operations. Toolpaths are derived, never stored.
public struct Project: Hashable, Codable, Sendable {
    public static let currentFormatVersion = 1

    public var formatVersion: Int
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
        self.formatVersion = Project.currentFormatVersion
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
        let p = try JSONDecoder().decode(Project.self, from: data)
        guard p.formatVersion <= currentFormatVersion else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey:
                "This project was saved by a newer version of NativeCAM (format \(p.formatVersion))."])
        }
        return p
    }
}
