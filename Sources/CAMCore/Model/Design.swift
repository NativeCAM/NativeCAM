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
    /// Spiral lines for a wrapped rotary job (a rope or barley twist): see `SpiralSpec`.
    case spiral(SpiralSpec)

    /// The project file format a shape of this kind needs: spirals are format 5 (older builds can't read them), and a
    /// model placed on a rotary blank is format 7 (see `ModelSpec.requiredFormatVersion`).
    public var requiredFormatVersion: Int {
        switch self {
        case .spiral: 5
        case let .model(spec): spec.requiredFormatVersion
        default: 1
        }
    }

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
        case .spiral: "Spiral"
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
    /// On a job nested onto several sheets, the sheet the shape is on (from 0; see `Project.additionalSheets`); nil =
    /// the first. Keep-outs are on every sheet.
    public var sheet: Int?

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
            // On a rotary blank: the outline from the side, centred on the axis.
            return spec.rotary == nil ? spec.oriented.silhouette : spec.alongAxis.outline
        case let .spiral(spec):
            return spec.lines
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

/// Spiral lines laid out on a wrapped rotary job's sheet: `starts` parallel lines that each climb once around the
/// blank for every `pitch` along it. On the unrolled sheet they're straight lines longer than the sheet is high;
/// wrapped, each becomes a helix, as in a rope or barley twist. Cut them on the line (a profile) with a ball nose or
/// V-bit. Local coordinates are centred on the shape's position, with the starts spread evenly around the blank.
public struct SpiralSpec: Hashable, Codable, Sendable {
    /// Number of separate spiral lines, evenly spaced around the blank.
    public var starts: Int
    /// Distance along the blank (X) for one turn of each line, mm.
    public var pitch: Double
    /// Length along the blank (X), mm.
    public var length: Double
    /// Height of the sheet one turn climbs (once around the blank at the wrap diameter), mm. Kept in step with the
    /// sheet by `Project.fitSpiralsToSheet()`.
    public var around: Double
    /// Twist direction. Right-handed (false) turns like an ordinary screw thread: seen from above, the lines run
    /// down to the right.
    public var leftHanded: Bool

    public init(starts: Int = 2, pitch: Double, length: Double, around: Double, leftHanded: Bool = false) {
        self.starts = starts
        self.pitch = pitch
        self.length = length
        self.around = around
        self.leftHanded = leftHanded
    }

    /// Turns each line makes along `length`.
    public var turns: Double { length / max(pitch, 1e-9) }

    /// The lines, centred on the origin.
    public var lines: [Polyline] {
        let n = max(1, starts)
        let rise = turns * around * (leftHanded ? 1 : -1)
        return (0..<n).map { k in
            let y = around * Double(k) / Double(n)
            return Polyline([Vec2(-length / 2, y - rise / 2), Vec2(length / 2, y + rise / 2)], closed: false)
        }
    }
}

// MARK: Moving parts as one

/// A turn about a point followed by a move, with no scaling: how Toolpaths ▸ Nest Parts moves a part, every shape in it
/// together.
public struct RigidMotion: Hashable, Sendable {
    /// The point turned about, design coordinates.
    public var pivot: Vec2
    /// Degrees counter-clockwise.
    public var rotation: Double
    /// Where the pivot ends up.
    public var position: Vec2

    public init(pivot: Vec2, rotation: Double, position: Vec2) {
        self.pivot = pivot
        self.rotation = rotation
        self.position = position
    }

    public static let identity = RigidMotion(pivot: .zero, rotation: 0, position: .zero)

    public var transform: Transform2D {
        Transform2D.translation(-pivot).then(.rotation(rotation.radians)).then(.translation(position))
    }

    public var isIdentity: Bool {
        abs(rotation.truncatingRemainder(dividingBy: 360)) < 1e-9 && pivot.isApprox(position, tolerance: 1e-9)
    }
}

public extension DesignShape {
    /// The shape moved rigidly by `motion`: its position follows and its rotation turns with it, so every point of it
    /// lands where `motion` takes it. Geometry, scale and layer stay as they are.
    func moved(_ motion: RigidMotion) -> DesignShape {
        var s = self
        s.position = motion.transform.apply(position)
        var r = (rotation + motion.rotation).truncatingRemainder(dividingBy: 360)
        if r > 180 + 1e-9 { r -= 360 }
        if r <= -180 + 1e-9 { r += 360 }
        s.rotation = abs(r) < 1e-9 ? 0 : r
        return s
    }

    /// The same motion in the shape's own coordinates (before its position, rotation and scale): for moving some of
    /// an imported shape's vectors within it, or a point stored in its own coordinates.
    func localMotion(_ motion: RigidMotion) -> Transform2D? {
        guard let inverse = transform.inverted else { return nil }
        return transform.then(motion.transform).then(inverse)
    }

    /// An imported shape (`.paths`) with the vectors at `indices` moved rigidly by `motion` and the rest left where
    /// they are. Other kinds come back unchanged.
    func movingPaths(_ indices: Set<Int>, by motion: RigidMotion) -> DesignShape {
        guard case let .paths(paths) = kind, let local = localMotion(motion) else { return self }
        var s = self
        s.kind = .paths(paths.enumerated().map { indices.contains($0.offset) ? $0.element.transformed(local) : $0.element })
        return s
    }
}
