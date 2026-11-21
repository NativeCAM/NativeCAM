import Foundation
import Testing
@testable import CAMCore

/// Layers read from imported DXF and SVG files: kept per polyline, never chained across, and turned into one shape per
/// layer, so toolpath templates bound by layer find them.
struct ImportLayerTests {
    static func layeredDXF() throws -> ImportResult {
        try DXFImportTests.load("layers_inch")
    }

    static func svg(_ body: String, inkscape: Bool = false) throws -> ImportResult {
        let ns = inkscape ? #" xmlns:inkscape="http://www.inkscape.org/namespaces/inkscape""# : ""
        let doc = #"<svg xmlns="http://www.w3.org/2000/svg""# + ns
            + #" width="100mm" height="100mm" viewBox="0 0 100 100">"# + body + "</svg>"
        return try SVGImporter.importSVG(data: Data(doc.utf8))
    }

    // MARK: DXF

    @Test func dxfPolylinesAndPointsKeepTheirLayers() throws {
        let r = try Self.layeredDXF()
        let groups = r.layerGroups
        let names = groups.map(\.layer)
        #expect(names == ["Cut Out", "Holes", nil])
        // The board's four lines close into one loop; the layer-0 line touching its corner isn't chained into it.
        #expect(groups[0].polylines.count == 1)
        #expect(groups[0].polylines.first?.isClosed == true)
        #expect(groups[2].polylines.count == 1)
        #expect(groups[2].polylines.first?.isClosed == false)
        // Two circles plus the block's circle, which is on layer 0 and so takes the insert's layer; and the point.
        #expect(groups[1].polylines.count == 3)
        #expect(groups[1].points.count == 1)
        #expect(r.polylineLayers.count == r.polylines.count)
    }

    @Test func aDXFOnLayerZeroStillImportsAsOneShape() throws {
        let r = try DXFImportTests.load("rect_lines_inch")
        #expect(r.layerGroups.count == 1)
        let shapes = r.shapes(name: "Panel", stock: Stock())
        #expect(shapes.map(\.name) == ["Panel"])
        #expect(shapes.map(\.layer) == ["Default"])
    }

    @Test func aDXFOnOneNamedLayerPutsTheShapeOnIt() throws {
        let data = DXFImportTests.dxf(insunits: 1, [
            (0, "LINE"), (8, "CUT"), (10, "0"), (20, "0"), (11, "4"), (21, "0"),
            (0, "LINE"), (8, "CUT"), (10, "4"), (20, "0"), (11, "4"), (21, "3"),
            (0, "LINE"), (8, "CUT"), (10, "4"), (20, "3"), (11, "0"), (21, "0"),
        ])
        let shapes = try DXFImporter.importDXF(data: data).shapes(name: "Triangle", stock: Stock())
        #expect(shapes.map(\.name) == ["Triangle"])
        #expect(shapes.map(\.layer) == ["CUT"])
    }

    @Test func aLayeredDXFImportsAsOneShapePerLayer() throws {
        let stock = Stock(width: 24.inch, height: 18.inch)
        let shapes = try Self.layeredDXF().shapes(name: "Board", stock: stock)
        #expect(shapes.map(\.name) == ["Board – Cut Out", "Board – Holes", "Board – Holes points", "Board – Default"])
        #expect(shapes.map(\.layer) == ["Cut Out", "Holes", "Holes", "Default"])
        // Moved together: the board's corner is still at the layer-0 line's end (the drawing didn't fit, so it was
        // centred, but every layer moved by the same amount).
        let board = shapes[0].bounds
        let line = shapes[3].bounds
        #expect(abs(board.min.x - line.max.x) < 1e-6)
        #expect(abs(board.min.y - line.max.y) < 1e-6)
    }

    // MARK: SVG

