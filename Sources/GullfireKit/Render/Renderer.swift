import Dispatch
import Foundation
import Metal
import QuartzCore
import simd

public enum RenderError: Error, Equatable {
    case noDevice
    case shaderCompile(String)
    case gpu(String)
}

/// Uniform block shared with `Shaders.source` (struct `U`). Keep the field order identical.
struct Uniforms {
    var vp: simd_float4x4
    var viewport: SIMD2<Float>
    var widthPx: Float
    var bias: Float
    var color: SIMD4<Float>
    var fadeDist: Float
    /// The draw distance in metres, or 0 for none: lines fade to nothing over its last fifth (the shader's `edge`).
    var cutoff: Float = 0
    /// The eye in render space, for the distance the cutoff measures.
    var eye: SIMD3<Float> = .zero
}

/// The latest completed frame's GPU time and any GPU error. Written by Metal's feedback thread,
/// read on the caller's thread. This class is the only state shared across threads.
private final class GPUStats: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds = 0.0
    private var error: String?

    func store(seconds: Double, error: String?) {
        lock.lock()
        self.seconds = seconds
        if let error { self.error = error }
        lock.unlock()
    }

    func read() -> (seconds: Double, error: String?) {
        lock.lock()
        defer { lock.unlock() }
        let e = error
        error = nil
        return (seconds, e)
    }
}

/// Everything one in-flight frame writes to, so the CPU can prepare the next frame while the GPU
/// still reads this one.
private final class FrameSlot {
    let allocator: MTL4CommandAllocator
    let commandBuffer: MTL4CommandBuffer
    /// Index 0 for solids; index 1 + `LineGroup.rawValue` for each line group.
    let uniforms: [MTLBuffer]
    let solidTable: MTL4ArgumentTable
    let lineTables: [MTL4ArgumentTable]
    /// The aircraft: its own uniforms (index 0 solids, 1 lines) and tables.
    let aircraftUniforms: [MTLBuffer]
    let aircraftSolidTable: MTL4ArgumentTable
    let aircraftLineTable: MTL4ArgumentTable

    init(allocator: MTL4CommandAllocator, commandBuffer: MTL4CommandBuffer, uniforms: [MTLBuffer],
         solidTable: MTL4ArgumentTable, lineTables: [MTL4ArgumentTable],
         aircraftUniforms: [MTLBuffer], aircraftSolidTable: MTL4ArgumentTable, aircraftLineTable: MTL4ArgumentTable) {
        self.allocator = allocator
        self.commandBuffer = commandBuffer
        self.uniforms = uniforms
        self.solidTable = solidTable
        self.lineTables = lineTables
        self.aircraftUniforms = aircraftUniforms
        self.aircraftSolidTable = aircraftSolidTable
        self.aircraftLineTable = aircraftLineTable
    }
}

/// Metal 4 renderer for one city package and one size.
///
/// Each frame: solids into the depth buffer only, then one instanced draw per line group with
/// `max` blending. Geometry is the package's memory-mapped buffers, wrapped without copying.
///
/// Two modes. The headless tool renders and waits, then reads pixels back. The app renders into
/// each window drawable without waiting, with as many frames in flight as it has drawables.
/// Every buffer and texture the GPU touches is in a residency set; a missing entry draws nothing
/// and reports no error, so the set is updated on every size change.
public final class Renderer {
    /// Frames the GPU may hold at once. Two for the app. The layer itself holds three drawables (`maximumDrawableCount = 3`, App/MetalView.swift).
    public static let framesInFlight = 2

    public private(set) var width: Int
    public private(set) var height: Int
    public let device: MTLDevice

    /// Kept alive so the memory-mapped data behind the buffers outlives them.
    private let city: CityPackage
    /// True for the headless tool, which reads pixels back. False in the app, which draws into
    /// each window drawable and needs no resolve texture of its own.
    private let offscreen: Bool
    private let queue: MTL4CommandQueue
    private let solidPipeline: MTLRenderPipelineState
    private let linePipeline: MTLRenderPipelineState
    private let depthWrite: MTLDepthStencilState
    private let depthRead: MTLDepthStencilState
    private let solidBuffer: MTLBuffer
    private let lineBuffer: MTLBuffer
    private let slots: [FrameSlot]
    private let residency: MTLResidencySet
    private let inflight = DispatchSemaphore(value: Renderer.framesInFlight)
    private let stats = GPUStats()
    private var nextSlot = 0
    public private(set) var target: OffscreenTarget
    /// Time the last frame spent in `inflight.wait()`, milliseconds (measurement only).
    public private(set) var lastInflightWaitMs = 0.0
    /// Start-up milestones with absolute `CACurrentMediaTime()` values, for the performance log.
    public private(set) var startupTimes: [(name: String, t: Double)] = []

