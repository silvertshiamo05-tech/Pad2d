// Port of the Inochi2D 0.8 node tree (inochi2d.core.nodes).
// Copyright © 2020, Inochi2D Project. Distributed under the 2-Clause BSD License.

import Foundation

/// Base node: a transform in the puppet hierarchy.
public class Node {
    public internal(set) var uuid: UInt32 = 0
    public var name = "Unnamed Node"
    public var enabled = true
    public internal(set) var children: [Node] = []
    public internal(set) weak var parent: Node?
    /// Only set on the root node; other nodes find it through their parents.
    weak var puppetRef: Puppet?

    var relZSort: Float = 0
    /// The node's own z-sort (draw order key; higher draws further back).
    public var zsort: Float {
        get { relZSort }
        set { relZSort = newValue }
    }
    /// Fields from the file that Pad2D doesn't model, kept so saving loses nothing.
    var extraJSON: [String: Any] = [:]
    public var lockToRoot = false

    public var localTransform = Transform()
    var offsetTransform = Transform()
    var offsetSort: Float = 0
    var globalTransform = Transform()
    var recalculateTransform = true

    var preProcessed = false
    var postProcessed = false
    /// Mesh group whose deformation is applied before/after this node updates.
    weak var preProcessFilter: MeshGroup?
    weak var postProcessFilter: MeshGroup?
    var overrideTransformMatrix: Mat4?

    public var typeId: String { "Node" }

    required init() {}

    public var puppet: Puppet? { parent?.puppet ?? puppetRef }

    public var renderEnabled: Bool {
        if let p = parent { return p.renderEnabled ? enabled : false }
        return enabled
    }

    public var zSort: Float { zSortBase + relZSort + offsetSort }
    var zSortBase: Float { parent?.zSort ?? 0 }

    func addChild(_ node: Node) {
        node.parent = self
        children.append(node)
    }

    // MARK: Transforms

    public func transform() -> Transform {
        if recalculateTransform {
            localTransform.update()
            offsetTransform.update()
            let combined = localTransform.calcOffset(offsetTransform)
            if lockToRoot, let root = puppet?.root {
                var rootLocal = root.localTransform
                rootLocal.update()
                globalTransform = combined * rootLocal
            } else if let p = parent {
                globalTransform = combined * p.transform()
            } else {
                globalTransform = combined
            }
            recalculateTransform = false
        }
        return globalTransform
    }

    func transformLocal() -> Transform {
        localTransform.update()
        return localTransform.calcOffset(offsetTransform)
    }

    func transformChanged() {
        recalculateTransform = true
        for c in children { c.transformChanged() }
    }

    /// The matrix used to draw this node this frame.
    func dynamicMatrix() -> Mat4 {
        overrideTransformMatrix ?? transform().matrix
    }

    // MARK: Update cycle

    func beginUpdate() {
        preProcessed = false
        postProcessed = false
        offsetSort = 0
        offsetTransform.clear()
        for c in children { c.beginUpdate() }
    }

    func update() {
        preProcess()
        guard enabled else { return }
        for c in children { c.update() }
        postProcess()
    }

    func preProcess() {
        if preProcessed { return }
        preProcessed = true
        if let group = preProcessFilter {
            overrideTransformMatrix = nil
            let matrix = parent?.transform().matrix ?? .identity
            var deform = [Vec2(offsetTransform.translation.x, offsetTransform.translation.y)]
            let local = [Vec2(localTransform.translation.x, localTransform.translation.y)]
            if group.filterChildren(local, &deform, matrix) != nil {
                offsetTransform.translation = Vec3(deform[0].x, deform[0].y, offsetTransform.translation.z)
                transformChanged()
            }
        }
    }

