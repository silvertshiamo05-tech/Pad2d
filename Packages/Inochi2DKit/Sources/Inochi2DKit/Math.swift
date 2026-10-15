// Ported from Inochi2D 0.8 (inochi2d.math) and the inmath library it uses.
// Copyright © 2020, Inochi2D Project. Distributed under the 2-Clause BSD License.

import Foundation

public struct Vec2: Equatable, Sendable {
    public var x: Float
    public var y: Float

    public init(_ x: Float, _ y: Float) {
        self.x = x
        self.y = y
    }

    public static let zero = Vec2(0, 0)

    @inline(__always) public static func + (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x + b.x, a.y + b.y) }
    @inline(__always) public static func - (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x - b.x, a.y - b.y) }
    @inline(__always) public static func * (a: Vec2, s: Float) -> Vec2 { Vec2(a.x * s, a.y * s) }
    @inline(__always) public static func * (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x * b.x, a.y * b.y) }
    @inline(__always) public static func / (a: Vec2, s: Float) -> Vec2 { Vec2(a.x / s, a.y / s) }
    @inline(__always) public static prefix func - (a: Vec2) -> Vec2 { Vec2(-a.x, -a.y) }
    @inline(__always) public static func += (a: inout Vec2, b: Vec2) { a = a + b }
    @inline(__always) public static func -= (a: inout Vec2, b: Vec2) { a = a - b }

    public var length: Float { (x * x + y * y).squareRoot() }

    public func distance(to o: Vec2) -> Float { (self - o).length }

    /// inmath's `normalized`: divides by length (yields NaN for zero vectors, like the original).
    public var normalized: Vec2 { self / length }

    public var isFinite: Bool { x.isFinite && y.isFinite }
}

public struct Vec3: Equatable, Sendable {
    public var x: Float
    public var y: Float
    public var z: Float

    public init(_ x: Float, _ y: Float, _ z: Float) {
        self.x = x
        self.y = y
        self.z = z
    }

    public static let zero = Vec3(0, 0, 0)
    public static let one = Vec3(1, 1, 1)

    public static func + (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x + b.x, a.y + b.y, a.z + b.z) }
}

/// 3x3 row-major matrix (inmath `mat3`).
public struct Mat3: Equatable, Sendable {
    public var m: [Float] // 9 values, row-major

    public init(_ m: [Float]) {
        precondition(m.count == 9)
        self.m = m
    }

    public static let identity = Mat3([1, 0, 0, 0, 1, 0, 0, 0, 1])

    public static func * (a: Mat3, b: Mat3) -> Mat3 {
        var r = [Float](repeating: 0, count: 9)
        for i in 0..<3 {
            for j in 0..<3 {
                r[i * 3 + j] = a.m[i * 3] * b.m[j] + a.m[i * 3 + 1] * b.m[3 + j] + a.m[i * 3 + 2] * b.m[6 + j]
            }
        }
        return Mat3(r)
    }

    /// Transforms (x, y, 1) and returns the resulting x, y.
    @inline(__always)
    public func apply(_ p: Vec2) -> Vec2 {
        Vec2(m[0] * p.x + m[1] * p.y + m[2], m[3] * p.x + m[4] * p.y + m[5])
    }
}

/// 4x4 row-major matrix (inmath `mat4`). `matrix * vector` treats vectors as columns.
public struct Mat4: Equatable, Sendable {
    public var m: (Float, Float, Float, Float,
                   Float, Float, Float, Float,
                   Float, Float, Float, Float,
                   Float, Float, Float, Float)

