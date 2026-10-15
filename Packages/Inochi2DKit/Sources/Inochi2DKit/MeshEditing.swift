// Mesh editing model following Inochi Creator's IncMesh
// (viewport/common/mesh.d): points plus explicit edges; triangles are derived
// from the edge graph when the mesh is applied. Also the contour and grid
// auto-mesh processors (viewport/common/automesh).

import Foundation

public struct MeshEdge: Hashable, Sendable {
    public let a: Int
    public let b: Int

    public init(_ a: Int, _ b: Int) {
        self.a = Swift.min(a, b)
        self.b = Swift.max(a, b)
    }
}

/// An editable mesh: vertex positions in the drawable's local space and the
/// edges between them.
public struct EditableMesh: Equatable, Sendable {
    public var points: [Vec2]
    public var edges: Set<MeshEdge>
    /// Grid lines when the mesh is a grid: [ys, xs] (both ascending).
    public var gridAxes: [[Float]]?

    public init(points: [Vec2] = [], edges: Set<MeshEdge> = [], gridAxes: [[Float]]? = nil) {
        self.points = points
        self.edges = edges
        self.gridAxes = gridAxes
    }

    /// Builds the edge graph from a triangle list.
    public init(points: [Vec2], indices: [UInt16]) {
        self.points = points
        edges = []
        var t = 0
        while t + 2 < indices.count {
            let i = Int(indices[t]), j = Int(indices[t + 1]), k = Int(indices[t + 2])
            if i < points.count, j < points.count, k < points.count {
                edges.insert(MeshEdge(i, j))
                edges.insert(MeshEdge(j, k))
                edges.insert(MeshEdge(k, i))
            }
            t += 3
        }
    }

    public init(_ d: Drawable) {
        self.init(points: d.vertices, indices: d.indices)
        if let axes = (d.extraJSON["mesh"] as? [String: Any])?["grid_axes"] as? [[NSNumber]], axes.count == 2,
           axes[0].count > 2, axes[1].count > 2, !d.meshEdited {
            gridAxes = axes.map { $0.map(\.floatValue) }
        }
    }

    // MARK: Graph editing

    @discardableResult
    public mutating func add(_ p: Vec2) -> Int {
        points.append(p)
        return points.count - 1
    }

    public mutating func remove(_ i: Int) {
        guard points.indices.contains(i) else { return }
        points.remove(at: i)
        edges = Set(edges.compactMap { e in
            if e.a == i || e.b == i { return nil }
            return MeshEdge(e.a > i ? e.a - 1 : e.a, e.b > i ? e.b - 1 : e.b)
        })
    }

    /// Removes several vertices (and their edges).
    public mutating func remove(_ set: Set<Int>) {
        for i in set.sorted(by: >) { remove(i) }
    }

    public mutating func connect(_ a: Int, _ b: Int) {
        guard a != b, points.indices.contains(a), points.indices.contains(b) else { return }
        edges.insert(MeshEdge(a, b))
    }

    public mutating func disconnect(_ a: Int, _ b: Int) { edges.remove(MeshEdge(a, b)) }

    public func isConnected(_ a: Int, _ b: Int) -> Bool { edges.contains(MeshEdge(a, b)) }

    /// The first vertex within `radius` of `p`.
    public func vertex(at p: Vec2, radius: Float) -> Int? {
        var best: (Int, Float)?
        for (i, v) in points.enumerated() {
            let d = v.distance(to: p)
            if d <= radius && d < (best?.1 ?? .infinity) { best = (i, d) }
        }
        return best?.0
    }

    /// Vertices inside an axis-aligned rectangle given by two corners.
    public func vertices(inRect a: Vec2, _ b: Vec2) -> [Int] {
        let lo = Vec2(Swift.min(a.x, b.x), Swift.min(a.y, b.y)), hi = Vec2(Swift.max(a.x, b.x), Swift.max(a.y, b.y))
        return points.indices.filter { points[$0].x >= lo.x && points[$0].x <= hi.x && points[$0].y >= lo.y && points[$0].y <= hi.y }
    }

    /// Vertices inside a polygon (non-zero winding, as Creator's lasso).
    public func vertices(inPolygon poly: [Vec2]) -> [Int] {
        guard poly.count > 2 else { return [] }
        return points.indices.filter { pointInPolygon(points[$0], poly) }
    }