    func postProcess() {
        if postProcessed { return }
        postProcessed = true
        if let group = postProcessFilter {
            overrideTransformMatrix = nil
            let matrix = parent?.transform().matrix ?? .identity
            var deform = [Vec2(offsetTransform.translation.x, offsetTransform.translation.y)]
            let local = [Vec2(localTransform.translation.x, localTransform.translation.y)]
            if group.filterChildren(local, &deform, matrix) != nil {
                offsetTransform.translation = Vec3(deform[0].x, deform[0].y, offsetTransform.translation.z)
                transformChanged()
                overrideTransformMatrix = transform().matrix
            }
        }
    }

    func finalize() {
        for c in children { c.finalize() }
    }

    func setupChild(_ child: Node) {}

    // MARK: Parameter targets

    func hasParam(_ key: String) -> Bool {
        switch key {
        case "zSort", "transform.t.x", "transform.t.y", "transform.t.z",
             "transform.r.x", "transform.r.y", "transform.r.z", "transform.s.x", "transform.s.y":
            return true
        default:
            return false
        }
    }

    func defaultValue(_ key: String) -> Float {
        switch key {
        case "zSort", "transform.t.x", "transform.t.y", "transform.t.z",
             "transform.r.x", "transform.r.y", "transform.r.z":
            return 0
        case "transform.s.x", "transform.s.y":
            return 1
        default:
            return .nan
        }
    }

    @discardableResult
    func setValue(_ key: String, _ value: Float) -> Bool {
        switch key {
        case "zSort": offsetSort += value
        case "transform.t.x": offsetTransform.translation.x += value
        case "transform.t.y": offsetTransform.translation.y += value
        case "transform.t.z": offsetTransform.translation.z += value
        case "transform.r.x": offsetTransform.rotation.x += value
        case "transform.r.y": offsetTransform.rotation.y += value
        case "transform.r.z": offsetTransform.rotation.z += value
        case "transform.s.x": offsetTransform.scale.x *= value
        case "transform.s.y": offsetTransform.scale.y *= value
        default: return false
        }
        if key != "zSort" { transformChanged() }
        return true
    }

    // MARK: Loading

    func deserialize(_ json: [String: Any]) {
        extraJSON = json
        extraJSON["children"] = nil
        uuid = json.uint32("uuid") ?? 0
        if let n = json.string("name") { name = n }
        enabled = json.bool("enabled") ?? true
        relZSort = json.float("zsort") ?? 0
        if let t = json.object("transform") {
            localTransform = Transform(translation: t.vec3("trans") ?? .zero,
                                       rotation: t.vec3("rot") ?? .zero,
                                       scale: t.vec2("scale") ?? Vec2(1, 1))
        }
        lockToRoot = json.bool("lockToRoot") ?? false
        for case let child as [String: Any] in json.array("children") ?? [] {
            guard let type = child.string("type"), let node = Node.make(type: type) else { continue }
            addChild(node)
            node.deserialize(child)
        }
    }

    // MARK: Saving

    func serialize() -> [String: Any] {
        var j = extraJSON
        j["uuid"] = uuid
        j["name"] = name
        j["type"] = (extraJSON["type"] as? String) ?? typeId
        j["enabled"] = enabled
        j["zsort"] = relZSort
        let t = localTransform
        j["transform"] = ["trans": [t.translation.x, t.translation.y, t.translation.z],
                          "rot": [t.rotation.x, t.rotation.y, t.rotation.z],
                          "scale": [t.scale.x, t.scale.y]] as [String: Any]
        j["lockToRoot"] = lockToRoot
        let kids = children.filter { !($0 is TmpNode) }.map { $0.serialize() }
        j["children"] = kids.isEmpty ? nil : kids
        return j
    }

    static func make(type: String) -> Node? {
        switch type {
        case "Node": return Node()
        case "Tmp": return TmpNode()
        case "Part", "AnimatedPart": return Part()
        case "Composite": return Composite()
        case "MeshGroup": return MeshGroup()
        case "SimplePhysics": return SimplePhysics()
        case "Camera": return Camera()
        default: return nil
        }
    }

