import Foundation

public enum PSDError: Error, LocalizedError {
    case notPSD
    case unsupported(String)
    case truncated

    public var errorDescription: String? {
        switch self {
        case .notPSD: return "This file isn't a Photoshop document (.psd)."
        case let .unsupported(s): return "This PSD isn't supported: \(s)."
        case .truncated: return "The PSD file is incomplete or damaged."
        }
    }
}

/// One layer record from a PSD.
public struct PSDLayer: Sendable {
    public enum Kind: Sendable { case pixels, groupStart, groupEnd }

    public var name: String
    public var kind: Kind
    public var top: Int, left: Int, bottom: Int, right: Int
    public var opacity: UInt8
    public var visible: Bool
    public var blendKey: String
    public var width: Int { right - left }
    public var height: Int { bottom - top }

    struct Channel { var id: Int16; var length: Int; var offset: Int }
    var channels: [Channel]
}

/// Streaming PSD/PSB reader (8-bit RGB). Layer pixels are decoded one at a time.
public final class PSDDocument {
    public let width: Int
    public let height: Int
    /// Layer records, bottom-most first (file order).
    public private(set) var layers: [PSDLayer] = []
    private let data: Data
    private let isPSB: Bool

    public init(data: Data) throws {
        self.data = data
        var r = ByteReader(data)
        guard try r.bytes(4) == Array("8BPS".utf8) else { throw PSDError.notPSD }
        let version = Int(try r.u16())
        guard version == 1 || version == 2 else { throw PSDError.unsupported("version \(version)") }
        isPSB = version == 2
        _ = try r.bytes(6)
        _ = try r.u16() // channels
        height = Int(try r.u32())
        width = Int(try r.u32())
        let depth = try r.u16(), mode = try r.u16()
        guard depth == 8 else { throw PSDError.unsupported("\(depth)-bit colour (save as 8-bit)") }
        guard mode == 3 else { throw PSDError.unsupported("colour mode \(mode) (save as RGB)") }
        _ = try r.data(Int(try r.u32())) // colour mode data
        _ = try r.data(Int(try r.u32())) // image resources
        let lmLength = isPSB ? Int(try r.u64()) : Int(try r.u32())
        guard lmLength > 0 else { return }
        let liLength = isPSB ? Int(try r.u64()) : Int(try r.u32())
        guard liLength > 0 else { return }
        let count = abs(Int(Int16(bitPattern: try r.u16())))

        var records: [PSDLayer] = []
        for _ in 0..<count {
            let top = Int(Int32(bitPattern: try r.u32())), left = Int(Int32(bitPattern: try r.u32()))
            let bottom = Int(Int32(bitPattern: try r.u32())), right = Int(Int32(bitPattern: try r.u32()))
            var chans: [PSDLayer.Channel] = []
            for _ in 0..<Int(try r.u16()) {
                let id = Int16(bitPattern: try r.u16())
                let len = isPSB ? Int(try r.u64()) : Int(try r.u32())
                chans.append(.init(id: id, length: len, offset: 0))
            }
            guard try r.bytes(4) == Array("8BIM".utf8) else { throw PSDError.truncated }
            let blend = String(decoding: try r.bytes(4), as: UTF8.self)
            let opacity = try r.u8()
            _ = try r.u8()
            let flags = try r.u8()
            _ = try r.u8()
            let extraLength = Int(try r.u32())
            let extraEnd = r.pos + extraLength
            _ = try r.data(Int(try r.u32())) // mask
            _ = try r.data(Int(try r.u32())) // blending ranges
            let nameLength = Int(try r.u8())
            var name = String(decoding: try r.bytes(nameLength), as: UTF8.self)
            _ = try r.data((nameLength + 4) / 4 * 4 - nameLength - 1)
            var kind = PSDLayer.Kind.pixels
            while r.pos + 12 <= extraEnd {
                let sig = try r.bytes(4)
                guard sig == Array("8BIM".utf8) || sig == Array("8B64".utf8) else { break }
                let key = String(decoding: try r.bytes(4), as: UTF8.self)
                let long: Set<String> = ["LMsk", "Lr16", "Lr32", "Layr", "Mt16", "Mt32", "Mtrn", "Alph", "FMsk", "lnk2", "FEid", "FXid", "PxSD"]
                let len = isPSB && long.contains(key) ? Int(try r.u64()) : Int(try r.u32())
                let start = r.pos
                if key == "luni", len >= 4 {
                    let n = Int(try r.u32())
                    var units: [UInt16] = []
                    for _ in 0..<min(n, (len - 4) / 2) { units.append(try r.u16()) }
                    name = String(decoding: units, as: UTF16.self)
                } else if key == "lsct" || key == "lsdk", len >= 4 {
                    let t = try r.u32()
                    if t == 1 || t == 2 { kind = .groupStart }
                    if t == 3 { kind = .groupEnd }
                }
                r.pos = start + len + (len % 2)
            }
            r.pos = extraEnd
            records.append(PSDLayer(name: name, kind: kind, top: top, left: left, bottom: bottom, right: right,
                                    opacity: opacity, visible: flags & 0x02 == 0, blendKey: blend, channels: chans))
        }
        for i in records.indices {
            for c in records[i].channels.indices {
                records[i].channels[c].offset = r.pos
                r.pos += records[i].channels[c].length
            }
        }
        guard r.pos <= data.count else { throw PSDError.truncated }
        layers = records
    }

