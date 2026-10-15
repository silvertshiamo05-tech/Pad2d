import SwiftUI
import Inochi2DKit

/// Canvas interaction for every mode and tool. Positions arrive in drawable
/// pixels and are converted to model space (or mesh space in Mesh mode).
extension EditorModel {
    /// Hit radius: Creator's 16 screen points.
    var hitRadiusPixels: Float { 18 * Float(contentScale) }
    /// The hit radius in model units.
    var hitRadius: Float { toModel(Vec2(hitRadiusPixels, 0)).x - toModel(.zero).x }

    // MARK: Entry points

    func tap(at pixel: Vec2) {
        guard state == .ready else { return }
        let p = toModel(pixel)
        switch mode {
        case .mesh:
            guard let s = meshSession, let d = meshTarget else { return }
            s.tap(localPoint(d, p), radius: localRadius(d), ctrl: ctrl, shift: shift)
            revision &+= 1
        case .model:
            if armed != nil && tool != .select {
                deformTap(p)
            } else {
                select(part(at: pixel), extend: shift)
            }
        case .animation, .test:
            break
        }
    }

    func doubleTap(at pixel: Vec2) {
        guard state == .ready else { return }
        let p = toModel(pixel)
        switch mode {
        case .mesh:
            guard let s = meshSession, let d = meshTarget else { return }
            s.doubleTap(localPoint(d, p), radius: localRadius(d))
            revision &+= 1
        case .model where armed != nil && tool == .path:
            pathDoubleTap(p)
        case .model where tool == .select:
            if let part = part(at: pixel), part is Drawable { select(part); setMode(.mesh) }
        default:
            break
        }
    }

    func longPress(at pixel: Vec2) {
        guard mode == .model else { return }
        pickList = parts(at: pixel)
    }

    func dragBegan(at pixel: Vec2) {
        guard state == .ready else { return }
        let p = toModel(pixel)
        switch mode {
        case .mesh:
            guard let s = meshSession, let d = meshTarget else { return }
            s.dragBegan(localPoint(d, p), radius: localRadius(d), ctrl: ctrl, shift: shift)
        case .model:
            if let h = handle(at: pixel) {
                beginHandle(h, at: p)
            } else if armed != nil && tool != .select {
                deformDragBegan(p)
            } else {
                beginNodeDrag(at: pixel, p)
            }
        default:
            break
        }
        revision &+= 1
    }

    func dragChanged(to pixel: Vec2) {
        let p = toModel(pixel)
        switch mode {
        case .mesh:
            guard let s = meshSession, let d = meshTarget else { return }
            s.dragChanged(localPoint(d, p), radius: localRadius(d), shift: shift, ctrl: ctrl)
        case .model:
            if handleDrag != nil {
                updateHandle(p)
            } else if deform.drag != nil {
                deformDragChanged(p)
            } else if nodeDrag != nil {
                updateNodeDrag(p)
            }
            if armed != nil, tool == .brush { deform.brushPoint = p }
        default:
            break
        }
        revision &+= 1
    }

    func dragEnded() {
        switch mode {
        case .mesh:
            if let s = meshSession, let d = meshTarget { s.dragEnded(radius: localRadius(d), shift: shift, ctrl: ctrl) }
        case .model:
            if handleDrag != nil {
                handleDrag = nil
                commitPending()
            } else if deform.drag != nil {
                deformDragEnded()
            } else if let nd = nodeDrag {
                nodeDrag = nil
                if nd.moved { commitPending() }
            }
        default:
            break
        }
        revision &+= 1
    }

    /// Arrow keys (hardware keyboard): nudge selected vertices.
    func nudge(_ d: Vec2) {
        let step: Float = alt ? 1 : (shift ? 100 : 10)
        switch mode {
        case .mesh:
            meshSession?.nudge(d * step, radius: meshTarget.map(localRadius) ?? 1)
        case .model where armed != nil:
            moveDeformSelection(by: d * step)
            commitPending()
        default:
            break
        }
        revision &+= 1
    }

