import SwiftUI
import MetalKit
import simd
import Inochi2DKit

/// Everything the editor knows about the puppet being edited.
///
/// The puppet itself is the source of truth; views read it directly and
/// refresh when `revision` changes. Every finished change is committed as a
/// snapshot for undo.
@MainActor
final class EditorModel: ObservableObject, RenderSource {
    enum State: Equatable {
        case loading
        case ready
        case failed(String)
    }

    enum Mode: String, CaseIterable, Identifiable {
        case layout, mesh
        var id: String { rawValue }
        var title: String { self == .layout ? "Model" : "Mesh" }
    }

    enum Tool: String, CaseIterable, Identifiable {
        case select, move, brush
        var id: String { rawValue }
        var title: String {
            switch self {
            case .select: return "Select"
            case .move: return "Move"
            case .brush: return "Deform"
            }
        }
        var icon: String {
            switch self {
            case .select: return "cursorarrow.rays"
            case .move: return "arrow.up.and.down.and.arrow.left.and.right"
            case .brush: return "paintbrush.pointed"
            }
        }
    }

    enum MeshTool: String, CaseIterable, Identifiable {
        case edit, delete
        var id: String { rawValue }
        var title: String { self == .edit ? "Add / Move" : "Delete" }
        var icon: String { self == .edit ? "plus.circle" : "minus.circle" }
    }

    @Published private(set) var state = State.loading
    @Published private(set) var revision = 0
    @Published var background: BackgroundStyle = .checker
    @Published private(set) var mode = Mode.layout
    @Published var tool = Tool.select
    @Published var meshTool = MeshTool.edit
    @Published var showWireframe = true
    @Published var brushRadius: Float = 80 // points on screen
    @Published var brushStrength: Float = 1
    @Published var meshSpacing: Float = 64
    @Published var physicsPreview = false {
        didSet {
            puppet?.enableDrivers = physicsPreview
            puppet?.resetDrivers()
        }
    }
    @Published var message: String?
    @Published private(set) var dirty = false
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var saving = false
    @Published private(set) var selectedID: UInt32?
    @Published private(set) var armedID: UInt32?

    private(set) var url: URL
    let name: String
    private(set) var puppet: Puppet?
    private var textures: [MTLTexture?] = []
    private var previews: [TexturePreview?] = []
    private var textureKeys: [Int] = []

    // Undo
    private var current: PuppetSnapshot?
    private var undoStack: [PuppetSnapshot] = []
    private var redoStack: [PuppetSnapshot] = []
    private var pendingCommit = false

    // Camera
    var zoom: CGFloat = 1
    var pan = CGPoint.zero
    private var bounds: (Float, Float, Float, Float)?
    private var viewSize = CGSize(width: 1, height: 1)
    var contentScale: CGFloat = 2
    private var lastList: DrawList?

    // Gestures
    private var drag: DragState?
    private var brushPoint: Vec2? // pixels
    private struct DragState {
        var start: Vec2 // model space
        var startPixels: Vec2
        var node: Node?
        var startTranslation = Vec3.zero
        var startOffsets: [Vec2] = []
        var weights: [Float] = []
        var meshVertex: Int?
        var startValues: (Float, Float) = (0, 0)
    }

    // Mesh editing
    @Published private(set) var meshVertices: [Vec2] = []
    private(set) var meshIndices: [UInt16] = []
    @Published private(set) var meshTarget: UInt32?
    private var meshDirty = false

    init(url: URL) {
        self.url = url
        name = url.deletingPathExtension().lastPathComponent
    }

    // MARK: Loading

