import CoreGraphics
import Foundation
import Metal
import simd

/// Draws a `ViewportScene` with Metal. Owns all GPU resources and only re-uploads what changed
/// (lines on `geometryVersion`, the height texture on `heightField.version`, the tool mesh when its
/// silhouette changes, bed/stock geometry when their dimensions change).
///
/// Used by `ViewportMTKView` for on-screen drawing and by `snapshot(width:height:)` for offscreen renders
/// (tests / harnesses). All calls are expected on one thread (the main thread in the app).
final class ViewportRenderer {
    static let colorPixelFormat: MTLPixelFormat = .bgra8Unorm
    static let depthPixelFormat: MTLPixelFormat = .depth32Float
    static let sampleCount = 4
    /// Clear color behind the background gradient (only visible if the shaders failed to compile).
    static let clearColor = MTLClearColor(red: 0.11, green: 0.115, blue: 0.13, alpha: 1)

    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    private let pipelines: Pipelines?

    var camera = ViewportCamera()
    private(set) var scene = ViewportScene()
    private var hasScene = false

    // Scene lines.
    private var lineBuffer: MTLBuffer?
    private var lineVertexCount = 0
    private var linesVersion = Int.min
    private var linesBounds: (min: SIMD3<Float>, max: SIMD3<Float>)?

    // Bed decorations (fill + grid + axes + travel + triad in one buffer).
    private struct BedKey: Equatable {
        var stock: SIMD3<Float>
        var travel: SIMD2<Float>?
        var spacing: Float
    }
    private var bedKey: BedKey?
    private var bedBuffer: MTLBuffer?
    private var bedFill = 0..<0
    private var bedMinor = 0..<0
    private var bedMajor = 0..<0
    private var bedOverlay = 0..<0
    private var bedTriad = 0..<0
    private var bedSpacing: Float = 25.4
    private var bedBounds: (min: SIMD3<Float>, max: SIMD3<Float>) = (.zero, .zero)

    // Stock box.
    private var stockKey: SIMD3<Float>?
    private var stockFaceBuffer: MTLBuffer?
    private var stockFaceCount = 0
    private var stockEdgeBuffer: MTLBuffer?
    private var stockEdgeCount = 0

    // Height field.
    private var heightTexture: MTLTexture?
    private var heightVersion: Int?
    private var heightColumns = 0
    private var heightRows = 0
    private var heightLayers = 1
    /// True when `heightTexture` is a 2D array (a rotary job's faces).
    private var heightIsArray = false

    // Radial grid (wrapped toolpaths): columns along the blank, rows round it.
    private var radialTexture: MTLTexture?
    private var radialVersion: Int?
    private var radialColumns = 0
    private var radialRows = 0
    /// Bound in place of a texture a rotary draw doesn't have (a wrapped job has no faces, an indexed one no radial
    /// grid): the shaders never read them, since the uniforms say there's nothing there.
    private lazy var emptyArray: MTLTexture? = emptyTexture(array: true)
    private lazy var empty2D: MTLTexture? = emptyTexture(array: false)

    // Rotary blank surface (in the blank's own frame), keyed by square-ness, radius and length.
    private var blankKey: SIMD3<Float>?
    private var blankBuffer: MTLBuffer?
    private var blankVertexCount = 0

    // Tool.
    private var toolSilhouette: [SIMD2<Float>]?
    private var toolBuffer: MTLBuffer?
    private var toolVertexCount = 0
    private var toolExtent = SIMD2<Float>(0, 0)  // (max radius, max height)

