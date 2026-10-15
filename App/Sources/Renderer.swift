import MetalKit
import simd
import Inochi2DKit

/// Renders Inochi2D draw lists with Metal.
///
/// Masks use an 8-bit stencil per render target, composites render into a
/// pooled offscreen layer, and every blend mode is computed in the fragment
/// shader with framebuffer fetch (supported by all Apple GPUs).
final class Renderer: NSObject, MTKViewDelegate {
    private struct Params {
        var tintOpacity: SIMD4<Float>
        var screen: SIMD4<Float>
        var mode: SIMD4<Int32>
        var extra: SIMD4<Float>
    }

    private struct Target {
        var color: MTLTexture
        var stencil: MTLTexture
    }

    enum StencilMode { case off, writing, content }

    let device: MTLDevice
    let queue: MTLCommandQueue
    private let partPipeline: MTLRenderPipelineState
    private let maskPipeline: MTLRenderPipelineState
    private let stencilClearPipeline: MTLRenderPipelineState
    private let compositePipeline: MTLRenderPipelineState
    private let backgroundPipeline: MTLRenderPipelineState
    private let overlayPipeline: MTLRenderPipelineState
    private let dsOff: MTLDepthStencilState
    private let dsWrite: MTLDepthStencilState
    private let dsContent: MTLDepthStencilState
    private var linearSampler: MTLSamplerState
    private let pointSampler: MTLSamplerState

    private var mainStencil: MTLTexture?
    private var layerPool: [Target] = []
    private let inFlight = DispatchSemaphore(value: 3)
    private var ring: [(MTLBuffer?, MTLBuffer?)] = Array(repeating: (nil, nil), count: 3)
    private var overlayRing: [MTLBuffer?] = Array(repeating: nil, count: 3)
    private var ringIndex = 0
    private var lastTime = CACurrentMediaTime()

    weak var source: (any RenderSource)?

    init?(view: MTKView) {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let lib = device.makeDefaultLibrary() else { return nil }
        self.device = device
        self.queue = queue
        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .invalid
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60

        let vd = MTLVertexDescriptor()
        vd.attributes[0].format = .float2
        vd.attributes[1].format = .float2
        vd.attributes[1].offset = 8
        vd.layouts[0].stride = 16

        func pipeline(_ v: String, _ f: String, vertexDescriptor: MTLVertexDescriptor?, colorWrites: Bool) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: v)
            d.fragmentFunction = lib.makeFunction(name: f)
            d.vertexDescriptor = vertexDescriptor
            d.colorAttachments[0].pixelFormat = .bgra8Unorm
            d.colorAttachments[0].isBlendingEnabled = false // blending is programmable
            if !colorWrites { d.colorAttachments[0].writeMask = [] }
            d.stencilAttachmentPixelFormat = .stencil8
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        guard let part = pipeline("meshVertex", "partFragment", vertexDescriptor: vd, colorWrites: true),
              let mask = pipeline("meshVertex", "maskFragment", vertexDescriptor: vd, colorWrites: false),
              let clear = pipeline("fullscreenVertex", "stencilClearFragment", vertexDescriptor: nil, colorWrites: false),
              let comp = pipeline("fullscreenVertex", "compositeFragment", vertexDescriptor: nil, colorWrites: true),
              let bg = pipeline("fullscreenVertex", "backgroundFragment", vertexDescriptor: nil, colorWrites: true),
              let overlay = pipeline("overlayVertex", "overlayFragment", vertexDescriptor: nil, colorWrites: true)
        else { return nil }
        overlayPipeline = overlay
        partPipeline = part
        maskPipeline = mask
        stencilClearPipeline = clear
        compositePipeline = comp
        backgroundPipeline = bg

        func ds(_ compare: MTLCompareFunction, _ pass: MTLStencilOperation) -> MTLDepthStencilState {
            let s = MTLStencilDescriptor()
            s.stencilCompareFunction = compare
            s.depthStencilPassOperation = pass
            let d = MTLDepthStencilDescriptor()
            d.frontFaceStencil = s
            d.backFaceStencil = s
            return device.makeDepthStencilState(descriptor: d)!
        }
        dsOff = ds(.always, .keep)
        dsWrite = ds(.always, .replace)
        dsContent = ds(.equal, .keep)