    public init(_ v: [Float]) {
        precondition(v.count == 16)
        m = (v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7],
             v[8], v[9], v[10], v[11], v[12], v[13], v[14], v[15])
    }

    public static let identity = Mat4([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1])

    public static func == (a: Mat4, b: Mat4) -> Bool { a.array == b.array }

    public var array: [Float] {
        [m.0, m.1, m.2, m.3, m.4, m.5, m.6, m.7, m.8, m.9, m.10, m.11, m.12, m.13, m.14, m.15]
    }

    public subscript(r: Int, c: Int) -> Float {
        get { array[r * 4 + c] }
        set {
            var a = array
            a[r * 4 + c] = newValue
            self = Mat4(a)
        }
    }

    public static func translation(_ t: Vec3) -> Mat4 {
        Mat4([1, 0, 0, t.x, 0, 1, 0, t.y, 0, 0, 1, t.z, 0, 0, 0, 1])
    }

    public static func scaling(_ x: Float, _ y: Float, _ z: Float) -> Mat4 {
        Mat4([x, 0, 0, 0, 0, y, 0, 0, 0, 0, z, 0, 0, 0, 0, 1])
    }

    /// `quat.eulerRotation(roll, pitch, yaw).toMatrix!(4, 4)` from inmath.
    public static func eulerRotation(_ roll: Float, _ pitch: Float, _ yaw: Float) -> Mat4 {
        if roll == 0 && pitch == 0 && yaw == 0 { return .identity }
        let cr = cos(Double(roll) / 2), cp = cos(Double(pitch) / 2), cy = cos(Double(yaw) / 2)
        let sr = sin(Double(roll) / 2), sp = sin(Double(pitch) / 2), sy = sin(Double(yaw) / 2)
        let w = Float(cr * cp * cy + sr * sp * sy)
        let x = Float(sr * cp * cy - cr * sp * sy)
        let y = Float(cr * sp * cy + sr * cp * sy)
        let z = Float(cr * cp * sy - sr * sp * cy)
        let xx = x * x, xy = x * y, xz = x * z, xw = x * w
        let yy = y * y, yz = y * z, yw = y * w, zz = z * z, zw = z * w
        return Mat4([
            1 - 2 * (yy + zz), 2 * (xy - zw), 2 * (xz + yw), 0,
            2 * (xy + zw), 1 - 2 * (xx + zz), 2 * (yz - xw), 0,
            2 * (xz - yw), 2 * (yz + xw), 1 - 2 * (xx + yy), 0,
            0, 0, 0, 1,
        ])
    }

    public static func * (a: Mat4, b: Mat4) -> Mat4 {
        let x = a.array, y = b.array
        var r = [Float](repeating: 0, count: 16)
        for i in 0..<4 {
            for j in 0..<4 {
                r[i * 4 + j] = x[i * 4] * y[j] + x[i * 4 + 1] * y[4 + j] + x[i * 4 + 2] * y[8 + j] + x[i * 4 + 3] * y[12 + j]
            }
        }
        return Mat4(r)
    }

    /// Transforms the point (x, y, 0, 1) and returns x, y.
    @inline(__always)
    public func apply(_ p: Vec2) -> Vec2 {
        Vec2(m.0 * p.x + m.1 * p.y + m.3, m.4 * p.x + m.5 * p.y + m.7)
    }

    /// Transforms the vector (x, y, z, w).
    public func apply4(_ x: Float, _ y: Float, _ z: Float, _ w: Float) -> (Float, Float, Float, Float) {
        (m.0 * x + m.1 * y + m.2 * z + m.3 * w,
         m.4 * x + m.5 * y + m.6 * z + m.7 * w,
         m.8 * x + m.9 * y + m.10 * z + m.11 * w,
         m.12 * x + m.13 * y + m.14 * z + m.15 * w)
    }

    /// The translation column.
    public var origin: Vec2 { Vec2(m.3, m.7) }

    /// General 4x4 inverse (inmath `mat4.inverse`).
    public var inverse: Mat4 {
        let a = array.map(Double.init)
        var inv = [Double](repeating: 0, count: 16)
        inv[0] = a[5] * a[10] * a[15] - a[5] * a[11] * a[14] - a[9] * a[6] * a[15] + a[9] * a[7] * a[14] + a[13] * a[6] * a[11] - a[13] * a[7] * a[10]
        inv[4] = -a[4] * a[10] * a[15] + a[4] * a[11] * a[14] + a[8] * a[6] * a[15] - a[8] * a[7] * a[14] - a[12] * a[6] * a[11] + a[12] * a[7] * a[10]
        inv[8] = a[4] * a[9] * a[15] - a[4] * a[11] * a[13] - a[8] * a[5] * a[15] + a[8] * a[7] * a[13] + a[12] * a[5] * a[11] - a[12] * a[7] * a[9]
        inv[12] = -a[4] * a[9] * a[14] + a[4] * a[10] * a[13] + a[8] * a[5] * a[14] - a[8] * a[6] * a[13] - a[12] * a[5] * a[10] + a[12] * a[6] * a[9]
        inv[1] = -a[1] * a[10] * a[15] + a[1] * a[11] * a[14] + a[9] * a[2] * a[15] - a[9] * a[3] * a[14] - a[13] * a[2] * a[11] + a[13] * a[3] * a[10]
        inv[5] = a[0] * a[10] * a[15] - a[0] * a[11] * a[14] - a[8] * a[2] * a[15] + a[8] * a[3] * a[14] + a[12] * a[2] * a[11] - a[12] * a[3] * a[10]
        inv[9] = -a[0] * a[9] * a[15] + a[0] * a[11] * a[13] + a[8] * a[1] * a[15] - a[8] * a[3] * a[13] - a[12] * a[1] * a[11] + a[12] * a[3] * a[9]
        inv[13] = a[0] * a[9] * a[14] - a[0] * a[10] * a[13] - a[8] * a[1] * a[14] + a[8] * a[2] * a[13] + a[12] * a[1] * a[10] - a[12] * a[2] * a[9]
        inv[2] = a[1] * a[6] * a[15] - a[1] * a[7] * a[14] - a[5] * a[2] * a[15] + a[5] * a[3] * a[14] + a[13] * a[2] * a[7] - a[13] * a[3] * a[6]
        inv[6] = -a[0] * a[6] * a[15] + a[0] * a[7] * a[14] + a[4] * a[2] * a[15] - a[4] * a[3] * a[14] - a[12] * a[2] * a[7] + a[12] * a[3] * a[6]
        inv[10] = a[0] * a[5] * a[15] - a[0] * a[7] * a[13] - a[4] * a[1] * a[15] + a[4] * a[3] * a[13] + a[12] * a[1] * a[7] - a[12] * a[3] * a[5]
        inv[14] = -a[0] * a[5] * a[14] + a[0] * a[6] * a[13] + a[4] * a[1] * a[14] - a[4] * a[2] * a[13] - a[12] * a[1] * a[6] + a[12] * a[2] * a[5]
        inv[3] = -a[1] * a[6] * a[11] + a[1] * a[7] * a[10] + a[5] * a[2] * a[11] - a[5] * a[3] * a[10] - a[9] * a[2] * a[7] + a[9] * a[3] * a[6]
        inv[7] = a[0] * a[6] * a[11] - a[0] * a[7] * a[10] - a[4] * a[2] * a[11] + a[4] * a[3] * a[10] + a[8] * a[2] * a[7] - a[8] * a[3] * a[6]
        inv[11] = -a[0] * a[5] * a[11] + a[0] * a[7] * a[9] + a[4] * a[1] * a[11] - a[4] * a[3] * a[9] - a[8] * a[1] * a[7] + a[8] * a[3] * a[5]
        inv[15] = a[0] * a[5] * a[10] - a[0] * a[6] * a[9] - a[4] * a[1] * a[10] + a[4] * a[2] * a[9] + a[8] * a[1] * a[6] - a[8] * a[2] * a[5]
        let det = a[0] * inv[0] + a[1] * inv[4] + a[2] * inv[8] + a[3] * inv[12]
        let d = det == 0 ? 0 : 1 / det
        return Mat4(inv.map { Float($0 * d) })
    }
}

