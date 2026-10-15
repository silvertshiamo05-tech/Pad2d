// Port of Inochi2D 0.8 MeshGroup (inochi2d.core.nodes.meshgroup).
// Copyright © 2020, Inochi2D Project. Distributed under the 2-Clause BSD License.

import Foundation

struct FilterResult {
    /// Matrix the filtered node should be drawn with instead of its own.
    var matrix: Mat4?
}

/// A mesh that deforms its children: each child vertex follows the triangle
/// of the group's mesh it sits in.
public final class MeshGroup: Drawable {
    private struct Triangle {
        var offsetMatrix: Mat3
        var transformMatrix = Mat3.identity
    }

    private var bitMask: [UInt16] = []
    private var groupBounds = (x: Float(0), y: Float(0), z: Float(0), w: Float(0))
    private var maskWidth = 0
    private var triangles: [Triangle] = []
    private var forwardMatrix = Mat4.identity
    private var inverseMatrix = Mat4.identity
    var translateChildren = true
    public var dynamic = false
    private(set) var isPrecalculated = false

    override public var typeId: String { "MeshGroup" }

    override func deserialize(_ json: [String: Any]) {
        super.deserialize(json)
        dynamic = json.bool("dynamic_deformation") ?? false
        translateChildren = json.bool("translate_children") ?? false
    }

    override func serialize() -> [String: Any] {
        var j = super.serialize()
        j["dynamic_deformation"] = dynamic
        j["translate_children"] = translateChildren
        return j
    }

    /// Forces the triangle lookup to be rebuilt (after the mesh changes).
    func invalidate() {
        isPrecalculated = false
    }

    // The original's postProcess forwards to preProcess (already done by then).
    override func postProcess() {
        super.preProcess()
    }

    override func update() {
        preProcess()
        updateDeform()
        if !indices.isEmpty {
            if !isPrecalculated { precalculate() }
            var transformed = vertices
            for i in transformed.indices where i < deformation.count { transformed[i] += deformation[i] }
            for t in triangles.indices {
                let p1 = transformed[Int(indices[t * 3])]
                let p2 = transformed[Int(indices[t * 3 + 1])]
                let p3 = transformed[Int(indices[t * 3 + 2])]
                triangles[t].transformMatrix = Mat3([p2.x - p1.x, p3.x - p1.x, p1.x,
                                                     p2.y - p1.y, p3.y - p1.y, p1.y,
                                                     0, 0, 1]) * triangles[t].offsetMatrix
            }
            forwardMatrix = transform().matrix
            inverseMatrix = globalTransform.matrix.inverse
        }
        // Node.update (skipping Drawable.update's deformation handling).
        if enabled {
            for c in children { c.update() }
        }
        updateDeform()
    }

    func filterChildren(_ origVertices: [Vec2], _ origDeformation: inout [Vec2], _ origTransform: Mat4) -> FilterResult? {
        guard isPrecalculated else { return nil }
        let center = inverseMatrix * origTransform
        var inv = center.inverse
        inv[0, 3] = 0
        inv[1, 3] = 0
        inv[2, 3] = 0
        let b = groupBounds
        for i in origVertices.indices where i < origDeformation.count {
            let v = origVertices[i]
            let c = center.apply(dynamic ? v + origDeformation[i] : v)
            var index = -1
            if b.x <= c.x && c.x < b.z && b.y <= c.y && c.y < b.w {
                let cell = Int(c.y - b.y) * maskWidth + Int(c.x - b.x)
                if cell >= 0 && cell < bitMask.count { index = Int(bitMask[cell]) - 1 }
            }
            let newPos = index < 0 ? c : triangles[index].transformMatrix.apply(c)
            if dynamic {
                origDeformation[i] = newPos - v
            } else {
                origDeformation[i] += inv.apply(newPos - c)
            }
        }
        return FilterResult(matrix: dynamic ? forwardMatrix : nil)
    }