    // MARK: Search

    public func find(uuid: UInt32) -> Node? {
        if self.uuid == uuid { return self }
        for c in children {
            if let n = c.find(uuid: uuid) { return n }
        }
        return nil
    }

    public func allNodes() -> [Node] {
        [self] + children.flatMap { $0.allNodes() }
    }
}

/// A temporary node; never saved (inochi2d TmpNode).
public final class TmpNode: Node {
    override public var typeId: String { "Tmp" }
}

/// Inochi Creator's camera (ExCamera): a viewport rectangle used for image
/// and video export.
public final class Camera: Node {
    /// Output size in pixels.
    public var viewport = Vec2(1920, 1080)

    override public var typeId: String { "Camera" }

    override func deserialize(_ json: [String: Any]) {
        super.deserialize(json)
        viewport = json.vec2("viewport") ?? Vec2(1920, 1080)
    }

    override func serialize() -> [String: Any] {
        var j = super.serialize()
        j["viewport"] = [viewport.x, viewport.y]
        return j
    }
}

// MARK: - Drawable

public struct MaskBinding {
    public enum Mode { case mask, dodge }
    var sourceUUID: UInt32
    public var mode: Mode
    weak var source: Drawable?
}

/// A node with a deformable mesh.
public class Drawable: Node {
    public internal(set) var vertices: [Vec2] = []
    public internal(set) var uvs: [Vec2] = []
    public internal(set) var indices: [UInt16] = []
    public internal(set) var origin = Vec2.zero
    /// Per-vertex offsets accumulated this frame.
    public internal(set) var deformation: [Vec2] = []

    override public var typeId: String { "Drawable" }

    override func deserialize(_ json: [String: Any]) {
        super.deserialize(json)
        guard let mesh = json.object("mesh") else { return }
        let v = mesh.floats("verts") ?? []
        vertices = stride(from: 0, to: v.count - 1, by: 2).map { Vec2(v[$0], v[$0 + 1]) }
        let u = mesh.floats("uvs") ?? []
        uvs = stride(from: 0, to: u.count - 1, by: 2).map { Vec2(u[$0], u[$0 + 1]) }
        indices = (mesh["indices"] as? [NSNumber])?.map { $0.uint16Value } ?? []
        origin = mesh.vec2("origin") ?? .zero
        deformation = Array(repeating: .zero, count: vertices.count)
    }

    /// Set when the mesh topology changed, so stale editor metadata isn't saved.
    var meshEdited = false

    override func serialize() -> [String: Any] {
        var j = super.serialize()
        var m = (extraJSON["mesh"] as? [String: Any]) ?? [:]
        if meshEdited { m["grid_axes"] = nil }
        m["verts"] = vertices.flatMap { [$0.x, $0.y] }
        m["uvs"] = uvs.flatMap { [$0.x, $0.y] }
        m["indices"] = indices.map { Int($0) }
        m["origin"] = [origin.x, origin.y]
        j["mesh"] = m
        return j
    }

    /// Adds a deformation (from a parameter binding).
    func pushDeformation(_ offsets: [Vec2]) {
        guard offsets.count == deformation.count else { return }
        for i in deformation.indices { deformation[i] += offsets[i] }
    }

    /// Adds `weight * offsets` without allocating.
    func accumulateDeformation(_ offsets: [Vec2], weight: Float) {
        guard offsets.count == deformation.count, weight != 0 else { return }
        offsets.withUnsafeBufferPointer { src in
            deformation.withUnsafeMutableBufferPointer { dst in
                for i in 0..<dst.count {
                    dst[i].x += src[i].x * weight
                    dst[i].y += src[i].y * weight
                }
            }
        }
    }

    override func beginUpdate() {
        for i in deformation.indices { deformation[i] = .zero }
        super.beginUpdate()
    }

    override func update() {
        preProcess()
        updateDeform()
        super.update()
        updateDeform()
    }

