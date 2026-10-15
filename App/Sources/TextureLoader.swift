import Metal
import ImageIO
import CoreGraphics
import Accelerate
import os
import Inochi2DKit

/// Memory policy for iPads with 4 GB of RAM (e.g. iPad 10th gen, A14).
/// iPadOS terminates a foreground app at roughly half of physical memory, and
/// face tracking needs headroom, so textures get about a sixth of RAM.
enum MemoryBudget {
    static var textureBytes: Int {
        let physical = ProcessInfo.processInfo.physicalMemory
        return Int(min(max(physical / 6, 256 << 20), 1536 << 20))
    }

    /// Largest texture edge. The A14 supports 16384, but 8192 keeps any single
    /// texture to 256 MB.
    static let maxTextureSize = 8192

    static var availableBytes: Int { Int(os_proc_available_memory()) }
}

/// A small CPU copy of a texture, for hit testing and mesh generation.
struct TexturePreview {
    var width: Int
    var height: Int
    var rgba: [UInt8]

    /// Alpha (0...255) at a texture coordinate.
    func alpha(atUV uv: Vec2) -> UInt8 {
        let x = Int(uv.x * Float(width)), y = Int(uv.y * Float(height))
        guard x >= 0, y >= 0, x < width, y < height else { return 0 }
        return rgba[(y * width + x) * 4 + 3]
    }

    static let maxSize = 1024
}

/// Decodes a puppet's texture blobs into premultiplied, mipmapped GPU textures.
struct TextureLoader {
    struct Result {
        var textures: [MTLTexture?]
        var scale: Float
        var gpuBytes: Int
        var previews: [TexturePreview?] = []
    }

    let device: MTLDevice
    let queue: MTLCommandQueue

    func load(_ blobs: [TextureBlob], previews: Bool = false) throws -> Result {
        // Sizes first, so we can decide on a uniform downscale before decoding.
        let sizes = blobs.map(Self.imageSize)
        let total = sizes.reduce(0.0) { $0 + Double(($1?.0 ?? 0) * ($1?.1 ?? 0)) * 4 * 4 / 3 }
        let scale = Float(min(1, (Double(MemoryBudget.textureBytes) / max(total, 1)).squareRoot()))

        var out: [MTLTexture?] = []
        var previewList: [TexturePreview?] = []
        var bytes = 0
        for (i, blob) in blobs.enumerated() {
            let tex: MTLTexture? = try autoreleasepool {
                guard var (pixels, w, h) = Self.decode(blob) else {
                    if previews { previewList.append(nil) }
                    return nil
                }
                if previews { previewList.append(Self.preview(pixels, w, h)) }
                let s = min(scale, Float(MemoryBudget.maxTextureSize) / Float(max(w, h)))
                if s < 0.999 {
                    let nw = max(1, Int(Float(w) * s)), nh = max(1, Int(Float(h) * s))
                    pixels = Self.resize(pixels, w, h, nw, nh)
                    w = nw
                    h = nh
                }
                return try makeTexture(pixels, w, h, label: "slot \(i)")
            }
            if let tex { bytes += tex.allocatedSize }
            out.append(tex)
        }
        return Result(textures: out, scale: scale, gpuBytes: bytes, previews: previewList)
    }

    /// Uploads one texture at full size (for textures added while editing).
    func loadOne(_ blob: TextureBlob) throws -> (MTLTexture?, TexturePreview?) {
        try autoreleasepool {
            guard var (pixels, w, h) = Self.decode(blob) else { return (nil, nil) }
            let preview = Self.preview(pixels, w, h)
            let s = Float(MemoryBudget.maxTextureSize) / Float(max(w, h))
            if s < 1 {
                let nw = max(1, Int(Float(w) * s)), nh = max(1, Int(Float(h) * s))
                pixels = Self.resize(pixels, w, h, nw, nh)
                w = nw
                h = nh
            }
            return (try makeTexture(pixels, w, h, label: "added"), preview)
        }
    }