    /// The layer's pixels as straight-alpha RGBA8, cropped to its bounds.
    public func rgba(for layer: PSDLayer) throws -> [UInt8] {
        let w = layer.width, h = layer.height
        guard w > 0, h > 0 else { return [] }
        var out = [UInt8](repeating: 255, count: w * h * 4)
        for ch in layer.channels {
            let dest: Int
            switch ch.id {
            case 0: dest = 0
            case 1: dest = 1
            case 2: dest = 2
            case -1: dest = 3
            default: continue
            }
            var r = ByteReader(data)
            r.pos = ch.offset
            let compression = try r.u16()
            var plane = [UInt8](repeating: 0, count: w * h)
            switch compression {
            case 0:
                plane = try r.bytes(w * h)
            case 1:
                var counts: [Int] = []
                for _ in 0..<h { counts.append(isPSB ? Int(try r.u32()) : Int(try r.u16())) }
                for y in 0..<h {
                    let end = r.pos + counts[y]
                    var o = y * w
                    let rowEnd = o + w
                    while o < rowEnd && r.pos < end {
                        let n = Int(Int8(bitPattern: try r.u8()))
                        if n >= 0 {
                            for b in try r.bytes(n + 1) where o < rowEnd { plane[o] = b; o += 1 }
                        } else if n != -128 {
                            let v = try r.u8()
                            for _ in 0..<(1 - n) where o < rowEnd { plane[o] = v; o += 1 }
                        }
                    }
                    r.pos = end
                }
            default:
                throw PSDError.unsupported("compressed (ZIP) layer data")
            }
            for i in 0..<(w * h) { out[i * 4 + dest] = plane[i] }
        }
        return out
    }
}

extension ByteReader {
    mutating func u16() throws -> UInt16 {
        let b = try bytes(2)
        return UInt16(b[0]) << 8 | UInt16(b[1])
    }

    mutating func u64() throws -> UInt64 {
        UInt64(try u32()) << 32 | UInt64(try u32())
    }
}

// MARK: - Import

public struct PSDImportOptions: Sendable {
    /// Keep layer folders as group nodes (otherwise only blended folders stay, as composites).
    public var keepFolders = true
    /// Generate meshes that follow each layer's shape instead of plain quads.
    public var autoMesh = true
    /// Vertex spacing for automatic meshes, in pixels.
    public var meshSpacing: Float = 64
    /// Largest texture edge; bigger layers are scaled down.
    public var maxTextureSize = 4096
    public init() {}
}

