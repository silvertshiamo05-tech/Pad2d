// Editing operations for building and rigging puppets, following the
// behaviour of Inochi Creator 0.8 where it matters for file compatibility.

import Foundation

public enum NodeKind: String, CaseIterable, Sendable {
    case node = "Node"
    case part = "Part"
    case composite = "Composite"
    case meshGroup = "MeshGroup"
    case physics = "SimplePhysics"
    case camera = "Camera"

    public var title: String {
        switch self {
        case .node: return "Group"
        case .part: return "Part"
        case .composite: return "Composite"
        case .meshGroup: return "Mesh Group"
        case .physics: return "Physics"
        case .camera: return "Camera"
        }
    }
}

public struct Keypoint: Hashable, Sendable {
    public var x: Int
    public var y: Int
    public init(_ x: Int, _ y: Int) {
        self.x = x
        self.y = y
    }
}

extension Parameter {
    /// Keypoint positions along each axis, normalised 0...1.
    public var axisKeypoints: [[Float]] { axisPoints }

    public var allBindings: [ParameterBinding] { bindings }

    /// The parameter value at a keypoint.
    public func value(at k: Keypoint) -> Vec2 {
        unmapValue(Vec2(axisPoints[0][k.x], isVec2 ? axisPoints[1][k.y] : 0))
    }

    /// The keypoint the current value sits on, if any.
    public var currentKeypoint: Keypoint? {
        let n = mapValue(value)
        guard let x = axisPoints[0].firstIndex(where: { abs($0 - n.x) < 0.002 }) else { return nil }
        if !isVec2 { return Keypoint(x, 0) }
        guard let y = axisPoints[1].firstIndex(where: { abs($0 - n.y) < 0.002 }) else { return nil }
        return Keypoint(x, y)
    }

    /// Keypoint nearest to the current value.
    public var nearestKeypoint: Keypoint {
        let n = mapValue(value)
        func nearest(_ a: [Float], _ v: Float) -> Int {
            a.indices.min { abs(a[$0] - v) < abs(a[$1] - v) } ?? 0
        }
        return Keypoint(nearest(axisPoints[0], n.x.isNaN ? 0 : n.x), isVec2 ? nearest(axisPoints[1], n.y.isNaN ? 0 : n.y) : 0)
    }
}

extension ParameterBinding {
    public func isSet(_ k: Keypoint) -> Bool {
        k.x < isSet.count && k.y < isSet[k.x].count && isSet[k.x][k.y]
    }

    public var isDeform: Bool { self is DeformBinding }

    func reinterpolateAny() {
        // With nothing set, everything returns to the default (rest).
        if !isSet.contains(where: { $0.contains(true) }) {
            for x in isSet.indices { for y in isSet[x].indices { clear(Keypoint(x, y)) } }
            return
        }
        (self as? ValueBinding)?.reinterpolateValues()
        (self as? DeformBinding)?.reinterpolateValues()
    }

    func insertKeypoint(axis: Int, at index: Int) {
        if axis == 0 {
            isSet.insert(Array(repeating: false, count: parameter.axisPoints[1].count), at: index)
        } else {
            for x in isSet.indices { isSet[x].insert(false, at: index) }
        }
    }

    func removeKeypoint(axis: Int, at index: Int) {
        if axis == 0 { isSet.remove(at: index) } else { for x in isSet.indices { isSet[x].remove(at: index) } }
    }
}

public extension Puppet {
    // MARK: IDs

    func newUUID() -> UInt32 {
        var used = Set(root.allNodes().map(\.uuid))
        used.formUnion(parameters.map(\.uuid))
        while true {
            let id = UInt32.random(in: 1..<UInt32.max)
            if !used.contains(id) { return id }
        }
    }

