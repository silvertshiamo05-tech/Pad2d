// Node helpers from Inochi2D 0.8 (inochi2d.core.nodes) used by the editor:
// lock-to-root space conversion, relative positioning, value scaling for
// mirroring, and bounds.
// Copyright © 2020, Inochi2D Project. Distributed under the 2-Clause BSD License.

import Foundation

public extension Node {
    /// The world transform ignoring `lockToRoot` (and parameter offsets).
    func transformNoLock() -> Transform {
        localTransform.update()
        if let p = parent { return localTransform * p.transform() }
        return localTransform
    }

    /// Turns lock-to-root on or off, converting the translation so the node
    /// stays where it is.
    func setLockToRoot(_ value: Bool) {
        if value && !lockToRoot {
            localTransform.translation = transformNoLock().translation
        } else if !value && lockToRoot, let p = parent {
            localTransform.translation = localTransform.translation - p.transformNoLock().translation
        }
        lockToRoot = value
        transformChanged()
    }

    /// The translation part of `m1⁻¹ · m2`.
    static func relativePosition(_ m1: Mat4, _ m2: Mat4) -> Vec3 {
        let cm = m1.inverse * m2
        return Vec3(cm[0, 3], cm[1, 3], cm[2, 3])
    }

    /// Re-expresses this node's position relative to `to` (before reparenting).
    func setRelativeTo(_ to: Node) {
        localTransform.translation = Node.relativePosition(to.transformNoLock().matrix, transformNoLock().matrix)
        localTransform.update()
        zsort = zSortNoOffset - to.zSortNoOffset
    }

    /// Z-sort without parameter offsets.
    var zSortNoOffset: Float { (parent?.zSortNoOffset ?? 0) + relZSort }

    /// Path like "/Root/Head/Eye".
    var nodePath: String {
        var parts: [String] = []
        var n: Node? = self
        while let c = n { parts.insert(c.name, at: 0); n = c.parent }
        return "/" + parts.joined(separator: "/")
    }

    /// Depth in the tree (root = 0).
    var depth: Int {
        var d = 0
        var n = parent
        while let c = n { d += 1; n = c.parent }
        return d
    }

    /// Mirrors a bound value: axis -1 scales everything; for axis 0/1 only
    /// properties aligned with that axis change sign.
    func scaleValue(_ key: String, _ value: Float, axis: Int, scale: Float) -> Float {
        if axis == -1 { return value * scale }
        var v = abs(scale) * value
        switch key {
        case "transform.r.z": v = scale * value
        case "transform.r.y", "transform.t.x": if axis == 0 { v = scale * value }
        case "transform.r.x", "transform.t.y": if axis == 1 { v = scale * value }
        default: break
        }
        return v
    }

    /// The default (rest) value a binding of `key` starts from.
    func bindingDefault(_ key: String) -> Float {
        let d = defaultValue(key)
        return d.isNaN ? 0 : d
    }

    /// Whether `key` can be bound on this node.
    func canBind(_ key: String) -> Bool { key == "deform" ? self is Drawable : hasParam(key) }

    /// World-space bounds (minX, minY, maxX, maxY) of this node and its
    /// children, as drawn this frame. Nodes without meshes count as a point.
    func combinedBounds() -> (Float, Float, Float, Float) {
        var b: (Float, Float, Float, Float)
        if let d = self as? Drawable, !d.vertices.isEmpty {
            let pts = d.deformedPositions(puppetMatrix: .identity)
            b = (pts.map(\.x).min()!, pts.map(\.y).min()!, pts.map(\.x).max()!, pts.map(\.y).max()!)
        } else {
            let o = transform().matrix.origin
            b = (o.x, o.y, o.x, o.y)
        }
        for c in children {
            let cb = c.combinedBounds()
            b = (Swift.min(b.0, cb.0), Swift.min(b.1, cb.1), Swift.max(b.2, cb.2), Swift.max(b.3, cb.3))
        }
        return b
    }
}

extension Vec3 {
    static func - (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x - b.x, a.y - b.y, a.z - b.z) }
}
