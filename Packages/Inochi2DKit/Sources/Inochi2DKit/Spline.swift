// Path deformation spline and deform brushes, ported from Inochi Creator
// (viewport/common/spline.d, viewport/common/mesheditor/brushes).

import Foundation

/// Inochi Creator's CatmullSpline: Hermite edge segments and Catmull–Rom
/// (as Bézier) middle segments.
public struct CatmullSpline: Equatable, Sendable {
    public var points: [Vec2] = []
    public var resolution = 40
    public private(set) var samples: [Vec2] = []

    public init(points: [Vec2] = []) {
        self.points = points
        interpolate()
    }

    public mutating func interpolate() {
        samples = []
        guard !points.isEmpty else { return }
        let n = resolution * (points.count - 1) + 1
        samples = (0..<n).map { eval(Float($0) / Float(resolution)) }
    }

    public func eval(_ off: Float) -> Vec2 {
        guard let first = points.first else { return .zero }
        if off <= 0 { return first }
        if off >= Float(points.count - 1) { return points[points.count - 1] }
        let i = Int(off)
        let t = off - Float(i), s = 1 - t
        let p1 = points[i], p2 = points[i + 1]
        if points.count == 2 { return p1 * s + p2 * t }
        func edge(_ p0: Vec2, _ p1: Vec2, _ p2: Vec2, _ t: Float) -> Vec2 {
            let t2 = t * t, t3 = t2 * t
            let h00 = 2 * t3 - 3 * t2 + 1, h01 = -2 * t3 + 3 * t2, h11 = t3 - t2
            let slope = (p2 - p0) / 2
            return slope * h11 + p1 * h01 + p0 * h00
        }
        if i == 0 { return edge(p1, p2, points[i + 2], t) }
        if i == points.count - 2 { return edge(p2, p1, points[i - 1], s) }
        let p0 = points[i - 1], p3 = points[i + 2]
        let b0 = p1, b1 = p1 + (p2 - p0) / 6, b2 = p2 - (p3 - p1) / 6, b3 = p2
        // de Casteljau.
        let a1 = b0 * s + b1 * t, mc = b1 * s + b2 * t, bb2 = b2 * s + b3 * t
        let a2 = a1 * s + mc * t, bb1 = bb2 * t + mc * s
        return a2 * s + bb1 * t
    }

    /// Position along the curve (0...count-1) nearest to `p`.
    public func closestOffset(to p: Vec2) -> Float {
        guard points.count >= 2, !samples.isEmpty else { return 0 }
        var best = 0
        var bestD = Float.infinity
        for (i, s) in samples.enumerated() {
            let d = s.distance(to: p)
            if d < bestD { bestD = d; best = i }
        }
        var left = Swift.max(0, Float(best - 1) / Float(resolution))
        var right = Swift.min(Float(points.count - 1), Float(best + 1) / Float(resolution))
        let eps: Float = 0.0001
        while right - left > eps * 2 {
            let mid = (left + right) / 2
            if p.distance(to: eval(mid - eps)) < p.distance(to: eval(mid + eps)) { right = mid } else { left = mid }
        }
        if left == 0 { return 0 }
        if right == Float(points.count - 1) { return Float(points.count - 1) }
        let a = eval(left), b = eval(right)
        let den = (b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y)
        let t = den > 0 ? ((p.x - a.x) * (b.x - a.x) + (p.y - a.y) * (b.y - a.y)) / den : 0
        return left * (1 - t) + right * t
    }

    /// Index of the control point within `radius` of `p`.
    public func point(near p: Vec2, radius: Float) -> Int? {
        guard let i = points.indices.min(by: { points[$0].distance(to: p) < points[$1].distance(to: p) }),
              points[i].distance(to: p) <= radius else { return nil }
        return i
    }

    /// Adds a control point like Creator: at an end, or on the curve when
    /// close to it. Returns the new index (nil if not added). The same edit
    /// is applied to `target` when given.
    @discardableResult
    public mutating func addPoint(_ p: Vec2, radius: Float, target: inout CatmullSpline?) -> Int? {
        if points.count < 2 {
            points.append(p)
            target?.points.append(p)
            interpolate(); target?.interpolate()
            return points.count - 1
        }
        let off = closestOffset(to: p)
        if off <= 0 {
            points.insert(p, at: 0)
            target?.points.insert(p, at: 0)
            interpolate(); target?.interpolate()
            return 0
        }
        if off >= Float(points.count - 1) {
            points.append(p)
            target?.points.append(p)
            interpolate(); target?.interpolate()
            return points.count - 1
        }
        guard p.distance(to: eval(off)) < radius else { return nil }
        let i = Int(off) + 1
        points.insert(eval(off), at: i)
        if var t = target {
            t.points.insert(t.eval(off), at: i)
            t.interpolate()
            target = t
        }
        interpolate()
        return i
    }