    public mutating func flipHorizontally() { points = points.map { Vec2(-$0.x, $0.y) } }
    public mutating func flipVertically() { points = points.map { Vec2($0.x, -$0.y) } }

    // MARK: Mirroring (around the local origin, as in Creator)

    /// `axis`: 0 none, 1 horizontal (x → -x), 2 vertical, 3 both.
    public static func mirror(_ p: Vec2, axis: Int) -> Vec2 {
        switch axis {
        case 1: return Vec2(-p.x, p.y)
        case 2: return Vec2(p.x, -p.y)
        case 3: return Vec2(-p.x, -p.y)
        default: return p
        }
    }

    public static func mirrorDelta(_ d: Vec2, axis: Int) -> Vec2 { mirror(d, axis: axis) }

    /// Active mirror axes for the given toggles; 0 (identity) comes last.
    public static func axes(horizontal: Bool, vertical: Bool) -> [Int] {
        var a: [Int] = []
        if horizontal { a.append(1) }
        if vertical { a.append(2) }
        if horizontal && vertical { a.append(3) }
        a.append(0)
        return a
    }

    /// The vertex at the mirrored position of vertex `i`, if any (and not `i`).
    public func mirrorVertex(_ i: Int, axis: Int, radius: Float) -> Int? {
        guard axis != 0, points.indices.contains(i) else { return nil }
        let m = vertex(at: EditableMesh.mirror(points[i], axis: axis), radius: radius)
        return m == i ? nil : m
    }

    // MARK: Triangles

    /// Triangles formed by the edges: every 3-cycle that doesn't enclose
    /// another vertex (so crossing edges don't create overlapping faces),
    /// wound counter-clockwise.
    public func triangles() -> [UInt16] {
        var adj = [Set<Int>](repeating: [], count: points.count)
        for e in edges {
            adj[e.a].insert(e.b)
            adj[e.b].insert(e.a)
        }
        var out: [UInt16] = []
        for a in points.indices {
            for b in adj[a] where b > a {
                for c in adj[a].intersection(adj[b]) where c > b {
                    let pa = points[a], pb = points[b], pc = points[c]
                    let cross = (pb.x - pa.x) * (pc.y - pa.y) - (pb.y - pa.y) * (pc.x - pa.x)
                    guard abs(cross) > 1e-6 else { continue }
                    let enclosesOther = points.indices.contains { i in
                        i != a && i != b && i != c && strictlyInside(points[i], pa, pb, pc)
                    }
                    if enclosesOther { continue }
                    out += cross > 0 ? [UInt16(a), UInt16(b), UInt16(c)] : [UInt16(a), UInt16(c), UInt16(b)]
                }
            }
        }
        return out
    }

    public var triangleCount: Int { triangles().count / 3 }

    /// Replaces the edges with a Delaunay triangulation of the points.
    public mutating func triangulate() {
        let idx = MeshGenerator.triangulate(points)
        self = EditableMesh(points: points, indices: idx)
    }

    /// A Delaunay preview of the current points (for drawing).
    public func delaunayEdges() -> Set<MeshEdge> {
        EditableMesh(points: points, indices: MeshGenerator.triangulate(points)).edges
    }

    // MARK: Grid meshes

    /// A grid mesh from axis values ([ys, xs]), triangulated in Creator's "X" pattern.
    public static func grid(_ axes: [[Float]]) -> EditableMesh {
        let ys = axes[0].sorted(), xs = axes[1].sorted()
        var pts: [Vec2] = []
        for y in ys { for x in xs { pts.append(Vec2(x, y)) } }
        var idx: [UInt16] = []
        let cx = Float(xs.count - 1) / 2, cy = Float(ys.count - 1) / 2
        if xs.count > 1 && ys.count > 1 {
            for j in 0..<(ys.count - 1) {
                for i in 0..<(xs.count - 1) {
                    let i0 = j * xs.count + i, i1 = (j + 1) * xs.count + i
                    let i2 = j * xs.count + i + 1, i3 = (j + 1) * xs.count + i + 1
                    let a = Float(i) < cx, b = Float(j) < cy
                    let t = (a && b) || (!a && !b) ? [i0, i2, i3, i0, i3, i1] : [i0, i1, i2, i1, i2, i3]
                    idx += t.map { UInt16($0) }
                }
            }
        }
        var m = EditableMesh(points: pts, indices: idx)
        m.gridAxes = [ys, xs]
        return m
    }

