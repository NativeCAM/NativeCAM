import Foundation

/// The G-code files a job is saved as, exactly as File ▸ Export G-code (and the command-line tool) saves them: one
/// file, or one per tool where the controller can't stop for a tool change, and on a tiled job that for every tile.
public enum JobExport {
    public struct File: Sendable {
        /// Added to the file's name, e.g. " - tile 1 of 2" or " 2 of 3 - T5"; nil for a job saved as one file.
        public var suffix: String?
        public var gcode: String
        /// The toolpaths the file cuts, in the file's coordinates, for checking it.
        public var toolpaths: [Toolpath]
        /// The project to check the file against: the job's, or on a tiled job the tile's (`tileProject`).
        public var project: Project
        /// The tile the file is for, from 0; nil when the job isn't tiled.
        public var tile: Int?
    }

    /// The files for `job`, raised for an air cut when `airCut` (mm) is set; nil when the machine has no post.
    public static func files(_ project: Project, job: JobResult, airCut: Double? = nil, date: Date = Date())
        -> (files: [File], post: any PostProcessor)? {
        guard let tiled = job.tiling else {
            if let height = airCut {
                guard let air = AirCut.files(project, toolpaths: job.toolpaths, height: height, date: date) else { return nil }
                return (air.files.map { File(suffix: $0.suffix, gcode: $0.gcode, toolpaths: $0.toolpaths, project: air.project, tile: nil) }, air.post)
            }
            guard let post = PostProcessors.post(for: project, date: date) else { return nil }
            return (post.files(job.toolpaths).map { File(suffix: $0.suffix, gcode: $0.gcode, toolpaths: $0.toolpaths, project: project, tile: nil) }, post)
        }
        let layout = tiled.layout
        var out: [File] = []
        var anyPost: (any PostProcessor)?
        for tile in layout.tiles {
            let tp = tiled.toolpaths(inTile: tile.index)
            let p = tileProject(project, layout: layout, tile: tile.index)
            let posted: (files: [PostedFile], project: Project, post: any PostProcessor)
            if let height = airCut {
                guard let air = AirCut.files(p, toolpaths: tp, height: height, date: date) else { return nil }
                posted = air
            } else {
                guard let post = PostProcessors.post(for: p, date: date) else { return nil }
                posted = (post.files(tp), p, post)
            }
            anyPost = anyPost ?? posted.post
            for (i, f) in posted.files.enumerated() {
                let part = posted.files.count > 1
                    ? " - \(i + 1) of \(posted.files.count)\(f.toolpaths.first.map { " - T\($0.tool.number)" } ?? "")" : ""
                let suffix = (airCut == nil ? "" : " (air cut)") + tileSuffix(tile.index, of: layout.count) + part
                out.append(File(suffix: suffix, gcode: f.gcode, toolpaths: f.toolpaths, project: posted.project, tile: tile.index))
            }
        }
        guard let post = anyPost else { return nil }
        return (out, post)
    }

    /// " - tile 1 of 2", zero-padded so the files sort in order.
    public static func tileSuffix(_ index: Int, of count: Int) -> String {
        let width = String(count).count
        let n = String(index + 1)
        return " - tile \(String(repeating: "0", count: max(0, width - n.count)) + n) of \(count)"
    }

    /// A tile's project, which its file is posted for: the job with the stock sized to the tile's frame (so the XY zero
    /// is at the same place on every tile) and the tile in its name.
    public static func tileProject(_ project: Project, layout: TileLayout, tile: Int) -> Project {
        var p = project
        p.stock = layout.tileStock(project.stock)
        p.name = (project.name.isEmpty ? "Untitled" : project.name) + tileSuffix(tile, of: layout.count)
        p.tiling = nil
        return p
    }

    /// The name of each file `files` saves, from the name chosen for the job's file (`base`, e.g. "Sign.tap").
    public static func fileNames(_ files: [File], base: String, fileExtension: String) -> [String] {
        let stem = (base as NSString).deletingPathExtension
        guard files.count > 1 else { return [stem + "." + fileExtension] }
        return files.map { stem + ($0.suffix ?? "") + "." + fileExtension }
    }
}
