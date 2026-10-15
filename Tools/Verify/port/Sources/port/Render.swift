// CPU reference renderer for the port. It interprets the draw list with the
// same semantics and blend formulas as App/Sources/Shaders.metal, so its output
// can be compared pixel by pixel with Inochi2D's own OpenGL renderer.
import Foundation
import Inochi2DKit

func renderToRGBA(model: String, out: String, width W: Int, height H: Int, centre: Vec2, scale: Float) throws {
    let puppet = try Puppet(contentsOf: URL(fileURLWithPath: model))
    puppet.enableDrivers = false
    puppet.update(deltaTime: 1.0 / 60)
    let list = puppet.draw()

    struct Tex { var w: Int; var h: Int; var px: [SIMD4<Float>]; var mips: [Tex] = [] }
    /// Box-filtered mip chain, like glGenerateMipmap / MTLBlitCommandEncoder.generateMipmaps.
    func withMips(_ t: Tex) -> Tex {
        var levels: [Tex] = []
        var cur = t
        while cur.w > 1 || cur.h > 1 {
            let nw = max(1, cur.w / 2), nh = max(1, cur.h / 2)
            var px = [SIMD4<Float>](repeating: .zero, count: nw * nh)
            for y in 0..<nh {
                for x in 0..<nw {
                    let x0 = min(x * 2, cur.w - 1), x1 = min(x * 2 + 1, cur.w - 1)
                    let y0 = min(y * 2, cur.h - 1), y1 = min(y * 2 + 1, cur.h - 1)
                    px[y * nw + x] = (cur.px[y0 * cur.w + x0] + cur.px[y0 * cur.w + x1] + cur.px[y1 * cur.w + x0] + cur.px[y1 * cur.w + x1]) / 4
                }
            }
            cur = Tex(w: nw, h: nh, px: px)
            levels.append(cur)
        }
        var r = t
        r.mips = levels
        return r
    }
    // Texture bytes are used exactly as stored (they are already premultiplied).
    let textures: [Tex?] = puppet.textures.map { blob in
        guard let img = try? TGADecoder.decode(blob.data) else { return nil }
        let p = img.rgba
        return withMips(Tex(w: img.width, h: img.height, px: stride(from: 0, to: p.count, by: 4).map {
            SIMD4(Float(p[$0]), Float(p[$0 + 1]), Float(p[$0 + 2]), Float(p[$0 + 3])) / 255
        }))
    }
    func screen(_ i: Int) -> (Float, Float, Float, Float) {
        let v = i * 4
        return ((list.vertices[v] - centre.x) * scale + Float(W) / 2, (list.vertices[v + 1] - centre.y) * scale + Float(H) / 2,
                list.vertices[v + 2], list.vertices[v + 3])
    }
    /// Trilinear sampling at a level of detail.
    func sample(_ t: Tex, _ u: Float, _ v: Float, lod: Float) -> SIMD4<Float> {
        guard lod > 0, !t.mips.isEmpty else { return sample(t, u, v) }
        let l = min(lod, Float(t.mips.count))
        let i = Int(l), f = l - Float(i)
        let a = i == 0 ? sample(t, u, v) : sample(t.mips[i - 1], u, v)
        if f == 0 || i >= t.mips.count { return a }
        return a * (1 - f) + sample(t.mips[i], u, v) * f
    }
    func sample(_ t: Tex, _ u: Float, _ v: Float) -> SIMD4<Float> {
        let x = u * Float(t.w) - 0.5, y = v * Float(t.h) - 0.5
        let x0 = Int(floor(x)), y0 = Int(floor(y))
        let fx = x - Float(x0), fy = y - Float(y0)
        func at(_ a: Int, _ b: Int) -> SIMD4<Float> { a < 0 || b < 0 || a >= t.w || b >= t.h ? .zero : t.px[b * t.w + a] }
        return (at(x0, y0) * (1 - fx) + at(x0 + 1, y0) * fx) * (1 - fy) + (at(x0, y0 + 1) * (1 - fx) + at(x0 + 1, y0 + 1) * fx) * fy
    }
    func f(_ m: Int, _ cs: Float, _ cd: Float) -> Float {
        switch m {
        case 1: return cs * cd
        case 2: return cs + cd - cs * cd
        case 3: return cd <= 0.5 ? 2 * cs * cd : 1 - 2 * (1 - cs) * (1 - cd)
        case 4: return min(cs, cd)
        case 5: return max(cs, cd)
        case 6: return cd <= 0 ? 0 : (cs >= 1 ? 1 : min(1, cd / max(1 - cs, 1e-6)))
        case 9: return cd >= 1 ? 1 : (cs <= 0 ? 0 : 1 - min(1, (1 - cd) / max(cs, 1e-6)))
        case 10: return cs <= 0.5 ? 2 * cs * cd : 1 - 2 * (1 - cs) * (1 - cd)
        case 11:
            let d = cd <= 0.25 ? ((16 * cd - 12) * cd + 4) * cd : cd.squareRoot()
            return cs <= 0.5 ? cd - (1 - 2 * cs) * cd * (1 - cd) : cd + (2 * cs - 1) * (d - cd)
        case 12: return abs(cs - cd)
        case 13: return cs + cd - 2 * cs * cd
        default: return cs
        }
    }
    func blend(_ s: SIMD4<Float>, _ d: SIMD4<Float>, _ bm: BlendMode, legacy: Bool) -> SIMD4<Float> {
        let m = bm.rawValue
        let s3 = SIMD3(s.x, s.y, s.z), d3 = SIMD3(d.x, d.y, d.z), one = SIMD3<Float>(1, 1, 1)
        if !legacy && ((m >= 1 && m <= 6) || (m >= 9 && m <= 13)) {
            let cs = s.w > 0 ? s3 / s.w : .zero, cd = d.w > 0 ? d3 / d.w : .zero
            let fr = SIMD3(f(m, cs.x, cd.x), f(m, cs.y, cd.y), f(m, cs.z, cd.z))
            return SIMD4(fr * s.w * d.w + s3 * (1 - d.w) + d3 * (1 - s.w), s.w + d.w * (1 - s.w))
        }
        var r: SIMD4<Float>
        switch m {
        case 1: r = s * d + d * (1 - s.w)
        case 2: r = s + d * (SIMD4(1, 1, 1, 1) - s)
        case 5: r = SIMD4(max(s.x, d.x), max(s.y, d.y), max(s.z, d.z), max(s.w, d.w))
        case 6: r = s * d + d
        case 7: r = SIMD4(s3 + d3 * (one - s3), s.w + d.w * (1 - s.w))
        case 8: r = SIMD4(s3 + d3, s.w + d.w * (1 - s.w))
        case 13: r = SIMD4(s3 * (one - d3) + d3 * (one - s3), s.w + d.w)
        case 14: let v = d3 - s3 * (one - d3); r = SIMD4(max(v.x, 0), max(v.y, 0), max(v.z, 0), s.w * (1 - d.w) + d.w)
        case 15: r = SIMD4(s3 * (one - d3) + d3 * (1 - s.w), s.w * (1 - d.w) + d.w * (1 - s.w))
        case 16: r = d * s.w
        case 17: r = s * d.w + d * (1 - s.w)
        case 18: r = d * (1 - s.w)
        default: r = s + d * (1 - s.w)
        }
        return SIMD4(min(max(r.x, 0), 1), min(max(r.y, 0), 1), min(max(r.z, 0), 1), min(max(r.w, 0), 1))
    }
    func shade(_ c: SIMD4<Float>, _ tint: Vec3, _ screenTint: Vec3, _ opacity: Float) -> SIMD4<Float> {
        let rgb = SIMD3<Float>(1, 1, 1) - (SIMD3<Float>(1, 1, 1) - SIMD3(c.x, c.y, c.z)) * (SIMD3<Float>(1, 1, 1) - SIMD3(screenTint.x, screenTint.y, screenTint.z) * c.w)
        return SIMD4(rgb * SIMD3(tint.x, tint.y, tint.z), c.w) * opacity
    }

    struct Target { var color: [SIMD4<Float>]; var stencil: [UInt8] }
    func blank() -> Target { Target(color: Array(repeating: .zero, count: W * H), stencil: Array(repeating: 0, count: W * H)) }
    var cur = blank()
    var stack: [(Target, Int)] = []
    var mode = 0 // 0 off, 2 masked content
    var lastLayer: [SIMD4<Float>]?

    func raster(_ m: MeshRange, texture: Tex? = nil, _ fragment: (Int, Float, Float, Float) -> Void) {
        var t = m.indexStart
        while t + 2 < m.indexStart + m.indexCount {
            let a = screen(m.baseVertex + Int(list.indices[t])), b = screen(m.baseVertex + Int(list.indices[t + 1]))
            let c = screen(m.baseVertex + Int(list.indices[t + 2]))
            t += 3
            let area = (b.0 - a.0) * (c.1 - a.1) - (b.1 - a.1) * (c.0 - a.0)
            guard abs(area) > 1e-9 else { continue }
            let minX = max(0, Int(min(a.0, b.0, c.0))), maxX = min(W - 1, Int(max(a.0, b.0, c.0)) + 1)
            let minY = max(0, Int(min(a.1, b.1, c.1))), maxY = min(H - 1, Int(max(a.1, b.1, c.1)) + 1)
            guard minX <= maxX, minY <= maxY else { continue }
            // Texture coordinates are affine over a triangle, so GL's per-pixel
            // level of detail is constant: log2 of the larger texel step per pixel.
            var lod: Float = 0
            if let tex = texture {
                let tw = Float(tex.w), th = Float(tex.h)
                let dudx = ((b.2 - a.2) * (c.1 - a.1) - (c.2 - a.2) * (b.1 - a.1)) / area * tw
                let dvdx = ((b.3 - a.3) * (c.1 - a.1) - (c.3 - a.3) * (b.1 - a.1)) / area * th
                let dudy = ((c.2 - a.2) * (b.0 - a.0) - (b.2 - a.2) * (c.0 - a.0)) / area * tw
                let dvdy = ((c.3 - a.3) * (b.0 - a.0) - (b.3 - a.3) * (c.0 - a.0)) / area * th
                let rho = max((dudx * dudx + dvdx * dvdx).squareRoot(), (dudy * dudy + dvdy * dvdy).squareRoot())
                lod = max(0, log2(max(rho, 1e-6)))
            }
            for y in minY...maxY {
                for x in minX...maxX {
                    let px = Float(x) + 0.5, py = Float(y) + 0.5
                    let w0 = ((b.0 - px) * (c.1 - py) - (b.1 - py) * (c.0 - px)) / area
                    let w1 = ((c.0 - px) * (a.1 - py) - (c.1 - py) * (a.0 - px)) / area
                    let w2 = 1 - w0 - w1
                    if w0 < 0 || w1 < 0 || w2 < 0 { continue }
                    fragment(y * W + x, w0 * a.2 + w1 * b.2 + w2 * c.2, w0 * a.3 + w1 * b.3 + w2 * c.3, lod)
                }
            }
        }
    }

    for c in list.commands {
        switch c {
        case let .beginMask(v):
            cur.stencil = Array(repeating: v, count: W * H)
        case let .maskSource(m):
            guard let tex = textures[m.texture] else { continue }
            raster(m.mesh, texture: tex) { i, u, v, lod in if sample(tex, u, v, lod: lod).w > m.threshold { cur.stencil[i] = m.dodge ? 0 : 1 } }
        case .beginMaskContent: mode = 2
        case .endMask: mode = 0
        case let .part(d):
            guard let tex = textures[d.albedo] else { continue }
            raster(d.mesh, texture: tex) { i, u, v, lod in
                if mode == 2 && cur.stencil[i] != 1 { return }
                cur.color[i] = blend(shade(sample(tex, u, v, lod: lod), d.tint, d.screenTint, d.opacity), cur.color[i], d.blendMode, legacy: false)
            }
        case .beginComposite:
            stack.append((cur, mode))
            cur = blank()
            mode = 0
        case .endComposite:
            lastLayer = cur.color
            let top = stack.removeLast()
            cur = top.0
            mode = top.1
        case let .compositeBlit(d):
            guard let layer = lastLayer else { continue }
            for i in 0..<(W * H) where layer[i].w > 0 && !(mode == 2 && cur.stencil[i] != 1) {
                cur.color[i] = blend(shade(layer[i], d.tint, d.screenTint, d.opacity), cur.color[i], d.blendMode, legacy: true)
            }
        }
    }
    var bytes = [UInt8](repeating: 0, count: W * H * 4)
    for i in 0..<(W * H) {
        for k in 0..<4 { bytes[i * 4 + k] = UInt8(max(0, min(255, (cur.color[i][k] * 255).rounded()))) }
    }
    try Data(bytes).write(to: URL(fileURLWithPath: out))
}