    /// Whether the points still match the grid axes exactly.
    public var isGrid: Bool {
        guard let g = gridAxes, g.count == 2, g[0].count >= 2, g[1].count >= 2 else { return false }
        return EditableMesh.grid(g).points == points
    }

    /// The final triangle list (grid meshes keep their pattern).
    public func exportIndices() -> [UInt16] {
        if isGrid, let g = gridAxes { return EditableMesh.grid(g).triangles() }
        return triangles()
    }
}

/// Non-zero winding point-in-polygon test (Creator's lasso).
public func pointInPolygon(_ p: Vec2, _ poly: [Vec2]) -> Bool {
    var winding = 0
    for i in poly.indices {
        let p1 = poly[i], p2 = poly[(i + 1) % poly.count]
        guard p1.y != p2.y else { continue }
        guard p.y >= Swift.min(p1.y, p2.y) && p.y <= Swift.max(p1.y, p2.y) else { continue }
        let crossX = p1.x + (p.y - p1.y) / (p2.y - p1.y) * (p2.x - p1.x)
        if p.x < crossX { winding += p1.y < p2.y ? 1 : -1 }
    }
    return winding != 0
}

private func strictlyInside(_ p: Vec2, _ a: Vec2, _ b: Vec2, _ c: Vec2) -> Bool {
    func s(_ p1: Vec2, _ p2: Vec2, _ p3: Vec2) -> Float { (p1.x - p3.x) * (p2.y - p3.y) - (p2.x - p3.x) * (p1.y - p3.y) }
    let d1 = s(p, a, b), d2 = s(p, b, c), d3 = s(p, c, a)
    // Points on an edge count too: such a triangle would overlap its neighbours.
    let eps: Float = -1e-6
    return (d1 > eps && d2 > eps && d3 > eps) || (d1 < -eps && d2 < -eps && d3 < -eps)
}

// MARK: - Auto-mesh processors

public struct ContourAutoMesh: Equatable, Sendable {
    public var samplingStep: Float = 50
    public var maskThreshold: Float = 15
    public var minDistance: Float = 16
    public var maxDistance: Float = 100
    public var scales: [Float] = [1, 1.1, 0.9, 0.7, 0.4, 0.2, 0.1, 0]

    public init() {}

    public enum Preset: String, CaseIterable, Sendable {
        case normal = "Normal parts", detailed = "Detailed mesh", large = "Large parts"
        case small = "Small parts", thin = "Thin and minimum parts", edges = "Preserve edges"
    }

    public static func preset(_ p: Preset) -> ContourAutoMesh {
        var c = ContourAutoMesh()
        let normalScales: [Float] = [1, 1.1, 0.9, 0.7, 0.4, 0.2, 0.1, 0]
        switch p {
        case .normal: (c.samplingStep, c.maskThreshold, c.minDistance, c.maxDistance, c.scales) = (50, 15, 16, 100, normalScales)
        case .detailed: (c.samplingStep, c.maskThreshold, c.minDistance, c.maxDistance, c.scales) = (32, 15, 16, 64, normalScales)
        case .large: (c.samplingStep, c.maskThreshold, c.minDistance, c.maxDistance, c.scales) = (80, 15, 24, 160, normalScales)
        case .small: (c.samplingStep, c.maskThreshold, c.minDistance, c.maxDistance, c.scales) = (24, 15, 12, 48, [1, 1.1, 0.6, 0.2])
        case .thin: (c.samplingStep, c.maskThreshold, c.minDistance, c.maxDistance, c.scales) = (12, 1, 4, 24, [1])
        case .edges: (c.samplingStep, c.maskThreshold, c.minDistance, c.maxDistance, c.scales) = (24, 15, 8, 48, [1, 1.2, 0.8])
        }
        return c
    }