    func updateDeform() {
        postProcess()
    }

    override func preProcess() {
        if preProcessed { return }
        preProcessed = true
        if let group = preProcessFilter {
            overrideTransformMatrix = nil
            if let m = group.filterChildren(vertices, &deformation, transform().matrix)?.matrix {
                overrideTransformMatrix = m
            }
        }
    }

    override func postProcess() {
        if postProcessed { return }
        postProcessed = true
        if let group = postProcessFilter {
            overrideTransformMatrix = nil
            if let m = group.filterChildren(vertices, &deformation, transform().matrix)?.matrix {
                overrideTransformMatrix = m
            }
        }
    }

    /// Final positions (puppet space) of the mesh this frame.
    func deformedPositions(puppetMatrix: Mat4) -> [Vec2] {
        let m = puppetMatrix * dynamicMatrix()
        var out = [Vec2](repeating: .zero, count: vertices.count)
        for i in vertices.indices {
            let d = i < deformation.count ? deformation[i] : .zero
            out[i] = m.apply(vertices[i] - origin + d)
        }
        return out
    }

    func renderMask(dodge: Bool, into list: inout DrawListBuilder) {}
}

// MARK: - Part

public enum BlendMode: Int, CaseIterable, Sendable {
    case normal, multiply, screen, overlay, darken, lighten, colorDodge, linearDodge, addGlow,
         colorBurn, hardLight, softLight, difference, exclusion, subtract, inverse,
         destinationIn, clipToLower, sliceFromLower

    static let names = ["Normal", "Multiply", "Screen", "Overlay", "Darken", "Lighten", "ColorDodge",
                        "LinearDodge", "AddGlow", "ColorBurn", "HardLight", "SoftLight", "Difference",
                        "Exclusion", "Subtract", "Inverse", "DestinationIn", "ClipToLower", "SliceFromLower"]

    init(name: String?) {
        self = BlendMode.names.firstIndex(of: name ?? "").flatMap(BlendMode.init(rawValue:)) ?? .normal
    }

    /// The name used in Inochi2D files.
    public var name: String { BlendMode.names[rawValue] }

    /// A readable name, e.g. "Color Dodge".
    public var title: String {
        name.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
    }
}

/// A textured mesh.
public final class Part: Drawable {
    static let noTexture = UInt32.max

    /// Texture indices for albedo, emissive and bump map (nil when empty).
    public internal(set) var textureIDs: [Int?] = [nil, nil, nil]
    /// The non-empty texture indices in order, as Inochi2D 0.8 loads them
    /// (an empty emissive slot moves the bump map into its place).
    public var textureSlots: [Int] { textureIDs.compactMap { $0 } }
    public internal(set) var masks: [MaskBinding] = []
    public var blendMode = BlendMode.normal
    public var maskAlphaThreshold: Float = 0.5
    public var opacity: Float = 1
    public var emissionStrength: Float = 1
    public var tint = Vec3.one
    public var screenTint = Vec3.zero

    var offsetMaskThreshold: Float = 0
    var offsetOpacity: Float = 1
    var offsetEmissionStrength: Float = 1
    var offsetTint = Vec3.one
    var offsetScreenTint = Vec3.zero

    override public var typeId: String { "Part" }

    override func deserialize(_ json: [String: Any]) {
        super.deserialize(json)
        textureIDs = [nil, nil, nil]
        for (i, item) in (json.array("textures") ?? []).prefix(3).enumerated() {
            guard let n = item as? NSNumber else { continue }
            let id = n.doubleValue
            if id < 0 || id >= Double(Part.noTexture) { continue }
            textureIDs[i] = Int(id)
        }
        opacity = json.float("opacity") ?? 1
        maskAlphaThreshold = json.float("mask_threshold") ?? 0.5
        tint = json.vec3("tint") ?? .one
        screenTint = json.vec3("screenTint") ?? .zero
        blendMode = BlendMode(name: json.string("blend_mode"))
        emissionStrength = json.float("emissionStrength") ?? 1
        masks = parseMasks(json)
    }