    func deleteKey() {
        if mode == .mesh, let s = meshSession, let d = meshTarget {
            s.deleteSelection(radius: localRadius(d))
            revision &+= 1
        }
    }

    // MARK: Picking

    /// Parts under a point, topmost first, skipping transparent pixels.
    func parts(at pixel: Vec2) -> [Part] {
        guard let list = lastList, let puppet else { return [] }
        let p = toModel(pixel)
        var out: [Part] = []
        for case let .part(d) in list.commands.reversed() {
            guard !out.contains(where: { $0.uuid == d.nodeUUID }) else { continue }
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
                    if opaque, let node = puppet.root.find(uuid: d.nodeUUID) as? Part {
                        out.append(node)
                        break
                    }
                }
                t += 3
            }
        }
        return out
    }

    func part(at pixel: Vec2) -> Part? { parts(at: pixel).first }

    func barycentric(_ p: Vec2, _ a: Vec2, _ b: Vec2, _ c: Vec2) -> (Float, Float, Float)? {
        let v0 = b - a, v1 = c - a, v2 = p - a
        let den = v0.x * v1.y - v1.x * v0.y
        guard abs(den) > 1e-9 else { return nil }
        let v = (v2.x * v1.y - v1.x * v2.y) / den
        let w = (v0.x * v2.y - v2.x * v0.y) / den
        let u = 1 - v - w
        return u >= 0 && v >= 0 && w >= 0 ? (u, v, w) : nil
    }

    // MARK: Mesh mode

    var meshTarget: Drawable? { meshSession.flatMap { puppet?.root.find(uuid: $0.targetID) as? Drawable } }

    func localPoint(_ d: Drawable, _ p: Vec2) -> Vec2 { puppet?.meshPoint(d, from: p) ?? p }

    func localRadius(_ d: Drawable) -> Float {
        guard let puppet else { return 1 }
        let a = puppet.meshPoint(d, from: .zero), b = puppet.meshPoint(d, from: Vec2(hitRadius, 0))
        return Swift.max(a.distance(to: b), 0.0001)
    }

    func setMode(_ m: Mode) {
        guard m != mode else { return }
        if mode == .mesh { exitMeshMode(apply: true) }
        if mode == .test { stopTest() }
        if mode == .animation { stopAnimation() }
        commitPending()
        switch m {
        case .mesh:
            guard let d = selected as? Drawable else {
                message = "Select a part or mesh group first, then switch to Mesh mode to edit its mesh."
                return
            }
            if armed != nil { arm(nil) }
            meshSession = MeshEditSession(drawable: d)
            mode = .mesh
            puppet?.renderParameters = false
        case .test:
            if armed != nil { arm(nil) }
            mode = .test
            startTest()
        case .animation:
            if armed != nil { arm(nil) }
            mode = .animation
            startAnimationMode()
        case .model:
            mode = .model
        }
        revision &+= 1
    }

    func exitMeshMode(apply: Bool) {
        guard mode == .mesh, let s = meshSession else { return }
        if apply && s.changed {
            if s.mesh.triangleCount < 1 && !s.mesh.isGrid {
                message = "Cannot apply invalid mesh. At least 3 vertices forming a triangle are needed."
                return
            }
            if let puppet, let d = meshTarget, puppet.applyMesh(s.mesh, to: d) {
                changed("Edit mesh of \(d.name)")
            }
        }
        meshSession = nil
        mode = .model
        puppet?.renderParameters = true
        revision &+= 1
    }

    func runAutoMesh(contour: ContourAutoMesh?, grid: GridAutoMesh?) {
        guard let puppet, let s = meshSession, let d = meshTarget, let part = d as? Part,
              let tex = preview(for: part),
              let m = puppet.autoMesh(d, rgba: tex.rgba, width: tex.width, height: tex.height,
                                      contour: contour, grid: grid, mirror: s.mirrorH) else {
            message = "Couldn't generate a mesh: auto-mesh needs a part with visible pixels."
            return
        }
        s.replace(with: m)
        revision &+= 1
    }

    /// Creator's "Copy Mesh": takes another drawable's mesh as-is.
    func copyMesh(from other: Drawable) {
        guard let s = meshSession else { return }
        s.replace(with: EditableMesh(other))
        revision &+= 1
    }

    // MARK: Moving nodes by dragging their body (Select tool)

    private func beginNodeDrag(at pixel: Vec2, _ p: Vec2) {
        if let hit = part(at: pixel), !isSelected(hit) { select(hit, extend: shift) }
        guard part(at: pixel).map(isSelected) ?? false else { return }
        let nodes = topLevelSelection()
        nodeDrag = NodeDrag(start: p, nodes: nodes.map { n in
            (n, n.localTransform.translation, value(n, "transform.t.x"), value(n, "transform.t.y"))
        })
    }

    private func updateNodeDrag(_ p: Vec2) {
        guard var nd = nodeDrag, let puppet else { return }
        var delta = p - nd.start
        if !nd.moved && delta.length < hitRadius * 0.5 { return }
        if shift { if abs(delta.x) > abs(delta.y) { delta.y = 0 } else { delta.x = 0 } }
        nd.moved = true
        for (n, t, bx, by) in nd.nodes {
            var local = puppet.localDelta(n, from: delta)
            if ctrl { local = Vec2((local.x / 5).rounded() * 5, (local.y / 5).rounded() * 5) }
            if armed != nil {
                setBound(n, "transform.t.x", bx + local.x)
                setBound(n, "transform.t.y", by + local.y)
            } else {
                n.localTransform.translation = Vec3(t.x + local.x, t.y + local.y, t.z)
                n.transformChanged()
            }
        }
        nodeDrag = nd
        changed("Move", commit: false)
    }

    /// Selected nodes without those whose ancestor is also selected.
    func topLevelSelection() -> [Node] {
        let nodes = selectedNodes
        let ids = Set(nodes.map(\.uuid))
        return nodes.filter { n in
            var p = n.parent
            while let c = p { if ids.contains(c.uuid) { return false }; p = c.parent }
            return n.parent != nil
        }
    }

    /// Writes a value into the armed parameter at the current keypoint.
    func setBound(_ node: Node, _ target: String, _ v: Float) {
        guard let p = armed, let k = armedKeypoint, let b = p.getOrAddBinding(node: node, target: target) else { return }
        b.setFloat(k, v)
    }

    // MARK: Transform handles

    enum Handle { case move, scale, rotate }

    /// Model-space bounds of the selection (minX, minY, maxX, maxY).
    func selectionBounds() -> (Float, Float, Float, Float)? {
        guard let puppet else { return nil }
        var b: (Float, Float, Float, Float)?
        for n in topLevelSelection() {
            var nb = n.combinedBounds()
            let m = puppet.transform.matrix
            let a = m.apply(Vec2(nb.0, nb.1)), c = m.apply(Vec2(nb.2, nb.3))
            nb = (Swift.min(a.x, c.x), Swift.min(a.y, c.y), Swift.max(a.x, c.x), Swift.max(a.y, c.y))
            b = b.map { (Swift.min($0.0, nb.0), Swift.min($0.1, nb.1), Swift.max($0.2, nb.2), Swift.max($0.3, nb.3)) } ?? nb
        }
        return b
    }

    /// Handle centres in pixels.
    func handlePositions() -> [(Handle, Vec2)] {
        guard mode == .model, tool == .select || armed == nil, let b = selectionBounds() else { return [] }
        let tl = toPixels(Vec2(b.0, b.1)), br = toPixels(Vec2(b.2, b.3))
        let off = 26 * Float(contentScale)
        var out: [(Handle, Vec2)] = [(.move, Vec2(tl.x - off, tl.y - off))]
        if topLevelSelection().count == 1 {
            out.append((.scale, Vec2(tl.x - off, br.y + off)))
            out.append((.rotate, Vec2(br.x + off, tl.y - off)))
        }
        return out
    }

    func handle(at pixel: Vec2) -> Handle? {
        handlePositions().first { $0.1.distance(to: pixel) < 22 * Float(contentScale) }?.0
    }

    private func beginHandle(_ h: Handle, at p: Vec2) {
        guard let b = selectionBounds() else { return }
        let nodes = topLevelSelection().map { n -> (Node, Vec3, Vec3, Vec2) in
            (n,
             Vec3(value(n, "transform.t.x"), value(n, "transform.t.y"), 0),
             Vec3(0, 0, value(n, "transform.r.z")),
             Vec2(value(n, "transform.s.x"), value(n, "transform.s.y")))
        }
        let center: Vec2
        if h == .rotate, let n = nodes.first?.0, let puppet {
            center = puppet.transform.matrix.apply(n.transform().matrix.origin)
        } else {
            center = Vec2((b.0 + b.2) / 2, (b.1 + b.3) / 2)
        }
        handleDrag = HandleDrag(kind: h == .move ? .move : h == .scale ? .scale : .rotate,
                                start: p, last: p, center: center, nodes: nodes)
    }

    private func updateHandle(_ p: Vec2) {
        guard var hd = handleDrag, let puppet else { return }
        func write(_ n: Node, _ target: String, _ v: Float) {
            if armed != nil { setBound(n, target, v) } else { n.setRestValue(target, v) }
        }
        switch hd.kind {
        case .move:
            var delta = p - hd.start
            if shift {
                if hd.lockAxis == nil, delta.length > hitRadius { hd.lockAxis = abs(delta.x) > abs(delta.y) ? 0 : 1 }
                if hd.lockAxis == 0 { delta.y = 0 } else if hd.lockAxis == 1 { delta.x = 0 }
            }
            for (n, t, _, _) in hd.nodes {
                var local = puppet.localDelta(n, from: delta)
                if ctrl { local = Vec2((local.x / 5).rounded() * 5, (local.y / 5).rounded() * 5) }
                write(n, "transform.t.x", t.x + local.x)
                write(n, "transform.t.y", t.y + local.y)
            }
            changed("Move", commit: false)
        case .scale:
            guard let (n, _, r, s) = hd.nodes.first else { return }
            let rot = -r.z
            func rotate(_ v: Vec2) -> Vec2 { Vec2(v.x * cos(rot) - v.y * sin(rot), v.x * sin(rot) + v.y * cos(rot)) }
            let a = rotate(hd.start - hd.center), b = rotate(p - hd.center)
            var ratio = Vec2(abs(a.x) > 0.001 ? b.x / a.x : 1, abs(a.y) > 0.001 ? b.y / a.y : 1)
            if shift && alt {
                let k = b.length / Swift.max(a.length, 0.001)
                ratio = Vec2(k, k)
            } else if shift {
                if abs(ratio.x - 1) > abs(ratio.y - 1) { ratio.y = 1 } else { ratio.x = 1 }
            }
            var sx = s.x * ratio.x, sy = s.y * ratio.y
            if ctrl { sx = (sx * 10).rounded(.down) / 10; sy = (sy * 10).rounded(.down) / 10 }
            write(n, "transform.s.x", sx)
            write(n, "transform.s.y", sy)
            changed("Scale", commit: false)
        case .rotate:
            guard let (n, _, r, _) = hd.nodes.first else { return }
            let a0 = atan2(hd.start.y - hd.center.y, hd.start.x - hd.center.x)
            let a1 = atan2(p.y - hd.center.y, p.x - hd.center.x)
            var delta = a1 - a0
            while delta > .pi { delta -= 2 * .pi }
            while delta <= -.pi { delta += 2 * .pi }
            var angle = r.z + delta
            if ctrl { let step = Float.pi / 36; angle = (angle / step).rounded() * step }
            write(n, "transform.r.z", angle)
            changed("Rotate", commit: false)
        }
        hd.last = p
        handleDrag = hd
    }
}
