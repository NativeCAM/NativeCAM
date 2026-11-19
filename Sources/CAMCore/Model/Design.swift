import CoreGraphics
import CoreText
import Foundation

/// Text drawn with a macOS system font; outlines come straight from CoreText.
public struct TextSpec: Hashable, Codable, Sendable {
    public var string: String
    /// PostScript or family name, e.g. "Helvetica-Bold", "Georgia".
    public var fontName: String
    /// Cap height target in mm (the font is scaled so a capital "H" is this tall).
    public var capHeight: Double
    /// Extra spacing between characters, mm.
    public var letterSpacing: Double

    public init(string: String, fontName: String = "Helvetica-Bold", capHeight: Double = 2.inch, letterSpacing: Double = 0) {
        self.string = string
        self.fontName = fontName
        self.capHeight = capHeight
        self.letterSpacing = letterSpacing
    }
}

/// Parametric (editable) shape definitions. Geometry is local; `DesignShape` places it on the stock.
public enum ShapeKind: Hashable, Codable, Sendable {
    case rectangle(width: Double, height: Double, cornerRadius: Double)
    case circle(radius: Double)
    case ellipse(radiusX: Double, radiusY: Double)
    case polygon(sides: Int, radius: Double)
    case star(points: Int, outerRadius: Double, innerRadius: Double)
    case text(TextSpec)
    /// Imported or free-form vectors in local coordinates (centred on the origin by the importer).
    case paths([Polyline])
    /// A 3D model (STL/OBJ/3MF/USDZ…) carved with 3D toolpaths; its outline is the silhouette seen from above.
    case model(ModelSpec)

    public var label: String {
        switch self {
        case .rectangle: "Rectangle"
        case .circle: "Circle"
        case .ellipse: "Ellipse"
        case .polygon: "Polygon"
        case .star: "Star"
        case .text: "Text"
        case .paths: "Vectors"
        case .model: "3D Model"
        }
    }
}

/// A vector shape placed on the stock (design coordinates: mm from the stock's lower-left corner).
public struct DesignShape: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: ShapeKind
    /// Placement of the local origin (the shape's centre for primitives and text).
    public var position: Vec2
    /// Rotation about `position`, degrees counter-clockwise.
    public var rotation: Double
    /// Uniform scale applied after rotation (1 = as defined).
    public var scale: Double
    public var layer: String
    /// When set, this shape marks a clamp or fixture (height above the material top, mm): nothing may cut inside it
    /// and links crossing it go over the top. Keep-out shapes are never machined.
    public var keepOutHeight: Double?

    public var isKeepOut: Bool { keepOutHeight != nil }

    public init(id: UUID = UUID(), name: String? = nil, kind: ShapeKind, position: Vec2, rotation: Double = 0,
                scale: Double = 1, layer: String = "Default") {
        self.id = id
        self.name = name ?? kind.label
        self.kind = kind
        self.position = position
        self.rotation = rotation
        self.scale = scale
        self.layer = layer
    }

    public var transform: Transform2D {
        Transform2D.scale(scale, scale)
            .then(.rotation(rotation.radians))
            .then(.translation(position))
    }

    /// Flattened outlines in design coordinates.
    public func polylines(tolerance: Double = 0.01) -> [Polyline] {
        let local = DesignShape.localPolylines(kind, tolerance: tolerance / max(scale, 1e-6))
        let t = transform
        return local.map { $0.transformed(t) }
    }

    public var bounds: Rect2 { polylines(tolerance: 0.05).bounds }

    static func localPolylines(_ kind: ShapeKind, tolerance: Double) -> [Polyline] {
        switch kind {
        case let .rectangle(w, h, r):
            return [roundedRect(width: w, height: h, radius: r, tolerance: tolerance)]
        case let .circle(r):
            return [Polyline(Curves.circle(center: .zero, radius: r, tolerance: tolerance), closed: true)]
        case let .ellipse(rx, ry):
            let pts = Curves.ellipse(center: .zero, majorAxis: Vec2(rx, 0), ratio: ry / max(rx, 1e-9),
                                     startParam: 0, endParam: 2 * .pi, tolerance: tolerance)
            return [Polyline(Array(pts.dropLast()), closed: true)]
        case let .polygon(sides, r):
            let n = max(3, sides)
            let pts = (0..<n).map { i in Vec2.fromAngle(.pi / 2 + 2 * .pi * Double(i) / Double(n), length: r) }
            return [Polyline(pts, closed: true)]
        case let .star(points, outer, inner):
            let n = max(3, points)
            let pts = (0..<(2 * n)).map { i in
                Vec2.fromAngle(.pi / 2 + .pi * Double(i) / Double(n), length: i % 2 == 0 ? outer : inner)
            }
            return [Polyline(pts, closed: true)]
        case let .text(spec):
            return TextOutliner.outlines(for: spec, tolerance: tolerance)
        case let .paths(paths):
            return paths
        case let .model(spec):
            return spec.oriented.silhouette
        }
    }

    static func roundedRect(width w: Double, height h: Double, radius rIn: Double, tolerance: Double) -> Polyline {
        let r = max(0, min(rIn, min(w, h) / 2))
        let hw = w / 2, hh = h / 2
        if r <= 1e-9 {
            return Polyline([Vec2(-hw, -hh), Vec2(hw, -hh), Vec2(hw, hh), Vec2(-hw, hh)], closed: true)
        }
        var pts: [Vec2] = []
        let corners: [(Vec2, Double)] = [
            (Vec2(hw - r, -hh + r), -.pi / 2),
            (Vec2(hw - r, hh - r), 0),
            (Vec2(-hw + r, hh - r), .pi / 2),
            (Vec2(-hw + r, -hh + r), .pi),
        ]
        for (c, a0) in corners {
            pts.append(contentsOf: Curves.arc(center: c, radius: r, startAngle: a0, sweep: .pi / 2, tolerance: tolerance))
        }
        return Polyline(pts, closed: true).deduplicated()
    }
}

