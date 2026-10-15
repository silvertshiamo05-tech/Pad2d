// Keypoint and parameter operations from Inochi2D 0.8 (core/param) that
// Inochi Creator builds its parameter tools on.
// Copyright © 2022, Inochi2D Project. Distributed under the 2-Clause BSD License.

import Foundation

public extension ParameterBinding {
    var owner: Parameter { parameter }

    /// Marks a keypoint as set, keeping its current (interpolated) value.
    func setCurrent(_ k: Keypoint) {
        guard inRange(k) else { return }
        isSet[k.x][k.y] = true
        reinterpolateAny()
    }

    /// Sets a keypoint to the default value and marks it set.
    func reset(_ k: Keypoint) {
        guard inRange(k) else { return }
        clear(k)
        isSet[k.x][k.y] = true
        reinterpolateAny()
    }

    /// Clears a keypoint to the default and marks it unset.
    func unset(_ k: Keypoint) {
        guard inRange(k) else { return }
        clear(k)
        isSet[k.x][k.y] = false
        reinterpolateAny()
    }

    /// Mirrors the value at a keypoint: axis -1 negates everything; 0/1 negate
    /// what lies along that axis (see `Node.scaleValue`).
    func scaleValue(at k: Keypoint, axis: Int, scale: Float) {
        guard inRange(k) else { return }
        if let v = self as? ValueBinding {
            let cur = v.values[k.x][k.y]
            v.values[k.x][k.y] = v.node?.scaleValue(v.target, cur, axis: axis, scale: scale) ?? cur * scale
        } else if let d = self as? DeformBinding {
            let s = axis == -1 ? Vec2(scale, scale) : axis == 0 ? Vec2(scale, 1) : Vec2(1, scale)
            d.values[k.x][k.y] = d.values[k.x][k.y].map { $0 * s }
        }
        isSet[k.x][k.y] = true
        reinterpolateAny()
    }

    /// Fills a keypoint from the mirrored keypoint (same binding), then
    /// mirrors the value.
    func extrapolateValue(at k: Keypoint, axis: Int) {
        guard inRange(k) else { return }
        var o = parameter.keypointOffset(k)
        switch axis {
        case -1: o = Vec2(1 - o.x, 1 - o.y)
        case 0: o.x = 1 - o.x
        default: o.y = 1 - o.y
        }
        setInterpolated(k, from: self, offset: o)
        scaleValue(at: k, axis: axis, scale: -1)
    }

    /// Copies keypoint `src` of this binding to `dest` of `other` (unset stays unset).
    func copyKeypoint(_ src: Keypoint, to other: ParameterBinding, at dest: Keypoint) {
        guard inRange(src), other.inRange(dest) else { return }
        if !isSet(src) {
            other.unset(dest)
            return
        }
        if let a = self as? ValueBinding, let b = other as? ValueBinding {
            b.values[dest.x][dest.y] = a.values[src.x][src.y]
        } else if let a = self as? DeformBinding, let b = other as? DeformBinding {
            guard a.values[src.x][src.y].count == b.values[dest.x][dest.y].count else { return }
            b.values[dest.x][dest.y] = a.values[src.x][src.y]
        } else {
            return
        }
        other.isSet[dest.x][dest.y] = true
        other.reinterpolateAny()
    }

    /// Swaps keypoint `src` of this binding with `dest` of `other`.
    func swapKeypoint(_ src: Keypoint, with other: ParameterBinding, at dest: Keypoint) {
        guard inRange(src), other.inRange(dest) else { return }
        if let a = self as? ValueBinding, let b = other as? ValueBinding {
            (a.values[src.x][src.y], b.values[dest.x][dest.y]) = (b.values[dest.x][dest.y], a.values[src.x][src.y])
        } else if let a = self as? DeformBinding, let b = other as? DeformBinding {
            guard a.values[src.x][src.y].count == b.values[dest.x][dest.y].count else { return }
            (a.values[src.x][src.y], b.values[dest.x][dest.y]) = (b.values[dest.x][dest.y], a.values[src.x][src.y])
        } else {
            return
        }
        (isSet[src.x][src.y], other.isSet[dest.x][dest.y]) = (other.isSet[dest.x][dest.y], isSet[src.x][src.y])
        reinterpolateAny()
        other.reinterpolateAny()
    }