        func sampler(_ filter: MTLSamplerMinMagFilter, mip: MTLSamplerMipFilter) -> MTLSamplerState {
            let s = MTLSamplerDescriptor()
            s.minFilter = filter
            s.magFilter = filter
            s.mipFilter = mip
            s.sAddressMode = .clampToZero
            s.tAddressMode = .clampToZero
            s.maxAnisotropy = 4
            return device.makeSamplerState(descriptor: s)!
        }
        linearSampler = sampler(.linear, mip: .linear)
        pointSampler = sampler(.nearest, mip: .notMipmapped)
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        mainStencil = nil
        layerPool = []
    }

    private func stencilTexture(_ w: Int, _ h: Int) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .stencil8, width: w, height: h, mipmapped: false)
        d.usage = .renderTarget
        // Memoryless would be ideal, but composites split the pass, so keep it.
        d.storageMode = .private
        return device.makeTexture(descriptor: d)
    }

    private func layer(_ depth: Int, _ w: Int, _ h: Int) -> Target? {
        while layerPool.count <= depth {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            guard let c = device.makeTexture(descriptor: d), let s = stencilTexture(w, h) else { return nil }
            layerPool.append(Target(color: c, stencil: s))
        }
        return layerPool[depth]
    }

    private func buffer(_ existing: MTLBuffer?, _ bytes: Int) -> MTLBuffer? {
        if let e = existing, e.length >= bytes { return e }
        return device.makeBuffer(length: max(bytes * 3 / 2, 256 << 10), options: .storageModeShared)
    }

    func draw(in view: MTKView) {
        guard let source, let drawable = view.currentDrawable else { return }
        let now = CACurrentMediaTime()
        let dt = min(now - lastTime, 0.1)
        lastTime = now

        let w = Int(view.drawableSize.width), h = Int(view.drawableSize.height)
        guard w > 0, h > 0 else { return }
        if mainStencil?.width != w || mainStencil?.height != h { mainStencil = stencilTexture(w, h); layerPool = [] }
        guard let mainStencil else { return }

        let frame = source.renderFrame(deltaTime: dt, viewSize: CGSize(width: w, height: h))

        inFlight.wait()
        ringIndex = (ringIndex + 1) % ring.count
        var (vbuf, ibuf) = ring[ringIndex]
        if let list = frame?.list {
            vbuf = buffer(vbuf, max(list.vertices.count, 4) * 4)
            ibuf = buffer(ibuf, max(list.indices.count, 1) * 4)
            list.vertices.withUnsafeBytes { if let b = vbuf, $0.count > 0 { b.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) } }
            list.indices.withUnsafeBytes { if let b = ibuf, $0.count > 0 { b.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) } }
            ring[ringIndex] = (vbuf, ibuf)
        }

        guard let cmd = queue.makeCommandBuffer() else { inFlight.signal(); return }
        let sem = inFlight
        cmd.addCompletedHandler { _ in sem.signal() }

        func pass(_ color: MTLTexture, _ stencil: MTLTexture, clear: Bool, clearColor: MTLClearColor) -> MTLRenderCommandEncoder? {
            let rp = MTLRenderPassDescriptor()
            rp.colorAttachments[0].texture = color
            rp.colorAttachments[0].loadAction = clear ? .clear : .load
            rp.colorAttachments[0].clearColor = clearColor
            rp.colorAttachments[0].storeAction = .store
            rp.stencilAttachment.texture = stencil
            rp.stencilAttachment.loadAction = clear ? .clear : .load
            rp.stencilAttachment.clearStencil = 0
            rp.stencilAttachment.storeAction = .store
            return cmd.makeRenderCommandEncoder(descriptor: rp)
        }

        // Like Inochi2D, draw the puppet onto a transparent canvas: blend
        // modes such as ClipToLower and DestinationIn depend on it. The
        // background goes underneath afterwards.
        guard var enc = pass(drawable.texture, mainStencil, clear: true,
                             clearColor: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)) else { cmd.commit(); return }

        if let frame, let vb = vbuf, let ib = ibuf {
            var mvp = frame.viewProjection
            let sampler = frame.preservePixels ? pointSampler : linearSampler
            var stencilMode = StencilMode.off
            var stack: [(target: Target?, mode: StencilMode)] = [] // nil target = drawable
            var current: Target? = nil
            var lastLayer: MTLTexture?

            func bindCommon(_ e: MTLRenderCommandEncoder) {
                e.setVertexBuffer(vb, offset: 0, index: 0)
                e.setVertexBytes(&mvp, length: MemoryLayout<simd_float4x4>.stride, index: 1)
                e.setFragmentSamplerState(sampler, index: 0)
            }
            bindCommon(enc)

            func drawMesh(_ m: MeshRange) {
                guard m.indexCount > 0 else { return }
                enc.drawIndexedPrimitives(type: .triangle, indexCount: m.indexCount, indexType: .uint32,
                                          indexBuffer: ib, indexBufferOffset: m.indexStart * 4,
                                          instanceCount: 1, baseVertex: m.baseVertex, baseInstance: 0)
            }

            for c in frame.list.commands {
                switch c {
                case let .beginMask(value):
                    enc.setRenderPipelineState(stencilClearPipeline)
                    enc.setDepthStencilState(dsWrite)
                    enc.setStencilReferenceValue(UInt32(value))
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                    stencilMode = .writing

                case let .maskSource(m):
                    guard let tex = frame.texture(m.texture) else { continue }
                    var p = Params(tintOpacity: .one, screen: .zero, mode: .zero, extra: SIMD4(m.threshold, 0, 0, 0))
                    enc.setRenderPipelineState(maskPipeline)
                    enc.setDepthStencilState(dsWrite)
                    enc.setStencilReferenceValue(m.dodge ? 0 : 1)
                    enc.setFragmentTexture(tex, index: 0)
                    enc.setFragmentBytes(&p, length: MemoryLayout<Params>.stride, index: 0)
                    drawMesh(m.mesh)

                case .beginMaskContent:
                    stencilMode = .content

                case .endMask:
                    stencilMode = .off

                case let .part(d):
                    guard let tex = frame.texture(d.albedo) else { continue }
                    var p = Params(tintOpacity: SIMD4(d.tint.x, d.tint.y, d.tint.z, d.opacity),
                                   screen: SIMD4(d.screenTint.x, d.screenTint.y, d.screenTint.z, 0),
                                   mode: SIMD4(Int32(d.blendMode.rawValue), 0, 0, 0), extra: .zero)
                    enc.setRenderPipelineState(partPipeline)
                    enc.setDepthStencilState(stencilMode == .content ? dsContent : dsOff)
                    enc.setStencilReferenceValue(1)
                    enc.setFragmentTexture(tex, index: 0)
                    enc.setFragmentBytes(&p, length: MemoryLayout<Params>.stride, index: 0)
                    drawMesh(d.mesh)

                case .beginComposite:
                    guard let t = layer(stack.count, w, h) else { continue }
                    enc.endEncoding()
                    stack.append((current, stencilMode))
                    current = t
                    stencilMode = .off
                    guard let e = pass(t.color, t.stencil, clear: true, clearColor: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)) else { cmd.commit(); return }
                    enc = e
                    bindCommon(enc)

                case .endComposite:
                    guard let top = stack.popLast() else { continue }
                    enc.endEncoding()
                    lastLayer = current?.color
                    current = top.target
                    stencilMode = top.mode
                    let color = current?.color ?? drawable.texture
                    let stencil = current?.stencil ?? mainStencil
                    guard let e = pass(color, stencil, clear: false, clearColor: MTLClearColor()) else { cmd.commit(); return }
                    enc = e
                    bindCommon(enc)

                case let .compositeBlit(d):
                    guard let layer = lastLayer else { continue }
                    var p = Params(tintOpacity: SIMD4(d.tint.x, d.tint.y, d.tint.z, d.opacity),
                                   screen: SIMD4(d.screenTint.x, d.screenTint.y, d.screenTint.z, 0),
                                   mode: SIMD4(Int32(d.blendMode.rawValue), 1, 0, 0), extra: .zero)
                    enc.setRenderPipelineState(compositePipeline)
                    enc.setDepthStencilState(stencilMode == .content ? dsContent : dsOff)
                    enc.setStencilReferenceValue(1)
                    enc.setFragmentTexture(layer, index: 0)
                    enc.setFragmentBytes(&p, length: MemoryLayout<Params>.stride, index: 0)
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                }
            }
        }
        let bg = source.background
        let custom = source.backgroundColor
        enc.setRenderPipelineState(backgroundPipeline)
        enc.setDepthStencilState(dsOff)
        var colors: [SIMD4<Float>] = bg.isChecker
            ? [SIMD4(0.80, 0.80, 0.82, 1), SIMD4(0.92, 0.92, 0.94, 1), SIMD4(Float(24 * view.contentScaleFactor), 0, 0, 0)]
            : [custom ?? bg.color, custom ?? bg.color, SIMD4(64, 0, 0, 0)]
        enc.setFragmentBytes(&colors, length: MemoryLayout<SIMD4<Float>>.stride * 3, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        // Editor overlays (wireframes, handles), already in clip space.
        if let overlay = frame?.overlay, !overlay.isEmpty {
            let bytes = overlay.count * MemoryLayout<OverlayVertex>.stride
            let ob = buffer(overlayRing[ringIndex], bytes)
            overlayRing[ringIndex] = ob
            if let ob {
                overlay.withUnsafeBytes { ob.contents().copyMemory(from: $0.baseAddress!, byteCount: bytes) }
                enc.setRenderPipelineState(overlayPipeline)
                enc.setVertexBuffer(ob, offset: 0, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: overlay.count)
            }
        }
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }
}

extension BackgroundStyle {
    var color: SIMD4<Float> {
        switch self {
        case .checker: return SIMD4(0.8, 0.8, 0.82, 1)
        case .dark: return SIMD4(0.11, 0.11, 0.13, 1)
        case .light: return SIMD4(0.97, 0.97, 0.97, 1)
        case .greenScreen: return SIMD4(0, 1, 0, 1)
        case .blueScreen: return SIMD4(0, 0, 1, 1)
        case .custom: return SIMD4(0.2, 0.2, 0.22, 1)
        }
    }

    var isChecker: Bool { self == .checker }
}