    public mutating func removePoint(_ i: Int, target: inout CatmullSpline?) {
        guard points.indices.contains(i) else { return }
        points.remove(at: i)
        if var t = target, t.points.indices.contains(i) {
            t.points.remove(at: i)
            t.interpolate()
            target = t
        }
        interpolate()
    }
}

/// Binds mesh vertices to a reference path so moving a copy of the path
/// (the target) bends them (Creator's path deform).
public struct PathBinding: Sendable {
    /// (along tangent, along normal, curve offset); offset NaN = not bound.
    public private(set) var refOffsets: [Vec3] = []
    public private(set) var initTangents: [Vec2] = []

    public init() {}

    private static func tangent(_ s: CatmullSpline, _ off: Float) -> Vec2 {
        let d = s.eval(off + 0.0001) - s.eval(off)
        let l = d.length
        return l > 0 ? d / l : Vec2(0, 1)
    }

    /// Records each vertex relative to the reference path (evaluated on `target`).
    public mutating func map(_ vertices: [Vec2], reference: CatmullSpline, target: CatmullSpline) {
        refOffsets = []
        initTangents = []
        guard reference.points.count >= 2 else { return }
        let last = Float(reference.points.count - 1)
        for v in vertices {
            let off = reference.closestOffset(to: v)
            let pt = target.eval(off)
            let tan = PathBinding.tangent(target, off)
            initTangents.append(tan)
            if off <= 0 || off >= last {
                refOffsets.append(Vec3(0, 0, .nan))
                continue
            }
            let d = v - pt
            refOffsets.append(Vec3(d.x * tan.x + d.y * tan.y, d.y * tan.x - d.x * tan.y, off))
        }
    }

    /// New vertex positions for a moved target path (nil = vertex not bound).
    public func positions(target: CatmullSpline, selected: Set<Int>? = nil) -> [Vec2?] {
        refOffsets.enumerated().map { i, rel in
            guard rel.z.isFinite, selected.map({ $0.isEmpty || $0.contains(i) }) ?? true else { return nil }
            let pt = target.eval(rel.z)
            let t = PathBinding.tangent(target, rel.z)
            return Vec2(pt.x + rel.x * t.x - rel.y * t.y, pt.y + rel.y * t.x + rel.x * t.y)
        }
    }

    /// Rotation change of the path at vertex `i` (radians), for node targets.
    public func rotation(_ i: Int, target: CatmullSpline) -> Float {
        guard i < refOffsets.count, refOffsets[i].z.isFinite else { return 0 }
        let t = PathBinding.tangent(target, refOffsets[i].z), t0 = initTangents[i]
        return atan2(t.y, t.x) - atan2(t0.y, t0.x)
    }
}

/// Deform brushes (Creator's mesheditor/brushes).
public enum DeformBrush: Equatable, Sendable {
    case circle(radius: Float)
    case doubleThreshold(radius: Float, inner: Float)
    case rectangle(width: Float, height: Float)

    public static let circleDefault = DeformBrush.circle(radius: 300)
    public static let doubleThresholdDefault = DeformBrush.doubleThreshold(radius: 300, inner: 100)
    public static let rectangleDefault = DeformBrush.rectangle(width: 300, height: 300)

    /// Influence (0...1) at a point relative to the brush centre.
    public func weight(_ d: Vec2) -> Float {
        switch self {
        case .circle(let r):
            return clamp(1 - d.length / r, 0, 1)
        case .doubleThreshold(let r, let inner):
            let l = d.length
            if l <= inner { return 1 }
            return clamp(1 - (l - inner) / Swift.max(r - inner, 0.0001), 0, 1)
        case .rectangle(let w, let h):
            return Swift.min(clamp(1 - abs(d.x) / w, 0, 1), clamp(1 - abs(d.y) / h, 0, 1))
        }
    }
}