    /// Mesh points in image pixel coordinates (not yet centred). `pixelScale`
    /// is how many source-texture pixels one image pixel represents (for
    /// downscaled previews); distances are in source pixels.
    public func points(alpha: (Int, Int) -> UInt8, width: Int, height: Int, pixelScale: Float = 1,
                       mirrorAxisX: Float? = nil) -> [Vec2] {
        let contours = traceContours(alpha: alpha, width: width, height: height, threshold: UInt8(clamping: Int(maskThreshold)))
        var all: [Vec2] = []
        for c in contours where c.count >= 10 { all += c.dropFirst().map { $0 * pixelScale } }
        guard !all.isEmpty else { return [] }
        let moment = all.reduce(Vec2.zero, +) / Float(all.count)
        var out: [Vec2] = []
        for scale in scales {
            let rate = Swift.min(maxDistance / scale, scale > 0 ? samplingStep / scale / scale : 1)
            // Resample along the contour.
            var base = 0
            if let ax = mirrorAxisX {
                base = all.indices.min { all[$0].x - ax < all[$1].x - ax } ?? 0
            }
            var sampled = [all[base]]
            var side: Float = 0
            for idx in 1..<all.count {
                let c = all[(idx + base) % all.count]
                guard (c - sampled[sampled.count - 1]).length > rate else { continue }
                if let ax = mirrorAxisX {
                    let s: Float = c.x - ax > 0 ? 1 : (c.x - ax < 0 ? -1 : 0)
                    if side == 0 { side = s } else if s != side { continue }
                }
                sampled.append(c)
            }
            var scaled = sampled.map { ($0 - moment) * scale + moment }
            if let ax = mirrorAxisX {
                let scaledAll = all.map { ($0 - moment) * scale + moment }
                for f in scaled {
                    let target = Vec2(2 * ax - f.x, f.y)
                    if let m = scaledAll.min(by: { ($0 - target).length < ($1 - target).length }) { scaled.append(m) }
                }
            }
            for c in scaled where out.allSatisfy({ ($0 - c).length > minDistance }) || out.isEmpty {
                out.append(c)
            }
        }
        return out
    }
}

public struct GridAutoMesh: Equatable, Sendable {
    public var maskThreshold: Float = 15
    public var xScales: [Float] = [-0.1, 0, 0.5, 1, 1.1]
    public var yScales: [Float] = [-0.1, 0, 0.5, 1, 1.1]

    public init() {}

    /// Evenly spaced scales with an optional margin outside the bounds.
    public static func scales(segments: Int, margin: Float) -> [Float] {
        var s: [Float] = margin > 0 ? [-margin] : []
        for i in 0...Swift.max(segments, 1) { s.append(Float(i) / Float(Swift.max(segments, 1))) }
        if margin > 0 { s.append(1 + margin) }
        return s
    }

