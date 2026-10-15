import Foundation

/// A mesh in texture pixel coordinates (0...width, 0...height).
public struct GeneratedMesh: Sendable {
    public var points: [Vec2]
    public var indices: [UInt16]

    public init(points: [Vec2], indices: [UInt16]) {
        self.points = points
        self.indices = indices
    }
}

/// Automatic meshing for imported layers.
public enum MeshGenerator {
    /// Two triangles covering the whole texture (Inochi Creator's default).
    public static func quad(width: Float, height: Float) -> GeneratedMesh {
        // Same vertex order as inCreateSimplePart.
        GeneratedMesh(points: [Vec2(0, 0), Vec2(0, height), Vec2(width, 0), Vec2(width, height)],
                      indices: [0, 1, 2, 2, 1, 3])
    }

    /// Delaunay triangulation of arbitrary points, as mesh indices.
    public static func triangulate(_ points: [Vec2]) -> [UInt16] {
        guard points.count >= 3, points.count <= Int(UInt16.max) else { return [] }
        return Delaunay.triangulate(points).flatMap { [UInt16($0.0), UInt16($0.1), UInt16($0.2)] }
    }

    /// A mesh that hugs the opaque pixels of an RGBA8 image.
    /// - Parameters:
    ///   - spacing: approximate distance between vertices, in pixels.
    ///   - margin: padding kept around opaque pixels, in pixels.
    public static func auto(rgba: [UInt8], width: Int, height: Int, spacing: Float = 48, margin: Float = 6,
                            threshold: UInt8 = 8) -> GeneratedMesh {
        let spacing = max(spacing, 6)
        // Work on a coarse occupancy grid, so cost doesn't grow with resolution.
        let cell = max(1, Int(spacing / 4))
        let gw = (width + cell - 1) / cell, gh = (height + cell - 1) / cell
        var grid = [Bool](repeating: false, count: gw * gh)
        rgba.withUnsafeBufferPointer { px in
            for y in 0..<height {
                let row = y * width, cy = y / cell
                for x in 0..<width where px[(row + x) * 4 + 3] > threshold {
                    grid[cy * gw + x / cell] = true
                }
            }
        }
        guard grid.contains(true) else { return quad(width: Float(width), height: Float(height)) }
        // Dilate by the margin.
        let m = max(1, Int((margin / Float(cell)).rounded(.up)))
        var dil = grid
        for cy in 0..<gh {
            for cx in 0..<gw where grid[cy * gw + cx] {
                for dy in -m...m {
                    for dx in -m...m {
                        let nx = cx + dx, ny = cy + dy
                        if nx >= 0, ny >= 0, nx < gw, ny < gh { dil[ny * gw + nx] = true }
                    }
                }
            }
        }
        func filled(_ cx: Int, _ cy: Int) -> Bool { cx >= 0 && cy >= 0 && cx < gw && cy < gh && dil[cy * gw + cx] }
        let maxX = Float(width), maxY = Float(height)
        var points: [Vec2] = []
        var taken = Set<Int64>()
        func add(_ p: Vec2, bucket: Float) {
            let q = Vec2(min(max(p.x, 0), maxX), min(max(p.y, 0), maxY))
            let key = Int64((q.x / bucket).rounded()) << 32 | (Int64((q.y / bucket).rounded()) & 0xffff_ffff)
            if taken.insert(key).inserted { points.append(q) }
        }
        // Outline: midpoints of occupied cell edges that face empty cells.
        for cy in 0..<gh {
            for cx in 0..<gw where filled(cx, cy) {
                for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] where !filled(cx + dx, cy + dy) {
                    let x0 = Float(cx * cell), y0 = Float(cy * cell), c = Float(cell)
                    let p = dx != 0 ? Vec2(dx > 0 ? x0 + c : x0, y0 + c / 2) : Vec2(x0 + c / 2, dy > 0 ? y0 + c : y0)
                    add(p, bucket: spacing * 0.5)
                }
            }
        }
        let outline = points
        // Interior: a regular grid away from the outline.
        var y = spacing / 2
        while y < maxY {
            var x = spacing / 2
            while x < maxX {
                if filled(Int(x) / cell, Int(y) / cell),
                   !outline.contains(where: { $0.distance(to: Vec2(x, y)) < spacing * 0.45 }) {
                    add(Vec2(x, y), bucket: spacing * 0.5)
                }
                x += spacing
            }
            y += spacing
        }
        if points.count > 4000 { points = Array(points.prefix(4000)) }

        var indices: [UInt16] = []
        for t in Delaunay.triangulate(points) {
            let a = points[t.0], b = points[t.1], c = points[t.2]
            let samples = [(a + b + c) / 3, (a + b) / 2, (b + c) / 2, (c + a) / 2]
            if samples.filter({ filled(Int($0.x) / cell, Int($0.y) / cell) }).count >= 3 {
                indices += [UInt16(t.0), UInt16(t.1), UInt16(t.2)]
            }
        }
        var remap = [Int](repeating: -1, count: points.count)
        var out: [Vec2] = []
        for i in indices.map(Int.init) where remap[i] < 0 {
            remap[i] = out.count
            out.append(points[i])
        }
        guard !out.isEmpty else { return quad(width: maxX, height: maxY) }
        return GeneratedMesh(points: out, indices: indices.map { UInt16(remap[Int($0)]) })
    }
}