    /// Re-links everything after the node tree changed.
    func rebuild() {
        let all = root.allNodes()
        for n in all {
            n.preProcessFilter = nil
            n.postProcessFilter = nil
            n.overrideTransformMatrix = nil
            n.transformChanged()
            (n as? MeshGroup)?.invalidate()
            if let d = n as? Drawable, d.deformation.count != d.vertices.count {
                d.deformation = Array(repeating: .zero, count: d.vertices.count)
            }
        }
        for n in all {
            if let p = n as? Part { p.masks = resolveMasks(p.masks, puppet: self) }
            if let c = n as? Composite { c.masks = resolveMasks(c.masks, puppet: self) }
            if let s = n as? SimplePhysics, s.param == nil || !parameters.contains(where: { $0 === s.param }) {
                s.setParameter(parameters.first { $0.uuid == s.paramRef })
            }
        }
        let ids = Set(all.map(\.uuid))
        for p in parameters {
            p.bindings.removeAll { !ids.contains($0.nodeRef) }
            for b in p.bindings { b.node = root.find(uuid: b.nodeRef) }
        }
        scanParts()
    }

    // MARK: Nodes

    /// Creates a node of the given kind (not yet in the tree).
    func makeNode(_ kind: NodeKind, name: String) -> Node {
        let n: Node
        switch kind {
        case .node: n = Node()
        case .part: n = Part()
        case .composite: n = Composite()
        case .meshGroup: n = MeshGroup()
        case .physics: n = SimplePhysics()
        case .camera: n = Camera()
        }
        n.uuid = newUUID()
        n.name = name
        if let s = n as? SimplePhysics { s.reset() }
        return n
    }

    /// Adds a node under `parent` (at the end, or at `index`).
    func add(_ node: Node, to parent: Node, at index: Int? = nil) {
        node.parent = parent
        let i = Swift.min(Swift.max(index ?? parent.children.count, 0), parent.children.count)
        parent.children.insert(node, at: i)
        rebuild()
        if let s = node as? SimplePhysics { s.reset() }
    }

    /// Whether `node` may be moved under `parent` (not into itself).
    func canMove(_ node: Node, to parent: Node) -> Bool {
        var p: Node? = parent
        while let c = p {
            if c === node { return false }
            p = c.parent
        }
        return node !== root
    }

    /// Moves a node, keeping where it appears on screen (like Creator's reparent).
    func move(_ node: Node, to parent: Node, at index: Int? = nil) {
        guard canMove(node, to: parent), let old = node.parent else { return }
        let world = node.transform().matrix
        let worldZ = node.zSort - node.offsetSort
        let oldIndex = old.children.firstIndex { $0 === node }
        old.children.removeAll { $0 === node }
        var i = index ?? parent.children.count
        if old === parent, let index, let oldIndex, oldIndex < index { i -= 1 }
        node.parent = parent
        parent.children.insert(node, at: Swift.min(Swift.max(i, 0), parent.children.count))
        // Keep the world position: new local translation = inverse(parent) * world origin.
        parent.transformChanged()
        let p = parent.transform().matrix.inverse.apply(world.origin)
        node.localTransform.translation.x = p.x
        node.localTransform.translation.y = p.y
        node.relZSort = worldZ - (parent.zSort - parent.offsetSort)
        rebuild()
    }

    /// Removes a node and everything under it, with their bindings and masks.
    func remove(_ node: Node) {
        guard node !== root, let parent = node.parent else { return }
        let gone = Set(([node] + node.children.flatMap { $0.allNodes() }).map(\.uuid))
        parent.children.removeAll { $0 === node }
        node.parent = nil
        for n in root.allNodes() {
            if let p = n as? Part { p.masks.removeAll { gone.contains($0.sourceUUID) } }
            if let c = n as? Composite { c.masks.removeAll { gone.contains($0.sourceUUID) } }
        }
        rebuild()
    }

    func setMasks(_ node: Node, sources: [(UInt32, MaskBinding.Mode)]) {
        let m = sources.map { MaskBinding(sourceUUID: $0.0, mode: $0.1, source: nil) }
        if let p = node as? Part { p.masks = resolveMasks(m, puppet: self) }
        if let c = node as? Composite { c.masks = resolveMasks(m, puppet: self) }
        if let c = node as? Composite { c.masks = resolveMasks(m, puppet: self) }
    }