    /// Grid axes ([ys, xs]) in image pixel coordinates, or nil if nothing is opaque.
    public func axes(alpha: (Int, Int) -> UInt8, width: Int, height: Int, pixelScale: Float = 1) -> [[Float]]? {
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        let t = UInt8(clamping: Int(maskThreshold))
        for y in 0..<height {
            for x in 0..<width where alpha(x, y) >= t {
                minX = Swift.min(minX, x); maxX = Swift.max(maxX, x)
                minY = Swift.min(minY, y); maxY = Swift.max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        let x0 = Float(minX) * pixelScale, x1 = Float(maxX) * pixelScale
        let y0 = Float(minY) * pixelScale, y1 = Float(maxY) * pixelScale
        let ys = yScales.sorted().map { y0 * $0 + y1 * (1 - $0) }.sorted()
        let xs = xScales.sorted().map { x0 * $0 + x1 * (1 - $0) }.sorted()
        return [ys, xs]
    }
}

/// Boundary chains between opaque and transparent pixels, each ordered by
/// walking neighbouring boundary pixels.
func traceContours(alpha: (Int, Int) -> UInt8, width: Int, height: Int, threshold: UInt8) -> [[Vec2]] {
    guard width > 0, height > 0 else { return [] }
    var solid = [Bool](repeating: false, count: width * height)
    for y in 0..<height { for x in 0..<width { solid[y * width + x] = alpha(x, y) >= threshold } }
    func isSolid(_ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < width && y < height && solid[y * width + x] }
    // Boundary pixels: transparent pixels touching an opaque one (like Creator,
    // which traces the edge of the transparent region).
    var boundary = [Bool](repeating: false, count: width * height)
    for y in -1...height {
        for x in -1...width where !isSolid(x, y) {
            if isSolid(x - 1, y) || isSolid(x + 1, y) || isSolid(x, y - 1) || isSolid(x, y + 1) {
                if x >= 0, y >= 0, x < width, y < height { boundary[y * width + x] = true }
            }
        }
    }
    // Opaque pixels on the image border also count, so shapes touching the edge close.
    for y in 0..<height {
        for x in 0..<width where solid[y * width + x] && (x == 0 || y == 0 || x == width - 1 || y == height - 1) {
            boundary[y * width + x] = true
        }
    }
    var visited = [Bool](repeating: false, count: width * height)
    let dirs = [(1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1), (0, -1), (1, -1)]
    var out: [[Vec2]] = []
    for start in 0..<(width * height) where boundary[start] && !visited[start] {
        var chain: [Vec2] = []
        var cx = start % width, cy = start / width
        var lastDir = 0
        visited[start] = true
        chain.append(Vec2(Float(cx), Float(cy)))
        while true {
            var moved = false
            for k in 0..<8 {
                let d = dirs[(lastDir + 6 + k) % 8]
                let nx = cx + d.0, ny = cy + d.1
                guard nx >= 0, ny >= 0, nx < width, ny < height else { continue }
                let n = ny * width + nx
                if boundary[n] && !visited[n] {
                    visited[n] = true
                    cx = nx
                    cy = ny
                    lastDir = (lastDir + 6 + k) % 8
                    chain.append(Vec2(Float(cx), Float(cy)))
                    moved = true
                    break
                }
            }
            if !moved { break }
        }
        out.append(chain)
    }
    return out
}

public extension Puppet {
    /// Runs an auto-mesh processor for a part, using its texture (RGBA8 at any
    /// resolution). Returns the new mesh in the part's local space.
    func autoMesh(_ d: Drawable, rgba: [UInt8], width: Int, height: Int, contour: ContourAutoMesh?,
                  grid: GridAutoMesh?, mirror: Bool = false) -> EditableMesh? {
        guard let toPos = positionMapping(for: d), !d.uvs.isEmpty, width > 0, height > 0 else { return nil }
        let us = d.uvs.map(\.x), vs = d.uvs.map(\.y)
        let x0 = Swift.max(0, Int((us.min()! * Float(width)).rounded(.down)))
        let y0 = Swift.max(0, Int((vs.min()! * Float(height)).rounded(.down)))
        let x1 = Swift.min(width, Int((us.max()! * Float(width)).rounded(.up)))
        let y1 = Swift.min(height, Int((vs.max()! * Float(height)).rounded(.up)))
        guard x1 > x0, y1 > y0 else { return nil }
        // Pixel distances are measured in mesh units.
        let unitsPerPixel = Swift.max(toPos(Vec2(0, 0)).distance(to: toPos(Vec2(1 / Float(width), 0))), 1e-6)
        let alpha: (Int, Int) -> UInt8 = { x, y in rgba[((y0 + y) * width + x0 + x) * 4 + 3] }
        func toMesh(_ p: Vec2) -> Vec2 {
            toPos(Vec2((Float(x0) + p.x / unitsPerPixel) / Float(width), (Float(y0) + p.y / unitsPerPixel) / Float(height)))
        }
        if let grid, let axes = grid.axes(alpha: alpha, width: x1 - x0, height: y1 - y0, pixelScale: unitsPerPixel) {
            let ys = axes[0].map { toMesh(Vec2(0, $0)).y }, xs = axes[1].map { toMesh(Vec2($0, 0)).x }
            return EditableMesh.grid([ys, xs])
        }
        guard let contour else { return nil }
        // Mirror axis: the part's local x = 0, in image pixels.
        var axisX: Float?
        if mirror {
            let zeroUV = uvMapping(for: d)(Vec2(0, 0))
            axisX = (zeroUV.x * Float(width) - Float(x0)) * unitsPerPixel
        }
        let pts = contour.points(alpha: alpha, width: x1 - x0, height: y1 - y0, pixelScale: unitsPerPixel, mirrorAxisX: axisX)
        guard pts.count >= 3 else { return nil }
        var m = EditableMesh(points: pts.map { toMesh($0) })
        m.triangulate()
        return m
    }

    /// Applies an edited mesh to a drawable, re-sampling its deformations.
    func applyMesh(_ m: EditableMesh, to d: Drawable) -> Bool {
        let idx = m.exportIndices()
        guard idx.count >= 3 else { return false }
        setMesh(d, vertices: m.points, indices: idx)
        if var mesh = d.extraJSON["mesh"] as? [String: Any] {
            mesh["grid_axes"] = nil
            d.extraJSON["mesh"] = mesh
        }
        if m.isGrid, let g = m.gridAxes {
            var mesh = (d.extraJSON["mesh"] as? [String: Any]) ?? [:]
            mesh["grid_axes"] = g
            d.extraJSON["mesh"] = mesh
            d.meshEdited = false
        }
        return true
    }
}