    /// Fails only if there is no Metal device or no command queue. If the shaders fail to compile the
    /// renderer still exists but draws nothing (the error is logged).
    init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let device, let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.commandQueue = queue
        queue.label = "NativeCAM viewport"
        self.pipelines = Pipelines.shared(for: device)
    }

    var isReady: Bool { pipelines != nil }

    // MARK: - Scene diffing

    func update(scene new: ViewportScene) {
        if !hasScene || new.geometryVersion != linesVersion || new.lines.count != lineVertexCount {
            uploadLines(new.lines)
            linesVersion = new.geometryVersion
        }

        let bk = BedKey(stock: new.stockSize, travel: new.machineTravel, spacing: new.gridSpacing)
        if bk != bedKey {
            rebuildBed(bk)
            bedKey = bk
        }

        if new.stockSize != stockKey {
            rebuildStock(new.stockSize)
            stockKey = new.stockSize
        }

        if let hf = new.heightField {
            let array = new.rotary != nil
            if hf.version != heightVersion || hf.columns != heightColumns || hf.rows != heightRows || heightTexture == nil
                || array != heightIsArray || hf.layers != heightLayers {
                uploadHeights(hf, array: array)
                heightVersion = hf.version
            }
        } else if heightTexture != nil {
            heightTexture = nil
            heightVersion = nil
            heightColumns = 0
            heightRows = 0
        }

        if let rad = new.rotary?.radial {
            if rad.version != radialVersion || rad.columns != radialColumns || rad.rows != radialRows || radialTexture == nil {
                uploadRadial(rad)
                radialVersion = rad.version
            }
        } else if radialTexture != nil {
            radialTexture = nil
            radialVersion = nil
            radialColumns = 0
            radialRows = 0
        }

        if let r = new.rotary {
            let key = SIMD3<Float>(r.square ? 1 : 0, r.radius, r.length)
            if key != blankKey {
                let mesh = ViewportMeshes.rotaryBlank(square: r.square, radius: r.radius, length: r.length)
                blankBuffer = makeBuffer(mesh)
                blankVertexCount = mesh.count
                blankKey = key
            }
        }

        if let tool = new.tool, tool.silhouette != toolSilhouette {
            rebuildTool(tool.silhouette)
            toolSilhouette = tool.silhouette
        }

        scene = new
        hasScene = true
    }

    private func uploadLines(_ lines: [LineVertex]) {
        let count = lines.count & ~1  // whole pairs only
        lineVertexCount = lines.count
        guard count >= 2 else {
            lineBuffer = nil
            linesBounds = nil
            return
        }
        lineBuffer = lines.withUnsafeBytes { raw in
            device.makeBuffer(bytes: raw.baseAddress!, length: count * MemoryLayout<LineVertex>.stride, options: .storageModeShared)
        }
        lineBuffer?.label = "viewport lines"
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for v in lines where v.position.x.isFinite && v.position.y.isFinite && v.position.z.isFinite {
            lo = simd_min(lo, v.position)
            hi = simd_max(hi, v.position)
        }
        linesBounds = lo.x <= hi.x ? (lo, hi) : nil
    }

    private func rebuildBed(_ key: BedKey) {
        let bed = ViewportMeshes.bed(stockSize: key.stock, travel: key.travel, spacing: key.spacing)
        var all: [LineVertex] = []
        func append(_ part: [LineVertex]) -> Range<Int> {
            let start = all.count
            all += part
            return start..<all.count
        }
        bedFill = append(bed.fill)
        bedMinor = append(bed.minor)
        bedMajor = append(bed.major)
        bedOverlay = append(bed.overlay)
        bedTriad = append(bed.triad)
        bedSpacing = bed.spacing
        bedBounds = (bed.boundsMin, bed.boundsMax)
        bedBuffer = makeBuffer(all)
        bedBuffer?.label = "viewport bed"
    }

    private func rebuildStock(_ size: SIMD3<Float>) {
        let box = ViewportMeshes.stockBox(size: size, edgeColor: SIMD4(0.93, 0.81, 0.62, 0.85))
        stockFaceBuffer = makeBuffer(box.faces)
        stockFaceCount = box.faces.count
        stockEdgeBuffer = makeBuffer(box.edges)
        stockEdgeCount = box.edges.count
    }

    /// Uploads the heights as a 2D texture, or as a 2D array with one slice per layer when `array` (a rotary job).
    private func uploadHeights(_ hf: HeightFieldSnapshot, array: Bool) {
        let cols = hf.columns, rows = hf.rows, layers = max(1, hf.layers)
        let maxDim = 16384
        guard cols >= 1, rows >= 1, cols <= maxDim, rows <= maxDim, layers <= 1024, array || layers == 1,
              hf.heights.count >= cols * rows * layers, hf.cellSize.isFinite, hf.cellSize > 0 else {
            heightTexture = nil
            heightColumns = 0
            heightRows = 0
            return
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: cols, height: rows, mipmapped: false)
        if array {
            desc.textureType = .type2DArray
            desc.arrayLength = layers
        }
        desc.usage = .shaderRead
        desc.storageMode = device.hasUnifiedMemory ? .shared : .managed
        // A fresh texture per version: the previous one stays alive (retained by in-flight command
        // buffers) so the GPU never reads a half-written field.
        guard let tex = device.makeTexture(descriptor: desc) else {
            heightTexture = nil
            return
        }
        tex.label = "viewport heights v\(hf.version)"
        let slice = cols * rows * MemoryLayout<Float>.stride
        hf.heights.withUnsafeBytes { raw in
            for layer in 0..<layers {
                tex.replace(region: MTLRegionMake2D(0, 0, cols, rows), mipmapLevel: 0, slice: layer,
                            withBytes: raw.baseAddress! + layer * slice, bytesPerRow: cols * MemoryLayout<Float>.stride,
                            bytesPerImage: slice)
            }
        }
        heightTexture = tex
        heightColumns = cols
        heightRows = rows
        heightLayers = layers
        heightIsArray = array
    }

    /// Uploads the radial grid as a 2D texture: one column per station along the blank, one row per angle.
    private func uploadRadial(_ r: RadialSnapshot) {
        guard r.columns >= 2, r.rows >= 3, r.columns <= 16384, r.rows <= 16384, r.radii.count >= r.columns * r.rows,
              r.cellSize.isFinite, r.cellSize > 0 else {
            radialTexture = nil
            return
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: r.columns, height: r.rows, mipmapped: false)
        desc.usage = .shaderRead
        desc.storageMode = device.hasUnifiedMemory ? .shared : .managed
        guard let tex = device.makeTexture(descriptor: desc) else {
            radialTexture = nil
            return
        }
        tex.label = "viewport radial v\(r.version)"
        r.radii.withUnsafeBytes { raw in
            tex.replace(region: MTLRegionMake2D(0, 0, r.columns, r.rows), mipmapLevel: 0, withBytes: raw.baseAddress!,
                        bytesPerRow: r.columns * MemoryLayout<Float>.stride)
        }
        radialTexture = tex
        radialColumns = r.columns
        radialRows = r.rows
    }

    private func emptyTexture(array: Bool) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: 1, height: 1, mipmapped: false)
        if array { desc.textureType = .type2DArray; desc.arrayLength = 1 }
        desc.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        var zero: Float = 0
        tex.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, slice: 0, withBytes: &zero,
                    bytesPerRow: MemoryLayout<Float>.stride, bytesPerImage: MemoryLayout<Float>.stride)
        return tex
    }

    private func rebuildTool(_ silhouette: [SIMD2<Float>]) {
        let mesh = ViewportMeshes.revolve(silhouette)
        toolBuffer = makeBuffer(mesh)
        toolVertexCount = mesh.count
        var ext = SIMD2<Float>(0, 0)
        for p in silhouette where p.x.isFinite && p.y.isFinite { ext = simd_max(ext, SIMD2(abs(p.x), p.y)) }
        toolExtent = ext
    }

    private func makeBuffer<T>(_ array: [T]) -> MTLBuffer? {
        guard !array.isEmpty else { return nil }
        return array.withUnsafeBytes { raw in
            device.makeBuffer(bytes: raw.baseAddress!, length: raw.count, options: .storageModeShared)
        }
    }

    // MARK: - Derived scene info

    private var heightFieldDrawable: Bool {
        heightTexture != nil && heightColumns >= 2 && heightRows >= 2 && scene.heightField != nil
    }

    /// Stock box bounds (falls back to a 100 mm square around the origin for empty stock). A rotary blank's are
    /// the space it sweeps as it turns.
    var stockBounds: (min: SIMD3<Float>, max: SIMD3<Float>) {
        if let r = scene.rotary, r.length > 0, r.radius > 0 {
            let o = r.outerRadius
            return (SIMD3(0, r.axis.x - o, r.axis.y - o), SIMD3(r.length, r.axis.x + o, r.axis.y + o))
        }
        let s = scene.stockSize
        let w = ViewportMeshes.finitePositive(s.x), h = ViewportMeshes.finitePositive(s.y), t = ViewportMeshes.finitePositive(s.z)
        if w <= 0 && h <= 0 { return (SIMD3(-50, -50, -max(t, 1)), SIMD3(50, 50, 0)) }
        return (SIMD3(0, 0, -t), SIMD3(w, h, 0))
    }

    /// Everything that can be drawn, used for clip planes and picking.
    var sceneBounds: (min: SIMD3<Float>, max: SIMD3<Float>) {
        var lo = simd_min(bedBounds.min, stockBounds.min)
        var hi = simd_max(bedBounds.max, stockBounds.max)
        if let lb = linesBounds {
            lo = simd_min(lo, lb.min)
            hi = simd_max(hi, lb.max)
        }
        if let tool = scene.tool, tool.tip.x.isFinite, tool.tip.y.isFinite, tool.tip.z.isFinite {
            let r = toolExtent.x
            lo = simd_min(lo, tool.tip - SIMD3(r, r, 0))
            hi = simd_max(hi, tool.tip + SIMD3(r, r, toolExtent.y))
        }
        return (lo, hi)
    }

    /// The current camera re-oriented to `preset` (or kept, if nil) and fitted to the stock.
    func fittedCamera(preset: ViewPreset?, aspect: Float) -> ViewportCamera {
        var c = camera
        if let preset {
            let a = ViewportCamera.angles(for: preset)
            c.azimuth = a.azimuth
            c.elevation = a.elevation
        }
        let b = stockBounds
        return c.fitted(boundsMin: b.min, boundsMax: b.max, aspect: aspect)
    }

    /// The world point under a normalized-device-coordinate position: the material top (z = 0) if the
    /// ray hits it reasonably close to the scene, else the plane through the camera target.
    func pickPoint(ndc: SIMD2<Float>, aspect: Float) -> SIMD3<Float> {
        let (o, d) = camera.ray(ndc: ndc, aspect: aspect)
        let b = sceneBounds
        let pad = max(b.max.x - b.min.x, b.max.y - b.min.y) * 0.5 + 10
        if abs(d.z) > 1e-4 {
            let t = -o.z / d.z
            if t > 0, t < camera.distance * 6 {
                let p = o + d * t
                if p.x > b.min.x - pad, p.x < b.max.x + pad, p.y > b.min.y - pad, p.y < b.max.y + pad { return p }
            }
        }
        let denom = max(simd_dot(d, camera.forward), 1e-3)
        return o + d * (camera.distance / denom)
    }

    // MARK: - Encoding

    private func frameUniforms(pixelSize: SIMD2<Float>) -> ViewportFrameUniforms {
        let aspect = pixelSize.x / max(pixelSize.y, 1)
        let b = sceneBounds
        let center = (b.min + b.max) * 0.5
        let radius = simd_length(b.max - b.min) * 0.5 + 1
        let eyeDist = simd_length(camera.eye - center)
        let near = max(eyeDist - radius * 1.05, camera.distance * 0.001, 0.01)
        let far = max(eyeDist + radius * 1.05, near * 4)
        let proj = ViewportCamera.projection(fovY: camera.fovY, aspect: aspect, near: near, far: far)
        // Camera-relative key light from the viewer's upper left.
        let light = simd_normalize(camera.right * -0.45 + camera.up * 0.55 - camera.forward * 0.70)
        let e = camera.eye
        return ViewportFrameUniforms(viewProj: proj * camera.viewMatrix,
                                     eye: SIMD4(e.x, e.y, e.z, 1),
                                     lightDir: SIMD4(light.x, light.y, light.z, 0),
                                     params: SIMD4(pixelSize.x, pixelSize.y,
                                                   pixelSize.y / (2 * tan(camera.fovY * 0.5)), 0))
    }

    private func setMesh(_ enc: MTLRenderCommandEncoder, _ u: ViewportMeshUniforms) {
        var u = u
        enc.setVertexBytes(&u, length: MemoryLayout<ViewportMeshUniforms>.stride, index: 2)
        enc.setFragmentBytes(&u, length: MemoryLayout<ViewportMeshUniforms>.stride, index: 2)
    }

    /// Encode the whole scene into a render pass whose attachments use the formats above (4x MSAA,
    /// depth cleared to 0 for reversed Z).
    func encode(_ enc: MTLRenderCommandEncoder, pixelSize: SIMD2<Float>) {
        guard let p = pipelines, pixelSize.x >= 1, pixelSize.y >= 1 else { return }
        var frame = frameUniforms(pixelSize: pixelSize)
        enc.setFrontFacing(.counterClockwise)
        enc.setCullMode(.none)

        // 1. Background gradient.
        enc.setRenderPipelineState(p.background)
        enc.setDepthStencilState(p.depthAlways)
        var bg = ViewportBackgroundUniforms(top: SIMD4(0.205, 0.215, 0.240, 1), bottom: SIMD4(0.078, 0.082, 0.094, 1))
        enc.setFragmentBytes(&bg, length: MemoryLayout<ViewportBackgroundUniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        enc.setVertexBytes(&frame, length: MemoryLayout<ViewportFrameUniforms>.stride, index: 1)
        enc.setFragmentBytes(&frame, length: MemoryLayout<ViewportFrameUniforms>.stride, index: 1)

        // 2. Bed fill, grid, axes, travel outline (depth-tested, no depth writes: everything else draws over).
        if let bed = bedBuffer {
            enc.setRenderPipelineState(p.color)
            enc.setDepthStencilState(p.depthTestNoWrite)
            setMesh(enc, ViewportMeshUniforms())
            enc.setVertexBuffer(bed, offset: 0, index: 0)
            if !bedFill.isEmpty {
                enc.drawPrimitives(type: .triangle, vertexStart: bedFill.lowerBound, vertexCount: bedFill.count)
            }
            // Grid lines fade out as their on-screen spacing shrinks (no far-field moire).
            for (range, spacing) in [(bedMinor, bedSpacing), (bedMajor, bedSpacing * 10), (bedOverlay, 0)] where range.count >= 2 {
                setMesh(enc, ViewportMeshUniforms(fadeSpacing: spacing))
                enc.drawPrimitives(type: .line, vertexStart: range.lowerBound, vertexCount: range.count)
            }
        }

        // 3. Carved stock: instanced strip grid + four side walls, or a rotary blank turned to its angle.
        let carved = heightFieldDrawable
        let faceTexture = carved && heightIsArray ? heightTexture : nil
        let radialReady = radialTexture != nil && scene.rotary?.radial != nil
        if let r = scene.rotary, faceTexture != nil || radialReady, let tex = faceTexture ?? emptyArray, let rtex = radialTexture ?? empty2D {
            let faces = faceTexture == nil ? 0 : heightLayers
            var angles = r.faceAngles.prefix(faces).map { $0 * .pi / 180 }
            if angles.count < max(faces, 1) { angles += [Float](repeating: 0, count: max(faces, 1) - angles.count) }
            let hf = scene.heightField
            var ru = ViewportRotaryUniforms(
                dims: SIMD4(Float(heightColumns), Float(heightRows), hf?.cellSize ?? 1, hf?.floorZ ?? 0),
                origin: SIMD4(hf?.origin.x ?? 0, hf?.origin.y ?? 0, r.radius, 0.002 + 0.001 * r.radius),
                axis: SIMD4(r.axis.x, r.axis.y, r.angle * .pi / 180, r.square ? 1 : 0),
                counts: SIMD4(Float(faces), r.length, 0, 0),
                topColor: SIMD4(0.80, 0.665, 0.475, 1),
                cutColor: SIMD4(0.73, 0.575, 0.395, 1),
                deepColor: SIMD4(0.56, 0.425, 0.28, 1),
                sideColor: SIMD4(0.71, 0.56, 0.385, 1))
            if radialReady, let rad = r.radial {
                ru.radial = SIMD4(Float(radialColumns), Float(radialRows), rad.cellSize, rad.originX)
            }
            enc.setDepthStencilState(p.depthWrite)
            for stage in 0..<2 {
                angles.withUnsafeBytes { raw in
                    if stage == 0 { enc.setVertexBytes(raw.baseAddress!, length: raw.count, index: 3) }
                    else { enc.setFragmentBytes(raw.baseAddress!, length: raw.count, index: 3) }
                }
            }
            enc.setVertexBytes(&ru, length: MemoryLayout<ViewportRotaryUniforms>.stride, index: 2)
            enc.setFragmentBytes(&ru, length: MemoryLayout<ViewportRotaryUniforms>.stride, index: 2)
            enc.setVertexTexture(tex, index: 0)
            enc.setFragmentTexture(tex, index: 0)
            enc.setVertexTexture(rtex, index: 1)
            enc.setFragmentTexture(rtex, index: 1)
            if faces > 0 {
                enc.setRenderPipelineState(p.rotaryFace)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 2 * heightColumns,
                                   instanceCount: (heightRows - 1) * faces)
            }
            if radialReady {
                // The radial grid's surface stands in for the blank's.
                enc.setRenderPipelineState(p.rotaryTube)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 2 * radialColumns, instanceCount: radialRows)
                enc.setRenderPipelineState(p.rotaryTubeCap)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6 * radialRows)
            } else if let blank = blankBuffer, blankVertexCount >= 3 {
                enc.setRenderPipelineState(p.rotaryBlank)
                enc.setVertexBuffer(blank, offset: 0, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: blankVertexCount)
            }
        } else if carved, !heightIsArray, let tex = heightTexture, let hf = scene.heightField {
            let thickness = max(-hf.floorZ, ViewportMeshes.finitePositive(scene.stockSize.z), 0.001)
            var hu = ViewportHeightUniforms(
                dims: SIMD4(Float(heightColumns), Float(heightRows), hf.cellSize, hf.floorZ),
                origin: SIMD4(hf.origin.x, hf.origin.y, thickness, 0.002 + 0.001 * thickness),
                topColor: SIMD4(0.80, 0.665, 0.475, 1),
                cutColor: SIMD4(0.73, 0.575, 0.395, 1),
                deepColor: SIMD4(0.56, 0.425, 0.28, 1),
                sideColor: SIMD4(0.71, 0.56, 0.385, 1))
            enc.setDepthStencilState(p.depthWrite)
            enc.setVertexBytes(&hu, length: MemoryLayout<ViewportHeightUniforms>.stride, index: 2)
            enc.setFragmentBytes(&hu, length: MemoryLayout<ViewportHeightUniforms>.stride, index: 2)
            enc.setVertexTexture(tex, index: 0)
            enc.setRenderPipelineState(p.heightField)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 2 * heightColumns,
                               instanceCount: heightRows - 1)
            enc.setRenderPipelineState(p.walls)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 2 * heightColumns,
                               instanceCount: 2, baseInstance: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 2 * heightRows,
                               instanceCount: 2, baseInstance: 2)
        }

        // 4. Tool marker (opaque, lit), translated to the tip.
        if let tool = scene.tool, let buf = toolBuffer, toolVertexCount >= 3,
           tool.tip.x.isFinite, tool.tip.y.isFinite, tool.tip.z.isFinite {
            var model = matrix_identity_float4x4
            model.columns.3 = SIMD4(tool.tip.x, tool.tip.y, tool.tip.z, 1)
            enc.setRenderPipelineState(p.meshOpaque)
            enc.setDepthStencilState(p.depthWrite)
            enc.setCullMode(.back)
            setMesh(enc, ViewportMeshUniforms(model: model, color: tool.color, specular: 0.45, shininess: 48))
            enc.setVertexBuffer(buf, offset: 0, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: toolVertexCount)
            enc.setCullMode(.none)
        }

        // 5. Translucent stock box (back faces, then front faces; no depth writes) and its edges.
        if !carved, !radialReady, scene.showStock, let faces = stockFaceBuffer, stockFaceCount >= 3 {
            enc.setRenderPipelineState(p.meshBlended)
            enc.setDepthStencilState(p.depthTestNoWrite)
            setMesh(enc, ViewportMeshUniforms(color: SIMD4(0.80, 0.66, 0.46, 0.17), specular: 0.04, shininess: 24))
            enc.setVertexBuffer(faces, offset: 0, index: 0)
            enc.setCullMode(.front)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: stockFaceCount)
            enc.setCullMode(.back)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: stockFaceCount)
            enc.setCullMode(.none)
            if let edges = stockEdgeBuffer, stockEdgeCount >= 2 {
                enc.setRenderPipelineState(p.color)
                setMesh(enc, ViewportMeshUniforms(depthPull: 0.0008))
                enc.setVertexBuffer(edges, offset: 0, index: 0)
                enc.drawPrimitives(type: .line, vertexStart: 0, vertexCount: stockEdgeCount)
            }
        }

        // 6. Scene lines (vectors, toolpaths): depth-tested but pulled slightly towards the eye so they
        //    stay visible on the surfaces they lie on.
        if let lines = lineBuffer {
            let count = lineVertexCount & ~1
            if count >= 2 {
                enc.setRenderPipelineState(p.color)
                enc.setDepthStencilState(p.depthTestNoWrite)
                setMesh(enc, ViewportMeshUniforms(depthPull: 0.0015))
                enc.setVertexBuffer(lines, offset: 0, index: 0)
                enc.drawPrimitives(type: .line, vertexStart: 0, vertexCount: count)
            }
        }

        // 7. Origin triad, always on top.
        if let bed = bedBuffer, bedTriad.count >= 2 {
            enc.setRenderPipelineState(p.color)
            enc.setDepthStencilState(p.depthAlways)
            setMesh(enc, ViewportMeshUniforms())
            enc.setVertexBuffer(bed, offset: 0, index: 0)
            enc.drawPrimitives(type: .line, vertexStart: bedTriad.lowerBound, vertexCount: bedTriad.count)
        }
    }

    // MARK: - Offscreen rendering

    /// Render the current scene and camera into a `width` x `height` pixel image (sRGB, opaque).
    func snapshot(width: Int, height: Int) -> CGImage? {
        guard isReady, width > 0, height > 0, width <= 16384, height <= 16384 else { return nil }
        func target(_ format: MTLPixelFormat, msaa: Bool) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
            if msaa {
                d.textureType = .type2DMultisample
                d.sampleCount = Self.sampleCount
            }
            d.usage = .renderTarget
            d.storageMode = .private
            return device.makeTexture(descriptor: d)
        }
        guard let msColor = target(Self.colorPixelFormat, msaa: true),
              let resolved = target(Self.colorPixelFormat, msaa: false),
              let depth = target(Self.depthPixelFormat, msaa: true) else { return nil }

        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = msColor
        rpd.colorAttachments[0].resolveTexture = resolved
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .multisampleResolve
        rpd.colorAttachments[0].clearColor = Self.clearColor
        rpd.depthAttachment.texture = depth
        rpd.depthAttachment.loadAction = .clear
        rpd.depthAttachment.storeAction = .dontCare
        rpd.depthAttachment.clearDepth = 0

        let bytesPerRow = width * 4
        guard let cb = commandQueue.makeCommandBuffer(),
              let readback = device.makeBuffer(length: bytesPerRow * height, options: .storageModeShared),
              let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return nil }
        encode(enc, pixelSize: SIMD2(Float(width), Float(height)))
        enc.endEncoding()
        guard let blit = cb.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: resolved, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: width, height: height, depth: 1), to: readback, destinationOffset: 0,
                  destinationBytesPerRow: bytesPerRow, destinationBytesPerImage: bytesPerRow * height)
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        guard cb.status == .completed else { return nil }

        let data = Data(bytes: readback.contents(), count: bytesPerRow * height) as CFData
        guard let provider = CGDataProvider(data: data),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                       space: space, bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }

    /// One-shot offscreen render of `scene` from a preset view fitted to the stock.
    static func snapshot(scene: ViewportScene, width: Int, height: Int, preset: ViewPreset = .iso,
                         device: MTLDevice? = MTLCreateSystemDefaultDevice()) -> CGImage? {
        guard let r = ViewportRenderer(device: device) else { return nil }
        r.update(scene: scene)
        r.camera = r.fittedCamera(preset: preset, aspect: Float(width) / Float(max(height, 1)))
        return r.snapshot(width: width, height: height)
    }
}