    // MARK: Textures

    /// Adds a texture from premultiplied RGBA8 pixels; returns its slot.
    @discardableResult
    func addTexture(rgba: [UInt8], width: Int, height: Int) -> Int {
        textures.append(TextureBlob(encoding: .tga, data: TGAEncoder.encode(rgba: rgba, width: width, height: height)))
        return textures.count - 1
    }

    /// Creates a part showing a texture, centred on its local origin like
    /// Inochi Creator's inCreateSimplePart. `mesh` is in texture pixels; nil
    /// gives a plain quad.
    func makePart(name: String, textureSlot: Int, width: Int, height: Int, mesh: GeneratedMesh? = nil) -> Part {
        let part = makeNode(.part, name: name) as! Part
        let size = Vec2(Float(width), Float(height))
        let m = mesh ?? MeshGenerator.quad(width: size.x, height: size.y)
        part.vertices = m.points.map { $0 - size * 0.5 }
        part.uvs = m.points.map { Vec2($0.x / size.x, $0.y / size.y) }
        part.indices = m.indices
        part.deformation = Array(repeating: .zero, count: part.vertices.count)
        part.textureIDs = [textureSlot, nil, nil]
        part.meshEdited = true
        return part
    }

    // MARK: Meshes

    /// Affine map from a drawable's rest vertices to its texture coordinates.
    func uvMapping(for d: Drawable) -> (Vec2) -> Vec2 {
        affineFit(from: d.vertices, to: d.uvs) ?? { _ in .zero }
    }

    /// Affine map from texture coordinates to a drawable's rest vertices.
    func positionMapping(for d: Drawable) -> ((Vec2) -> Vec2)? {
        affineFit(from: d.uvs, to: d.vertices)
    }

    /// A new mesh for `d` hugging the opaque pixels of its texture.
    /// - Parameters:
    ///   - rgba: the drawable's texture (any resolution), RGBA8.
    ///   - spacing: vertex spacing in mesh units.
    func autoMesh(_ d: Drawable, rgba: [UInt8], width: Int, height: Int, spacing: Float) -> GeneratedMesh? {
        guard let toPos = positionMapping(for: d), !d.uvs.isEmpty, width > 0, height > 0 else { return nil }
        // Texture area the drawable covers.
        let us = d.uvs.map(\.x), vs = d.uvs.map(\.y)
        let x0 = Swift.max(0, Int((us.min()! * Float(width)).rounded(.down)))
        let y0 = Swift.max(0, Int((vs.min()! * Float(height)).rounded(.down)))
        let x1 = Swift.min(width, Int((us.max()! * Float(width)).rounded(.up)))
        let y1 = Swift.min(height, Int((vs.max()! * Float(height)).rounded(.up)))
        guard x1 > x0, y1 > y0 else { return nil }
        let cw = x1 - x0, ch = y1 - y0
        var crop = [UInt8](repeating: 0, count: cw * ch * 4)
        for y in 0..<ch {
            let src = ((y0 + y) * width + x0) * 4
            crop[(y * cw * 4)..<((y + 1) * cw * 4)] = rgba[src..<(src + cw * 4)]
        }
        // Spacing is given in mesh units; convert to texture pixels.
        let p0 = toPos(Vec2(0, 0)), p1 = toPos(Vec2(1 / Float(width), 0))
        let unitsPerPixel = Swift.max(p0.distance(to: p1), 1e-6)
        let m = MeshGenerator.auto(rgba: crop, width: cw, height: ch, spacing: spacing / unitsPerPixel,
                                   margin: 6 / unitsPerPixel)
        let points = m.points.map { toPos(Vec2((Float(x0) + $0.x) / Float(width), (Float(y0) + $0.y) / Float(height))) }
        return GeneratedMesh(points: points, indices: m.indices)
    }

