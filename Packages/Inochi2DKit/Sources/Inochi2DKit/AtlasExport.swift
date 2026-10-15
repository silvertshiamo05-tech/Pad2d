// Inochi Creator's INP export (io/inpexport.d, atlas/*): packs the parts'
// textures into atlases with a MaxRects packer, optionally prunes hidden
// nodes, flattens Creator-only data and bakes mesh groups.

import Foundation

/// MaxRects bin packing, best short side fit, no rotation.
public struct MaxRectsPacker {
    public struct Rect: Equatable {
        public var x, y, w, h: Int
        var right: Int { x + w }
        var bottom: Int { y + h }
        func intersects(_ o: Rect) -> Bool { x < o.right && o.x < right && y < o.bottom && o.y < bottom }
        func contains(_ o: Rect) -> Bool { o.x >= x && o.y >= y && o.right <= right && o.bottom <= bottom }
    }

    public private(set) var free: [Rect]
    public let width: Int, height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
        free = [Rect(x: 0, y: 0, w: width, h: height)]
    }

    /// Places a w×h rectangle; nil when it doesn't fit.
    public mutating func pack(_ w: Int, _ h: Int) -> Rect? {
        var best: Rect?
        var bestShort = Int.max, bestLong = Int.max
        for f in free where f.w >= w && f.h >= h {
            let lh = f.w - w, lv = f.h - h
            let s = Swift.min(lh, lv), l = Swift.max(lh, lv)
            if s < bestShort || (s == bestShort && l < bestLong) {
                best = Rect(x: f.x, y: f.y, w: w, h: h)
                bestShort = s
                bestLong = l
            }
        }
        guard let used = best else { return nil }
        var next: [Rect] = []
        for f in free {
            guard f.intersects(used) else { next.append(f); continue }
            if used.y > f.y && used.y < f.bottom { next.append(Rect(x: f.x, y: f.y, w: f.w, h: used.y - f.y)) }
            if used.bottom < f.bottom { next.append(Rect(x: f.x, y: used.bottom, w: f.w, h: f.bottom - used.bottom)) }
            if used.x > f.x && used.x < f.right { next.append(Rect(x: f.x, y: f.y, w: used.x - f.x, h: f.h)) }
            if used.right < f.right { next.append(Rect(x: used.right, y: f.y, w: f.right - used.right, h: f.h)) }
        }
        // Prune rectangles contained in others.
        free = next.enumerated().filter { i, r in
            !next.enumerated().contains { j, o in j != i && o.contains(r) && (o != r || j < i) }
        }.map(\.element)
        return used
    }
}

public struct INPExportSettings: Sendable {
    public var atlasResolution = 2048
    /// Scale each too-large part on its own instead of all parts uniformly.
    public var nonLinearScaling = false
    public var scale: Float = 1
    public var padding = 16
    public var pruneHidden = true
    public var watermark: (rgba: [UInt8], width: Int, height: Int)?
    public var watermarkOpacity: Float = 1
    public var watermarkBlend: BlendMode = .clipToLower
    public var watermarkLoops = 10

    public init() {}
}

public struct INPExportResult {
    public var data: Data
    /// The scale textures were reduced to so everything fit (1 = none).
    public var forcedScale: Float
    public var atlasCount: Int
    /// First atlas (premultiplied RGBA) for previews.
    public var preview: (rgba: [UInt8], width: Int, height: Int)?
}

