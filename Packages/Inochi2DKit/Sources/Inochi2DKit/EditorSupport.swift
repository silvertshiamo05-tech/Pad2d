// Read access and helpers for editor front ends.

import Foundation

/// A copy of a puppet's state for undo. Texture data is shared, not copied.
public struct PuppetSnapshot {
    let json: Data
    let textures: [TextureBlob]
    let extensions: [String: Data]

    /// Approximate memory held by the snapshot itself.
    public var byteCount: Int { json.count }
}

public extension Puppet {
    func snapshot() -> PuppetSnapshot {
        PuppetSnapshot(json: JSONWriter.encode(serializeJSON()), textures: textures, extensions: extensions)
    }

    /// Maps a drawable's rest vertices (minus origin) to the space the draw
    /// list's vertices are in.
    func meshMatrix(_ d: Drawable) -> Mat4 {
        transform.matrix * d.dynamicMatrix()
    }

    /// Vertex positions as drawn this frame (after `update`).
    func drawnPositions(_ d: Drawable) -> [Vec2] {
        d.deformedPositions(puppetMatrix: transform.matrix)
    }

    /// Converts a draw-list-space point to a drawable's mesh space.
    func meshPoint(_ d: Drawable, from p: Vec2) -> Vec2 {
        meshMatrix(d).inverse.apply(p) + d.origin
    }

    /// Converts a draw-list-space movement into a movement in `node`'s parent space,
    /// i.e. the change to apply to its local translation.
    func localDelta(_ node: Node, from delta: Vec2) -> Vec2 {
        let m = (node.parent?.transform().matrix ?? .identity)
        let inv = (transform.matrix * m).inverse
        return inv.apply(delta) - inv.apply(.zero)
    }

    /// Applies a changed physics model and restarts the simulation.
    func applyPhysicsSettings(_ s: SimplePhysics) {
        s.system = s.model == .pendulum ? Pendulum(driver: s) : SpringPendulum(driver: s)
        s.reset()
        scanParts()
    }

    /// Whether `d` has a deform binding on `p`.
    func hasDeformation(_ p: Parameter, _ d: Drawable) -> Bool {
        binding(p, node: d, target: "deform") != nil
    }
}

public extension Puppet {
    /// Copies a node and its children (with new IDs) next to the original,
    /// along with the parameter bindings that drive them.
    @discardableResult
    func duplicate(_ node: Node) -> Node? {
        guard let parent = node.parent else { return nil }
        func reparse(_ j: [String: Any]) -> [String: Any] {
            (try? JSONSerialization.jsonObject(with: JSONWriter.encode(j))) as? [String: Any] ?? [:]
        }
        var used = Set(root.allNodes().map(\.uuid))
        used.formUnion(parameters.map(\.uuid))
        var map: [UInt32: UInt32] = [:]
        func fresh() -> UInt32 {
            while true {
                let id = UInt32.random(in: 1..<UInt32.max)
                if used.insert(id).inserted { return id }
            }
        }
        func renumber(_ j: [String: Any]) -> [String: Any] {
            var j = j
            if let id = j.uint32("uuid") {
                let n = fresh()
                map[id] = n
                j["uuid"] = n
            }
            if let kids = j["children"] as? [[String: Any]] { j["children"] = kids.map(renumber) }
            return j
        }
        func fixMasks(_ j: [String: Any]) -> [String: Any] {
            var j = j
            if let masks = j["masks"] as? [[String: Any]] {
                j["masks"] = masks.map { m -> [String: Any] in
                    var m = m
                    if let s = m.uint32("source"), let n = map[s] { m["source"] = n }
                    return m
                }
            }
            if let kids = j["children"] as? [[String: Any]] { j["children"] = kids.map(fixMasks) }
            return j
        }
        var json = fixMasks(renumber(reparse(node.serialize())))
        json["name"] = node.name + " Copy"
        guard let copy = Node.make(type: node.typeId == "Drawable" ? "Part" : (json.string("type") ?? "Node")) else { return nil }
        copy.deserialize(reparse(json))
        for p in parameters {
            for b in p.bindings {
                guard let n = map[b.nodeRef] else { continue }
                var j = b.serialize()
                j["node"] = n
                j = reparse(j)
                p.bindings.append(b.target == "deform" ? DeformBinding(parameter: p, json: j) : ValueBinding(parameter: p, json: j))
            }
        }
        let i = (parent.children.firstIndex { $0 === node } ?? parent.children.count - 1) + 1
        add(copy, to: parent, at: i)
        return copy
    }
}