    override func serialize() -> [String: Any] {
        var j = super.serialize()
        j["textures"] = textureIDs.map { $0.map { UInt32($0) } ?? Part.noTexture }
        j["blend_mode"] = blendMode.name
        j["tint"] = [tint.x, tint.y, tint.z]
        j["screenTint"] = [screenTint.x, screenTint.y, screenTint.z]
        j["emissionStrength"] = emissionStrength
        j["mask_threshold"] = maskAlphaThreshold
        j["opacity"] = opacity
        writeMasks(masks, into: &j)
        return j
    }

    override func finalize() {
        super.finalize()
        masks = resolveMasks(masks, puppet: puppet)
    }

    override func beginUpdate() {
        offsetMaskThreshold = 0
        offsetOpacity = 1
        offsetTint = .one
        offsetScreenTint = .zero
        offsetEmissionStrength = 1
        super.beginUpdate()
    }

    override func hasParam(_ key: String) -> Bool {
        if super.hasParam(key) { return true }
        return ["alphaThreshold", "opacity", "tint.r", "tint.g", "tint.b",
                "screenTint.r", "screenTint.g", "screenTint.b", "emissionStrength"].contains(key)
    }

    override func defaultValue(_ key: String) -> Float {
        let d = super.defaultValue(key)
        if !d.isNaN { return d }
        switch key {
        case "alphaThreshold": return 0
        case "opacity", "tint.r", "tint.g", "tint.b", "emissionStrength": return 1
        case "screenTint.r", "screenTint.g", "screenTint.b": return 0
        default: return .nan
        }
    }

    override func setValue(_ key: String, _ value: Float) -> Bool {
        if super.setValue(key, value) { return true }
        switch key {
        case "alphaThreshold": offsetMaskThreshold *= value
        case "opacity": offsetOpacity *= value
        case "tint.r": offsetTint.x *= value
        case "tint.g": offsetTint.y *= value
        case "tint.b": offsetTint.z *= value
        case "screenTint.r": offsetScreenTint.x += value
        case "screenTint.g": offsetScreenTint.y += value
        case "screenTint.b": offsetScreenTint.z += value
        case "emissionStrength": offsetEmissionStrength += value
        default: return false
        }
        return true
    }

    var effectiveTint: Vec3 {
        Vec3(offsetTint.x.isNaN ? tint.x : clamp(tint.x * offsetTint.x, 0, 1),
             offsetTint.y.isNaN ? tint.y : clamp(tint.y * offsetTint.y, 0, 1),
             offsetTint.z.isNaN ? tint.z : clamp(tint.z * offsetTint.z, 0, 1))
    }

    var effectiveScreenTint: Vec3 {
        Vec3(offsetScreenTint.x.isNaN ? screenTint.x : clamp(screenTint.x + offsetScreenTint.x, 0, 1),
             offsetScreenTint.y.isNaN ? screenTint.y : clamp(screenTint.y + offsetScreenTint.y, 0, 1),
             offsetScreenTint.z.isNaN ? screenTint.z : clamp(screenTint.z + offsetScreenTint.z, 0, 1))
    }

    var effectiveOpacity: Float { clamp(offsetOpacity * opacity, 0, 1) }

    // MARK: Drawing

    func drawOne(into list: inout DrawListBuilder) {
        guard enabled else { return }
        if !masks.isEmpty {
            list.beginMask(hasMasks: masks.contains { $0.mode == .mask })
            for m in masks { m.source?.renderMask(dodge: m.mode == .dodge, into: &list) }
            list.beginMaskContent()
            drawSelf(into: &list)
            list.endMask()
            return
        }
        drawSelf(into: &list)
    }