public extension Puppet {
    /// Exports a copy of the puppet as an `.inp` with atlased textures.
    /// `decode` turns a texture blob into premultiplied RGBA8.
    func exportINP(_ s: INPExportSettings, decode: (TextureBlob) -> ([UInt8], Int, Int)?) throws -> INPExportResult {
        let copy = try Puppet(data: fileData())
        copy.prepareForExport(pruneHidden: s.pruneHidden)

        // Texture regions used by parts: per texture, the union of their UV boxes.
        struct Region { var tex: Int; var u0: Float; var v0: Float; var u1: Float; var v1: Float; var w: Int; var h: Int }
        var regions: [Int: Region] = [:]
        var decoded: [Int: ([UInt8], Int, Int)] = [:]
        for p in copy.parts {
            guard let t = p.textureIDs[0], t < copy.textures.count, !p.uvs.isEmpty else { continue }
            if decoded[t] == nil, let d = decode(copy.textures[t]) { decoded[t] = d }
            guard let (_, tw, th) = decoded[t] else { continue }
            let u0 = clamp(p.uvs.map(\.x).min()!, 0, 1), u1 = clamp(p.uvs.map(\.x).max()!, 0, 1)
            let v0 = clamp(p.uvs.map(\.y).min()!, 0, 1), v1 = clamp(p.uvs.map(\.y).max()!, 0, 1)
            if var r = regions[t] {
                r.u0 = Swift.min(r.u0, u0); r.v0 = Swift.min(r.v0, v0); r.u1 = Swift.max(r.u1, u1); r.v1 = Swift.max(r.v1, v1)
                regions[t] = r
            } else {
                regions[t] = Region(tex: t, u0: u0, v0: v0, u1: u1, v1: v1, w: tw, h: th)
            }
        }
        for p in copy.parts {
            for slot in 1..<3 {
                if let t = p.textureIDs[slot], decoded[t] == nil, t < copy.textures.count, let d = decode(copy.textures[t]) { decoded[t] = d }
            }
        }

        let res = s.atlasResolution
        let pad = s.padding
        // Regions snapped to whole texture pixels, so scale 1 copies 1:1.
        func pixels(_ r: Region) -> (x0: Int, y0: Int, x1: Int, y1: Int) {
            let x0 = Swift.max(0, Int((r.u0 * Float(r.w)).rounded(.down))), x1 = Swift.min(r.w, Int((r.u1 * Float(r.w)).rounded(.up)))
            let y0 = Swift.max(0, Int((r.v0 * Float(r.h)).rounded(.down))), y1 = Swift.min(r.h, Int((r.v1 * Float(r.h)).rounded(.up)))
            return (x0, y0, Swift.max(x1, x0 + 1), Swift.max(y1, y0 + 1))
        }
        func size(_ r: Region, _ f: Float) -> (Int, Int) {
            let b = pixels(r)
            return (Swift.max(1, Int((Float(b.x1 - b.x0) * f).rounded(.up))) + 2 * pad,
                    Swift.max(1, Int((Float(b.y1 - b.y0) * f).rounded(.up))) + 2 * pad)
        }
        // Uniform scaling: the largest region must fit.
        var uniform = s.scale
        if !s.nonLinearScaling {
            for r in regions.values {
                let (w, h) = size(r, uniform)
                if w > res { uniform *= Float(res - 2 * pad) / Float(w - 2 * pad) * 0.995 }
                if h > res { uniform *= Float(res - 2 * pad) / Float(h - 2 * pad) * 0.995 }
            }
        }
        func scaleFor(_ r: Region) -> Float {
            guard s.nonLinearScaling else { return uniform }
            var f = s.scale
            let (w, h) = size(r, f)
            if w > res { f *= Float(res - 2 * pad) / Float(w - 2 * pad) * 0.995 }
            let (_, h2) = size(r, f)
            if h2 > res || h > res { f *= Float(res - 2 * pad) / Float(h2 - 2 * pad) * 0.995 }
            return f
        }

        // Pack, largest first.
        let order = regions.values.sorted { ($0.w + $0.h, $1.tex) > ($1.w + $1.h, $0.tex) }
        var packers: [MaxRectsPacker] = [MaxRectsPacker(width: res, height: res)]
        var placed: [Int: (atlas: Int, rect: MaxRectsPacker.Rect, scale: Float)] = [:]
        for r in order {
            let f = scaleFor(r)
            let (w, h) = size(r, f)
            var done = false
            for i in packers.indices {
                if let rect = packers[i].pack(w, h) {
                    placed[r.tex] = (i, rect, f)
                    done = true
                    break
                }
            }
            if !done {
                var p = MaxRectsPacker(width: res, height: res)
                guard let rect = p.pack(w, h) else { throw INPError.badJSON("A texture is too big for the atlas.") }
                packers.append(p)
                placed[r.tex] = (packers.count - 1, rect, f)
            }
        }

        // Draw atlases: one per page and slot that's used.
        var pages: [[[UInt8]?]] = Array(repeating: [nil, nil, nil], count: packers.count)
        func blit(_ src: ([UInt8], Int, Int), _ r: Region, into page: inout [UInt8], at rect: MaxRectsPacker.Rect) {
            let (px, sw, sh) = src
            let dw = rect.w - 2 * pad, dh = rect.h - 2 * pad
            guard dw > 0, dh > 0 else { return }
            let b = pixels(r)
            // Source box in this texture's pixels (other slots may differ in size).
            let sx0 = Float(b.x0) / Float(r.w) * Float(sw), sx1 = Float(b.x1) / Float(r.w) * Float(sw)
            let sy0 = Float(b.y0) / Float(r.h) * Float(sh), sy1 = Float(b.y1) / Float(r.h) * Float(sh)
            let exact = sw == r.w && sh == r.h && dw == b.x1 - b.x0 && dh == b.y1 - b.y0
            for y in 0..<dh {
                let fy = sy0 + (Float(y) + 0.5) / Float(dh) * (sy1 - sy0) - 0.5
                for x in 0..<dw {
                    let o = ((rect.y + pad + y) * res + rect.x + pad + x) * 4
                    if exact {
                        let si = ((b.y0 + y) * sw + b.x0 + x) * 4
                        page[o] = px[si]; page[o + 1] = px[si + 1]; page[o + 2] = px[si + 2]; page[o + 3] = px[si + 3]
                        continue
                    }
                    let fx = sx0 + (Float(x) + 0.5) / Float(dw) * (sx1 - sx0) - 0.5
                    let c = sampleBilinear(px, sw, sh, fx, fy)
                    page[o] = c.0; page[o + 1] = c.1; page[o + 2] = c.2; page[o + 3] = c.3
                }
            }
        }
        // Which slot textures belong with which albedo region.
        var slotTex: [Int: [Int?]] = [:]
        for p in copy.parts { if let a = p.textureIDs[0], slotTex[a] == nil { slotTex[a] = p.textureIDs } }
        for (tex, place) in placed {
            guard let r = regions[tex] else { continue }
            let ids = slotTex[tex] ?? [tex, nil, nil]
            for slot in 0..<3 {
                guard let t = ids[slot], let d = decoded[t] else { continue }
                if pages[place.atlas][slot] == nil { pages[place.atlas][slot] = [UInt8](repeating: 0, count: res * res * 4) }
                var page = pages[place.atlas][slot]!
                // Other slots share the albedo's UV region but may differ in size.
                blit(d, r, into: &page, at: place.rect)
                pages[place.atlas][slot] = page
            }
        }
        if let wm = s.watermark {
            for i in pages.indices {
                if var page = pages[i][0] {
                    applyWatermark(&page, res, wm, loops: s.watermarkLoops, opacity: s.watermarkOpacity, blend: s.watermarkBlend)
                    pages[i][0] = page
                }
            }
        }

        // New texture list and remapped parts.
        var newTextures: [TextureBlob] = []
        var pageIndex: [[Int?]] = []
        for page in pages {
            var row: [Int?] = []
            for slot in 0..<3 {
                if let px = page[slot] {
                    row.append(newTextures.count)
                    newTextures.append(TextureBlob(encoding: .tga, data: TGAEncoder.encode(rgba: px, width: res, height: res)))
                } else {
                    row.append(nil)
                }
            }
            pageIndex.append(row)
        }
        for p in copy.parts {
            guard let a = p.textureIDs[0], let place = placed[a], let r = regions[a] else {
                p.textureIDs = [nil, nil, nil]
                continue
            }
            let rect = place.rect
            let b = pixels(r)
            let sx = Float(rect.w - 2 * pad) / Float(b.x1 - b.x0), sy = Float(rect.h - 2 * pad) / Float(b.y1 - b.y0)
            p.uvs = p.uvs.map { uv in
                Vec2((Float(rect.x + pad) + (uv.x * Float(r.w) - Float(b.x0)) * sx) / Float(res),
                     (Float(rect.y + pad) + (uv.y * Float(r.h) - Float(b.y0)) * sy) / Float(res))
            }
            p.meshEdited = true
            p.textureIDs = (0..<3).map { slot in p.textureIDs[slot] == nil ? nil : pageIndex[place.atlas][slot] }
        }
        copy.textures = newTextures
        let preview = pages.first?[0].map { ($0, res, res) }
        return INPExportResult(data: copy.fileData(), forcedScale: s.nonLinearScaling ? 1 : uniform / s.scale,
                               atlasCount: pages.count, preview: preview)
    }

