import SwiftUI
import MetalKit
import simd
import Inochi2DKit

/// Everything the editor knows about the puppet being edited.
///
/// The puppet itself is the source of truth; views read it directly and
/// refresh when `revision` changes. Every finished change is committed as a
/// named snapshot for undo (see EditorModel+History).
@MainActor
final class EditorModel: ObservableObject, RenderSource {
    enum State: Equatable {
        case loading
        case ready
        case failed(String)
    }

    /// Inochi Creator's edit modes.
    enum Mode: String, CaseIterable, Identifiable {
        case model, mesh, animation, test
        var id: String { rawValue }
        var title: String {
            switch self {
            case .model: return "Model"
            case .mesh: return "Mesh"
            case .animation: return "Animate"
            case .test: return "Test"
            }
        }
    }

    /// Model-mode tools. The deform tools apply while a parameter is armed.
    enum Tool: String, CaseIterable, Identifiable {
        case select, points, brush, path, lasso
        var id: String { rawValue }
        var title: String {
            switch self {
            case .select: return "Select"
            case .points: return "Vertices"
            case .brush: return "Brush"
            case .path: return "Path"
            case .lasso: return "Lasso"
            }
        }
        var icon: String {
            switch self {
            case .select: return "cursorarrow"
            case .points: return "circle.grid.2x2"
            case .brush: return "paintbrush.pointed"
            case .path: return "point.topleft.down.to.point.bottomright.curvepath"
            case .lasso: return "lasso"
            }
        }
        var deformOnly: Bool { self != .select }
    }

    @Published private(set) var state = State.loading
    @Published internal(set) var revision = 0
    @Published var background: BackgroundStyle = .checker
    @Published var customBackground = Color(red: 0.2, green: 0.2, blue: 0.22)
    @Published internal(set) var mode = Mode.model
    @Published var tool = Tool.select
    @Published var message: String?
    @Published internal(set) var dirty = false
    @Published private(set) var saving = false
    @Published internal(set) var selectedIDs: [UInt32] = []
    @Published internal(set) var armedID: UInt32?
    @Published var physicsPreview = false {
        didSet {
            puppet?.enableDrivers = physicsPreview
            puppet?.resetDrivers()
        }
    }

    // Gizmos (Creator's "Gizmos" menu)
    @Published var showVertices = true
    @Published var showBounds = false
    @Published var showOrientation = false
    @Published var mirrorView = false

    // Modifier toggles (stand-ins for Ctrl / Shift / Alt on a keyboard).
    @Published var modAdd = false      // Ctrl: create / remove, snap
    @Published var modExtend = false   // Shift: add to selection, axis lock, slide
    @Published var modSelect = false   // Alt: select vertices with deform tools
    var hardwareModifiers = UIKeyModifierFlags()
    var ctrl: Bool { modAdd || hardwareModifiers.contains(.command) || hardwareModifiers.contains(.control) }
    var shift: Bool { modExtend || hardwareModifiers.contains(.shift) }
    var alt: Bool { modSelect || hardwareModifiers.contains(.alternate) }

    /// Parts under the finger, for the long-press picker.
    @Published var pickList: [Part] = []

    internal(set) var url: URL
    let name: String
    internal(set) var puppet: Puppet?
    var textures: [MTLTexture?] = []
    var previews: [TexturePreview?] = []
    var textureKeys: [Int] = []

    // Undo history (EditorModel+History)
    var history: [HistoryEntry] = []
    var historyIndex = 0
    var pendingCommit = false
    var pendingLabel = "Edit"
    @Published var maxUndo = UserDefaults.standard.object(forKey: "MaxUndoHistory") as? Int ?? 100

    // Camera
    var zoom: CGFloat = 1
    var pan = CGPoint.zero
    var bounds: (Float, Float, Float, Float)?
    var viewSize = CGSize(width: 1, height: 1)
    var contentScale: CGFloat = 2
    var lastList: DrawList?