/// Bowyer–Watson Delaunay triangulation.
public enum Delaunay {
    public static func triangulate(_ pts: [Vec2]) -> [(Int, Int, Int)] {
        guard pts.count >= 3 else { return [] }
        var lo = pts[0], hi = pts[0]
        for p in pts { lo = Vec2(min(lo.x, p.x), min(lo.y, p.y)); hi = Vec2(max(hi.x, p.x), max(hi.y, p.y)) }
        let d = max(hi.x - lo.x, hi.y - lo.y, 1) * 20
        let c = (lo + hi) * 0.5
        let all = pts + [Vec2(c.x - d, c.y - d), Vec2(c.x + d, c.y - d), Vec2(c.x, c.y + d)]
        let n = pts.count

        struct Tri { var a, b, c: Int; var cc: Vec2; var r2: Float }
        func make(_ a: Int, _ b: Int, _ c: Int) -> Tri {
            let A = all[a], B = all[b], C = all[c]
            let dd = 2 * (A.x * (B.y - C.y) + B.x * (C.y - A.y) + C.x * (A.y - B.y))
            if abs(dd) < 1e-12 { return Tri(a: a, b: b, c: c, cc: A, r2: .infinity) }
            let a2 = A.x * A.x + A.y * A.y, b2 = B.x * B.x + B.y * B.y, c2 = C.x * C.x + C.y * C.y
            let cc = Vec2((a2 * (B.y - C.y) + b2 * (C.y - A.y) + c2 * (A.y - B.y)) / dd,
                          (a2 * (C.x - B.x) + b2 * (A.x - C.x) + c2 * (B.x - A.x)) / dd)
            let r = A - cc
            return Tri(a: a, b: b, c: c, cc: cc, r2: r.x * r.x + r.y * r.y)
        }
        var tris = [make(n, n + 1, n + 2)]
        for i in 0..<n {
            let p = all[i]
            var bad: [Int] = []
            for (k, t) in tris.enumerated() {
                let q = p - t.cc
                if q.x * q.x + q.y * q.y <= t.r2 * (1 + 1e-6) { bad.append(k) }
            }
            var edges: [UInt64: (Int, Int, Int)] = [:]
            for k in bad {
                let t = tris[k]
                for (u, v) in [(t.a, t.b), (t.b, t.c), (t.c, t.a)] {
                    let key = UInt64(min(u, v)) << 32 | UInt64(max(u, v))
                    if let e = edges[key] { edges[key] = (e.0, e.1, e.2 + 1) } else { edges[key] = (u, v, 1) }
                }
            }
            for k in bad.sorted(by: >) { tris.swapAt(k, tris.count - 1); tris.removeLast() }
            for (_, e) in edges where e.2 == 1 { tris.append(make(e.0, e.1, i)) }
        }
        return tris.compactMap { t in
            guard t.a < n, t.b < n, t.c < n else { return nil }
            let area = (all[t.b] - all[t.a]).x * (all[t.c] - all[t.a]).y - (all[t.b] - all[t.a]).y * (all[t.c] - all[t.a]).x
            if abs(area) < 1e-6 { return nil }
            return area > 0 ? (t.a, t.b, t.c) : (t.a, t.c, t.b)
        }
    }
}

/// Writes RLE-compressed 32-bit TGA files (the format Inochi Creator saves).
public enum TGAEncoder {
    public static func encode(rgba: [UInt8], width: Int, height: Int) -> Data {
        var out = [UInt8](repeating: 0, count: 18)
        out[2] = 10 // RLE true colour
        out[12] = UInt8(width & 0xff); out[13] = UInt8(width >> 8)
        out[14] = UInt8(height & 0xff); out[15] = UInt8(height >> 8)
        out[16] = 32
        out[17] = 0x28 // 8 alpha bits, top-left origin
        out.reserveCapacity(rgba.count / 2)
        func px(_ i: Int) -> (UInt8, UInt8, UInt8, UInt8) { (rgba[i * 4 + 2], rgba[i * 4 + 1], rgba[i * 4], rgba[i * 4 + 3]) }
        for y in 0..<height {
            var x = 0
            let row = y * width
            while x < width {
                // Run of identical pixels?
                var run = 1
                while x + run < width && run < 128 && px(row + x + run) == px(row + x) { run += 1 }
                if run > 1 {
                    let p = px(row + x)
                    out += [UInt8(0x80 | (run - 1)), p.0, p.1, p.2, p.3]
                    x += run
                } else {
                    var raw = 1
                    while x + raw < width && raw < 128 && !(x + raw + 1 < width && px(row + x + raw) == px(row + x + raw + 1)) { raw += 1 }
                    out.append(UInt8(raw - 1))
                    for k in 0..<raw { let p = px(row + x + k); out += [p.0, p.1, p.2, p.3] }
                    x += raw
                }
            }
        }
        return Data(out)
    }
}
