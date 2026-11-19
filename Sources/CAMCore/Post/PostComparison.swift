import Foundation

/// How an imported post's output differs from NativeCAM's own post for the same job: whether the moves are the
/// same, where they first part, and the code lines only one of them writes (comments aside).
public struct PostComparison: Sendable {
    public var sameMoves: Bool
    public var moveCount: (imported: Int, builtIn: Int)
    /// The first move that differs, described.
    public var firstDifference: String?
    public var onlyInImported: [String]
    public var onlyInBuiltIn: [String]

    public static func compare(imported: String, builtIn: String, units: LengthUnit) -> PostComparison {
        func moves(_ g: String) -> [Motion] {
            guard let program = try? GCodeParser.parse(g) else { return [] }
            var out: [Motion] = []
            for seg in program.segments {
                var p = seg.start
                for m in seg.motions {
                    if m.kind == .dwell || m.end != p { out.append(m) }
                    if m.kind != .dwell { p = m.end }
                }
            }
            return out
        }
        func codeLines(_ g: String) -> [String] {
            g.components(separatedBy: .newlines).map { GCodeParser.stripComments($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        let a = moves(imported), b = moves(builtIn)
        var first: String?
        for (i, (x, y)) in zip(a, b).enumerated() {
            let same = x.kind == y.kind && abs(x.end.x - y.end.x) < 1e-3 && abs(x.end.y - y.end.y) < 1e-3 && abs(x.end.z - y.end.z) < 1e-3
                && abs(x.feed - y.feed) < 0.5
            if !same {
                func show(_ m: Motion) -> String {
                    let d = units == .inch ? 4 : 3
                    return String(format: "%@ to X%.\(d)f Y%.\(d)f Z%.\(d)f", "\(m.kind)", units.fromMM(m.end.x), units.fromMM(m.end.y), units.fromMM(m.end.z))
                }
                first = "Move \(i + 1): the imported post writes \(show(x)), NativeCAM's post \(show(y))."
                break
            }
        }
        if first == nil, a.count != b.count {
            first = "The imported post writes \(a.count) moves, NativeCAM's post \(b.count)."
        }
        let la = Set(codeLines(imported)), lb = Set(codeLines(builtIn))
        return PostComparison(sameMoves: first == nil, moveCount: (a.count, b.count), firstDifference: first,
                              onlyInImported: codeLines(imported).filter { !lb.contains($0) }.uniqued(),
                              onlyInBuiltIn: codeLines(builtIn).filter { !la.contains($0) }.uniqued())
    }
}

extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