    // Editing sessions
    var meshSession: MeshEditSession?
    let deform = DeformSession()
    var handleDrag: HandleDrag?
    var nodeDrag: NodeDrag?

    // Animation (EditorModel+Animation)
    @Published var currentAnimation: String?
    @Published var animationFrame = 0
    var player: AnimationPlayer?
    var animationPlaying = false

    // Test mode tracking
    let faceTracker = FaceTracker()
    @Published var testBindings: [TrackingBinding] = []
    @Published var trackingStatus: String?

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
            resetHistory()
            loadTestBindings()
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
        resetHistory()
        dirty = true
        state = .ready
    }

    func install(_ puppet: Puppet) {
        self.puppet = puppet
        puppet.enableDrivers = physicsPreview && armedID == nil
        puppet.renderParameters = mode != .mesh
        player = AnimationPlayer(puppet: puppet)
    }

    func fitCamera() {
        guard let puppet else { return }
        puppet.update(deltaTime: 0)
        bounds = puppet.draw().bounds
        if bounds == nil { bounds = (-500, -500, 500, 500) }
    }

    static func key(_ blob: TextureBlob) -> Int {
        var h = Hasher()
        h.combine(blob.data.count)
        h.combine(blob.data.prefix(64))
        h.combine(blob.data.suffix(64))
        return h.finalize()
    }

    /// Uploads textures that were added or replaced since the last sync.
    func syncTextures() {
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

    func preview(for part: Part) -> TexturePreview? {
        guard let slot = part.textureSlots.first, slot < previews.count else { return nil }
        return previews[slot]
    }

    // MARK: Selection

    var selectedNodes: [Node] { selectedIDs.compactMap { puppet?.root.find(uuid: $0) } }
    /// The primary (last selected) node.
    var selected: Node? { selectedIDs.last.flatMap { puppet?.root.find(uuid: $0) } }
    var armed: Parameter? { armedID.flatMap { id in puppet?.parameters.first { $0.uuid == id } } }

    /// The keypoint being recorded: the one nearest the armed parameter's value.
    var armedKeypoint: Keypoint? {
        guard let p = armed else { return nil }
        return p.nearestKeypoint
    }

    func isSelected(_ node: Node) -> Bool { selectedIDs.contains(node.uuid) }

    func select(_ node: Node?, extend: Bool = false) {
        if mode == .mesh { exitMeshMode(apply: true) }
        guard let node else {
            if !extend { selectedIDs = [] }
            deform.reset()
            return
        }
        if extend {
            if let i = selectedIDs.firstIndex(of: node.uuid) { selectedIDs.remove(at: i) } else { selectedIDs.append(node.uuid) }
        } else {
            selectedIDs = [node.uuid]
        }
        deform.reset()
    }

    func select(_ nodes: [Node]) {
        selectedIDs = nodes.map(\.uuid)
        deform.reset()
    }

    func selectAll() {
        guard let puppet else { return }
        selectedIDs = puppet.root.allNodes().dropFirst().map(\.uuid)
    }

    // MARK: Saving

    /// Bundled samples are saved as a copy in the library.
    var saveURL: URL {
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
            Autosave.didSave(dest)
            RecentProjects.add(dest)
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

    // MARK: Parameters

    func arm(_ p: Parameter?) {
        if mode == .mesh { exitMeshMode(apply: true) }
        commitPending()
        armedID = p?.uuid
        if let p {
            p.value = p.value(at: p.nearestKeypoint)
            if tool == .select { tool = .points }
            // Physics is off while recording, as in Creator.
            puppet?.enableDrivers = false
            puppet?.resetDrivers()
        } else {
            tool = .select
            puppet?.enableDrivers = physicsPreview
        }
        deform.reset()
        revision &+= 1
    }

    func setValue(_ p: Parameter, _ v: Vec2) {
        p.value = v
        if p.uuid == armedID { deform.reset() }
        revision &+= 1
    }

    /// Moves a parameter to a keypoint (when armed, that's the one recorded).
    func goTo(_ p: Parameter, _ k: Keypoint) {
        p.value = p.value(at: k)
        if p.uuid == armedID { deform.reset() }
        revision &+= 1
    }

    // MARK: Node values (rest values, or bindings when armed)

    /// Reads a bindable value of a node: the armed parameter's value at the
    /// current keypoint, or the node's own value.
    func value(_ node: Node, _ target: String) -> Float {
        if let p = armed, let k = armedKeypoint {
            if let b = p.binding(node: node, target: target), let v = b.floatValue(k) { return v }
            return node.bindingDefault(target)
        }
        return node.restValue(target)
    }

    func setValue(_ node: Node, _ target: String, _ v: Float, commit: Bool = true) {
        if let p = armed {
            guard let k = armedKeypoint, let b = p.getOrAddBinding(node: node, target: target) else { return }
            b.setFloat(k, v)
            changed("Change \(target)", commit: commit)
        } else {
            node.setRestValue(target, v)
            changed("Change \(target)", commit: commit)
        }
    }

    func isBound(_ node: Node, _ target: String) -> Bool {
        guard let p = armed else { return false }
        return p.binding(node: node, target: target) != nil
    }

    // MARK: Structure

    func add(_ kind: NodeKind, under parent: Node? = nil) {
        guard let puppet else { return }
        let parent = parent ?? selected ?? puppet.root
        let node = puppet.makeNode(kind, name: "Unnamed " + kind.title)
        puppet.add(node, to: parent, at: 0)
        selectedIDs = [node.uuid]
        changed("Add \(kind.title)")
    }

    /// Adds an image (premultiplied RGBA8) as a new part under the selection.
    func addImagePart(rgba: [UInt8], width: Int, height: Int, name: String) {
        guard let puppet else { return }
        let slot = puppet.addTexture(rgba: rgba, width: width, height: height)
        let part = puppet.makePart(name: name, textureSlot: slot, width: width, height: height)
        let parent = selected.map { $0 is Part ? ($0.parent ?? puppet.root) : $0 } ?? puppet.root
        puppet.add(part, to: parent, at: 0)
        syncTextures()
        selectedIDs = [part.uuid]
        changed("Add \(name)")
    }

    func delete(_ nodes: [Node]) {
        guard let puppet else { return }
        for n in nodes where n !== puppet.root { puppet.remove(n) }
        selectedIDs = []
        changed(nodes.count == 1 ? "Delete \(nodes[0].name)" : "Delete \(nodes.count) nodes")
    }

    func delete(_ node: Node) { delete([node]) }

    /// Moves nodes under `parent` (at `index`), keeping their world position.
    func move(_ nodes: [Node], to parent: Node, at index: Int? = nil) {
        guard let puppet else { return }
        var moved = 0
        for (k, n) in nodes.enumerated() where puppet.canMove(n, to: parent) && n !== parent {
            puppet.move(n, to: parent, at: index.map { $0 + k })
            moved += 1
        }
        if moved == 0 {
            message = "A node can't be moved into itself or one of its children."
            return
        }
        changed("Move")
    }

    func move(_ node: Node, to parent: Node) { move([node], to: parent) }

    /// Moves a node up (-1) or down (+1) among its siblings.
    func reorder(_ node: Node, by step: Int) {
        guard let puppet, let parent = node.parent, let i = parent.children.firstIndex(where: { $0 === node }) else { return }
        let j = i + step
        guard j >= 0, j < parent.children.count else { return }
        puppet.move(node, to: parent, at: j)
        changed("Reorder")
    }

    func rename(_ node: Node, _ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, n != node.name else { return }
        node.name = n
        changed("Rename")
    }

    func duplicate(_ node: Node) {
        guard let puppet, let copy = puppet.duplicate(node) else { return }
        selectedIDs = [copy.uuid]
        changed("Duplicate \(node.name)")
    }

    func toggleVisible(_ node: Node) {
        node.enabled.toggle()
        changed(node.enabled ? "Show" : "Hide")
    }
}

extension Notification.Name {
    static let editorRevision = Notification.Name("Pad2DEditorRevision")
}