// MARK: - Pipeline states (compiled once per device from the runtime shader source)

private final class Pipelines {
    let background: MTLRenderPipelineState
    let color: MTLRenderPipelineState
    let meshOpaque: MTLRenderPipelineState
    let meshBlended: MTLRenderPipelineState
    let heightField: MTLRenderPipelineState
    let walls: MTLRenderPipelineState
    let rotaryFace: MTLRenderPipelineState
    let rotaryBlank: MTLRenderPipelineState
    let rotaryTube: MTLRenderPipelineState
    let rotaryTubeCap: MTLRenderPipelineState
    let depthWrite: MTLDepthStencilState
    let depthTestNoWrite: MTLDepthStencilState
    let depthAlways: MTLDepthStencilState

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [UInt64: Pipelines] = [:]

    static func shared(for device: MTLDevice) -> Pipelines? {
        lock.lock()
        defer { lock.unlock() }
        if let p = cache[device.registryID] { return p }
        do {
            let p = try Pipelines(device: device)
            cache[device.registryID] = p
            return p
        } catch {
            NSLog("NativeCAM viewport: failed to build Metal pipelines: %@", String(describing: error))
            return nil
        }
    }

    private struct BuildError: Error, CustomStringConvertible {
        var description: String
    }

    private init(device: MTLDevice) throws {
        let library = try device.makeLibrary(source: ViewportShaders.source, options: nil)
        func function(_ name: String) throws -> MTLFunction {
            guard let f = library.makeFunction(name: name) else { throw BuildError(description: "missing shader function \(name)") }
            return f
        }

        let colorVD = MTLVertexDescriptor()
        colorVD.attributes[0].format = .float3
        colorVD.attributes[0].offset = MemoryLayout<LineVertex>.offset(of: \LineVertex.position) ?? 0
        colorVD.attributes[0].bufferIndex = 0
        colorVD.attributes[1].format = .float4
        colorVD.attributes[1].offset = MemoryLayout<LineVertex>.offset(of: \LineVertex.color) ?? 16
        colorVD.attributes[1].bufferIndex = 0
        colorVD.layouts[0].stride = MemoryLayout<LineVertex>.stride

        let meshVD = MTLVertexDescriptor()
        meshVD.attributes[0].format = .float3
        meshVD.attributes[0].offset = MemoryLayout<ViewportMeshVertex>.offset(of: \ViewportMeshVertex.position) ?? 0
        meshVD.attributes[0].bufferIndex = 0
        meshVD.attributes[1].format = .float3
        meshVD.attributes[1].offset = MemoryLayout<ViewportMeshVertex>.offset(of: \ViewportMeshVertex.normal) ?? 16
        meshVD.attributes[1].bufferIndex = 0
        meshVD.layouts[0].stride = MemoryLayout<ViewportMeshVertex>.stride

        func pipeline(_ label: String, _ vertex: String, _ fragment: String, _ vd: MTLVertexDescriptor?,
                      blended: Bool) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.label = label
            d.vertexFunction = try function(vertex)
            d.fragmentFunction = try function(fragment)
            d.vertexDescriptor = vd
            d.rasterSampleCount = ViewportRenderer.sampleCount
            d.depthAttachmentPixelFormat = ViewportRenderer.depthPixelFormat
            let ca = d.colorAttachments[0]!
            ca.pixelFormat = ViewportRenderer.colorPixelFormat
            if blended {
                ca.isBlendingEnabled = true
                ca.rgbBlendOperation = .add
                ca.alphaBlendOperation = .add
                ca.sourceRGBBlendFactor = .sourceAlpha
                ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
                ca.sourceAlphaBlendFactor = .one
                ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try device.makeRenderPipelineState(descriptor: d)
        }

        background = try pipeline("background", "background_vertex", "background_fragment", nil, blended: false)
        color = try pipeline("color", "color_vertex", "color_fragment", colorVD, blended: true)
        meshOpaque = try pipeline("mesh", "mesh_vertex", "mesh_fragment", meshVD, blended: false)
        meshBlended = try pipeline("mesh blended", "mesh_vertex", "mesh_fragment", meshVD, blended: true)
        heightField = try pipeline("height field", "heightfield_vertex", "heightfield_fragment", nil, blended: false)
        walls = try pipeline("walls", "wall_vertex", "wall_fragment", nil, blended: false)
        rotaryFace = try pipeline("rotary faces", "rotary_face_vertex", "rotary_face_fragment", nil, blended: false)
        rotaryBlank = try pipeline("rotary blank", "rotary_blank_vertex", "rotary_blank_fragment", meshVD, blended: false)
        rotaryTube = try pipeline("rotary radial", "rotary_tube_vertex", "rotary_tube_fragment", nil, blended: false)
        rotaryTubeCap = try pipeline("rotary radial ends", "rotary_tube_cap_vertex", "rotary_tube_fragment", nil, blended: false)

        func depthState(_ compare: MTLCompareFunction, write: Bool) throws -> MTLDepthStencilState {
            let d = MTLDepthStencilDescriptor()
            d.depthCompareFunction = compare
            d.isDepthWriteEnabled = write
            guard let s = device.makeDepthStencilState(descriptor: d) else { throw BuildError(description: "depth state") }
            return s
        }
        // Reversed Z: nearer = larger depth.
        depthWrite = try depthState(.greaterEqual, write: true)
        depthTestNoWrite = try depthState(.greaterEqual, write: false)
        depthAlways = try depthState(.always, write: false)
    }
}
