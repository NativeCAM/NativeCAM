import Foundation
import Testing
@testable import CAMCore

/// Runs Clipper2's own regression fixtures (Polygons.txt, Lines.txt; Boost license) through our C bridge,
/// with the same per-case tolerances Clipper2's C++ suite uses. This proves the bridge passes paths, fill rules
/// and clip types through correctly.
struct ClipperFixtureTests {
    struct Case {
        var number: Int
        var clip: Clipper.ClipType?
        var fill: Clipper.FillRule
        var area: Int64
        var count: Int64
        var subjects: [Clipper.IntPath] = []
        var openSubjects: [Clipper.IntPath] = []
        var clips: [Clipper.IntPath] = []
    }

    static func load(_ name: String) throws -> [Case] {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures/clipper2"))
        let text = try String(contentsOf: url, encoding: .utf8)
        var cases: [Case] = []
        var cur: Case?
        enum Section { case none, subjects, open, clips }
        var section = Section.none
        func parsePath(_ line: String) -> Clipper.IntPath {
            let nums = line.split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { Int64($0) }
            return stride(from: 0, to: nums.count - 1, by: 2).map { Clipper.IntPoint(x: nums[$0], y: nums[$0 + 1]) }
        }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("CAPTION:") {
                if let c = cur { cases.append(c) }
                let n = Int(line.dropFirst(8).trimmingCharacters(in: CharacterSet(charactersIn: " ."))) ?? 0
                cur = Case(number: n, clip: nil, fill: .evenOdd, area: 0, count: 0)
                section = .none
            } else if line.hasPrefix("CLIPTYPE:") {
                let v = line.dropFirst(9).trimmingCharacters(in: .whitespaces)
                cur?.clip = ["INTERSECTION": .intersection, "UNION": .union, "DIFFERENCE": .difference, "XOR": .xor][v]
            } else if line.hasPrefix("FILLRULE:") {
                let v = line.dropFirst(9).trimmingCharacters(in: .whitespaces)
                cur?.fill = ["EVENODD": .evenOdd, "NONZERO": .nonZero, "POSITIVE": .positive, "NEGATIVE": .negative][v] ?? .evenOdd
            } else if line.hasPrefix("SOL_AREA:") {
                cur?.area = Int64(line.dropFirst(9).trimmingCharacters(in: .whitespaces)) ?? 0
            } else if line.hasPrefix("SOL_COUNT:") {
                cur?.count = Int64(line.dropFirst(10).trimmingCharacters(in: .whitespaces)) ?? 0
            } else if line == "SUBJECTS" {
                section = .subjects
            } else if line == "SUBJECTS_OPEN" {
                section = .open
            } else if line == "CLIPS" {
                section = .clips
            } else if !line.isEmpty, let first = line.first, first.isNumber || first == "-" {
                let path = parsePath(line)
                switch section {
                case .subjects: cur?.subjects.append(path)
                case .open: cur?.openSubjects.append(path)
                case .clips: cur?.clips.append(path)
                case .none: break
                }
            }
        }
        if let c = cur { cases.append(c) }
        return cases
    }

    @Test func polygonsFixture() throws {
        let cases = try Self.load("Polygons")
        #expect(cases.count >= 190)
        var checked = 0
        for c in cases {
            guard let clip = c.clip else { continue }
            let (closed, open) = Clipper.booleanInt(clip, fill: c.fill, subjects: c.subjects, openSubjects: c.openSubjects, clips: c.clips)
            let area = Int64(Clipper.intArea(closed))
            let count = Int64(closed.count + open.count)
            let n = c.number
            // Count tolerances (copied from Clipper2's TestPolygons.cpp).
            if c.count > 0 {
                let tol: Int64
                if [120, 121, 130, 138, 140, 148, 163, 165, 166, 167, 168, 172, 173, 175, 178, 180].contains(n) { tol = 5 }
                else if n == 126 { tol = 3 }
                else if [16, 27, 181].contains(n) || (120...184).contains(n) { tol = 2 }
                else if [23, 45, 87, 102, 111, 113, 191].contains(n) { tol = 1 }
                else { tol = 0 }
                #expect(abs(count - c.count) <= tol, "test \(n): count \(count) vs \(c.count)")
            }
            if c.area > 0 {
                let frac: Double
                if [19, 22, 23, 24].contains(n) { frac = 0.5 }
                else if n == 193 { frac = 0.2 }
                else if n == 63 { frac = 0.1 }
                else if n == 16 { frac = 0.075 }
                else if n == 26 { frac = 0.05 }
                else if [15, 52, 53, 54, 59, 60, 64, 117, 119, 184].contains(n) { frac = 0.02 }
                else { frac = 0.01 }
                #expect(abs(Double(area - c.area)) <= frac * Double(area) + 1, "test \(n): area \(area) vs \(c.area)")
            }
            checked += 1
        }
        #expect(checked >= 190)
    }

    @Test func linesFixture() throws {
        let cases = try Self.load("Lines")
        #expect(!cases.isEmpty)
        #expect(cases.count >= 16)
        for c in cases {
            guard let clip = c.clip else { continue }
            let (closed, open) = Clipper.booleanInt(clip, fill: c.fill, subjects: c.subjects, openSubjects: c.openSubjects, clips: c.clips)
            if c.number == 1 {
                // Same special case as Clipper2's TestLines.cpp.
                #expect(closed.count == 1 && closed.first?.count == 6 && Clipper.intArea(closed) > 0)
                #expect(open.count == 1 && open.first?.count == 2 && open.first?.first?.y == 6)
            } else {
                let diff = abs(Int64(closed.count + open.count) - c.count)
                #expect(diff <= 8, "lines test \(c.number)")
                if c.count > 0 { #expect(Double(diff) / Double(c.count) <= 0.1, "lines test \(c.number)") }
            }
        }
    }

    @Test func offsetSquareRoundJoin() {
        let square = Polyline([Vec2(0, 0), Vec2(10, 0), Vec2(10, 10), Vec2(0, 10)], closed: true)
        let grown = Clipper.offset([square], delta: 1, join: .round, arcTolerance: 0.001)
        #expect(grown.count == 1)
        // Square + four edge strips + four quarter circles = 100 + 40 + π.
        #expect(abs(grown[0].area - (100 + 40 + Double.pi)) < 0.02)
        let shrunk = Clipper.offset([square], delta: -2)
        #expect(abs(shrunk[0].area - 36) < 1e-6)
        #expect(Clipper.offset([square], delta: -6).isEmpty)
    }
}
