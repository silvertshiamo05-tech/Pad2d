// Deformation transfer and left/right mirroring, following Inochi Creator
// (viewport/common/mesh.d deformByDeformationBinding, utils/transform.d,
// windows/flipconfig.d).

import Foundation

/// Re-samples a deformation of one mesh onto another mesh by position.
///
/// Each destination vertex is located in a source triangle (or the nearest
/// one), expressed in that triangle's oblique coordinates, and moved with the
/// deformed triangle. With `flipHorizontally` the lookup and result are
/// mirrored across local x = 0, which turns a left-side deformation into the
/// matching right-side one.
public func transferDeformation(to destVertices: [Vec2], from srcVertices: [Vec2], indices: [UInt16],
                                offsets: [Vec2], flipHorizontally: Bool) -> [Vec2] {
    guard offsets.count >= 3, offsets.count == srcVertices.count, indices.count >= 3 else {
        return Array(repeating: .zero, count: destVertices.count)
    }
    let deformed = zip(srcVertices, offsets).map { $0 + $1 }
    let triCount = indices.count / 3

    func sign(_ p1: Vec2, _ p2: Vec2, _ p3: Vec2) -> Float {
        (p1.x - p3.x) * (p2.y - p3.y) - (p2.x - p3.x) * (p1.y - p3.y)
    }
    func contains(_ pt: Vec2, _ t: Int) -> Bool {
        let a = srcVertices[Int(indices[t * 3])], b = srcVertices[Int(indices[t * 3 + 1])], c = srcVertices[Int(indices[t * 3 + 2])]
        let d1 = sign(pt, a, b), d2 = sign(pt, b, c), d3 = sign(pt, c, a)
        let neg = d1 < 0 || d2 < 0 || d3 < 0, pos = d1 > 0 || d2 > 0 || d3 > 0
        return !(neg && pos)
    }
    func nearest(_ pt: Vec2) -> Int {
        var best = 0
        var bestD = Float.infinity
        for t in 0..<triCount {
            for k in 0..<3 {
                let v = srcVertices[Int(indices[t * 3 + k])]
                let d = (pt.x - v.x) * (pt.x - v.x) + (pt.y - v.y) * (pt.y - v.y)
                if d < bestD { bestD = d; best = t }
            }
        }
        return best
    }

    return destVertices.map { v in
        var pt = v
        if flipHorizontally { pt.x = -pt.x }
        let t = (0..<triCount).first { contains(pt, $0) } ?? nearest(pt)
        let i0 = Int(indices[t * 3]), i1 = Int(indices[t * 3 + 1]), i2 = Int(indices[t * 3 + 2])
        let p1 = srcVertices[i0], a0 = srcVertices[i1] - p1, a1 = srcVertices[i2] - p1
        // Solve pt = p1 + s·a0 + t·a1.
        let det = a0.x * a1.y - a1.x * a0.y
        var s: Float = 0, u: Float = 0
        if abs(det) > 1e-12 {
            let d = pt - p1
            s = (d.x * a1.y - a1.x * d.y) / det
            u = (a0.x * d.y - d.x * a0.y) / det
        }
        let q1 = deformed[i0], b0 = deformed[i1] - q1, b1 = deformed[i2] - q1
        var newPos = q1 + b0 * s + b1 * u
        if flipHorizontally { newPos.x = -newPos.x }
        return newPos - v
    }
}

/// Two nodes that mirror each other (e.g. left and right eye).
public struct FlipPair: Equatable {
    public var first: UInt32
    public var second: UInt32

    public init(_ a: UInt32, _ b: UInt32) {
        first = a
        second = b
    }
}

public extension Puppet {
    static let flipConfigKey = "com.inochi2d.creator.FlipConfig"

    /// Mirror pairs, stored like Inochi Creator in the file's extension section.
    var flipPairs: [FlipPair] {
        get {
            guard let data = extensions[Puppet.flipConfigKey],
                  let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
            let ids = Set(root.allNodes().map(\.uuid))
            return list.compactMap { e in
                var a = e.uint32("uuid1").flatMap { ids.contains($0) ? $0 : nil }
                var b = e.uint32("uuid2").flatMap { ids.contains($0) ? $0 : nil }
                if a == nil { swap(&a, &b) }
                guard let first = a else { return nil }
                return FlipPair(first, b ?? .max)
            }
        }
        set {
            if newValue.isEmpty {
                extensions[Puppet.flipConfigKey] = nil
                return
            }
            let list = newValue.map { ["uuid1": $0.first, "uuid2": $0.second] as [String: Any] }
            extensions[Puppet.flipConfigKey] = JSONWriter.encode(list)
        }
    }

    /// The node mirroring `node`, if a complete pair exists.
    func flipPartner(of node: Node) -> Node? {
        for p in flipPairs where p.first != .max && p.second != .max {
            if p.first == node.uuid { return root.find(uuid: p.second) }
            if p.second == node.uuid { return root.find(uuid: p.first) }
        }
        return nil
    }

    /// Pairs nodes whose names differ only by `a` ↔ `b` (e.g. "L"/"R").
    func autoPair(_ a: String, _ b: String) -> [FlipPair] {
        guard !a.isEmpty else { return flipPairs }
        var pairs = flipPairs
        var used = Set(pairs.flatMap { [$0.first, $0.second] })
        let nodes = root.allNodes()
        for n in nodes where !used.contains(n.uuid) && n.name.contains(a) {
            let target = n.name.replacingOccurrences(of: a, with: b)
            if let m = nodes.first(where: { $0 !== n && $0.name == target && !used.contains($0.uuid) }) {
                pairs.append(FlipPair(n.uuid, m.uuid))
                used.insert(n.uuid)
                used.insert(m.uuid)
            }
        }
        return pairs
    }