    /// Creator's export clean-up: prune hidden nodes, flatten parameter
    /// groups, bake mesh groups, drop cameras and dangling animation lanes.
    func prepareForExport(pruneHidden: Bool) {
        if pruneHidden {
            func prune(_ n: Node) {
                n.children.removeAll { c in
                    if !c.enabled { c.parent = nil; return true }
                    return false
                }
                for c in n.children { prune(c) }
            }
            prune(root)
        }
        for case let c as Camera in root.allNodes() { remove(c) }
        groups = []
        for p in parameters { p.groupUUID = nil }
        rebuild()
        applyDeformToChildren()
        for a in animations.values {
            a.finalize(self)
            a.lanes.removeAll { $0.parameter == nil }
        }
        flipPairs = []
    }
}

private func sampleBilinear(_ px: [UInt8], _ w: Int, _ h: Int, _ x: Float, _ y: Float) -> (UInt8, UInt8, UInt8, UInt8) {
    let x0 = Int(x.rounded(.down)), y0 = Int(y.rounded(.down))
    let tx = x - Float(x0), ty = y - Float(y0)
    func at(_ xi: Int, _ yi: Int, _ c: Int) -> Float {
        let cx = Swift.min(Swift.max(xi, 0), w - 1), cy = Swift.min(Swift.max(yi, 0), h - 1)
        return Float(px[(cy * w + cx) * 4 + c])
    }
    func ch(_ c: Int) -> UInt8 {
        let a = at(x0, y0, c) * (1 - tx) + at(x0 + 1, y0, c) * tx
        let b = at(x0, y0 + 1, c) * (1 - tx) + at(x0 + 1, y0 + 1, c) * tx
        return UInt8(clamp((a * (1 - ty) + b * ty).rounded(), 0, 255))
    }
    return (ch(0), ch(1), ch(2), ch(3))
}