    @Test func svgInkscapeLayersAreReadByLabel() throws {
        let r = try Self.svg("""
            <g inkscape:groupmode="layer" id="layer1" inkscape:label="Cut Out"><rect x="10" y="10" width="50" height="30"/></g>
            <g inkscape:groupmode="layer" id="layer2" inkscape:label="Pockets"><g id="g42"><circle cx="70" cy="70" r="5"/></g></g>
            <g id="loose"><path d="M 0 90 L 20 95"/></g>
            """, inkscape: true)
        // Plain groups (inside a layer, or outside any in an Inkscape file) don't start layers.
        #expect(r.layerGroups.map(\.layer) == ["Cut Out", "Pockets", nil])
    }

    @Test func svgTopLevelGroupsAreLayersInOtherPrograms() throws {
        let r = try Self.svg("""
            <g id="Cut_Out" data-name="Cut Out"><rect x="10" y="10" width="50" height="30"/></g>
            <g id="Holes"><circle cx="70" cy="70" r="5"/><g id="Inner"><circle cx="80" cy="80" r="5"/></g></g>
            <g id="g12"><circle cx="20" cy="70" r="5"/></g>
            <circle cx="40" cy="80" r="5"/>
            """)
        let groups = r.layerGroups
        #expect(groups.map(\.layer) == ["Cut Out", "Holes", nil])
        // A nested group stays on its top-level group's layer.
        #expect(groups[1].polylines.count == 2)
        #expect(groups[2].polylines.count == 2)
    }

    @Test func anSVGWithoutGroupsImportsAsOneShape() throws {
        let r = try Self.svg(#"<rect x="10" y="10" width="50" height="30"/><circle cx="70" cy="70" r="5"/>"#)
        #expect(r.layerGroups.count == 1)
        #expect(r.shapes(name: "Logo", stock: Stock()).map(\.layer) == ["Default"])
    }

    // MARK: PDF and Illustrator

    @Test func pdfLayersAreReadByName() throws {
        // Two visible layers (optional content groups) and artwork outside any.
        let data = PDFImportTests.rawPDF(
            "/OC /L1 BDC 10 10 100 100 re f EMC /OC /L2 BDC 200 200 50 50 re f 300 300 m 400 300 l S EMC 500 500 10 10 re f",
            resources: "<< /Properties << /L1 5 0 R /L2 6 0 R >> >>",
            catalogExtras: "/OCProperties << /OCGs [5 0 R 6 0 R] /D << >> >>",
            extraObjects: ["<< /Type /OCG /Name (Cut lines) >>", "<< /Type /OCG /Name (Holes) >>"])
        let groups = try PDFImporter.importPDF(data: data).layerGroups
        #expect(groups.map(\.layer) == ["Cut lines", "Holes", nil])
        #expect(groups.map(\.polylines.count) == [1, 2, 1])
    }

    // MARK: Templates

    @Test func aTemplateBindsToTheLayersOfAnImportedDXF() throws {
        var project = Project(stock: Stock(width: 24.inch, height: 18.inch, thickness: 0.5.inch))
        project.shapes = try Self.layeredDXF().shapes(name: "Board", stock: project.stock)
        let quarter = ToolLibrary.starter.tool(number: 1)!
        let template = ToolpathTemplate(name: "Board", operations: [
            CAMOperation(name: "Holes", kind: .drill(DrillParams(depth: 0, fromBottom: -MaterialDepth.defaultOvercut)), shapeIDs: [],
                         tool: quarter, vectorSelection: .layers(["Holes"])),
            CAMOperation(name: "Cut out", kind: .profile(ProfileParams(depth: .through(0.75.inch))), shapeIDs: [], tool: quarter,
                         vectorSelection: .layers(["cut out"])),
        ])
        let applied = template.apply(to: project, library: .starter)
        let counts = applied.rows.map(\.shapeCount)
        #expect(counts == [2, 1]) // the holes' circles and their points; the board
        #expect(applied.emptyCount == 0)
        let issues = CAMEngine.generate(applied.project).issues
        #expect(!issues.contains { $0.message.contains("No vectors on layer") })
        let job = CAMEngine.generate(applied.project)
        let cut = try #require(job.toolpaths.first { $0.name == "Cut out" }?.cuttingExtents)
        #expect(abs(cut.min.z + 0.52.inch) < 1e-6)
    }
}