    /// Cull tiles outside the view. Ignored for a package without tiles.
    /// False draws everything, as a package without tiles does.
    public var culling = true
    /// The aircraft to draw this frame (set each frame by the app; nil draws none). Needs `loadAircraft` first.
    public var aircraft: AircraftPose?
    private var aircraftSolids: MTLBuffer?
    private var aircraftLines: MTLBuffer?
    private var aircraftTriangleCount = 0
    private var aircraftSegmentCount = 0
    /// Distant tiles draw less (LevelOfDetail.swift). Nil draws every tile in full, as today. Applies
    /// only on the tiled path; a package without tiles ignores it.
    public var levelOfDetail: LevelOfDetail? = nil
    /// Tiles whose nearest point is farther than this from the eye (metres) are not drawn: a draw distance, so a very large package
    /// costs what the nearby part costs. Nil draws every tile in view. Tiled packages only.
    public var drawDistance: Float? = nil
    /// Statistics for the last frame. Without a tile index, `lastTilesTotal` and `lastTilesDrawn` are 0.
    public private(set) var lastTilesDrawn = 0
    public private(set) var lastTilesTotal = 0
    public private(set) var lastSegmentsDrawn = 0
    /// Draw calls after merging adjacent ranges.
    public private(set) var lastDrawCalls = 0
    /// CPU time from the start of visibility work to `endEncoding()`, milliseconds.
    public private(set) var lastEncodeMs = 0.0

    /// A contiguous range: vertices for solids, instances (segments) for lines.
    private struct Run {
        var first: Int
        var count: Int
    }
    /// Reused every frame, so visibility does not allocate once they have grown.
    private var solidRuns: [Run] = []
    private var lineRuns: [[Run]] = Array(repeating: [], count: LineGroup.allCases.count)

    /// Called at the start-up steps the memory brief measures (marks 2–4). Empty for the tool.
    public typealias Checkpoint = (String) -> Void