    func load() async {
        state = .loading
        let url = self.url
        let device = GPU.device, queue = GPU.queue
        do {
            let (puppet, result) = try await Task.detached(priority: .userInitiated) {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let puppet = try Puppet(contentsOf: url)
                let textures = try TextureLoader(device: device, queue: queue).load(puppet.textures, previews: true)
                return (puppet, textures)
            }.value
            install(puppet)
            textures = result.textures
            previews = result.previews
            textureKeys = puppet.textures.map(Self.key)
            if result.scale < 0.999 {
                message = "Textures are shown at \(Int(result.scale * 100))% to fit this iPad's memory. Saving keeps the originals."
            }
            fitCamera()
            current = puppet.snapshot()
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Loads a puppet that was just created (e.g. from a PSD).
    func loadNew(_ puppet: Puppet) {
        install(puppet)
        syncTextures()
        fitCamera()
        current = puppet.snapshot()
        dirty = true
        state = .ready
    }

    private func install(_ puppet: Puppet) {
        self.puppet = puppet
        puppet.enableDrivers = physicsPreview
        puppet.renderParameters = mode != .mesh
    }

    private func fitCamera() {
        guard let puppet else { return }
        puppet.update(deltaTime: 0)
        bounds = puppet.draw().bounds
        if bounds == nil { bounds = (-500, -500, 500, 500) }
    }

    private static func key(_ blob: TextureBlob) -> Int {
        var h = Hasher()
        h.combine(blob.data.count)
        h.combine(blob.data.prefix(64))
        h.combine(blob.data.suffix(64))
        return h.finalize()
    }

    /// Uploads textures that were added or replaced since the last sync.
    private func syncTextures() {
        guard let puppet else { return }
        let loader = TextureLoader(device: GPU.device, queue: GPU.queue)
        for (i, blob) in puppet.textures.enumerated() {
            let k = Self.key(blob)
            if i < textureKeys.count && textureKeys[i] == k { continue }
            let (tex, preview) = (try? loader.loadOne(blob)) ?? (nil, nil)
            if i < textures.count {
                textures[i] = tex
                previews[i] = preview
                textureKeys[i] = k
            } else {
                textures.append(tex)
                previews.append(preview)
                textureKeys.append(k)
            }
        }
    }

    // MARK: Lookup

    var selected: Node? { selectedID.flatMap { puppet?.root.find(uuid: $0) } }
    var armed: Parameter? { armedID.flatMap { id in puppet?.parameters.first { $0.uuid == id } } }

    /// The keypoint being recorded, when a parameter is armed and sits on one.
    var armedKeypoint: Keypoint? { armed?.currentKeypoint }

    func select(_ node: Node?) {
        guard node?.uuid != selectedID else { return }
        if mode == .mesh { exitMeshMode(apply: true) }
        selectedID = node?.uuid
    }

    // MARK: Changes and undo

    /// Call after changing the puppet. `commit` false for continuous edits
    /// (slider drags), followed by `commitPending()` when they end.
    func changed(commit: Bool = true) {
        revision &+= 1
        dirty = true
        pendingCommit = true
        if commit { commitPending() }
    }

    func commitPending() {
        guard pendingCommit, let puppet else { return }
        pendingCommit = false
        if let current { undoStack.append(current) }
        current = puppet.snapshot()
        redoStack.removeAll()
        // Keep undo history within ~120 MB and 60 steps.
        var total = undoStack.reduce(0) { $0 + $1.byteCount }
        while undoStack.count > 60 || (total > 120 << 20 && undoStack.count > 1) {
            total -= undoStack.removeFirst().byteCount
        }
        updateUndoFlags()
    }

    func undo() {
        commitPending()
        guard let prev = undoStack.popLast(), let cur = current else { return }
        redoStack.append(cur)
        restore(prev)
    }

    func redo() {
        commitPending()
        guard let next = redoStack.popLast(), let cur = current else { return }
        undoStack.append(cur)
        restore(next)
    }

    private func restore(_ snap: PuppetSnapshot) {
        let values = Dictionary((puppet?.parameters ?? []).map { ($0.uuid, $0.value) }, uniquingKeysWith: { a, _ in a })
        guard let p = try? Puppet(snapshot: snap) else { return }
        for param in p.parameters { if let v = values[param.uuid] { param.value = v } }
        if mode == .mesh { mode = .layout; meshTarget = nil }
        install(p)
        current = snap
        syncTextures()
        if let id = selectedID, p.root.find(uuid: id) == nil { selectedID = nil }
        if let id = armedID, !p.parameters.contains(where: { $0.uuid == id }) { armedID = nil }
        revision &+= 1
        dirty = true
        updateUndoFlags()
    }

    private func updateUndoFlags() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    // MARK: Saving

    /// Bundled samples are saved as a copy in the library.
    private var saveURL: URL {
        if url.path.hasPrefix(Bundle.main.bundleURL.path) {
            return ModelLibrary.importedDirectory.appendingPathComponent(name + ".inx")
        }
        return url
    }

    func save() async -> Bool {
        if mode == .mesh { exitMeshMode(apply: true) }
        commitPending()
        guard let puppet else { return false }
        saving = true
        defer { saving = false }
        let data = puppet.fileData()
        let dest = saveURL
        do {
            try await Task.detached(priority: .userInitiated) {
                try data.write(to: dest, options: .atomic)
            }.value
            url = dest
            dirty = false
            return true
        } catch {
            message = "Couldn't save: \(error.localizedDescription)"
            return false
        }
    }

    func exportData() -> Data? {
        commitPending()
        return puppet?.fileData()
    }

    // MARK: Rendering

    func renderFrame(deltaTime dt: Double, viewSize size: CGSize) -> RenderFrame? {
        guard let puppet, state == .ready else { return nil }
        viewSize = size
        puppet.update(deltaTime: physicsPreview ? dt : 0)
        let list = puppet.draw()
        lastList = list
        return RenderFrame(list: list, viewProjection: viewProjection(size),
                           preservePixels: puppet.meta.preservePixels, textures: textures,
                           overlay: buildOverlay(puppet, size))
    }

    private var scale: Float {
        guard let b = bounds else { return 1 }
        let w = CGFloat(b.2 - b.0), h = CGFloat(b.3 - b.1)
        guard w > 0, h > 0 else { return 1 }
        return Float(min(viewSize.width / w, viewSize.height / h) * 0.9 * zoom)
    }

    private var center: Vec2 {
        let b = bounds ?? (-500, -500, 500, 500)
        return Vec2((b.0 + b.2) / 2, (b.1 + b.3) / 2)
    }

    private func viewProjection(_ size: CGSize) -> simd_float4x4 {
        let c = center, s = scale
        let w = Float(size.width), h = Float(size.height)
        let px = Float(pan.x), py = Float(pan.y)
        return simd_float4x4(columns: (
            SIMD4(2 * s / w, 0, 0, 0),
            SIMD4(0, -2 * s / h, 0, 0),
            SIMD4(0, 0, 1, 0),
            SIMD4((-c.x * s + px) * 2 / w, -(-c.y * s + py) * 2 / h, 0, 1)))
    }

    /// Model space -> drawable pixels.
    func toPixels(_ p: Vec2) -> Vec2 {
        let s = scale, c = center
        return Vec2((p.x - c.x) * s + Float(pan.x) + Float(viewSize.width) / 2,
                    (p.y - c.y) * s + Float(pan.y) + Float(viewSize.height) / 2)
    }

    /// Drawable pixels -> model space.
    func toModel(_ p: Vec2) -> Vec2 {
        let s = scale, c = center
        return Vec2((p.x - Float(pan.x) - Float(viewSize.width) / 2) / s + c.x,
                    (p.y - Float(pan.y) - Float(viewSize.height) / 2) / s + c.y)
    }

    func resetView() {
        zoom = 1
        pan = .zero
    }

    // MARK: Overlay

    private struct OverlayBuilder {
        var verts: [OverlayVertex] = []
        let w: Float, h: Float

        func ndc(_ p: Vec2) -> SIMD2<Float> { SIMD2(p.x / w * 2 - 1, 1 - p.y / h * 2) }

        mutating func line(_ a: Vec2, _ b: Vec2, _ width: Float, _ color: SIMD4<Float>) {
            let d = b - a
            let len = d.length
            guard len > 0.01 else { return }
            let n = Vec2(-d.y / len, d.x / len) * (width / 2)
            let q = [a + n, a - n, b + n, b - n].map { ndc($0) }
            for i in [0, 1, 2, 2, 1, 3] { verts.append(OverlayVertex(position: q[i], color: color)) }
        }

        mutating func dot(_ c: Vec2, _ r: Float, _ color: SIMD4<Float>) {
            let n = 8
            let center = ndc(c)
            for i in 0..<n {
                let a0 = Float(i) / Float(n) * 2 * .pi, a1 = Float(i + 1) / Float(n) * 2 * .pi
                verts.append(OverlayVertex(position: center, color: color))
                verts.append(OverlayVertex(position: ndc(c + Vec2(cos(a0), sin(a0)) * r), color: color))
                verts.append(OverlayVertex(position: ndc(c + Vec2(cos(a1), sin(a1)) * r), color: color))
            }
        }

        mutating func circle(_ c: Vec2, _ r: Float, _ width: Float, _ color: SIMD4<Float>) {
            let n = 48
            for i in 0..<n {
                let a0 = Float(i) / Float(n) * 2 * .pi, a1 = Float(i + 1) / Float(n) * 2 * .pi
                line(c + Vec2(cos(a0), sin(a0)) * r, c + Vec2(cos(a1), sin(a1)) * r, width, color)
            }
        }

        mutating func mesh(_ pts: [Vec2], _ indices: [UInt16], _ width: Float, _ color: SIMD4<Float>) {
            var seen = Set<UInt32>()
            var t = 0
            while t + 2 < indices.count {
                let tri = [Int(indices[t]), Int(indices[t + 1]), Int(indices[t + 2])]
                for (a, b) in [(tri[0], tri[1]), (tri[1], tri[2]), (tri[2], tri[0])] {
                    let k = UInt32(min(a, b)) << 16 | UInt32(max(a, b))
                    if a < pts.count, b < pts.count, seen.insert(k).inserted { line(pts[a], pts[b], width, color) }
                }
                t += 3
            }
        }
    }

    static let accent = SIMD4<Float>(0.15, 0.55, 1, 1)
    static let armedColor = SIMD4<Float>(1, 0.25, 0.3, 1)

    private func buildOverlay(_ puppet: Puppet, _ size: CGSize) -> [OverlayVertex] {
        var o = OverlayBuilder(w: Float(size.width), h: Float(size.height))
        let px = Float(contentScale)
        let color = armed != nil ? Self.armedColor : Self.accent

        if mode == .mesh, let id = meshTarget, let d = puppet.root.find(uuid: id) as? Drawable {
            let m = puppet.meshMatrix(d)
            let pts = meshVertices.map { toPixels(m.apply($0 - d.origin)) }
            o.mesh(pts, meshIndices, 1.5 * px, SIMD4(1, 1, 1, 0.9))
            o.mesh(pts, meshIndices, 0.75 * px, color)
            for (i, p) in pts.enumerated() {
                o.dot(p, 5 * px, SIMD4(1, 1, 1, 1))
                o.dot(p, 3.5 * px, drag?.meshVertex == i ? SIMD4(1, 0.8, 0, 1) : color)
            }
            return o.verts
        }

        guard let node = selected else { return o.verts }
        if let d = node as? Drawable {
            let pts = puppet.drawnPositions(d).map(toPixels)
            if showWireframe {
                o.mesh(pts, d.indices, 1 * px, color * SIMD4(1, 1, 1, 0.7))
            } else {
                // Just the outline of the bounding box.
                let xs = pts.map(\.x), ys = pts.map(\.y)
                if let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max() {
                    let c = [Vec2(x0, y0), Vec2(x1, y0), Vec2(x1, y1), Vec2(x0, y1)]
                    for i in 0..<4 { o.line(c[i], c[(i + 1) % 4], 1.5 * px, color) }
                }
            }
            if tool == .brush && armed != nil {
                for p in pts { o.dot(p, 2.5 * px, color) }
            }
        }
        // Node origin.
        let origin = toPixels(puppet.transform.matrix.apply(node.transform().matrix.origin))
        o.line(origin - Vec2(10 * px, 0), origin + Vec2(10 * px, 0), 1.5 * px, color)
        o.line(origin - Vec2(0, 10 * px), origin + Vec2(0, 10 * px), 1.5 * px, color)

        if tool == .brush, armed != nil, let b = brushPoint {
            o.circle(b, brushRadius * px, 1.5 * px, SIMD4(1, 1, 1, 0.9))
            o.circle(b, brushRadius * px - 1.5 * px, 1 * px, color)
        }
        return o.verts
    }

    // MARK: Hit testing

    /// The topmost visible part under a point, skipping transparent pixels.
    func part(at pixel: Vec2) -> Part? {
        guard let list = lastList, let puppet else { return nil }
        let p = toModel(pixel)
        for case let .part(d) in list.commands.reversed() {
            let start = d.mesh.indexStart
            var t = 0
            while t + 2 < d.mesh.indexCount {
                func v(_ k: Int) -> (Vec2, Vec2) {
                    let i = (d.mesh.baseVertex + Int(list.indices[start + t + k])) * 4
                    return (Vec2(list.vertices[i], list.vertices[i + 1]), Vec2(list.vertices[i + 2], list.vertices[i + 3]))
                }
                let (a, ua) = v(0), (b, ub) = v(1), (c, uc) = v(2)
                if let w = barycentric(p, a, b, c) {
                    let uv = ua * w.0 + ub * w.1 + uc * w.2
                    let opaque = d.albedo < previews.count ? (previews[d.albedo]?.alpha(atUV: uv) ?? 255) > 24 : true
                    if opaque, let node = puppet.root.find(uuid: d.nodeUUID) as? Part { return node }
                }
                t += 3
            }
        }
        return nil
    }

    private func barycentric(_ p: Vec2, _ a: Vec2, _ b: Vec2, _ c: Vec2) -> (Float, Float, Float)? {
        let v0 = b - a, v1 = c - a, v2 = p - a
        let den = v0.x * v1.y - v1.x * v0.y
        guard abs(den) > 1e-9 else { return nil }
        let v = (v2.x * v1.y - v1.x * v2.y) / den
        let w = (v0.x * v2.y - v2.x * v0.y) / den
        let u = 1 - v - w
        return u >= 0 && v >= 0 && w >= 0 ? (u, v, w) : nil
    }

    // MARK: Canvas gestures (positions in drawable pixels)

    func tap(at pixel: Vec2) {
        guard state == .ready else { return }
        if mode == .mesh {
            meshTap(pixel)
            return
        }
        select(part(at: pixel))
    }

    func dragBegan(at pixel: Vec2) {
        guard let puppet, state == .ready else { return }
        let model = toModel(pixel)
        var ds = DragState(start: model, startPixels: pixel)
        if mode == .mesh {
            ds.meshVertex = nearestMeshVertex(pixel)
            if ds.meshVertex == nil, meshTool == .edit, let i = addMeshVertex(pixel) { ds.meshVertex = i }
            drag = ds
            return
        }
        switch tool {
        case .select:
            if let p = part(at: pixel) { select(p) }
            ds.node = selected
            ds.startTranslation = ds.node?.localTransform.translation ?? .zero
        case .move:
            ds.node = selected
            if let node = ds.node {
                ds.startTranslation = node.localTransform.translation
                if let param = armed, let k = armedKeypoint {
                    ds.startValues = (puppet.value(param, node, target: "transform.t.x", at: k),
                                      puppet.value(param, node, target: "transform.t.y", at: k))
                }
            }
        case .brush:
            brushPoint = pixel
            guard let param = armed, let k = armedKeypoint, let d = selected as? Drawable else { break }
            ds.node = d
            ds.startOffsets = puppet.deformation(param, d, at: k)
            let r = brushRadius * Float(contentScale)
            ds.weights = puppet.drawnPositions(d).map { v in
                let dist = toPixels(v).distance(to: pixel)
                guard dist < r else { return 0 }
                let x = 1 - (dist / r) * (dist / r)
                return x * x * brushStrength
            }
        }
        drag = ds
    }

    func dragChanged(to pixel: Vec2) {
        guard let puppet, var ds = drag else { return }
        let delta = toModel(pixel) - ds.start
        if mode == .mesh {
            if let i = ds.meshVertex, i < meshVertices.count, let id = meshTarget,
               let d = puppet.root.find(uuid: id) as? Drawable {
                meshVertices[i] = puppet.meshPoint(d, from: toModel(pixel))
                meshIndices = MeshGenerator.triangulate(meshVertices)
                meshDirty = true
            }
            return
        }
        switch tool {
        case .select, .move:
            guard let node = ds.node, tool == .move || node === selected else { return }
            if tool == .select && ds.startPixels.distance(to: pixel) < 12 * Float(contentScale) { return }
            let local = puppet.localDelta(node, from: delta)
            if let param = armed {
                guard let k = armedKeypoint else { return }
                puppet.setValue(param, node, target: "transform.t.x", at: k, value: ds.startValues.0 + local.x)
                puppet.setValue(param, node, target: "transform.t.y", at: k, value: ds.startValues.1 + local.y)
            } else {
                node.localTransform.translation = ds.startTranslation + Vec3(local.x, local.y, 0)
            }
            changed(commit: false)
        case .brush:
            brushPoint = pixel
            guard let param = armed, let k = armedKeypoint, let d = ds.node as? Drawable,
                  ds.startOffsets.count == d.vertices.count else { return }
            let inv = puppet.meshMatrix(d).inverse
            let md = inv.apply(delta) - inv.apply(.zero)
            let offsets = zip(ds.startOffsets, ds.weights).map { $0 + md * $1 }
            puppet.setDeformation(param, d, at: k, offsets: offsets)
            changed(commit: false)
        }
        drag = ds
    }

    func dragEnded() {
        drag = nil
        brushPoint = nil
        commitPending()
    }

    /// Shows the brush outline while the Pencil hovers.
    func hover(at pixel: Vec2?) {
        brushPoint = pixel
    }

    // MARK: Mesh mode

    var meshTargetNode: Drawable? { meshTarget.flatMap { puppet?.root.find(uuid: $0) as? Drawable } }

    func setMode(_ m: Mode) {
        guard m != mode else { return }
        if m == .mesh {
            guard let d = selected as? Drawable else {
                message = "Select a part first, then switch to Mesh mode to edit its mesh."
                return
            }
            commitPending()
            meshTarget = d.uuid
            meshVertices = d.vertices
            meshIndices = d.indices
            meshDirty = false
            mode = .mesh
            puppet?.renderParameters = false
        } else {
            exitMeshMode(apply: true)
        }
    }

    func exitMeshMode(apply: Bool) {
        guard mode == .mesh else { return }
        if apply { applyMesh() }
        mode = .layout
        meshTarget = nil
        puppet?.renderParameters = true
        revision &+= 1
    }

    func applyMesh() {
        guard meshDirty, let puppet, let d = meshTargetNode, meshVertices.count >= 3, !meshIndices.isEmpty else { return }
        puppet.setMesh(d, vertices: meshVertices, indices: meshIndices)
        meshDirty = false
        changed()
    }

    func autoMesh() {
        guard let puppet, let d = meshTargetNode, let part = d as? Part,
              let slot = part.textureSlots.first, slot < previews.count, let tex = previews[slot],
              let m = puppet.autoMesh(d, rgba: tex.rgba, width: tex.width, height: tex.height, spacing: meshSpacing)
        else {
            message = "Couldn't generate a mesh for this part."
            return
        }
        meshVertices = m.points
        meshIndices = MeshGenerator.triangulate(m.points)
        meshDirty = true
        revision &+= 1
    }

    func quadMesh() {
        guard let d = meshTargetNode, !d.vertices.isEmpty else { return }
        let xs = d.vertices.map(\.x), ys = d.vertices.map(\.y)
        let x0 = xs.min()!, x1 = xs.max()!, y0 = ys.min()!, y1 = ys.max()!
        meshVertices = [Vec2(x0, y0), Vec2(x0, y1), Vec2(x1, y0), Vec2(x1, y1)]
        meshIndices = [0, 1, 2, 2, 1, 3]
        meshDirty = true
        revision &+= 1
    }

    func revertMesh() {
        guard let d = meshTargetNode else { return }
        meshVertices = d.vertices
        meshIndices = d.indices
        meshDirty = false
        revision &+= 1
    }

    var meshHasChanges: Bool { meshDirty }

    private func nearestMeshVertex(_ pixel: Vec2) -> Int? {
        guard let puppet, let d = meshTargetNode else { return nil }
        let m = puppet.meshMatrix(d)
        var best: (Int, Float)?
        for (i, v) in meshVertices.enumerated() {
            let dist = toPixels(m.apply(v - d.origin)).distance(to: pixel)
            if dist < 22 * Float(contentScale), dist < (best?.1 ?? .infinity) { best = (i, dist) }
        }
        return best?.0
    }

    private func addMeshVertex(_ pixel: Vec2) -> Int? {
        guard let puppet, let d = meshTargetNode else { return nil }
        meshVertices.append(puppet.meshPoint(d, from: toModel(pixel)))
        meshIndices = MeshGenerator.triangulate(meshVertices)
        meshDirty = true
        return meshVertices.count - 1
    }

    private func meshTap(_ pixel: Vec2) {
        if let i = nearestMeshVertex(pixel) {
            if meshTool == .delete, meshVertices.count > 3 {
                meshVertices.remove(at: i)
                meshIndices = MeshGenerator.triangulate(meshVertices)
                meshDirty = true
            }
        } else if meshTool == .edit {
            _ = addMeshVertex(pixel)
        }
        revision &+= 1
    }

    // MARK: Parameters

    func arm(_ p: Parameter?) {
        if mode == .mesh { exitMeshMode(apply: true) }
        armedID = p?.uuid
        if let p {
            p.value = p.value(at: p.nearestKeypoint)
            if tool == .select { tool = .brush }
        } else if tool == .brush {
            tool = .select
        }
        revision &+= 1
    }

    func setValue(_ p: Parameter, _ v: Vec2) {
        p.value = v
        revision &+= 1
    }

    /// Moves a parameter to a keypoint (when armed, that's the one recorded).
    func goTo(_ p: Parameter, _ k: Keypoint) {
        p.value = p.value(at: k)
        revision &+= 1
    }

    // MARK: Node values (rest values, or bindings when armed)

    /// Reads a bindable value of a node: the armed parameter's value at the
    /// current keypoint, or the node's own value.
    func value(_ node: Node, _ target: String) -> Float {
        if let p = armed, let k = armedKeypoint, let puppet {
            return puppet.value(p, node, target: target, at: k)
        }
        return node.restValue(target)
    }

    func setValue(_ node: Node, _ target: String, _ v: Float, commit: Bool = true) {
        if let p = armed {
            guard let k = armedKeypoint, let puppet else { return }
            puppet.setValue(p, node, target: target, at: k, value: v)
        } else {
            node.setRestValue(target, v)
        }
        changed(commit: commit)
    }

    /// Whether edits to `target` go into the armed parameter.
    var recording: Bool { armed != nil }

    func isBound(_ node: Node, _ target: String) -> Bool {
        guard let p = armed, let puppet else { return false }
        return puppet.binding(p, node: node, target: target) != nil
    }

    // MARK: Structure

    func add(_ kind: NodeKind, under parent: Node? = nil) {
        guard let puppet else { return }
        let parent = parent ?? selected ?? puppet.root
        let node = puppet.makeNode(kind, name: kind.title)
        if let s = node as? SimplePhysics, let p = puppet.parameters.first(where: { $0.isVec2 }) {
            s.setParameter(p)
        }
        puppet.add(node, to: parent)
        selectedID = node.uuid
        changed()
    }

    /// Adds an image (premultiplied RGBA8) as a new, auto-meshed part.
    func addImagePart(rgba: [UInt8], width: Int, height: Int, name: String) {
        guard let puppet else { return }
        let slot = puppet.addTexture(rgba: rgba, width: width, height: height)
        let mesh = MeshGenerator.auto(rgba: rgba, width: width, height: height, spacing: meshSpacing)
        let part = puppet.makePart(name: name, textureSlot: slot, width: width, height: height, mesh: mesh)
        puppet.add(part, to: selected.map { $0 is Part ? ($0.parent ?? puppet.root) : $0 } ?? puppet.root)
        syncTextures()
        selectedID = part.uuid
        changed()
    }

    func delete(_ node: Node) {
        guard let puppet, node !== puppet.root else { return }
        if selectedID == node.uuid { selectedID = node.parent?.uuid }
        puppet.remove(node)
        changed()
    }

    func move(_ node: Node, to parent: Node) {
        guard let puppet, puppet.canMove(node, to: parent) else { return }
        puppet.move(node, to: parent)
        changed()
    }

    /// Moves a node up (-1) or down (+1) among its siblings.
    func reorder(_ node: Node, by step: Int) {
        guard let puppet, let parent = node.parent, let i = parent.children.firstIndex(where: { $0 === node }) else { return }
        let j = i + step
        guard j >= 0, j < parent.children.count else { return }
        puppet.move(node, to: parent, at: j)
        changed()
    }

    func rename(_ node: Node, _ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, n != node.name else { return }
        node.name = n
        changed()
    }

    func duplicate(_ node: Node) {
        guard let puppet, let copy = puppet.duplicate(node) else { return }
        selectedID = copy.uuid
        changed()
    }
}
