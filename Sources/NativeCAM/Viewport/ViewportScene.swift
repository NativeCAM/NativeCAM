import simd

/// Everything the Metal viewport draws, in millimetres.
///
/// World space matches CAMCore: X/Y are design coordinates (stock lower-left = 0,0),
/// Z = 0 is the material top and Z = -stockThickness is the material bottom / spoilboard.
/// The app rebuilds this value whenever the project, selection or simulation changes; the renderer
/// diffs `geometryVersion` / `heightField.version` to decide what to re-upload.
struct ViewportScene {
    /// Stock size: x = width, y = height (Y), z = thickness.
    var stockSize: SIMD3<Float> = SIMD3(609.6, 457.2, 19.05)
    /// Machine work area (x, y), drawn as a faint outline on the bed plane with the stock at its origin.
    var machineTravel: SIMD2<Float>? = nil
    /// Grid spacing on the bed plane (mm). 25.4 for inch projects, 10 for mm.
    var gridSpacing: Float = 25.4

    /// Line-list geometry (pairs of vertices) for vectors and toolpaths.
    var lines: [LineVertex] = []
    /// Bumped whenever `lines` changes.
    var geometryVersion: Int = 0

    /// Material-removal simulation result. When non-nil the carved stock is drawn instead of the stock box.
    var heightField: HeightFieldSnapshot? = nil

    /// Tool drawn at its current simulated position (nil hides it).
    var tool: ToolMarker? = nil

    /// Draw the translucent stock box when no height field is present.
    var showStock: Bool = true
}

struct LineVertex {
    var position: SIMD3<Float>
    var color: SIMD4<Float>

    init(_ position: SIMD3<Float>, _ color: SIMD4<Float>) {
        self.position = position
        self.color = color
    }
}

/// A regular grid of surface heights over the stock.
struct HeightFieldSnapshot {
    var columns: Int
    var rows: Int
    /// Cell size in mm (square cells).
    var cellSize: Float
    /// World XY of the centre of cell (0, 0).
    var origin: SIMD2<Float>
    /// Row-major heights (index = row * columns + column), mm. 0 = uncut top; <= floorZ means cut through.
    var heights: [Float]
    /// Bottom of the material (-thickness).
    var floorZ: Float
    /// Bumped whenever `heights` changes.
    var version: Int
}

struct ToolMarker {
    /// Tool tip position in world space.
    var tip: SIMD3<Float>
    /// Right-half silhouette: (radius, height above tip) from the tip up to the top of the shank.
    /// Revolve this around the Z axis to draw the tool.
    var silhouette: [SIMD2<Float>]
    var color: SIMD4<Float> = SIMD4(0.85, 0.85, 0.9, 1)
}

/// Camera presets the app's toolbar can request.
enum ViewPreset: String, CaseIterable, Identifiable {
    case top, front, iso
    var id: String { rawValue }
    var label: String { rawValue == "iso" ? "Iso" : rawValue.capitalized }
}