    /// The binding on the mirror partner of `node` (or `node` itself when it
    /// has no partner and `create` is set), created if needed.
    func mirrorBinding(_ p: Parameter, node: Node, target: String, create: Bool) -> ParameterBinding? {
        let other = flipPartner(of: node) ?? (create ? node : nil)
        guard let other else { return nil }
        if let b = p.binding(node: other, target: target) { return b }
        return create ? p.getOrAddBinding(node: other, target: target) : nil
    }

    /// Inochi Creator's incBindingAutoFlip: sets `dest` at keypoint `k` from
    /// `src` (or from itself) read at the mirrored keypoint position.
    /// - axis: 0 horizontal, 1 vertical, -1 both, 2 no mirroring (plain copy).
    /// - selected: for deforms, only these vertices change.
    func autoFlip(dest: ParameterBinding, src: ParameterBinding?, at k: Keypoint, axis: Int,
                  extrapolate: Bool = true, selected: [Int]? = nil) {
        let source = src ?? dest
        var o = dest.parameter.keypointOffset(k)
        if extrapolate {
            switch axis {
            case 0: o.x = 1 - o.x
            case 1: o.y = 1 - o.y
            case -1: o = Vec2(1 - o.x, 1 - o.y)
            default: break
            }
        }
        if dest is DeformBinding {
            guard let destNode = dest.node as? Drawable, let srcNode = source.node as? Drawable,
                  let srcOffsets = source.interpolatedOffsets(at: o) else { return }
            // Every mirroring case flips horizontally in space, as in Creator.
            var result = transferDeformation(to: destNode.vertices, from: srcNode.vertices, indices: srcNode.indices,
                                             offsets: srcOffsets, flipHorizontally: extrapolate || axis == 0)
            if let selected, let current = dest.offsets(k), current.count == result.count {
                let keep = Set(selected)
                for i in result.indices where !keep.contains(i) { result[i] = current[i] }
            }
            dest.setOffsets(k, result)
        } else if src != nil {
            guard let v = source.interpolatedFloat(at: o) else { return }
            dest.setFloat(k, v)
            if axis == 0 || axis == 1 { dest.scaleValue(at: k, axis: axis, scale: -1) }
        } else if extrapolate {
            dest.extrapolateValue(at: k, axis: axis)
        }
    }

    /// Fills unset keypoints in one half of the parameter from the other half,
    /// using mirror partners (Creator's "Mirrored Autofill").
    func mirroredAutofill(_ p: Parameter, axis: Int, range: ClosedRange<Float>) {
        for b in p.bindings {
            guard let node = b.node,
                  let t = mirrorBinding(p, node: node, target: b.target, create: true) else { continue }
            for k in p.keypoints {
                let off = p.keypointOffset(k)
                let v = axis == 0 ? off.x : off.y
                guard range.contains(v), !t.isSet(k) else { continue }
                autoFlip(dest: t, src: t === b ? nil : b, at: k, axis: axis)
            }
        }
    }

    /// Keypoint "Set from mirror": every binding's keypoint `k` takes the
    /// mirrored value (from its partner when paired, else from itself).
    func setFromMirror(_ p: Parameter, bindings list: [ParameterBinding]? = nil, at k: Keypoint, axis: Int) {
        for b in list ?? p.bindings {
            guard let node = b.node else { continue }
            let partner = mirrorBinding(p, node: node, target: b.target, create: false)
            autoFlip(dest: b, src: partner === b ? nil : partner, at: k, axis: axis)
        }
    }

    /// Pastes a copied parameter's bindings into `p` (all keypoints). With
    /// `flip`, values go to the mirror partners, mirrored horizontally.
    func pasteParameter(_ source: Parameter, into p: Parameter, flip: Bool) {
        for s in source.bindings {
            guard let node = s.node else { continue }
            let target = flip ? (flipPartner(of: node) ?? node) : node
            guard let d = p.getOrAddBinding(node: target, target: s.target) else { continue }
            for k in p.keypoints {
                let o = p.keypointOffset(k)
                let so = flip ? Vec2(1 - o.x, o.y) : o
                if d is DeformBinding {
                    guard let dn = d.node as? Drawable, let sn = s.node as? Drawable,
                          let off = s.interpolatedOffsets(at: so) else { continue }
                    d.setOffsets(k, transferDeformation(to: dn.vertices, from: sn.vertices, indices: sn.indices,
                                                        offsets: off, flipHorizontally: flip))
                } else if let v = s.interpolatedFloat(at: so) {
                    d.setFloat(k, v)
                    if flip { d.scaleValue(at: k, axis: 0, scale: -1) }
                }
            }
        }
    }

    /// Mirrors a drawable's deformation at a keypoint across its own local x = 0.
    func flipDeformation(_ b: ParameterBinding, at k: Keypoint) {
        guard let d = b.node as? Drawable, b.isSet(k), let off = b.offsets(k) else { return }
        b.setOffsets(k, transferDeformation(to: d.vertices, from: d.vertices, indices: d.indices,
                                            offsets: off, flipHorizontally: true))
    }

    /// Pastes one binding's keypoint onto a different node (Creator's
    /// cross-node paste): deforms are re-sampled by position.
    func pasteKeypoint(from src: ParameterBinding, at sk: Keypoint, to dest: ParameterBinding, at dk: Keypoint) {
        if dest is DeformBinding {
            guard let dn = dest.node as? Drawable, let sn = src.node as? Drawable, let off = src.offsets(sk) else { return }
            dest.setOffsets(dk, transferDeformation(to: dn.vertices, from: sn.vertices, indices: sn.indices,
                                                    offsets: off, flipHorizontally: false))
        } else if let v = src.floatValue(sk) {
            dest.setFloat(dk, v)
        }
    }
}