public extension Node {
    /// A node's own (unanimated) value for a bindable target.
    func restValue(_ target: String) -> Float {
        let t = localTransform
        switch target {
        case "zSort": return zsort
        case "transform.t.x": return t.translation.x
        case "transform.t.y": return t.translation.y
        case "transform.t.z": return t.translation.z
        case "transform.r.x": return t.rotation.x
        case "transform.r.y": return t.rotation.y
        case "transform.r.z": return t.rotation.z
        case "transform.s.x": return t.scale.x
        case "transform.s.y": return t.scale.y
        default: break
        }
        if let p = self as? Part {
            switch target {
            case "opacity": return p.opacity
            case "tint.r": return p.tint.x
            case "tint.g": return p.tint.y
            case "tint.b": return p.tint.z
            case "screenTint.r": return p.screenTint.x
            case "screenTint.g": return p.screenTint.y
            case "screenTint.b": return p.screenTint.z
            case "alphaThreshold": return p.maskAlphaThreshold
            case "emissionStrength": return p.emissionStrength
            default: break
            }
        }
        if let s = self as? SimplePhysics {
            switch target {
            case "gravity": return s.gravity
            case "length": return s.length
            case "frequency": return s.frequency
            case "angleDamping": return s.angleDamping
            case "lengthDamping": return s.lengthDamping
            case "outputScale.x": return s.outputScale.x
            case "outputScale.y": return s.outputScale.y
            default: break
            }
        }
        return 0
    }

    func setRestValue(_ target: String, _ v: Float) {
        switch target {
        case "zSort": zsort = v
        case "transform.t.x": localTransform.translation.x = v
        case "transform.t.y": localTransform.translation.y = v
        case "transform.t.z": localTransform.translation.z = v
        case "transform.r.x": localTransform.rotation.x = v
        case "transform.r.y": localTransform.rotation.y = v
        case "transform.r.z": localTransform.rotation.z = v
        case "transform.s.x": localTransform.scale.x = v
        case "transform.s.y": localTransform.scale.y = v
        default: break
        }
        if let p = self as? Part {
            switch target {
            case "opacity": p.opacity = v
            case "tint.r": p.tint.x = v
            case "tint.g": p.tint.y = v
            case "tint.b": p.tint.z = v
            case "screenTint.r": p.screenTint.x = v
            case "screenTint.g": p.screenTint.y = v
            case "screenTint.b": p.screenTint.z = v
            case "alphaThreshold": p.maskAlphaThreshold = v
            case "emissionStrength": p.emissionStrength = v
            default: break
            }
        }
        if let s = self as? SimplePhysics {
            switch target {
            case "gravity": s.gravity = v
            case "length": s.length = v
            case "frequency": s.frequency = v
            case "angleDamping": s.angleDamping = v
            case "lengthDamping": s.lengthDamping = v
            case "outputScale.x": s.outputScale.x = v
            case "outputScale.y": s.outputScale.y = v
            default: break
            }
        }
        transformChanged()
    }
}

public extension MaskBinding {
    var sourceID: UInt32 { sourceUUID }
}

public extension Node {
    /// Value-binding targets this node supports, for editors.
    var bindableTargets: [String] {
        var t = ["transform.t.x", "transform.t.y", "transform.r.z", "transform.s.x", "transform.s.y", "zSort"]
        if self is Part {
            t += ["opacity", "tint.r", "tint.g", "tint.b", "screenTint.r", "screenTint.g", "screenTint.b", "alphaThreshold"]
        }
        if self is SimplePhysics {
            t += ["gravity", "length", "frequency", "angleDamping", "lengthDamping", "outputScale.x", "outputScale.y"]
        }
        return t.filter(hasParam)
    }
}

public extension Puppet {
    /// Bakes every mesh group's deformation into its children (export step).
    func applyDeformToChildren() {
        root.beginUpdate()
        root.transformChanged()
        for case let g as MeshGroup in root.allNodes() { g.applyDeformToChildren(parameters) }
        rebuild()
    }

    /// Moves a group-like node's origin to the centre of its contents,
    /// keeping children where they are (Creator's "Recalculate origin").
    func recalculateOrigin(_ node: Node) {
        for c in node.children { recalculateOrigin(c) }
        guard node is MeshGroup || !(node is Drawable), node !== root else { return }
        root.beginUpdate()
        root.transformChanged()
        let worldBefore = node.children.map { $0.transformNoLock().matrix }
        var b: (Float, Float, Float, Float)?
        for c in node.children {
            let cb = c.combinedBounds()
            b = b.map { (Swift.min($0.0, cb.0), Swift.min($0.1, cb.1), Swift.max($0.2, cb.2), Swift.max($0.3, cb.3)) } ?? cb
        }
        guard let bounds = b else { return }
        let center = Vec2((bounds.0 + bounds.2) / 2, (bounds.1 + bounds.3) / 2)
        let parentInv = (node.parent?.transform().matrix ?? .identity).inverse
        let local = parentInv.apply(center)
        let diff = Vec2(local.x - node.localTransform.translation.x, local.y - node.localTransform.translation.y)
        node.localTransform.translation.x = local.x
        node.localTransform.translation.y = local.y
        if let g = node as? MeshGroup {
            g.vertices = g.vertices.map { $0 - diff }
            g.invalidate()
        }
        node.transformChanged()
        for (c, m) in zip(node.children, worldBefore) {
            c.localTransform.translation = Node.relativePosition(node.transformNoLock().matrix, m)
            c.transformChanged()
        }
        rebuild()
    }
}