    /// Replaces a drawable's mesh. Deformations recorded on its bindings are
    /// carried over by interpolating them from the old mesh, and texture
    /// coordinates follow the existing texture placement.
    func setMesh(_ d: Drawable, vertices newVerts: [Vec2], indices newIndices: [UInt16], uvs: [Vec2]? = nil) {
        let oldVerts = d.vertices, oldIdx = d.indices
        let toUV = uvMapping(for: d)
        // Set keypoints are re-sampled onto the new mesh by position (as
        // Inochi Creator does); unset ones are refilled by interpolation.
        var touched: [DeformBinding] = []
        for p in parameters {
            for case let b as DeformBinding in p.bindings where b.node === d {
                for x in b.values.indices {
                    for y in b.values[x].indices {
                        b.values[x][y] = b.isSet[x][y]
                            ? transferDeformation(to: newVerts, from: oldVerts, indices: oldIdx,
                                                  offsets: b.values[x][y], flipHorizontally: false)
                            : Array(repeating: .zero, count: newVerts.count)
                    }
                }
                touched.append(b)
            }
        }
        d.uvs = uvs ?? newVerts.map(toUV)
        d.vertices = newVerts
        d.indices = newIndices
        d.deformation = Array(repeating: .zero, count: newVerts.count)
        d.meshEdited = true
        (d as? MeshGroup)?.invalidate()
        rebuild()
        for b in touched { b.reinterpolateAny() }
    }

    // MARK: Parameters

    @discardableResult
    func createParameter(name: String, isVec2: Bool, min: Vec2 = Vec2(-1, -1), max: Vec2 = Vec2(1, 1),
                         defaults: Vec2 = .zero) -> Parameter {
        let p = Parameter(json: [:])
        p.uuid = newUUID()
        p.name = name
        p.isVec2 = isVec2
        p.min = isVec2 ? min : Vec2(min.x, 0)
        p.max = isVec2 ? max : Vec2(max.x, 1)
        p.defaults = defaults
        p.value = defaults
        p.axisPoints = [[0, 1], isVec2 ? [0, 1] : [0]]
        parameters.append(p)
        scanParts()
        return p
    }

    func deleteParameter(_ p: Parameter) {
        parameters.removeAll { $0 === p }
        for n in root.allNodes() {
            if let s = n as? SimplePhysics, s.param === p { s.setParameter(nil) }
        }
        scanParts()
    }

    func renameParameter(_ p: Parameter, to name: String) { p.name = name }

    /// Changes a parameter's range. Keypoints keep their relative positions.
    func setRange(_ p: Parameter, min: Vec2, max: Vec2, defaults: Vec2) {
        p.min = min
        p.max = max
        p.defaults = Vec2(clamp(defaults.x, Swift.min(min.x, max.x), Swift.max(min.x, max.x)),
                          clamp(defaults.y, Swift.min(min.y, max.y), Swift.max(min.y, max.y)))
        p.value = p.defaults
    }

    /// Adds a keypoint at a normalised position (0...1) on an axis.
    @discardableResult
    func addKeypoint(_ p: Parameter, axis: Int, at offset: Float) -> Int {
        let pts = p.axisPoints[axis]
        if let existing = pts.firstIndex(where: { abs($0 - offset) < 0.002 }) { return existing }
        let index = pts.firstIndex { $0 > offset } ?? pts.count
        p.axisPoints[axis].insert(offset, at: index)
        for b in p.bindings {
            if let v = b as? ValueBinding {
                if axis == 0 { v.values.insert(v.values[Swift.max(index - 1, 0)], at: index) }
                else { for x in v.values.indices { v.values[x].insert(v.values[x][Swift.max(index - 1, 0)], at: index) } }
            } else if let d = b as? DeformBinding {
                if axis == 0 { d.values.insert(d.values[Swift.max(index - 1, 0)], at: index) }
                else { for x in d.values.indices { d.values[x].insert(d.values[x][Swift.max(index - 1, 0)], at: index) } }
            }
            b.insertKeypoint(axis: axis, at: index)
            b.reinterpolateAny()
        }
        return index
    }