    public init(city: CityPackage, width: Int, height: Int, offscreen: Bool = true,
                checkpoint: Checkpoint = { _ in }) throws {
        var milestones: [(name: String, t: Double)] = [("renderer init begins", CACurrentMediaTime())]
        guard let device = MTLCreateSystemDefaultDevice() else { throw RenderError.noDevice }
        self.device = device
        self.city = city
        self.width = width
        self.height = height
        self.offscreen = offscreen

        guard let queue = device.makeMTL4CommandQueue() else {
            throw RenderError.gpu("could not create a Metal 4 command queue")
        }
        self.queue = queue

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: Shaders.source, options: nil)
        } catch {
            throw RenderError.shaderCompile("\(error)")
        }
        milestones.append(("shader library compiled", CACurrentMediaTime()))
        checkpoint("shader library compiled")
        let compiler = try device.makeCompiler(descriptor: MTL4CompilerDescriptor())

        func function(_ name: String) -> MTL4LibraryFunctionDescriptor {
            let f = MTL4LibraryFunctionDescriptor()
            f.name = name
            f.library = library
            return f
        }
        func pipeline(_ vertex: String, _ fragment: String, blendLines: Bool) throws -> MTLRenderPipelineState {
            let d = MTL4RenderPipelineDescriptor()
            d.vertexFunctionDescriptor = function(vertex)
            d.fragmentFunctionDescriptor = function(fragment)
            d.rasterSampleCount = OffscreenTarget.sampleCount
            let colour = d.colorAttachments[0]!
            colour.pixelFormat = .bgra8Unorm
            if blendLines {
                colour.blendingState = .enabled
                colour.rgbBlendOperation = .max
                colour.alphaBlendOperation = .max
                colour.sourceRGBBlendFactor = .one
                colour.destinationRGBBlendFactor = .one
                colour.sourceAlphaBlendFactor = .one
                colour.destinationAlphaBlendFactor = .one
            } else {
                colour.writeMask = []
            }
            return try compiler.makeRenderPipelineState(descriptor: d)
        }
        solidPipeline = try pipeline("solidV", "solidF", blendLines: false)
        linePipeline = try pipeline("lineV", "lineF", blendLines: true)
        milestones.append(("pipelines built", CACurrentMediaTime()))
        checkpoint("pipelines built")

        func depthState(write: Bool) throws -> MTLDepthStencilState {
            let d = MTLDepthStencilDescriptor()
            d.depthCompareFunction = .greater     // reverse-Z
            d.isDepthWriteEnabled = write
            guard let state = device.makeDepthStencilState(descriptor: d) else {
                throw RenderError.gpu("could not create a depth state")
            }
            return state
        }
        depthWrite = try depthState(write: true)
        depthRead = try depthState(write: false)

        solidBuffer = try Renderer.sharedBuffer(city.solids, device: device)
        lineBuffer = try Renderer.sharedBuffer(city.lines, device: device)

        let tableDescriptor = MTL4ArgumentTableDescriptor()
        tableDescriptor.maxBufferBindCount = 2
        var built: [FrameSlot] = []
        for _ in 0..<Renderer.framesInFlight {
            guard let allocator = device.makeCommandAllocator(),
                  let commandBuffer = device.makeCommandBuffer() else {
                throw RenderError.gpu("could not create a command allocator or buffer")
            }
            var uniforms: [MTLBuffer] = []
            for _ in 0...LineGroup.allCases.count {
                guard let buffer = device.makeBuffer(length: MemoryLayout<Uniforms>.stride, options: .storageModeShared) else {
                    throw RenderError.gpu("could not create a uniform buffer")
                }
                uniforms.append(buffer)
            }
            let solidTable = try device.makeArgumentTable(descriptor: tableDescriptor)
            solidTable.setAddress(solidBuffer.gpuAddress, index: 0)
            solidTable.setAddress(uniforms[0].gpuAddress, index: 1)
            var lineTables: [MTL4ArgumentTable] = []
            for group in LineGroup.allCases {
                let table = try device.makeArgumentTable(descriptor: tableDescriptor)
                let first = city.manifest.lineGroups[group.rawValue].first
                table.setAddress(lineBuffer.gpuAddress + UInt64(first * 24), index: 0)
                table.setAddress(uniforms[1 + group.rawValue].gpuAddress, index: 1)
                lineTables.append(table)
            }
            var aircraftUniforms: [MTLBuffer] = []
            for _ in 0..<2 {
                guard let buffer = device.makeBuffer(length: MemoryLayout<Uniforms>.stride, options: .storageModeShared) else {
                    throw RenderError.gpu("could not create an aircraft uniform buffer")
                }
                aircraftUniforms.append(buffer)
            }
            let aircraftSolidTable = try device.makeArgumentTable(descriptor: tableDescriptor)
            aircraftSolidTable.setAddress(aircraftUniforms[0].gpuAddress, index: 1)
            let aircraftLineTable = try device.makeArgumentTable(descriptor: tableDescriptor)
            aircraftLineTable.setAddress(aircraftUniforms[1].gpuAddress, index: 1)
            built.append(FrameSlot(allocator: allocator, commandBuffer: commandBuffer, uniforms: uniforms,
                                   solidTable: solidTable, lineTables: lineTables, aircraftUniforms: aircraftUniforms,
                                   aircraftSolidTable: aircraftSolidTable, aircraftLineTable: aircraftLineTable))
        }
        slots = built
        milestones.append(("argument tables built", CACurrentMediaTime()))

        target = try OffscreenTarget(device: device, width: width, height: height, makeResolve: offscreen)

        let set = try device.makeResidencySet(descriptor: MTLResidencySetDescriptor())
        var allocations: [MTLAllocation] = [solidBuffer, lineBuffer]
        for slot in built { allocations += slot.uniforms + slot.aircraftUniforms }
        set.addAllocations(allocations + target.allocations)
        set.commit()
        queue.addResidencySet(set)
        residency = set
        milestones.append(("residency set committed", CACurrentMediaTime()))
        checkpoint("residency set committed")
        startupTimes = milestones
    }

    /// Loads the aircraft's triangles and lines into buffers of their own and makes them resident. Call once, before the first frame
    /// that sets `aircraft`.
    public func loadAircraft(_ model: AircraftModel) throws {
        guard !model.triangles.isEmpty, !model.lines.isEmpty else { return }
        guard let solids = device.makeBuffer(bytes: model.triangles, length: model.triangles.count * 4, options: .storageModeShared),
              let lines = device.makeBuffer(bytes: model.lines, length: model.lines.count * 4, options: .storageModeShared) else {
            throw RenderError.gpu("could not create the aircraft buffers")
        }
        aircraftSolids = solids
        aircraftLines = lines
        aircraftTriangleCount = model.triangles.count / 9
        aircraftSegmentCount = model.lines.count / 6
        for slot in slots {
            slot.aircraftSolidTable.setAddress(solids.gpuAddress, index: 0)
            slot.aircraftLineTable.setAddress(lines.gpuAddress, index: 0)
        }
        residency.addAllocations([solids, lines])
        residency.commit()
    }

    /// Adds a window's layer residency set, so its drawables can be written to. Call once.
    public func attach(layer: CAMetalLayer) {
        queue.addResidencySet(layer.residencySet)
    }

    /// Rebuilds the MSAA and depth textures for a new size. The old ones leave the residency set,
    /// the new ones join it, and the set is committed. Skipping this step draws nothing.
    public func resize(width newWidth: Int, height newHeight: Int) throws {
        guard newWidth != width || newHeight != height else { return }
        let replacement = try OffscreenTarget(device: device, width: newWidth, height: newHeight, makeResolve: offscreen)
        residency.removeAllocations(target.allocations)
        residency.addAllocations(replacement.allocations)
        residency.commit()
        target = replacement
        width = newWidth
        height = newHeight
    }

    /// Wraps mapped file data in a Metal buffer without copying. The size is rounded up to the
    /// 16 KB page Metal requires; the mapping already covers the rounded length.
    static func sharedBuffer(_ data: Data, device: MTLDevice) throws -> MTLBuffer {
        let page = 16_384
        let length = (data.count + page - 1) / page * page
        let buffer = data.withUnsafeBytes { raw -> MTLBuffer? in
            guard let base = raw.baseAddress else { return nil }
            return device.makeBuffer(bytesNoCopy: UnsafeMutableRawPointer(mutating: base), length: length,
                                     options: .storageModeShared, deallocator: nil)
        }
        guard let buffer else { throw RenderError.gpu("could not wrap \(data.count) bytes of package data") }
        return buffer
    }

    /// Renders one frame.
    ///
    /// Offscreen (no drawable): waits for the GPU and returns this frame's GPU time in seconds.
    /// With a drawable: returns at once and presents the frame when the GPU is done. The return
    /// value is then the latest completed frame's GPU time. A GPU error from an earlier frame is
    /// thrown by the next call.
    @discardableResult
    public func render(camera: Camera, palette: Palette, style: LineStyle = .standard,
                       drawHidden: Bool = true, drawable: CAMetalDrawable? = nil) throws -> Double {
        let previous = stats.read()
        if let error = previous.error { throw RenderError.gpu(error) }

        let resolve: MTLTexture
        if let drawable {
            resolve = drawable.texture
        } else if let offscreenResolve = target.resolve {
            resolve = offscreenResolve
        } else {
            throw RenderError.gpu("no resolve texture: the app must pass a drawable")
        }

        let waitStart = CACurrentMediaTime()   // measurement only: the pacing is unchanged
        inflight.wait()
        lastInflightWaitMs = (CACurrentMediaTime() - waitStart) * 1000
        let slot = slots[nextSlot]
        nextSlot = (nextSlot + 1) % slots.count
        // The token just granted means the GPU has finished the frame that used this slot.
        slot.allocator.reset()

        let vp = camera.viewProjection(aspect: Float(width) / Float(height))
        let viewport = SIMD2(Float(width), Float(height))
        let widthPx = 1.6 * Float(height) / 1440
        for (index, buffer) in slot.uniforms.enumerated() {
            let colour: SIMD4<Float>
            if index == 0 {
                colour = SIMD4(0, 0, 0, 1)
            } else {
                let group = LineGroup(rawValue: index - 1)!
                let base = group == .water ? palette.water : palette.line
                colour = SIMD4(base * style.intensity(for: group), 1)
            }
            buffer.contents().storeBytes(of: Uniforms(vp: vp, viewport: viewport, widthPx: widthPx,
                                                      bias: 0.002, color: colour, fadeDist: 600, cutoff: drawDistance ?? 0, eye: camera.eye),
                                         as: Uniforms.self)
        }

        // The aircraft: the same view-projection times its model matrix; lines at full brightness and not faded with distance.
        if let pose = aircraft, aircraftSolids != nil {
            let mvp = vp * pose.matrix()
            slot.aircraftUniforms[0].contents().storeBytes(
                of: Uniforms(vp: mvp, viewport: viewport, widthPx: widthPx, bias: 0.002, color: SIMD4(0, 0, 0, 1), fadeDist: 0),
                as: Uniforms.self)
            slot.aircraftUniforms[1].contents().storeBytes(
                of: Uniforms(vp: mvp, viewport: viewport, widthPx: widthPx, bias: 0.002, color: SIMD4(palette.line, 1), fadeDist: 0),
                as: Uniforms.self)
        }

        // Visibility and encode time (measurement is CPU only; nothing here changes what is drawn).
        let encodeStart = CACurrentMediaTime()
        let tiles = culling ? city.manifest.tiles : nil
        if let tiles {
            gatherVisible(vp: vp, eye: camera.eye, fovDegrees: camera.fovDegrees, drawHidden: drawHidden, tiles: tiles)
        } else {
            lastTilesTotal = city.manifest.tiles?.entries.count ?? 0
            lastTilesDrawn = lastTilesTotal
            lastSegmentsDrawn = city.manifest.segmentCount
        }

        let pass = MTL4RenderPassDescriptor()
        pass.colorAttachments[0].texture = target.msaa
        pass.colorAttachments[0].resolveTexture = resolve
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .multisampleResolve
        let bg = palette.background
        pass.colorAttachments[0].clearColor = MTLClearColor(red: Double(bg.x), green: Double(bg.y),
                                                            blue: Double(bg.z), alpha: 1)
        pass.depthAttachment.texture = target.depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        pass.depthAttachment.clearDepth = 0

        let commands = slot.commandBuffer
        commands.beginCommandBuffer(allocator: slot.allocator)
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else {
            throw RenderError.gpu("could not create a render encoder")
        }
        var calls = 0
        let tiled = tiles != nil
        if drawHidden {
            encoder.setRenderPipelineState(solidPipeline)
            encoder.setDepthStencilState(depthWrite)
            encoder.setCullMode(.none)
            encoder.setDepthBias(-1, slopeScale: -1.5, clamp: 0)
            encoder.setArgumentTable(slot.solidTable, stages: [.vertex, .fragment])
            if tiled {
                for run in solidRuns {
                    encoder.drawPrimitives(primitiveType: .triangle, vertexStart: run.first, vertexCount: run.count)
                    calls += 1
                }
            } else {
                encoder.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: city.manifest.solidTriangleCount * 3)
                calls += 1
            }
            if aircraft != nil, aircraftSolids != nil {
                encoder.setArgumentTable(slot.aircraftSolidTable, stages: [.vertex, .fragment])
                encoder.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: aircraftTriangleCount * 3)
                calls += 1
            }
        }
        encoder.setRenderPipelineState(linePipeline)
        encoder.setDepthStencilState(depthRead)
        for group in LineGroup.allCases {
            let range = city.manifest.lineGroups[group.rawValue]
            if tiled {
                // Instance IDs are relative to the group's buffer offset, so `baseInstance` is the run's
                // first segment minus the group's first (the table is bound at that offset).
                let runs = lineRuns[group.rawValue]
                guard !runs.isEmpty else { continue }
                encoder.setArgumentTable(slot.lineTables[group.rawValue], stages: [.vertex, .fragment])
                for run in runs {
                    encoder.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: 6,
                                           instanceCount: run.count, baseInstance: run.first - range.first)
                    calls += 1
                }
            } else {
                guard range.count > 0 else { continue }
                encoder.setArgumentTable(slot.lineTables[group.rawValue], stages: [.vertex, .fragment])
                encoder.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: range.count)
                calls += 1
            }
        }
        if aircraft != nil, aircraftLines != nil {
            encoder.setArgumentTable(slot.aircraftLineTable, stages: [.vertex, .fragment])
            encoder.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: aircraftSegmentCount)
            calls += 1
        }
        encoder.endEncoding()
        commands.endCommandBuffer()
        lastDrawCalls = calls
        lastEncodeMs = (CACurrentMediaTime() - encodeStart) * 1000

        let completion: DispatchSemaphore? = drawable == nil ? DispatchSemaphore(value: 0) : nil
        let stats = self.stats, inflight = self.inflight
        let options = MTL4CommitOptions()
        options.addFeedbackHandler { feedback in
            stats.store(seconds: feedback.gpuEndTime - feedback.gpuStartTime,
                        error: feedback.error?.localizedDescription)
            inflight.signal()
            completion?.signal()
        }
        if let drawable { queue.waitForDrawable(drawable) }
        queue.commit([commands], options: options)
        if let drawable {
            queue.signalDrawable(drawable)
            drawable.present()
            return previous.seconds
        }
        completion?.wait()
        let result = stats.read()
        if let error = result.error { throw RenderError.gpu(error) }
        return result.seconds
    }

    /// Fills `solidRuns` and `lineRuns` with the merged ranges of the tiles whose box can be on screen,
    /// plus the always-drawn ground quad, and sets the tile statistics. Tiles are in ascending order
    /// within each group, so adjacent visible tiles merge into one draw.
    private func gatherVisible(vp: simd_float4x4, eye: SIMD3<Float>, fovDegrees: Float, drawHidden: Bool,
                               tiles: TileIndex) {
        let frustum = Frustum(viewProjection: vp)
        solidRuns.removeAll(keepingCapacity: true)
        for g in lineRuns.indices { lineRuns[g].removeAll(keepingCapacity: true) }
        if drawHidden, tiles.always.solidCount > 0 {
            Renderer.appendRun(&solidRuns, first: tiles.always.solidFirst, count: tiles.always.solidCount)
        }
        var visible = 0
        var segments = 0
        for e in tiles.entries {
            // Render space: x = east, y = up, z = minus north (the same mapping as `StillView.camera`).
            let lo = SIMD3<Float>(Float(e.min[0]), Float(e.min[2]), -Float(e.max[1]))
            let hi = SIMD3<Float>(Float(e.max[0]), Float(e.max[2]), -Float(e.min[1]))
            guard frustum.intersects(min: lo, max: hi) else { continue }
            if let limit = drawDistance, LevelOfDetail.distance(from: eye, toBoxMin: lo, max: hi) > limit { continue }
            visible += 1
            if drawHidden, e.solidCount > 0 {
                Renderer.appendRun(&solidRuns, first: e.solidFirst, count: e.solidCount)
            }
            // Level of detail (brief T4): a shorter draw of the same range, so no extra geometry.
            var level = 1
            var tallIndex: Int? = nil
            if let lod = levelOfDetail {
                let distance = LevelOfDetail.distance(from: eye, toBoxMin: lo, max: hi)
                level = lod.level(distance: distance)
                // Brief T4b: at level 3, the buildings past the height cut for this distance.
                if level >= 3, let h = lod.minHeight(distance: distance, fovDegrees: fovDegrees),
                   let cuts = tiles.heightCutsM {
                    tallIndex = LevelOfDetail.heightCut(atOrBelow: h, cuts: cuts)
                }
            }
            for g in lineRuns.indices {
                let range = e.lines[g]
                if level >= 3, g == LineGroup.buildingsDefault.rawValue || g == LineGroup.roads.rawValue { continue }
                let reduced = level >= 2 && g <= LineGroup.buildingsDefault.rawValue
                var count = reduced ? min(range.farCount, range.count) : range.count
                if let i = tallIndex, let tall = range.tallCounts, i < tall.count {
                    // The tall buildings of this tile, not `farCount`, at level 3.
                    count = min(tall[i], range.count)
                }
                guard count > 0 else { continue }
                // A truncated range ends before the next range starts, so it never merges with it.
                Renderer.appendRun(&lineRuns[g], first: range.first, count: count)
                segments += count
            }
        }
        lastTilesDrawn = visible
        lastTilesTotal = tiles.entries.count
        lastSegmentsDrawn = segments
    }

    /// Appends a range, or extends the last one when it ends where this one starts.
    private static func appendRun(_ runs: inout [Run], first: Int, count: Int) {
        if let last = runs.last, last.first + last.count == first {
            runs[runs.count - 1].count += count
        } else {
            runs.append(Run(first: first, count: count))
        }
    }

    /// Resolved pixels of the most recent offscreen frame, BGRA, top row first.
    public func pixels() -> [UInt8] {
        target.readBGRA()
    }

    public func writePNG(to url: URL) throws {
        try Image.writePNG(bgra: pixels(), width: width, height: height, to: url)
    }
}