    static func preview(_ px: [UInt8], _ w: Int, _ h: Int) -> TexturePreview {
        let s = min(1, Float(TexturePreview.maxSize) / Float(max(w, h)))
        if s >= 1 { return TexturePreview(width: w, height: h, rgba: px) }
        let nw = max(1, Int(Float(w) * s)), nh = max(1, Int(Float(h) * s))
        return TexturePreview(width: nw, height: nh, rgba: resize(px, w, h, nw, nh))
    }

    private func makeTexture(_ pixels: [UInt8], _ w: Int, _ h: Int, label: String) throws -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: true)
        desc.usage = .shaderRead
        desc.storageMode = .private
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        tex.label = label
        // Stage through a shared buffer, then build mipmaps on the GPU.
        let rowBytes = w * 4
        guard let staging = pixels.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: rowBytes * h, options: .storageModeShared) }),
              let cmd = queue.makeCommandBuffer(), let blit = cmd.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: staging, sourceOffset: 0, sourceBytesPerRow: rowBytes, sourceBytesPerImage: rowBytes * h,
                  sourceSize: MTLSize(width: w, height: h, depth: 1), to: tex, destinationSlice: 0,
                  destinationLevel: 0, destinationOrigin: MTLOrigin())
        if tex.mipmapLevelCount > 1 { blit.generateMipmaps(for: tex) }
        blit.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        return tex
    }

    // MARK: Decoding

    static func imageSize(_ blob: TextureBlob) -> (Int, Int)? {
        let d = blob.data
        if blob.encoding == .tga, d.count >= 18 {
            return (Int(d[d.startIndex + 12]) | Int(d[d.startIndex + 13]) << 8,
                    Int(d[d.startIndex + 14]) | Int(d[d.startIndex + 15]) << 8)
        }
        guard let src = CGImageSourceCreateWithData(d as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (w, h)
    }

    /// RGBA8 exactly as stored in the file, top row first.
    ///
    /// Inochi2D uploads texture bytes unchanged and blends them as
    /// premultiplied colour (Inochi Creator exports them that way), so they
    /// must not be premultiplied again here: that darkens every soft edge.
    static func decode(_ blob: TextureBlob) -> ([UInt8], Int, Int)? {
        guard !blob.isEmpty else { return nil }
        if blob.encoding == .tga, let img = try? TGADecoder.decode(blob.data) {
            return (img.rgba, img.width, img.height)
        }
        return decodeImage(blob.data)
    }

    /// Straight-alpha RGBA8 from PNG, JPEG, HEIC and other ImageIO formats.
    static func decodeImage(_ data: Data) -> ([UInt8], Int, Int)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let w = image.width, h = image.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            // Core Graphics only renders premultiplied RGBA; undo that so the
            // bytes match what the file holds.
            var buffer = vImage_Buffer(data: buf.baseAddress, height: vImagePixelCount(h),
                                       width: vImagePixelCount(w), rowBytes: w * 4)
            vImageUnpremultiplyData_RGBA8888(&buffer, &buffer, vImage_Flags(kvImageNoFlags))
            return true
        }
        return ok ? (px, w, h) : nil
    }

    static func resize(_ px: [UInt8], _ w: Int, _ h: Int, _ nw: Int, _ nh: Int) -> [UInt8] {
        var src = px
        var out = [UInt8](repeating: 0, count: nw * nh * 4)
        src.withUnsafeMutableBytes { s in
            out.withUnsafeMutableBytes { d in
                let space = CGColorSpaceCreateDeviceRGB()
                let info = CGImageAlphaInfo.premultipliedLast.rawValue
                guard let sctx = CGContext(data: s.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                           bytesPerRow: w * 4, space: space, bitmapInfo: info),
                      let image = sctx.makeImage(),
                      let dctx = CGContext(data: d.baseAddress, width: nw, height: nh, bitsPerComponent: 8,
                                           bytesPerRow: nw * 4, space: space, bitmapInfo: info) else { return }
                dctx.interpolationQuality = .high
                dctx.draw(image, in: CGRect(x: 0, y: 0, width: nw, height: nh))
            }
        }
        return out
    }
}