public extension Puppet {
    /// Builds a new puppet from a layered PSD, the way Inochi Creator does.
    static func importPSD(_ data: Data, options: PSDImportOptions = .init(),
                          progress: ((Double) -> Void)? = nil) throws -> Puppet {
        let doc = try PSDDocument(data: data)
        let puppet = Puppet()
        let center = Vec2(Float(doc.width / 2), Float(doc.height / 2))

        // Walk top-down; folder records come before their contents.
        var stack: [Node?] = [puppet.root]
        var index = 0
        let total = max(doc.layers.count, 1)
        for (n, layer) in doc.layers.reversed().enumerated() {
            progress?(Double(n) / Double(total))
            index -= 1
            let parent = stack.compactMap { $0 }.last ?? puppet.root
            switch layer.kind {
            case .groupEnd:
                if stack.count > 1 { stack.removeLast() }
            case .groupStart:
                let blend = psdBlendMode(layer.blendKey)
                var node: Node?
                if layer.blendKey != "pass" && layer.blendKey != "norm" {
                    let c = puppet.makeNode(.composite, name: layer.name) as! Composite
                    c.blendMode = blend
                    c.opacity = Float(layer.opacity) / 255
                    node = c
                } else if options.keepFolders {
                    node = puppet.makeNode(.node, name: layer.name)
                }
                if let node {
                    node.relZSort = -Float(index)
                    node.enabled = layer.visible
                    node.parent = parent
                    parent.children.append(node)
                }
                stack.append(node)
            case .pixels:
                guard layer.width > 0, layer.height > 0 else { continue }
                var rgba = try doc.rgba(for: layer)
                var w = layer.width, h = layer.height
                // Mesh from the full-resolution alpha, in source pixels.
                let mesh = options.autoMesh
                    ? MeshGenerator.auto(rgba: rgba, width: w, height: h, spacing: options.meshSpacing)
                    : MeshGenerator.quad(width: Float(w), height: Float(h))
                let srcW = Float(w), srcH = Float(h)
                let scale = min(1, Float(options.maxTextureSize) / Float(max(w, h)))
                if scale < 1 {
                    (rgba, w, h) = downscale(rgba, w, h, scale)
                }
                TGADecoder.premultiply(&rgba)
                let slot = puppet.addTexture(rgba: rgba, width: w, height: h)
                // Geometry stays in document pixels even if the texture shrank:
                // texture coordinates are normalised.
                let part = puppet.makePart(name: layer.name, textureSlot: slot, width: Int(srcW), height: Int(srcH), mesh: mesh)
                part.localTransform.translation = Vec3(Float(layer.left) + srcW / 2 - center.x,
                                                       Float(layer.top) + srcH / 2 - center.y, 0)
                part.enabled = layer.visible
                part.opacity = Float(layer.opacity) / 255
                part.blendMode = psdBlendMode(layer.blendKey)
                part.relZSort = -Float(index)
                part.extraJSON["psdLayerPath"] = "/" + (stack.compactMap { $0?.name }.dropFirst() + [layer.name]).joined(separator: "/")
                part.parent = parent
                parent.children.append(part)
            }
        }
        // Children's z-sort is relative to their parent's.
        func relativise(_ n: Node, _ base: Float) {
            for c in n.children {
                let abs = c.relZSort
                c.relZSort = abs - base
                relativise(c, abs)
            }
        }
        relativise(puppet.root, 0)
        puppet.rebuild()
        progress?(1)
        return puppet
    }
}

private func downscale(_ px: [UInt8], _ w: Int, _ h: Int, _ s: Float) -> ([UInt8], Int, Int) {
    let nw = max(1, Int(Float(w) * s)), nh = max(1, Int(Float(h) * s))
    var out = [UInt8](repeating: 0, count: nw * nh * 4)
    // Box filter over the source footprint of each destination pixel.
    for y in 0..<nh {
        let y0 = y * h / nh, y1 = max(y0 + 1, (y + 1) * h / nh)
        for x in 0..<nw {
            let x0 = x * w / nw, x1 = max(x0 + 1, (x + 1) * w / nw)
            var acc = (0, 0, 0, 0), n = 0
            for sy in y0..<y1 {
                for sx in x0..<x1 {
                    let i = (sy * w + sx) * 4
                    let a = Int(px[i + 3])
                    acc.0 += Int(px[i]) * a; acc.1 += Int(px[i + 1]) * a; acc.2 += Int(px[i + 2]) * a; acc.3 += a
                    n += 1
                }
            }
            let o = (y * nw + x) * 4
            if acc.3 > 0 {
                out[o] = UInt8(acc.0 / acc.3); out[o + 1] = UInt8(acc.1 / acc.3); out[o + 2] = UInt8(acc.2 / acc.3)
            }
            out[o + 3] = UInt8(acc.3 / max(n, 1))
        }
    }
    return (out, nw, nh)
}

func psdBlendMode(_ key: String) -> BlendMode {
    switch key {
    case "mul ": return .multiply
    case "scrn": return .screen
    case "over": return .overlay
    case "dark": return .darken
    case "lite": return .lighten
    case "div ": return .colorDodge
    case "lddg": return .linearDodge
    case "idiv": return .colorBurn
    case "hLit": return .hardLight
    case "sLit": return .softLight
    case "diff": return .difference
    case "smud": return .exclusion
    case "fsub": return .subtract
    default: return .normal
    }
}