    /// Whether this binding could drive `node` instead (same property or same vertex count).
    func isCompatible(with node: Node) -> Bool {
        if self is DeformBinding {
            guard let a = self.node as? Drawable, let b = node as? Drawable else { return false }
            return a.vertices.count == b.vertices.count
        }
        return node.hasParam(target)
    }

    /// Value of a value binding at a keypoint.
    func floatValue(_ k: Keypoint) -> Float? {
        guard inRange(k), let v = self as? ValueBinding else { return nil }
        return v.values[k.x][k.y]
    }

    /// Offsets of a deform binding at a keypoint.
    func offsets(_ k: Keypoint) -> [Vec2]? {
        guard inRange(k), let d = self as? DeformBinding else { return nil }
        return d.values[k.x][k.y]
    }

    /// Sets a value binding's keypoint.
    func setFloat(_ k: Keypoint, _ value: Float) {
        guard inRange(k), let v = self as? ValueBinding else { return }
        v.values[k.x][k.y] = value
        isSet[k.x][k.y] = true
        reinterpolateAny()
    }

    /// Sets a deform binding's keypoint.
    func setOffsets(_ k: Keypoint, _ offsets: [Vec2]) {
        guard inRange(k), let d = self as? DeformBinding else { return }
        d.values[k.x][k.y] = offsets
        isSet[k.x][k.y] = true
        reinterpolateAny()
    }

    /// The binding's value at a normalised parameter position (value bindings).
    func interpolatedFloat(at offset: Vec2) -> Float? {
        guard let v = self as? ValueBinding else { return nil }
        let (index, sub) = parameter.findOffset(offset)
        var r: Float = 0
        for (x, y, w) in weights(index, sub) where w != 0 { r += v.values[x][y] * w }
        return r
    }

    /// The binding's offsets at a normalised parameter position (deform bindings).
    func interpolatedOffsets(at offset: Vec2) -> [Vec2]? {
        guard let d = self as? DeformBinding, let first = d.values.first?.first else { return nil }
        let (index, sub) = parameter.findOffset(offset)
        var r = [Vec2](repeating: .zero, count: first.count)
        for (x, y, w) in weights(index, sub) where w != 0 {
            let cell = d.values[x][y]
            guard cell.count == r.count else { continue }
            for i in r.indices { r[i] += cell[i] * w }
        }
        return r
    }

    /// Reverses the keypoint grid along an axis.
    internal func reverseAxis(_ axis: Int) {
        if axis == 0 {
            isSet.reverse()
            (self as? ValueBinding)?.values.reverse()
            (self as? DeformBinding)?.values.reverse()
        } else {
            for i in isSet.indices { isSet[i].reverse() }
            if let v = self as? ValueBinding { for i in v.values.indices { v.values[i].reverse() } }
            if let d = self as? DeformBinding { for i in d.values.indices { d.values[i].reverse() } }
        }
    }

    internal func inRange(_ k: Keypoint) -> Bool {
        k.x >= 0 && k.y >= 0 && k.x < isSet.count && k.y < isSet[k.x].count
    }

    internal func clear(_ k: Keypoint) {
        if let v = self as? ValueBinding {
            v.values[k.x][k.y] = v.node?.bindingDefault(v.target) ?? 0
        } else if let d = self as? DeformBinding {
            let n = (d.node as? Drawable)?.vertices.count ?? d.values[k.x][k.y].count
            d.values[k.x][k.y] = Array(repeating: .zero, count: n)
        }
    }

    /// Sets keypoint `k` to `source`'s value at a normalised position.
    internal func setInterpolated(_ k: Keypoint, from source: ParameterBinding, offset: Vec2) {
        if self is ValueBinding, let v = source.interpolatedFloat(at: offset) {
            setFloat(k, v)
        } else if self is DeformBinding, let o = source.interpolatedOffsets(at: offset) {
            setOffsets(k, o)
        }
    }
}

public extension Parameter {
    /// Normalised position of a keypoint.
    func keypointOffset(_ k: Keypoint) -> Vec2 {
        Vec2(axisPoints[0][Swift.min(k.x, axisPoints[0].count - 1)],
             isVec2 ? axisPoints[1][Swift.min(k.y, axisPoints[1].count - 1)] : 0)
    }

