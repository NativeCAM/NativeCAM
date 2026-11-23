import Foundation

/// A sheet of the job's material after the first, on a job nested onto several (Toolpaths ▸ Nest Parts): the same
/// material and thickness as the first (the job's `stock`), its own width and height. Each sheet has its own
/// coordinates, from its lower-left corner, and is cut on its own, one after another: the toolpaths are shared, and
/// each cuts the shapes on the sheet being cut (`Project.sheetProject`).
public struct MaterialSheet: Hashable, Codable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

public extension Project {
    /// How many sheets the job is cut from: the first (the stock) and `additionalSheets`.
    var sheetCount: Int { 1 + additionalSheets.count }

    /// The sheet a shape is on, from 0 (a sheet past the last counts as the last).
    func sheetIndex(of shape: DesignShape) -> Int { min(max(0, shape.sheet ?? 0), sheetCount - 1) }

    /// Sheet `k`'s size, mm.
    func sheetSize(_ k: Int) -> Vec2 {
        guard k > 0, k <= additionalSheets.count else { return Vec2(stock.width, stock.height) }
        let s = additionalSheets[k - 1]
        return Vec2(s.width, s.height)
    }

    /// The stock sheet `k` is cut from: the job's, at the sheet's size.
    func stock(forSheet k: Int) -> Stock {
        var s = stock
        let size = sheetSize(k)
        s.width = size.x
        s.height = size.y
        return s
    }

    /// The shapes on sheet `k`, with the clamps and keep-outs (which are on every sheet).
    func shapes(onSheet k: Int) -> [DesignShape] {
        shapes.filter { $0.isKeepOut || sheetIndex(of: $0) == k }
    }

    /// Sheet `k` as a job of its own, as its file is posted: its stock and shapes, and the toolpaths that cut any of
    /// them (each with only those shapes). Toolpaths that need no shapes cut every sheet; one whose shapes are on no
    /// sheet stays on the first, which reports it.
    func sheetProject(_ k: Int) -> Project {
        guard sheetCount > 1 else { return self }
        var p = self
        p.additionalSheets = []
        p.stock = stock(forSheet: k)
        p.shapes = shapes(onSheet: k).map { s in
            var s = s
            s.sheet = nil
            return s
        }
        let here = Set(p.shapes.filter { !$0.isKeepOut }.map(\.id))
        let anywhere = Set(shapes.filter { !$0.isKeepOut }.map(\.id))
        p.operations = operations.compactMap { op in
            guard op.kind.needsShapes else { return op }
            let kept = op.shapeIDs.filter { here.contains($0) }
            if kept.isEmpty {
                return k == 0 && op.shapeIDs.allSatisfy({ !anywhere.contains($0) }) ? op : nil
            }
            var o = op
            o.shapeIDs = op.shapeIDs.filter { here.contains($0) || !anywhere.contains($0) }
            return o
        }
        p.name = (name.isEmpty ? "Untitled" : name) + Project.sheetSuffix(k, of: sheetCount)
        return p
    }

    /// " - sheet 1 of 2", zero-padded so the files sort in order.
    static func sheetSuffix(_ index: Int, of count: Int) -> String {
        let width = String(count).count
        let n = String(index + 1)
        return " - sheet \(String(repeating: "0", count: max(0, width - n.count)) + n) of \(count)"
    }

    /// Drops the sheets at the end with nothing on them (keep-outs aside).
    mutating func removeEmptySheets() {
        let used = shapes.filter { !$0.isKeepOut }.map { sheetIndex(of: $0) }.max() ?? 0
        if used + 1 < sheetCount { additionalSheets = Array(additionalSheets.prefix(used)) }
        for i in shapes.indices where shapes[i].sheet != nil && sheetIndex(of: shapes[i]) == 0 { shapes[i].sheet = nil }
    }
}