    func drawSelf(into list: inout DrawListBuilder) {
        guard let albedo = textureSlots.first else { return }
        let mesh = list.mesh(for: self)
        list.commands.append(.part(PartDraw(
            mesh: mesh,
            albedo: albedo,
            emissive: textureSlots.count > 1 ? textureSlots[1] : nil,
            opacity: effectiveOpacity,
            tint: effectiveTint,
            screenTint: effectiveScreenTint,
            emissionStrength: emissionStrength * offsetEmissionStrength,
            blendMode: blendMode,
            nodeUUID: uuid)))
    }

    override func renderMask(dodge: Bool, into list: inout DrawListBuilder) {
        guard let albedo = textureSlots.first else { return }
        list.commands.append(.maskSource(MaskDraw(
            mesh: list.mesh(for: self), texture: albedo,
            threshold: clamp(offsetMaskThreshold + maskAlphaThreshold, 0, 1), dodge: dodge)))
    }
}

func parseMasks(_ json: [String: Any]) -> [MaskBinding] {
    var out: [MaskBinding] = []
    if let legacy = json.array("masked_by") {
        let mode: MaskBinding.Mode = (json["mask_mode"] as? String) == "DodgeMask"
            || (json["mask_mode"] as? NSNumber)?.intValue == 1 ? .dodge : .mask
        for case let n as NSNumber in legacy {
            out.append(MaskBinding(sourceUUID: n.uint32Value, mode: mode, source: nil))
        }
    }
    for case let m as [String: Any] in json.array("masks") ?? [] {
        guard let src = m.uint32("source") else { continue }
        let modeValue = m["mode"]
        let dodge = (modeValue as? String) == "DodgeMask" || (modeValue as? NSNumber)?.intValue == 1
        out.append(MaskBinding(sourceUUID: src, mode: dodge ? .dodge : .mask, source: nil))
    }
    return out
}

func writeMasks(_ masks: [MaskBinding], into j: inout [String: Any]) {
    j["masked_by"] = nil
    j["mask_mode"] = nil
    j["masks"] = masks.isEmpty ? nil : masks.map {
        ["source": $0.sourceUUID, "mode": $0.mode == .dodge ? "DodgeMask" : "Mask"] as [String: Any]
    }
}

func resolveMasks(_ masks: [MaskBinding], puppet: Puppet?) -> [MaskBinding] {
    masks.compactMap { m in
        guard let d = puppet?.root.find(uuid: m.sourceUUID) as? Drawable else { return nil }
        var r = m
        r.source = d
        return r
    }
}

// MARK: - Composite

/// Renders its parts into an offscreen layer, then blends that layer as one.
public final class Composite: Node {
    public var blendMode = BlendMode.normal
    public var opacity: Float = 1
    public var threshold: Float = 0.5
    public var tint = Vec3.one
    public var screenTint = Vec3.zero
    public internal(set) var masks: [MaskBinding] = []
    /// Whether mesh groups above deform the composite's children.
    public var propagateMeshGroup = true

    var offsetOpacity: Float = 1
    var offsetTint = Vec3.one
    var offsetScreenTint = Vec3.zero
    var subParts: [Part] = []

    override public var typeId: String { "Composite" }

    override func deserialize(_ json: [String: Any]) {
        opacity = json.float("opacity") ?? 1
        threshold = json.float("mask_threshold") ?? 0.5
        tint = json.vec3("tint") ?? .one
        screenTint = json.vec3("screenTint") ?? .zero
        blendMode = BlendMode(name: json.string("blend_mode"))
        masks = parseMasks(json)
        propagateMeshGroup = json.bool("propagate_meshgroup") ?? false
        super.deserialize(json)
    }

    override func serialize() -> [String: Any] {
        var j = super.serialize()
        j["blend_mode"] = blendMode.name
        j["tint"] = [tint.x, tint.y, tint.z]
        j["screenTint"] = [screenTint.x, screenTint.y, screenTint.z]
        j["mask_threshold"] = threshold
        j["opacity"] = opacity
        j["propagate_meshgroup"] = propagateMeshGroup
        writeMasks(masks, into: &j)
        return j
    }