    /// All keypoints of the grid.
    var keypoints: [Keypoint] {
        axisPoints[0].indices.flatMap { x in axisPoints[1].indices.map { Keypoint(x, $0) } }
    }

    /// The binding for a node and target, if any.
    func binding(node: Node, target: String) -> ParameterBinding? {
        bindings.first { $0.node === node && $0.target == target }
    }

    /// Creates (and adds) a binding; the keypoint at value 0, if any, starts set to rest.
    @discardableResult
    func getOrAddBinding(node: Node, target: String) -> ParameterBinding? {
        if let b = binding(node: node, target: target) { return b }
        guard node.canBind(target) else { return nil }
        let b: ParameterBinding = target == "deform"
            ? DeformBinding(parameter: self, node: node, target: target)
            : ValueBinding(parameter: self, node: node, target: target)
        let k = nearestKeypoint(to: .zero)
        let v = value(at: k)
        if abs(v.x) < 0.001 && abs(v.y) < 0.001 { b.isSet[k.x][k.y] = true }
        bindings.append(b)
        return b
    }

    /// Keypoint nearest a parameter value.
    func nearestKeypoint(to v: Vec2) -> Keypoint {
        let n = mapValue(v)
        func nearest(_ a: [Float], _ x: Float) -> Int { a.indices.min { abs(a[$0] - x) < abs(a[$1] - x) } ?? 0 }
        return Keypoint(nearest(axisPoints[0], n.x.isNaN ? 0 : n.x), isVec2 ? nearest(axisPoints[1], n.y.isNaN ? 0 : n.y) : 0)
    }

    /// Reverses an axis: keypoints mirror to `1 - p` and every binding's grid
    /// flips with them (values keep their sign).
    func reverseAxis(_ axis: Int) {
        axisPoints[axis] = axisPoints[axis].reversed().map { 1 - $0 }
        for b in bindings { b.reverseAxis(axis) }
    }

    /// Negates every set keypoint along an axis (Creator's "Mirror").
    func mirrorAll(axis: Int) {
        for b in bindings {
            for k in keypoints where b.isSet(k) { b.scaleValue(at: k, axis: axis, scale: -1) }
        }
    }
}

public extension Puppet {
    func parameter(uuid: UInt32) -> Parameter? { parameters.first { $0.uuid == uuid } }

    /// Copies a parameter with all its bindings (named "… (Copy)").
    @discardableResult
    func duplicateParameter(_ p: Parameter) -> Parameter {
        let n = Parameter(json: [:])
        n.uuid = newUUID()
        n.name = p.name + " (Copy)"
        n.isVec2 = p.isVec2
        n.min = p.min
        n.max = p.max
        n.defaults = p.defaults
        n.value = p.defaults
        n.axisPoints = p.axisPoints
        n.mergeMode = p.mergeMode
        n.groupUUID = p.groupUUID
        for b in p.bindings {
            guard let node = b.node else { continue }
            let c: ParameterBinding = b is DeformBinding
                ? DeformBinding(parameter: n, node: node, target: b.target)
                : ValueBinding(parameter: n, node: node, target: b.target)
            c.interpolation = b.interpolation
            n.bindings.append(c)
            for k in p.keypoints { b.copyKeypoint(k, to: c, at: k) }
        }
        let i = (parameters.firstIndex { $0 === p } ?? parameters.count - 1) + 1
        parameters.insert(n, at: i)
        scanParts()
        return n
    }

    /// Turns a 1D parameter into a 2D one (same UUID); values go to the first row.
    @discardableResult
    func convertTo2D(_ p: Parameter) -> Parameter? {
        guard !p.isVec2, let i = parameters.firstIndex(where: { $0 === p }) else { return nil }
        let n = Parameter(json: [:])
        n.uuid = p.uuid
        n.name = p.name
        n.isVec2 = true
        n.min = Vec2(p.min.x, p.min.x)
        n.max = Vec2(p.max.x, p.max.x)
        n.defaults = Vec2(p.defaults.x, p.min.x)
        n.value = n.defaults
        n.groupUUID = p.groupUUID
        n.mergeMode = p.mergeMode
        n.axisPoints = [p.axisPoints[0], [0, 1]]
        for b in p.bindings {
            guard let node = b.node else { continue }
            let c: ParameterBinding = b is DeformBinding
                ? DeformBinding(parameter: n, node: node, target: b.target)
                : ValueBinding(parameter: n, node: node, target: b.target)
            c.interpolation = b.interpolation
            n.bindings.append(c)
            for x in p.axisPoints[0].indices { b.copyKeypoint(Keypoint(x, 0), to: c, at: Keypoint(x, 0)) }
        }
        parameters[i] = n
        for node in root.allNodes() {
            if let s = node as? SimplePhysics, s.param === p { s.setParameter(n) }
        }
        for a in animations.values { a.finalize(self) }
        for a in automation { a.finalize(self) }
        scanParts()
        return n
    }