/// Tiles a premultiplied watermark `loops`×`loops` times over a page.
private func applyWatermark(_ page: inout [UInt8], _ res: Int, _ wm: (rgba: [UInt8], width: Int, height: Int),
                            loops: Int, opacity: Float, blend: BlendMode) {
    let tile = Float(res) / Float(Swift.max(loops, 1))
    for y in 0..<res {
        for x in 0..<res {
            let u = (Float(x).truncatingRemainder(dividingBy: tile)) / tile * Float(wm.width)
            let v = (Float(y).truncatingRemainder(dividingBy: tile)) / tile * Float(wm.height)
            let s = sampleBilinear(wm.rgba, wm.width, wm.height, u, v)
            let o = (y * res + x) * 4
            let sa = Float(s.3) / 255 * opacity
            var sc = [Float(s.0), Float(s.1), Float(s.2)].map { $0 / 255 * opacity }
            let da = Float(page[o + 3]) / 255
            let dc = [Float(page[o]), Float(page[o + 1]), Float(page[o + 2])].map { $0 / 255 }
            var outA = sa + da * (1 - sa)
            var outC = [Float](repeating: 0, count: 3)
            switch blend {
            case .multiply:
                for i in 0..<3 { outC[i] = sc[i] * dc[i] + sc[i] * (1 - da) + dc[i] * (1 - sa) }
            case .screen:
                for i in 0..<3 { outC[i] = sc[i] + dc[i] - sc[i] * dc[i] }
            case .clipToLower:
                for i in 0..<3 { sc[i] *= da }
                for i in 0..<3 { outC[i] = sc[i] + dc[i] * (1 - sa * da) }
                outA = da
            case .sliceFromLower:
                for i in 0..<3 { outC[i] = dc[i] * (1 - sa) }
                outA = da * (1 - sa)
            default:
                for i in 0..<3 { outC[i] = sc[i] + dc[i] * (1 - sa) }
            }
            for i in 0..<3 { page[o + i] = UInt8(clamp(outC[i] * 255, 0, 255)) }
            page[o + 3] = UInt8(clamp(outA * 255, 0, 255))
        }
    }
}