    /// Removes an inner keypoint (the ends at 0 and 1 stay).
    func removeKeypoint(_ p: Parameter, axis: Int, index: Int) {
        guard index > 0, index < p.axisPoints[axis].count - 1 else { return }
        p.axisPoints[axis].remove(at: index)
        for b in p.bindings {
            if let v = b as? ValueBinding {
                if axis == 0 { v.values.remove(at: index) } else { for x in v.values.indices { v.values[x].remove(at: index) } }
            } else if let d = b as? DeformBinding {
                if axis == 0 { d.values.remove(at: index) } else { for x in d.values.indices { d.values[x].remove(at: index) } }
            }
            b.removeKeypoint(axis: axis, at: index)
            b.reinterpolateAny()
        }
    }

    // MARK: Bindings

    func binding(_ p: Parameter, node: Node, target: String) -> ParameterBinding? {
        p.bindings.first { $0.node === node && $0.target == target }
    }

    /// Records a deformation of `d` at keypoint `k` (offsets per rest vertex).
    func setDeformation(_ p: Parameter, _ d: Drawable, at k: Keypoint, offsets: [Vec2]) {
        guard offsets.count == d.vertices.count else { return }
        let b: DeformBinding
        if let existing = binding(p, node: d, target: "deform") as? DeformBinding {
            b = existing
        } else {
            b = DeformBinding(parameter: p, node: d, target: "deform")
            setRest(b)
            p.bindings.append(b)
        }
        b.values[k.x][k.y] = offsets
        b.isSet[k.x][k.y] = true
        b.reinterpolateValues()
    }

    /// The recorded deformation of `d` at keypoint `k` (zeros if none).
    func deformation(_ p: Parameter, _ d: Drawable, at k: Keypoint) -> [Vec2] {
        if let b = binding(p, node: d, target: "deform") as? DeformBinding,
           k.x < b.values.count, k.y < b.values[k.x].count, b.values[k.x][k.y].count == d.vertices.count {
            return b.values[k.x][k.y]
        }
        return Array(repeating: .zero, count: d.vertices.count)
    }

    /// Records a value (e.g. "transform.t.x", "opacity") of `node` at keypoint `k`.
    func setValue(_ p: Parameter, _ node: Node, target: String, at k: Keypoint, value: Float) {
        guard node.hasParam(target) else { return }
        let b: ValueBinding
        if let existing = binding(p, node: node, target: target) as? ValueBinding {
            b = existing
        } else {
            b = ValueBinding(parameter: p, node: node, target: target)
            setRest(b)
            p.bindings.append(b)
        }
        b.values[k.x][k.y] = value
        b.isSet[k.x][k.y] = true
        b.reinterpolateValues()
    }

    func value(_ p: Parameter, _ node: Node, target: String, at k: Keypoint) -> Float {
        if let b = binding(p, node: node, target: target) as? ValueBinding { return b.values[k.x][k.y] }
        let d = node.defaultValue(target)
        return d.isNaN ? 0 : d
    }

    /// Clears a keypoint of a binding; the binding goes away when nothing is set.
    func unset(_ b: ParameterBinding, at k: Keypoint) {
        b.unset(k)
    }

    /// Like Inochi Creator's createBinding: a keypoint sitting exactly at
    /// value 0 starts out set to the rest pose.
    private func setRest(_ b: ParameterBinding) {
        let p = b.parameter
        var best: Keypoint?
        var bestDistance = Float.infinity
        for x in p.axisPoints[0].indices {
            for y in p.axisPoints[1].indices {
                let v = p.value(at: Keypoint(x, y))
                let dist = v.x * v.x + v.y * v.y
                if dist < bestDistance { bestDistance = dist; best = Keypoint(x, y) }
            }
        }
        guard let k = best else { return }
        let v = p.value(at: k)
        guard abs(v.x) < 0.001 && abs(v.y) < 0.001 else { return }
        b.isSet[k.x][k.y] = true
    }