/// Converts text to closed outlines using CoreText glyph paths, centred on the origin.
public enum TextOutliner {
    public static func outlines(for spec: TextSpec, tolerance: Double) -> [Polyline] {
        guard !spec.string.isEmpty else { return [] }
        // Measure cap height at a reference size, then scale to the requested cap height.
        let reference: CGFloat = 100
        let refFont = CTFontCreateWithName(spec.fontName as CFString, reference, nil)
        let capRef = CTFontGetCapHeight(refFont)
        let scale = capRef > 0 ? spec.capHeight / Double(capRef) : spec.capHeight / Double(reference)
        let font = CTFontCreateWithName(spec.fontName as CFString, reference, nil)
        let attrs: [CFString: Any] = [kCTFontAttributeName: font, kCTKernAttributeName: spec.letterSpacing / scale]
        guard let attributed = CFAttributedStringCreate(nil, spec.string as CFString, attrs as CFDictionary) else { return [] }
        let line = CTLineCreateWithAttributedString(attributed)
        var loops: [Polyline] = []
        let runs = CTLineGetGlyphRuns(line) as? [CTRun] ?? []
        for run in runs {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            let runAttrs = CTRunGetAttributes(run) as NSDictionary
            let runFontRef = runAttrs[kCTFontAttributeName as String]
            let runFont = runFontRef.map { $0 as! CTFont } ?? font
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            for i in 0..<count {
                var t = CGAffineTransform(translationX: positions[i].x, y: positions[i].y)
                guard let path = CTFontCreatePathForGlyph(runFont, glyphs[i], &t) else { continue }
                loops.append(contentsOf: flatten(path, tolerance: tolerance / scale))
            }
        }
        let scaled = loops.map { $0.transformed(.scale(scale, scale)) }
        // Centre the text block on the origin.
        let b = scaled.bounds
        guard !b.isEmpty else { return [] }
        let c = b.center
        return scaled.map { $0.transformed(.translation(-c)) }
    }

    /// Flattens a CGPath into closed polylines.
    public static func flatten(_ path: CGPath, tolerance: Double) -> [Polyline] {
        var loops: [Polyline] = []
        var current: [Vec2] = []
        var start = Vec2.zero
        func finish(closed: Bool) {
            if current.count >= 2 { loops.append(Polyline(current, closed: closed || current.count >= 3).deduplicated()) }
            current = []
        }
        path.applyWithBlock { elementPtr in
            let e = elementPtr.pointee
            let p = e.points
            switch e.type {
            case .moveToPoint:
                finish(closed: true)
                start = Vec2(Double(p[0].x), Double(p[0].y))
                current = [start]
            case .addLineToPoint:
                current.append(Vec2(Double(p[0].x), Double(p[0].y)))
            case .addQuadCurveToPoint:
                let p0 = current.last ?? start
                Curves.flattenQuad(p0, Vec2(Double(p[0].x), Double(p[0].y)), Vec2(Double(p[1].x), Double(p[1].y)),
                                   tolerance: tolerance, into: &current)
            case .addCurveToPoint:
                let p0 = current.last ?? start
                Curves.flattenCubic(p0, Vec2(Double(p[0].x), Double(p[0].y)), Vec2(Double(p[1].x), Double(p[1].y)),
                                    Vec2(Double(p[2].x), Double(p[2].y)), tolerance: tolerance, into: &current)
            case .closeSubpath:
                finish(closed: true)
            @unknown default:
                break
            }
        }
        finish(closed: true)
        return loops.filter { $0.count >= 3 }
    }
}
