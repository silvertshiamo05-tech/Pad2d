// Inochi Creator's Tools menu: texture premultiply / colour bleed, layer
// names and puppet repair (core/colorbleed.d, utils/repair.d).

import Foundation

/// Spreads colour from opaque pixels into fully transparent ones (alpha stays
/// 0), so filtering doesn't pull dark fringes in. Port of Creator's
/// Gemserk-style colour bleeding.
public func colorBleed(_ rgba: inout [UInt8], width: Int, height: Int, maxIterations: Int = 32) {
    let n = width * height
    guard rgba.count >= n * 4 else { return }
    var isData = [Bool](repeating: false, count: n)
    var pending: [Int] = []
    for i in 0..<n {
        if rgba[i * 4 + 3] == 0 { pending.append(i) } else { isData[i] = true }
    }
    var iterations = 0
    while !pending.isEmpty && iterations < maxIterations {
        let before = pending.count
        var changing: [Int] = []
        var k = 0
        while k < pending.count {
            let p = pending[k]
            let x = p % width, y = p / width
            var r = 0, g = 0, b = 0, count = 0
            for dy in -1...1 {
                for dx in -1...1 where !(dx == 0 && dy == 0) {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, ny >= 0, nx < width, ny < height else { continue }
                    let q = ny * width + nx
                    guard isData[q] else { continue }
                    r += Int(rgba[q * 4]); g += Int(rgba[q * 4 + 1]); b += Int(rgba[q * 4 + 2])
                    count += 1
                }
            }
            if count > 0 {
                rgba[p * 4] = UInt8(r / count)
                rgba[p * 4 + 1] = UInt8(g / count)
                rgba[p * 4 + 2] = UInt8(b / count)
                rgba[p * 4 + 3] = 0
                changing.append(p)
                pending[k] = pending[pending.count - 1]
                pending.removeLast()
            } else {
                k += 1
            }
        }
        for p in changing { isData[p] = true }
        iterations += 1
        if pending.count == before { break }
    }
}

public extension Part {
    /// The PSD/KRA layer path Creator stores for re-merging ("/Group/Layer").
    var layerPath: String? {
        get { extraJSON["psdLayerPath"] as? String }
        set { extraJSON["psdLayerPath"] = newValue }
    }
}

public extension Puppet {
    /// Decoded RGBA8 of a texture (as stored, i.e. premultiplied).
    func textureRGBA(_ index: Int) -> (rgba: [UInt8], width: Int, height: Int)? {
        guard textures.indices.contains(index), textures[index].encoding == .tga,
              let img = try? TGADecoder.decode(textures[index].data) else { return nil }
        return (img.rgba, img.width, img.height)
    }

    /// Creator's "Premultiply textures" (for files whose textures weren't).
    func premultiplyTextures(decode: (TextureBlob) -> ([UInt8], Int, Int)?) {
        for i in textures.indices {
            guard var (px, w, h) = decode(textures[i]) else { continue }
            TGADecoder.premultiply(&px)
            replaceTexture(i, rgba: px, width: w, height: h)
        }
    }

    /// Creator's "Bleed textures".
    func bleedTextures(decode: (TextureBlob) -> ([UInt8], Int, Int)?, progress: ((Double) -> Void)? = nil) {
        for i in textures.indices {
            progress?(Double(i) / Double(Swift.max(textures.count, 1)))
            guard var (px, w, h) = decode(textures[i]) else { continue }
            colorBleed(&px, width: w, height: h)
            replaceTexture(i, rgba: px, width: w, height: h)
        }
    }

    /// Creator's "Generate fake layer name info": layer path = "/" + name.
    func generateLayerNames() {
        for p in parts { p.layerPath = "/" + p.name }
    }

    /// Gives every node a new ID, updating bindings, masks, flip pairs and
    /// physics links (Creator's "Regenerate Node IDs" / "Attempt full repair").
    func regenerateNodeIDs() {
        var map: [UInt32: UInt32] = [:]
        var used = Set(parameters.map(\.uuid))
        for n in root.allNodes() {
            var id = UInt32.random(in: 1..<UInt32.max)
            while used.contains(id) { id = UInt32.random(in: 1..<UInt32.max) }
            used.insert(id)
            map[n.uuid] = id
        }
        let pairs = flipPairs
        for n in root.allNodes() {
            n.uuid = map[n.uuid] ?? n.uuid
            if let p = n as? Part { p.masks = p.masks.map { var m = $0; m.sourceUUID = map[m.sourceUUID] ?? m.sourceUUID; return m } }
            if let c = n as? Composite { c.masks = c.masks.map { var m = $0; m.sourceUUID = map[m.sourceUUID] ?? m.sourceUUID; return m } }
        }
        for p in parameters { for b in p.bindings { b.nodeRef = map[b.nodeRef] ?? b.nodeRef } }
        flipPairs = pairs.map { FlipPair(map[$0.first] ?? $0.first, map[$0.second] ?? $0.second) }
        rebuild()
    }

    /// Fixes common problems: duplicate IDs, dangling bindings and masks.
    func repair() {
        let ids = root.allNodes().map(\.uuid)
        if Set(ids).count != ids.count || ids.contains(0) { regenerateNodeIDs() }
        rebuild()
    }
}