    /// Moves the bindings of `nodes` to a new parameter "… (Split)" inserted after `p`.
    @discardableResult
    func splitParameter(_ p: Parameter, moving nodes: [Node]) -> Parameter? {
        let ids = Set(nodes.map { ObjectIdentifier($0) })
        let moving = p.bindings.filter { b in b.node.map { ids.contains(ObjectIdentifier($0)) } ?? false }
        guard !moving.isEmpty, let i = parameters.firstIndex(where: { $0 === p }) else { return nil }
        let n = Parameter(json: [:])
        n.uuid = newUUID()
        n.name = p.name + " (Split)"
        n.isVec2 = p.isVec2
        n.min = p.min
        n.max = p.max
        n.defaults = p.defaults
        n.value = p.value
        n.axisPoints = p.axisPoints
        n.groupUUID = p.groupUUID
        n.mergeMode = p.mergeMode
        for b in moving {
            guard let node = b.node else { continue }
            let c: ParameterBinding = b is DeformBinding
                ? DeformBinding(parameter: n, node: node, target: b.target)
                : ValueBinding(parameter: n, node: node, target: b.target)
            c.interpolation = b.interpolation
            n.bindings.append(c)
            for k in p.keypoints { b.copyKeypoint(k, to: c, at: k) }
        }
        p.bindings.removeAll { b in moving.contains { $0 === b } }
        parameters.insert(n, at: i + 1)
        scanParts()
        return n
    }

    /// Replaces a parameter's keypoint positions on one axis. `points` are the
    /// new interior positions (0 < p < 1) paired with the index they had
    /// before, or nil for new ones. Removed keypoints are deleted.
    func setAxisPoints(_ p: Parameter, axis: Int, interior points: [(position: Float, original: Int?)]) {
        let old = p.axisPoints[axis]
        let kept = Set(points.compactMap(\.original))
        // Delete removed points, highest index first.
        for i in (1..<(old.count - 1)).reversed() where !kept.contains(i) {
            removeKeypoint(p, axis: axis, index: i)
        }
        // Move kept points (their order is preserved by the editor's clamping).
        let survivors = (1..<(old.count - 1)).filter { kept.contains($0) }
        for (newIndex, oldIndex) in survivors.enumerated() {
            if let pos = points.first(where: { $0.original == oldIndex })?.position {
                p.axisPoints[axis][newIndex + 1] = pos
            }
        }
        // Add new points.
        for pt in points where pt.original == nil && pt.position > 0 && pt.position < 1 {
            addKeypoint(p, axis: axis, at: pt.position)
        }
        for b in p.bindings { b.reinterpolateAny() }
    }

    // MARK: Groups

    @discardableResult
    func addGroup(name: String) -> ParameterGroup {
        var used = Set(groups.map(\.uuid))
        used.formUnion(parameters.map(\.uuid))
        var id = UInt32.random(in: 1..<UInt32.max)
        while used.contains(id) { id = UInt32.random(in: 1..<UInt32.max) }
        let g = ParameterGroup(uuid: id, name: name, color: nil)
        groups.append(g)
        return g
    }

    /// Deletes a group; its parameters become ungrouped.
    func removeGroup(_ g: ParameterGroup) {
        for p in parameters where p.groupUUID == g.uuid { p.groupUUID = nil }
        groups.removeAll { $0 === g }
    }

    /// Moves a parameter in the list.
    func moveParameter(_ p: Parameter, to index: Int) {
        guard let i = parameters.firstIndex(where: { $0 === p }) else { return }
        parameters.remove(at: i)
        parameters.insert(p, at: Swift.min(Swift.max(index, 0), parameters.count))
    }
}