    override func finalize() {
        super.finalize()
        masks = resolveMasks(masks, puppet: puppet)
    }

    override func preProcess() {
        if !propagateMeshGroup { super.preProcess() }
    }

    override func postProcess() {
        if !propagateMeshGroup { super.postProcess() }
    }

    override func beginUpdate() {
        offsetOpacity = 1
        offsetTint = .one
        offsetScreenTint = .zero
        super.beginUpdate()
    }

    override func hasParam(_ key: String) -> Bool {
        if super.hasParam(key) { return true }
        return ["opacity", "tint.r", "tint.g", "tint.b", "screenTint.r", "screenTint.g", "screenTint.b"].contains(key)
    }

    override func defaultValue(_ key: String) -> Float {
        let d = super.defaultValue(key)
        if !d.isNaN { return d }
        switch key {
        case "opacity", "tint.r", "tint.g", "tint.b": return 1
        case "screenTint.r", "screenTint.g", "screenTint.b": return 0
        default: return .nan
        }
    }

    override func setValue(_ key: String, _ value: Float) -> Bool {
        if super.setValue(key, value) { return true }
        switch key {
        case "opacity": offsetOpacity *= value
        case "tint.r": offsetTint.x *= value
        case "tint.g": offsetTint.y *= value
        case "tint.b": offsetTint.z *= value
        case "screenTint.r": offsetScreenTint.x += value
        case "screenTint.g": offsetScreenTint.y += value
        case "screenTint.b": offsetScreenTint.z += value
        default: return false
        }
        return true
    }

    func scanParts() {
        subParts = []
        func recurse(_ node: Node) {
            if let p = node as? Part {
                subParts.append(p)
                for c in p.children { recurse(c) }
            } else {
                for c in node.children { recurse(c) }
            }
        }
        for c in children { recurse(c) }
    }

    func drawOne(into list: inout DrawListBuilder) {
        guard enabled else { return }
        // Higher z-sort draws first (stable).
        subParts = subParts.enumerated().sorted {
            $0.element.zSort != $1.element.zSort ? $0.element.zSort > $1.element.zSort : $0.offset < $1.offset
        }.map(\.element)
        guard !subParts.isEmpty else { return }
        list.commands.append(.beginComposite)
        for p in subParts { p.drawOne(into: &list) }
        list.commands.append(.endComposite)

        if !masks.isEmpty {
            list.beginMask(hasMasks: masks.contains { $0.mode == .mask })
            for m in masks { m.source?.renderMask(dodge: m.mode == .dodge, into: &list) }
            list.beginMaskContent()
            drawSelf(into: &list)
            list.endMask()
            return
        }
        drawSelf(into: &list)
    }

    func drawSelf(into list: inout DrawListBuilder) {
        let t = Vec3(offsetTint.x.isNaN ? tint.x : clamp(tint.x * offsetTint.x, 0, 1),
                     offsetTint.y.isNaN ? tint.y : clamp(tint.y * offsetTint.y, 0, 1),
                     offsetTint.z.isNaN ? tint.z : clamp(tint.z * offsetTint.z, 0, 1))
        let s = Vec3(offsetScreenTint.x.isNaN ? screenTint.x : clamp(screenTint.x + offsetScreenTint.x, 0, 1),
                     offsetScreenTint.y.isNaN ? screenTint.y : clamp(screenTint.y + offsetScreenTint.y, 0, 1),
                     offsetScreenTint.z.isNaN ? screenTint.z : clamp(screenTint.z + offsetScreenTint.z, 0, 1))
        list.commands.append(.compositeBlit(CompositeDraw(
            opacity: clamp(offsetOpacity * opacity, 0, 1), tint: t, screenTint: s, blendMode: blendMode)))
    }
}
