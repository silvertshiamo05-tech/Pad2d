import Foundation
import Inochi2DKit

/// Mesh edit mode for one drawable (Inochi Creator's vertex edit mode).
/// Works in the drawable's local mesh space.
@MainActor
final class MeshEditSession {
    enum Tool: String, CaseIterable, Identifiable {
        case points, edges, grid, lasso
        var id: String { rawValue }
        var title: String {
            switch self {
            case .points: return "Vertices"
            case .edges: return "Edges"
            case .grid: return "Grid"
            case .lasso: return "Lasso"
            }
        }
        var icon: String {
            switch self {
            case .points: return "circle.grid.2x2"
            case .edges: return "line.diagonal"
            case .grid: return "grid"
            case .lasso: return "lasso"
            }
        }
    }

    let targetID: UInt32
    let original: EditableMesh
    var mesh: EditableMesh
    var selection = Set<Int>()
    var tool: Tool
    var mirrorH = false
    var mirrorV = false
    var autoConnect = true
    var previewTriangulation = false
    var polyLasso = false

    // Interaction state
    var lasso: [Vec2] = []
    var box: (Vec2, Vec2)?
    var gridPreview: (Vec2, Vec2)?
    private var dragStart: Vec2?
    private var lastPoint: Vec2?
    private var dragKind: DragKind = .none
    private var lastAdded: Int?
    private var lastSelected: Int?
    private var gridDrag: (axis: Int, index: Int, both: Int?)?
    private var undoStack: [(EditableMesh, Set<Int>)] = []
    private var redoStack: [(EditableMesh, Set<Int>)] = []

    private enum DragKind { case none, move, box, lasso, gridCreate, gridLine }

    init(drawable: Drawable) {
        targetID = drawable.uuid
        original = EditableMesh(drawable)
        mesh = original
        tool = original.isGrid ? .grid : .points
    }

    var changed: Bool { mesh != original }

    // MARK: Undo inside the session