    func precalculate() {
        guard !indices.isEmpty else {
            triangles = []
            bitMask = []
            return
        }
        func bounds(_ pts: [Vec2]) -> (x: Float, y: Float, z: Float, w: Float) {
            var r = (x: Float.greatestFiniteMagnitude, y: Float.greatestFiniteMagnitude,
                     z: -Float.greatestFiniteMagnitude, w: -Float.greatestFiniteMagnitude)
            for p in pts {
                r = (min(r.x, p.x), min(r.y, p.y), max(r.z, p.x), max(r.w, p.y))
            }
            return (r.x.rounded(.down), r.y.rounded(.down), r.z.rounded(.up), r.w.rounded(.up))
        }
        groupBounds = bounds(vertices)
        triangles = []
        for i in 0..<(indices.count / 3) {
            let p1 = vertices[Int(indices[3 * i])], p2 = vertices[Int(indices[3 * i + 1])]
            let p3 = vertices[Int(indices[3 * i + 2])]
            var axis0 = p2 - p1
            let axis0len = axis0.length
            axis0 = axis0 / axis0len
            var axis1 = p3 - p1
            let axis1len = axis1.length
            axis1 = axis1 / axis1len
            let raxis1 = Mat3([axis0.x, axis0.y, 0, -axis0.y, axis0.x, 0, 0, 0, 1]).apply(axis1)
            let cosA = raxis1.x, sinA = raxis1.y
            let offset = Mat3([axis0len > 0 ? 1 / axis0len : 0, 0, 0,
                               0, axis1len > 0 ? 1 / axis1len : 0, 0,
                               0, 0, 1])
                * Mat3([1, -cosA / sinA, 0, 0, 1 / sinA, 0, 0, 0, 1])
                * Mat3([axis0.x, axis0.y, 0, -axis0.y, axis0.x, 0, 0, 0, 1])
                * Mat3([1, 0, -p1.x, 0, 1, -p1.y, 0, 0, 1])
            triangles.append(Triangle(offsetMatrix: offset))
        }

        let width = Int(groupBounds.z.rounded(.up) - groupBounds.x.rounded(.down) + 1)
        let height = Int(groupBounds.w.rounded(.up) - groupBounds.y.rounded(.down) + 1)
        maskWidth = width
        bitMask = [UInt16](repeating: 0, count: max(0, width * height))
        for i in triangles.indices {
            let tv = [vertices[Int(indices[3 * i])], vertices[Int(indices[3 * i + 1])], vertices[Int(indices[3 * i + 2])]]
            let tb = bounds(tv)
            let bw = Int(tb.z.rounded(.up) - tb.x.rounded(.down) + 1)
            let bh = Int(tb.w.rounded(.up) - tb.y.rounded(.down) + 1)
            let top = Int(tb.y.rounded(.down)), left = Int(tb.x.rounded(.down))
            for y in 0..<bh {
                for x in 0..<bw {
                    let pt = Vec2(Float(left + x), Float(top + y))
                    if isPointInTriangle(pt, tv[0], tv[1], tv[2]) {
                        let local = pt - Vec2(groupBounds.x, groupBounds.y)
                        let cell = Int(local.y * Float(width) + local.x)
                        if cell >= 0 && cell < bitMask.count { bitMask[cell] = UInt16(truncatingIfNeeded: i + 1) }
                    }
                }
            }
        }
        isPrecalculated = true
        for c in children { setupChild(c) }
    }

    override func setupChild(_ child: Node) {
        guard !indices.isEmpty else { return }
        func setGroup(_ node: Node) {
            let isDrawable = node is Drawable
            let isGroup = node is MeshGroup
            let isComposite = (node as? Composite)?.propagateMeshGroup ?? false
            let mustPropagate = (isDrawable && !isGroup) || isComposite
            if translateChildren || isDrawable {
                if isDrawable && dynamic {
                    node.preProcessFilter = nil
                    node.postProcessFilter = self
                } else {
                    node.preProcessFilter = self
                    node.postProcessFilter = nil
                }
            } else {
                node.preProcessFilter = nil
                node.postProcessFilter = nil
            }
            if mustPropagate {
                for c in node.children { setGroup(c) }
            }
        }
        setGroup(child)
    }
}

func isPointInTriangle(_ pt: Vec2, _ p1: Vec2, _ p2: Vec2, _ p3: Vec2) -> Bool {
    func sign(_ a: Vec2, _ b: Vec2, _ c: Vec2) -> Float {
        (a.x - c.x) * (b.y - c.y) - (b.x - c.x) * (a.y - c.y)
    }
    let d1 = sign(pt, p1, p2), d2 = sign(pt, p2, p3), d3 = sign(pt, p3, p1)
    let hasNeg = d1 < 0 || d2 < 0 || d3 < 0
    let hasPos = d1 > 0 || d2 > 0 || d3 > 0
    return !(hasNeg && hasPos)
}