/// Node transform (inochi2d.math.transform).
public struct Transform: Sendable {
    public var translation = Vec3.zero
    public var rotation = Vec3.zero
    public var scale = Vec2(1, 1)
    public private(set) var matrix = Mat4.identity

    public init(translation: Vec3 = .zero, rotation: Vec3 = .zero, scale: Vec2 = Vec2(1, 1)) {
        self.translation = translation
        self.rotation = rotation
        self.scale = scale
    }

    public mutating func update() {
        matrix = Mat4.translation(translation)
            * Mat4.eulerRotation(rotation.x, rotation.y, rotation.z)
            * Mat4.scaling(scale.x, scale.y, 1)
    }

    public mutating func clear() {
        translation = .zero
        rotation = .zero
        scale = Vec2(1, 1)
    }

    /// `localTransform.calcOffset(offsetTransform)`.
    public func calcOffset(_ other: Transform) -> Transform {
        var t = Transform(translation: translation + other.translation,
                          rotation: rotation + other.rotation,
                          scale: scale * other.scale)
        t.update()
        return t
    }

    /// `child * parent`: the combined matrix is `parent.matrix * child.matrix`.
    public static func * (child: Transform, parent: Transform) -> Transform {
        var t = Transform()
        let strs = parent.matrix * child.matrix
        let p = strs.apply4(1, 1, 1, 1)
        t.translation = Vec3(p.0, p.1, p.2)
        t.rotation = child.rotation + parent.rotation
        t.scale = child.scale * parent.scale
        t.matrix = strs
        return t
    }
}

@inline(__always) func clamp(_ v: Float, _ lo: Float, _ hi: Float) -> Float { min(max(v, lo), hi) }

/// inmath `cubic` (Catmull–Rom style) for any type with the needed arithmetic.
@inline(__always)
func cubic(_ p0: Float, _ p1: Float, _ p2: Float, _ p3: Float, _ t: Float) -> Float {
    let a = -0.5 * p0 + 1.5 * p1 - 1.5 * p2 + 0.5 * p3
    let b = p0 - 2.5 * p1 + 2 * p2 - 0.5 * p3
    let c = -0.5 * p0 + 0.5 * p2
    let d = p1
    return a * (t * t * t) + b * (t * t) + c * t + d
}

/// Cubic weights for p0...p3 so that `cubic` equals the weighted sum.
@inline(__always)
func cubicWeights(_ t: Float) -> (Float, Float, Float, Float) {
    let t2 = t * t, t3 = t2 * t
    return (-0.5 * t3 + t2 - 0.5 * t,
            1.5 * t3 - 2.5 * t2 + 1,
            -1.5 * t3 + 2 * t2 + 0.5 * t,
            0.5 * t3 - 0.5 * t2)
}