    func removeBinding(_ b: ParameterBinding) {
        b.parameter.bindings.removeAll { $0 === b }
    }

    /// Bindings that affect a node.
    func bindings(for node: Node) -> [(Parameter, ParameterBinding)] {
        parameters.flatMap { p in p.bindings.filter { $0.node === node }.map { (p, $0) } }
    }
}

/// Least squares affine fit mapping `from` points onto `to` points.
func affineFit(from: [Vec2], to: [Vec2]) -> ((Vec2) -> Vec2)? {
    var sxx = 0.0, sxy = 0.0, syy = 0.0, sx = 0.0, sy = 0.0, n = 0.0
    var su = (0.0, 0.0, 0.0), sv = (0.0, 0.0, 0.0)
    for (p, t) in zip(from, to) {
        let x = Double(p.x), y = Double(p.y), u = Double(t.x), v = Double(t.y)
        sxx += x * x; sxy += x * y; syy += y * y; sx += x; sy += y; n += 1
        su.0 += x * u; su.1 += y * u; su.2 += u
        sv.0 += x * v; sv.1 += y * v; sv.2 += v
    }
    let m = [[sxx, sxy, sx], [sxy, syy, sy], [sx, sy, n]]
    func d3(_ a: [[Double]]) -> Double {
        a[0][0] * (a[1][1] * a[2][2] - a[1][2] * a[2][1]) - a[0][1] * (a[1][0] * a[2][2] - a[1][2] * a[2][0])
            + a[0][2] * (a[1][0] * a[2][1] - a[1][1] * a[2][0])
    }
    let det = d3(m)
    guard abs(det) > 1e-12 else { return nil }
    func solve(_ r: (Double, Double, Double)) -> (Double, Double, Double) {
        let rr = [r.0, r.1, r.2]
        var out = [0.0, 0.0, 0.0]
        for c in 0..<3 {
            var a = m
            for row in 0..<3 { a[row][c] = rr[row] }
            out[c] = d3(a) / det
        }
        return (out[0], out[1], out[2])
    }
    let a = solve(su), b = solve(sv)
    return { p in Vec2(Float(a.0 * Double(p.x) + a.1 * Double(p.y) + a.2), Float(b.0 * Double(p.x) + b.1 * Double(p.y) + b.2)) }
}

/// Barycentric interpolation of per-vertex values at a point; points outside
/// the mesh take the value of the nearest triangle (clamped).
func interpolateOnMesh(_ p: Vec2, vertices: [Vec2], indices: [UInt16], values: [Vec2]) -> Vec2 {
    guard values.count == vertices.count else { return .zero }
    var best: (Float, Vec2) = (.infinity, .zero)
    var t = 0
    while t + 2 < indices.count {
        let ia = Int(indices[t]), ib = Int(indices[t + 1]), ic = Int(indices[t + 2])
        t += 3
        let a = vertices[ia], b = vertices[ib], c = vertices[ic]
        let v0 = b - a, v1 = c - a, v2 = p - a
        let den = v0.x * v1.y - v1.x * v0.y
        guard abs(den) > 1e-9 else { continue }
        let v = (v2.x * v1.y - v1.x * v2.y) / den
        let w = (v0.x * v2.y - v2.x * v0.y) / den
        let u = 1 - v - w
        let outside = Swift.max(0, -u) + Swift.max(0, -v) + Swift.max(0, -w)
        if outside < best.0 {
            let cu = Swift.max(u, 0), cv = Swift.max(v, 0), cw = Swift.max(w, 0)
            let s = Swift.max(cu + cv + cw, 1e-6)
            best = (outside, values[ia] * (cu / s) + values[ib] * (cv / s) + values[ic] * (cw / s))
            if outside == 0 { break }
        }
    }
    if best.0 == .infinity {
        // No triangles: use the nearest vertex.
        if let i = vertices.indices.min(by: { vertices[$0].distance(to: p) < vertices[$1].distance(to: p) }) { return values[i] }
    }
    return best.1
}
