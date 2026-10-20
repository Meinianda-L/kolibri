import Metal
import MetalKit
import QuartzCore

/// Draws the latest guest frame aspect-fit into the view. Runs at the display's
/// native refresh (ProMotion up to 120 Hz) and samples whatever the engine last
/// wrote, so there is no extra frame of queueing latency.
final class GameRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    var frame: SharedFrameBuffer?
    /// Zero-copy frames from the engine's IOSurfaces (self-built engine); replaces the
    /// MMAP stream + `ingest()` copies when set. Polled once per display refresh.
    var surfaces: IOSurfaceFrames?
    /// Called (on the drawing thread) for each new IOSurface frame.
    var onSurfaceFrame: (() -> Void)?
    /// Guest content rect inside the drawable, in points (for input mapping).
    private(set) var contentRect: CGRect = .zero
    /// Called once per display refresh before drawing (keymap timers).
    var onTick: ((CFTimeInterval) -> Void)?
    /// The proto says rows are bottom-up, but with MMAP transport the engine
    /// (36.6) writes top-down rows (verified by pixel probe). Keep it switchable.
    var flipY = false
    /// Guest frames copied out of the shared buffer and ready to show (see `ingest()`).
    var frameSerial: UInt64 { lock.withLock { ready?.serial ?? 0 } }
    private var capturedSerial: UInt64 = 0
    /// Active screen recording, fed one encoded frame per new guest frame.
    var recorder: ScreenRecorder?

    /// Present path. `true` (default): the screen samples the private, tiled copies made
    /// by `ingest()`; nothing is redrawn until a new frame arrives or the view resizes.
    /// `false`: the old path, sampling the shared linear buffer on every refresh.
    var tiledPresent = true
    private var lastDrawn: (serial: UInt64, size: CGSize)?

    /// Copies of guest frames, filled by `ingest()` from the frame-stream thread.
    private let lock = NSLock()
    private var copies: [MTLTexture] = []
    private var nextCopy = 0
    private var ingested: UInt64 = 0
    private var ready: (tex: MTLTexture, serial: UInt64)?
    /// Pacing numbers for the perf log (written by GameSession once a second).
    let perf = FramePerf()
    /// Last view size (points), drawable size (pixels) and full-screen state, for the perf log.
    private(set) var lastSizes: (view: CGSize, drawable: CGSize, fullScreen: Bool) = (.zero, .zero, false)
    /// Diagnostics (`--renderload`): ms from a frame notification to its copy finishing.
    var measureIngest = false
    private(set) var ingestMs: [Double] = []

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct VOut { float4 pos [[position]]; float2 uv; };
    vertex VOut v_main(uint vid [[vertex_id]], constant float4 &rect [[buffer(0)]], constant float &flip [[buffer(1)]]) {
        float2 c[4] = { float2(0,0), float2(1,0), float2(0,1), float2(1,1) };
        float2 t = c[vid];
        VOut o;
        o.pos = float4(rect.x + t.x * rect.z, rect.y + t.y * rect.w, 0, 1);
        o.uv = float2(t.x, flip > 0.5 ? t.y : 1.0 - t.y);
        return o;
    }
    fragment float4 f_main(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]]) {
        return float4(tex.sample(s, in.uv).rgb, 1.0);
    }
    """

    init(device: MTLDevice, pixelFormat: MTLPixelFormat) throws {
        self.device = device
        queue = device.makeCommandQueue()!
        let lib = try device.makeLibrary(source: Self.shader, options: nil)
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = lib.makeFunction(name: "v_main")
        pd.fragmentFunction = lib.makeFunction(name: "f_main")
        pd.colorAttachments[0].pixelFormat = pixelFormat
        pipeline = try device.makeRenderPipelineState(descriptor: pd)
        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sampler = device.makeSamplerState(descriptor: sd)!
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    /// `--renderload`: one display refresh drawn into `target` instead of a window
    /// (same skip / upload logic as `draw(in:)`). Returns whether it drew.
    @discardableResult
    func presentOffscreen(into target: MTLTexture) -> Bool {
        onTick?(CACurrentMediaTime())
        pollSurfaces()
        let size = CGSize(width: target.width, height: target.height)
        guard let frame, !upToDate(size), let cmd = queue.makeCommandBuffer() else { return false }
        let (src, serial) = source(frame)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let enc = cmd.makeRenderCommandEncoder(descriptor: pass)!
        let s = min(size.width / CGFloat(frame.width), size.height / CGFloat(frame.height))
        let w = CGFloat(frame.width) * s, h = CGFloat(frame.height) * s
        var rect = SIMD4<Float>(Float(-w / size.width), Float(-h / size.height), Float(2 * w / size.width), Float(2 * h / size.height))
        var flip: Float = flipY ? 1 : 0
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        enc.setVertexBytes(&flip, length: MemoryLayout<Float>.size, index: 1)
        enc.setFragmentTexture(src, index: 0)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        lastDrawn = (serial, size)
        cmd.commit()
        return true
    }

    /// `--renderbench`: average GPU ms to draw one frame into a `size` target,
    /// sampling either the shared linear texture or a private (tiled) copy.
    func benchmark(size: CGSize, tiledCopy: Bool, frames: Int) -> Double {
        guard let frame else { return -1 }
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Int(size.width), height: Int(size.height), mipmapped: false)
        td.usage = .renderTarget
        td.storageMode = .private
        let target = device.makeTexture(descriptor: td)!
        var source = frame.texture
        if tiledCopy {
            let sd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: frame.width, height: frame.height, mipmapped: false)
            sd.usage = .shaderRead
            sd.storageMode = .private
            source = device.makeTexture(descriptor: sd)!
        }
        var total = 0.0
        for _ in 0..<frames {
            let cmd = queue.makeCommandBuffer()!
            if tiledCopy {
                // Every frame pays the upload, like a new guest frame each refresh (worst case).
                let blit = cmd.makeBlitCommandEncoder()!
                blit.copy(from: frame.buffer, sourceOffset: 0, sourceBytesPerRow: frame.bytesPerRow, sourceBytesPerImage: frame.bytesPerRow * frame.height,
                          sourceSize: MTLSize(width: frame.width, height: frame.height, depth: 1), to: source, destinationSlice: 0, destinationLevel: 0,
                          destinationOrigin: MTLOrigin())
                blit.endEncoding()
            }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            let enc = cmd.makeRenderCommandEncoder(descriptor: pass)!
            var rect = SIMD4<Float>(-1, -1, 2, 2)
            var flip: Float = 0
            enc.setRenderPipelineState(pipeline)
            enc.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
            enc.setVertexBytes(&flip, length: MemoryLayout<Float>.size, index: 1)
            enc.setFragmentTexture(source, index: 0)
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            enc.endEncoding()
            cmd.commit()
            cmd.waitUntilCompleted()
            total += (cmd.gpuEndTime - cmd.gpuStartTime) * 1000
        }
        return total / Double(frames)
    }

    /// The engine just finished writing a frame into the shared buffer: copy it out on the
    /// GPU right away, before the engine starts writing the next one (10 ms later at worst,
    /// measured with `--framecheck`). Copying at the next screen refresh instead (up to
    /// 8-17 ms later) overlapped that write, so some frames were half new and half old and
    /// the picture jerked back and forth, most visibly in full screen. Three textures
    /// rotate so a copy never lands in one the screen may still be sampling.
    /// Called from the frame-stream thread.
    func ingest() {
        guard let frame, let cmd = queue.makeCommandBuffer(), let blit = cmd.makeBlitCommandEncoder() else { return }
        let t0 = CACurrentMediaTime()
        perf.arrival(t0)
        let (dst, serial): (MTLTexture, UInt64) = lock.withLock {
            if copies.first.map({ $0.width != frame.width || $0.height != frame.height }) ?? true {
                let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: frame.width, height: frame.height, mipmapped: false)
                d.usage = .shaderRead
                d.storageMode = .private
                copies = (0..<3).compactMap { _ in device.makeTexture(descriptor: d) }
                ready = nil
            }
            let t = copies[nextCopy]
            nextCopy = (nextCopy + 1) % copies.count
            ingested &+= 1
            return (t, ingested)
        }
        blit.copy(from: frame.buffer, sourceOffset: 0, sourceBytesPerRow: frame.bytesPerRow,
                  sourceBytesPerImage: frame.bytesPerRow * frame.height,
                  sourceSize: MTLSize(width: frame.width, height: frame.height, depth: 1),
                  to: dst, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
        blit.endEncoding()
        cmd.addCompletedHandler { [weak self] _ in
            guard let self else { return }
            self.perf.copied(ms: (CACurrentMediaTime() - t0) * 1000)
            self.lock.withLock {
                if serial > (self.ready?.serial ?? 0) { self.ready = (dst, serial) }
                if self.measureIngest { self.ingestMs.append((CACurrentMediaTime() - t0) * 1000) }
            }
        }
        cmd.commit()
    }

    /// IOSurface mode: pick up the newest engine frame (no copy, the screen samples it).
    private func pollSurfaces() {
        guard let surfaces, let (tex, _) = surfaces.poll() else { return }
        perf.arrival(CACurrentMediaTime())
        lock.withLock {
            ingested &+= 1
            ready = (tex, ingested)
        }
        onSurfaceFrame?()
    }

    /// The texture to sample and its frame serial: the newest finished copy, or the
    /// shared linear view (old path, or before the first copy lands).
    private func source(_ frame: SharedFrameBuffer) -> (MTLTexture, UInt64) {
        let r = lock.withLock { ready }
        guard tiledPresent, let r else { return (frame.texture, r?.serial ?? 0) }
        return (r.tex, r.serial)
    }

    /// Nothing changed since the last present: skip the redraw (the layer keeps showing it).
    private func upToDate(_ size: CGSize) -> Bool {
        // Diagnostics switch (`defaults write dev.kolibri.app presentEveryRefresh -bool YES`,
        // read live): present on every display refresh instead of only on new frames.
        if UserDefaults.standard.bool(forKey: "presentEveryRefresh") { return false }
        guard tiledPresent, recorder == nil || capturedSerial == frameSerial, let l = lastDrawn else { return false }
        return l.serial == frameSerial && l.size == size
    }

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        perf.callback(now)
        pollSurfaces()
        lastSizes = (view.bounds.size, view.drawableSize, view.window?.styleMask.contains(.fullScreen) ?? false)
        onTick?(now)
        if let frame {
            let vw = view.bounds.width, vh = view.bounds.height
            let scale = min(vw / CGFloat(frame.width), vh / CGFloat(frame.height))
            let w = CGFloat(frame.width) * scale, h = CGFloat(frame.height) * scale
            contentRect = CGRect(x: (vw - w) / 2, y: (vh - h) / 2, width: w, height: h)
        }
        if upToDate(view.drawableSize) { return }
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cmd = queue.makeCommandBuffer() else { return }
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        let current = frame.map { source($0) }
        let src = current?.0
        let enc = cmd.makeRenderCommandEncoder(descriptor: pass)!
        if let frame, let src {
            let vw = view.bounds.width, vh = view.bounds.height
            let w = contentRect.width, h = contentRect.height
            // NDC rect: x,y = bottom-left, z,w = size.
            var rect = SIMD4<Float>(Float(-w / vw), Float(-h / vh), Float(2 * w / vw), Float(2 * h / vh))
            var flip: Float = flipY ? 1 : 0
            enc.setRenderPipelineState(pipeline)
            enc.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
            enc.setVertexBytes(&flip, length: MemoryLayout<Float>.size, index: 1)
            enc.setFragmentTexture(src, index: 0)
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            _ = frame
        }
        enc.endEncoding()
        let serial = current?.1 ?? 0
        if let recorder, let src, serial != capturedSerial { capture(src, serial: serial, into: recorder, cmd) }
        if serial != lastDrawn?.serial {
            let perf = self.perf
            drawable.addPresentedHandler { d in perf.presented(d.presentedTime) }
        }
        lastDrawn = (serial, view.drawableSize)
        cmd.present(drawable)
        cmd.commit()
    }

    /// A frame without a drawable: runs timers (keymap, replay) and feeds the
    /// screen recorder while the window is hidden, minimized or the screen is locked.
    func pumpOffscreen() {
        onTick?(CACurrentMediaTime())
        pollSurfaces()
        guard let recorder, let frame, frameSerial != capturedSerial, let cmd = queue.makeCommandBuffer() else { return }
        let (src, serial) = source(frame)
        capture(src, serial: serial, into: recorder, cmd)
        cmd.commit()
    }

    /// Draw the guest frame 1:1 into a recorder pixel buffer on the same command buffer.
    private func capture(_ src: MTLTexture, serial: UInt64, into recorder: ScreenRecorder, _ cmd: MTLCommandBuffer) {
        guard let (pb, cvTex, tex) = recorder.nextTarget() else { return }
        capturedSerial = serial
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = tex
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        var rect = SIMD4<Float>(-1, -1, 2, 2)
        var flip: Float = flipY ? 1 : 0
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        enc.setVertexBytes(&flip, length: MemoryLayout<Float>.size, index: 1)
        enc.setFragmentTexture(src, index: 0)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        let host = CACurrentMediaTime()
        cmd.addCompletedHandler { _ in
            withExtendedLifetime(cvTex) { recorder.append(pb, host: host) }
        }
    }
}