    func checkpoint() {
        undoStack.append((mesh, selection))
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func undo() -> Bool {
        guard let s = undoStack.popLast() else { return false }
        redoStack.append((mesh, selection))
        (mesh, selection) = s
        return true
    }

    func redo() -> Bool {
        guard let s = redoStack.popLast() else { return false }
        undoStack.append((mesh, selection))
        (mesh, selection) = s
        return true
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    // MARK: Mirroring

    var axes: [Int] { EditableMesh.axes(horizontal: mirrorH, vertical: mirrorV) }

    /// Mirror counterparts of the selection (drawn magenta).
    func mirrorSelection(radius: Float) -> Set<Int> {
        var out = Set<Int>()
        for i in selection {
            for a in axes where a != 0 {
                if let m = mesh.mirrorVertex(i, axis: a, radius: radius), !selection.contains(m) { out.insert(m) }
            }
        }
        return out
    }

    private func isOnMirror(_ p: Vec2, aoe: Float) -> Bool {
        (mirrorH && abs(p.x) < aoe) || (mirrorV && abs(p.y) < aoe)
    }

    // MARK: Editing operations

    /// Adds a vertex (and its mirror copies), auto-connecting to the last one.
    func addVertex(_ p: Vec2, radius: Float, selectLast: Bool) {
        checkpoint()
        var added: [Int: Int] = [:]
        if isOnMirror(p, aoe: radius / 4) {
            var q = p
            if mirrorH { q.x = 0 }
            if mirrorV { q.y = 0 }
            added[0] = mesh.add(q)
        } else {
            for a in axes { added[a] = mesh.add(EditableMesh.mirror(p, axis: a)) }
        }
        if autoConnect, let prev = lastAdded, mesh.points.indices.contains(prev) {
            for a in axes {
                guard let n = added[a] ?? added[0] else { continue }
                let from = a == 0 ? prev : mesh.vertex(at: EditableMesh.mirror(mesh.points[prev], axis: a), radius: radius) ?? prev
                if from != n { mesh.connect(from, n) }
            }
        }
        lastAdded = added[0]
        if let n = added[0] { selection = [n] }
        _ = selectLast
    }

    func removeVertex(at i: Int, radius: Float) {
        checkpoint()
        var set = Set([i])
        for a in axes where a != 0 {
            if let m = mesh.mirrorVertex(i, axis: a, radius: radius) { set.insert(m) }
        }
        mesh.remove(set)
        selection = []
        lastAdded = nil
    }

    func deleteSelection(radius: Float) {
        guard !selection.isEmpty else { return }
        checkpoint()
        mesh.remove(selection.union(mirrorSelection(radius: radius)))
        selection = []
        lastAdded = nil
    }

    func moveSelection(by d: Vec2, radius: Float) {
        let mirrors = axes.filter { $0 != 0 }
        var moved = Set<Int>()
        for i in selection {
            for a in mirrors {
                if let m = mesh.mirrorVertex(i, axis: a, radius: radius), !selection.contains(m), !moved.contains(m) {
                    mesh.points[m] += EditableMesh.mirrorDelta(d, axis: a)
                    moved.insert(m)
                }
            }
        }
        for i in selection { mesh.points[i] += d }
    }

    func nudge(_ d: Vec2, radius: Float) {
        guard !selection.isEmpty else { return }
        checkpoint()
        moveSelection(by: d, radius: radius)
    }

    func selectAll() { selection = Set(mesh.points.indices) }

    func flip(horizontal: Bool) {
        checkpoint()
        if horizontal { mesh.flipHorizontally() } else { mesh.flipVertically() }
    }

    func bakeTriangulation() {
        checkpoint()
        mesh.triangulate()
        previewTriangulation = false
    }

    func replace(with m: EditableMesh) {
        checkpoint()
        mesh = m
        selection = []
        lastAdded = nil
        if m.isGrid { tool = .grid }
    }

    func revert() { replace(with: original) }

    // MARK: Gestures (local mesh coordinates; radius = hit radius in local units)

    func tap(_ p: Vec2, radius: Float, ctrl: Bool, shift: Bool) {
        let hit = mesh.vertex(at: p, radius: radius)
        switch tool {
        case .points:
            if ctrl {
                if let h = hit { removeVertex(at: h, radius: radius) } else { addVertex(p, radius: radius, selectLast: true) }
            } else if let h = hit {
                if shift {
                    if selection.contains(h) { selection.remove(h) } else { selection.insert(h) }
                } else {
                    selection = [h]
                }
                lastAdded = h
            } else {
                selection = []
            }
        case .edges:
            guard let h = hit else {
                selection = []
                lastSelected = nil
                return
            }
            if let prev = lastSelected, prev != h, mesh.points.indices.contains(prev) {
                checkpoint()
                let connect = !mesh.isConnected(prev, h)
                for a in axes {
                    let pa = a == 0 ? prev : mesh.vertex(at: EditableMesh.mirror(mesh.points[prev], axis: a), radius: radius)
                    let pb = a == 0 ? h : mesh.vertex(at: EditableMesh.mirror(mesh.points[h], axis: a), radius: radius)
                    guard let x = pa, let y = pb, x != y else { continue }
                    if connect { mesh.connect(x, y) } else { mesh.disconnect(x, y) }
                }
                if shift {
                    selection = [h]
                    lastSelected = h
                } else {
                    selection = []
                    lastSelected = nil
                }
            } else if lastSelected == h {
                selection = []
                lastSelected = nil
            } else {
                selection = [h]
                lastSelected = h
            }
        case .grid:
            break
        case .lasso:
            if polyLasso { addLassoPoint(p, radius: radius, shift: shift, ctrl: ctrl) }
        }
    }

    func doubleTap(_ p: Vec2, radius: Float) {
        let hit = mesh.vertex(at: p, radius: radius)
        switch tool {
        case .points:
            if let h = hit {
                if selection.contains(h) { removeVertex(at: h, radius: radius) }
            } else {
                addVertex(p, radius: radius, selectLast: false)
            }
        case .grid:
            gridDoubleTap(p, hit: hit, radius: radius)
        default:
            break
        }
    }

    func dragBegan(_ p: Vec2, radius: Float, ctrl: Bool, shift: Bool) {
        dragStart = p
        lastPoint = p
        let hit = mesh.vertex(at: p, radius: radius)
        switch tool {
        case .points, .edges:
            if let h = hit, tool == .points {
                if !selection.contains(h) {
                    if shift { selection.insert(h) } else { selection = [h] }
                }
                checkpoint()
                dragKind = .move
            } else {
                dragKind = .box
                box = (p, p)
            }
        case .grid:
            if let h = hit, mesh.isGrid {
                checkpoint()
                startGridDrag(h)
                dragKind = .gridLine
            } else if !mesh.isGrid || mesh.points.isEmpty {
                dragKind = .gridCreate
                gridPreview = (p, p)
            } else {
                dragKind = .none
            }
        case .lasso:
            if !polyLasso {
                lasso = [p]
                dragKind = .lasso
            }
        }
    }

    func dragChanged(_ p: Vec2, radius: Float, shift: Bool, ctrl: Bool) {
        defer { lastPoint = p }
        switch dragKind {
        case .move:
            if let last = lastPoint { moveSelection(by: p - last, radius: radius) }
        case .box:
            if let s = dragStart { box = (s, p) }
        case .lasso:
            if let l = lasso.last, l.distance(to: p) > radius * 0.9 { lasso.append(p) }
        case .gridCreate:
            if let s = dragStart { gridPreview = (s, p) }
        case .gridLine:
            moveGridLine(to: p)
        case .none:
            break
        }
    }

    func dragEnded(radius: Float, shift: Bool, ctrl: Bool) {
        switch dragKind {
        case .box:
            if let bx = box {
                let (a, b) = bx
                let found = Set(mesh.vertices(inRect: a, b))
                if shift && ctrl { selection.subtract(found) } else if shift { selection.formUnion(found) } else { selection = found }
            }
        case .lasso:
            finishLasso(shift: shift, ctrl: ctrl)
        case .gridCreate:
            if let gp = gridPreview, abs(gp.0.x - gp.1.x) > radius, abs(gp.0.y - gp.1.y) > radius {
                let (a, b) = gp
                checkpoint()
                let xs = [Swift.min(a.x, b.x), (a.x + b.x) / 2, Swift.max(a.x, b.x)]
                let ys = [Swift.min(a.y, b.y), (a.y + b.y) / 2, Swift.max(a.y, b.y)]
                mesh = EditableMesh.grid([ys, xs])
                selection = []
            }
        default:
            break
        }
        box = nil
        gridPreview = nil
        dragKind = .none
        gridDrag = nil
    }

    // MARK: Lasso

    func addLassoPoint(_ p: Vec2, radius: Float, shift: Bool, ctrl: Bool) {
        if let first = lasso.first, lasso.count > 2, first.distance(to: p) < radius {
            finishLasso(shift: shift, ctrl: ctrl)
            return
        }
        lasso.append(p)
    }

    func finishLasso(shift: Bool, ctrl: Bool) {
        defer { lasso = [] }
        guard lasso.count > 2 else { return }
        let found = Set(mesh.vertices(inPolygon: lasso))
        if !shift && !ctrl { selection = [] }
        for i in found {
            if shift && ctrl {
                if selection.contains(i) { selection.remove(i) } else { selection.insert(i) }
            } else if ctrl {
                selection.remove(i)
            } else {
                selection.insert(i)
            }
        }
    }

    // MARK: Grid tool

    private func gridIndex(_ i: Int) -> (yi: Int, xi: Int)? {
        guard let g = mesh.gridAxes, g.count == 2 else { return nil }
        let xs = g[1].count
        return (i / xs, i % xs)
    }

    private func startGridDrag(_ i: Int) {
        guard let gi = gridIndex(i), let g = mesh.gridAxes else { return }
        let (yi, xi) = gi
        let lastY = g[0].count - 1, lastX = g[1].count - 1
        let edgeRow = yi == 0 || yi == lastY, edgeCol = xi == 0 || xi == lastX
        if edgeRow && !edgeCol {
            gridDrag = (axis: 1, index: xi, both: nil)
        } else if edgeCol && !edgeRow {
            gridDrag = (axis: 0, index: yi, both: nil)
        } else {
            gridDrag = (axis: 1, index: xi, both: yi)
        }
    }

    private func moveGridLine(to p: Vec2) {
        guard var g = mesh.gridAxes, let d = gridDrag else { return }
        g[d.axis][d.index] = d.axis == 1 ? p.x : p.y
        var newIndex = d.index
        let v = g[d.axis][d.index]
        g[d.axis].sort()
        newIndex = g[d.axis].firstIndex(of: v) ?? d.index
        var both = d.both
        if let yi = d.both {
            g[0][yi] = p.y
            let vy = g[0][yi]
            g[0].sort()
            both = g[0].firstIndex(of: vy)
        }
        mesh = EditableMesh.grid(g)
        gridDrag = (d.axis, newIndex, both)
    }

    private func gridDoubleTap(_ p: Vec2, hit: Int?, radius: Float) {
        guard var g = mesh.gridAxes, mesh.isGrid else { return }
        checkpoint()
        if let h = hit, let gi = gridIndex(h) {
            let (yi, xi) = gi
            let lastY = g[0].count - 1, lastX = g[1].count - 1
            let edgeRow = yi == 0 || yi == lastY, edgeCol = xi == 0 || xi == lastX
            if edgeRow && edgeCol { return }
            if edgeCol { if g[0].count > 2 { g[0].remove(at: yi) } }
            else if edgeRow { if g[1].count > 2 { g[1].remove(at: xi) } }
            else {
                if g[0].count > 2 { g[0].remove(at: yi) }
                if g[1].count > 2 { g[1].remove(at: xi) }
            }
        } else {
            if !g[0].contains(where: { abs($0 - p.y) < radius }), let lo = g[0].first, let hi = g[0].last, p.y > lo, p.y < hi {
                g[0].append(p.y)
                g[0].sort()
            }
            if !g[1].contains(where: { abs($0 - p.x) < radius }), let lo = g[1].first, let hi = g[1].last, p.x > lo, p.x < hi {
                g[1].append(p.x)
                g[1].sort()
            }
        }
        mesh = EditableMesh.grid(g)
        selection = []
    }
}
