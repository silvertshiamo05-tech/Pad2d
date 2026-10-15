import SwiftUI
import Inochi2DKit

/// Deform tools (parameter armed): vertices, brush, path and lasso, writing
/// the armed parameter's deform bindings at the current keypoint.
extension EditorModel {
    /// Drawables being deformed: the selection.
    var deformTargets: [Drawable] { selectedNodes.compactMap { $0 as? Drawable } }
    /// Non-drawable selected nodes (moved as one point by the path tool).
    var deformNodeTargets: [Node] { selectedNodes.filter { !($0 is Drawable) && $0 !== puppet?.root } }

    /// Current offsets of `d` at the armed keypoint.
    func offsets(_ d: Drawable) -> [Vec2] {
        guard let p = armed, let k = armedKeypoint else { return [] }
        if let b = p.binding(node: d, target: "deform"), let o = b.offsets(k), o.count == d.vertices.count { return o }
        return Array(repeating: .zero, count: d.vertices.count)
    }

    func setOffsets(_ d: Drawable, _ o: [Vec2]) {
        guard let p = armed, let k = armedKeypoint, let b = p.getOrAddBinding(node: d, target: "deform") else { return }
        b.setOffsets(k, o)
    }

    /// Model-space delta → local mesh delta for `d`.
    func localDelta(_ d: Drawable, _ delta: Vec2) -> Vec2 {
        guard let puppet else { return delta }
        let inv = puppet.meshMatrix(d).inverse
        return inv.apply(delta) - inv.apply(.zero)
    }

    func drawn(_ d: Drawable) -> [Vec2] { puppet?.drawnPositions(d) ?? [] }

    private func hitVertex(_ p: Vec2) -> (Drawable, Int)? {
        var best: (Drawable, Int, Float)?
        for d in deformTargets {
            for (i, v) in drawn(d).enumerated() {
                let dist = v.distance(to: p)
                if dist < hitRadius && dist < (best?.2 ?? .infinity) { best = (d, i, dist) }
            }
        }
        return best.map { ($0.0, $0.1) }
    }

    // MARK: Taps

    func deformTap(_ p: Vec2) {
        switch tool {
        case .points, .brush:
            if tool == .brush && !alt { return }
            if let (d, i) = hitVertex(p) {
                var s = deform.selection[d.uuid] ?? []
                if shift {
                    if s.contains(i) { s.remove(i) } else { s.insert(i) }
                    deform.selection[d.uuid] = s
                } else {
                    deform.selection = [d.uuid: [i]]
                }
            } else if !shift {
                deform.selection = [:]
            }
        case .path:
            if ctrl, let i = deform.editedPath.point(near: p, radius: hitRadius) {
                deform.lockedPoint = deform.lockedPoint == i ? nil : i
                modAdd = false
            }
        case .lasso:
            if deform.polyLasso {
                if let first = deform.lasso.first, deform.lasso.count > 2, first.distance(to: p) < hitRadius {
                    finishDeformLasso()
                } else {
                    deform.lasso.append(p)
                }
            }
        case .select:
            break
        }
        revision &+= 1
    }

    func pathDoubleTap(_ p: Vec2) {
        guard !deform.pathTransform else { return }
        var none: CatmullSpline?
        if let i = deform.path.point(near: p, radius: hitRadius) {
            deform.path.removePoint(i, target: &none)
        } else {
            deform.path.addPoint(p, radius: hitRadius, target: &none)
        }
        deform.lockedPoint = nil
        revision &+= 1
    }

    // MARK: Drags

    func deformDragBegan(_ p: Vec2) {
        var drag = DeformSession.Drag(kind: .none, start: p, last: p)
        func snapshot() {
            for d in deformTargets {
                drag.startOffsets[d.uuid] = offsets(d)
                drag.startPositions[d.uuid] = drawn(d)
            }
        }
        switch tool {
        case .points:
            if let (d, i) = hitVertex(p) {
                if !(deform.selection[d.uuid]?.contains(i) ?? false) {
                    if shift { deform.selection[d.uuid, default: []].insert(i) } else { deform.selection = [d.uuid: [i]] }
                }
                drag.kind = .moveVertices
                snapshot()
            } else {
                drag.kind = .box
                deform.box = (p, p)
            }
        case .brush:
            if alt {
                drag.kind = .box
                deform.box = (p, p)
            } else {
                drag.kind = .brush
                snapshot()
                computeWeights(&drag, at: p)
                deform.brushPoint = p
            }
        case .path:
            if let i = deform.editedPath.point(near: p, radius: hitRadius) {
                drag.kind = .pathPoint(i)
                snapshot()
            } else if alt {
                drag.kind = .box
                deform.box = (p, p)
            }
        case .lasso:
            if !deform.polyLasso {
                drag.kind = .lasso
                deform.lasso = [p]
            }
        case .select:
            break
        }
        deform.drag = drag
    }

    private func computeWeights(_ drag: inout DeformSession.Drag, at p: Vec2) {
        let brush = deform.brush
        for d in deformTargets {
            let pos = drag.startPositions[d.uuid] ?? drawn(d)
            let sel = deform.selection[d.uuid] ?? []
            let anySelected = deform.hasSelection
            drag.weights[d.uuid] = pos.enumerated().map { i, v in
                if anySelected && !sel.contains(i) { return 0 }
                return brush.weight(v - p)
            }
        }
    }

    func deformDragChanged(_ p0: Vec2) {
        guard var drag = deform.drag else { return }
        var p = p0
        switch drag.kind {
        case .moveVertices:
            moveDeformSelection(by: p - drag.last)
        case .brush:
            if shift {
                let d = p - drag.start
                if drag.axisLock == nil, d.length > hitRadius * 2 { drag.axisLock = abs(d.x) > abs(d.y) ? 0 : 1 }
                if drag.axisLock == 0 { p.y = drag.start.y } else if drag.axisLock == 1 { p.x = drag.start.x }
            }
            let delta = p - drag.last
            if deform.flow {
                // Smear: weights follow the brush.
                for d in deformTargets { drag.startPositions[d.uuid] = drawn(d) }
                computeWeights(&drag, at: p)
            }
            for d in deformTargets {
                guard let w = drag.weights[d.uuid] else { continue }
                var o = offsets(d)
                let ld = localDelta(d, delta)
                for i in o.indices where i < w.count && w[i] > 0 { o[i] += ld * w[i] }
                setOffsets(d, o)
            }
            changed("Deform", commit: false)
        case .box:
            deform.box = (drag.start, p)
        case .lasso:
            if let l = deform.lasso.last, l.distance(to: p) > hitRadius * 0.8 { deform.lasso.append(p) }
        case .pathPoint(let i):
            dragPathPoint(i, to: p, drag: drag)
        case .none:
            break
        }
        drag.last = p
        deform.drag = drag
    }

    func deformDragEnded() {
        guard let drag = deform.drag else { return }
        switch drag.kind {
        case .box:
            if let b = deform.box {
                let lo = Vec2(Swift.min(b.0.x, b.1.x), Swift.min(b.0.y, b.1.y))
                let hi = Vec2(Swift.max(b.0.x, b.1.x), Swift.max(b.0.y, b.1.y))
                applySelection { v in v.x >= lo.x && v.x <= hi.x && v.y >= lo.y && v.y <= hi.y }
            }
            deform.box = nil
        case .lasso:
            finishDeformLasso()
        default:
            commitPending()
        }
        deform.drag = nil
        deform.brushPoint = nil
    }

    private func applySelection(_ inside: (Vec2) -> Bool) {
        if !shift && !ctrl { deform.selection = [:] }
        for d in deformTargets {
            var s = deform.selection[d.uuid] ?? []
            for (i, v) in drawn(d).enumerated() where inside(v) {
                if shift && ctrl { s.remove(i) } else if ctrl { s.remove(i) } else { s.insert(i) }
            }
            deform.selection[d.uuid] = s
        }
    }

    func finishDeformLasso() {
        let poly = deform.lasso
        deform.lasso = []
        guard poly.count > 2 else { return }
        applySelection { pointInPolygon($0, poly) }
        revision &+= 1
    }

    /// Moves selected vertices (and their mirror counterparts) by a model-space delta.
    func moveDeformSelection(by delta: Vec2) {
        let axes = EditableMesh.axes(horizontal: deform.mirrorH, vertical: deform.mirrorV).filter { $0 != 0 }
        var any = false
        for d in deformTargets {
            guard let sel = deform.selection[d.uuid], !sel.isEmpty else { continue }
            var o = offsets(d)
            let ld = localDelta(d, delta)
            // Mirror counterparts found by position in the drawable's local space.
            let local = EditableMesh(points: zip(d.vertices, o).map { $0 + $1 })
            let r = localRadius(d)
            var moved = Set<Int>()
            for i in sel where i < o.count {
                o[i] += ld
                moved.insert(i)
            }
            for i in sel {
                for a in axes {
                    if let m = local.mirrorVertex(i, axis: a, radius: r), !moved.contains(m) {
                        o[m] += EditableMesh.mirrorDelta(ld, axis: a)
                        moved.insert(m)
                    }
                }
            }
            setOffsets(d, o)
            any = true
        }
        if any { changed("Deform", commit: false) }
    }

    // MARK: Context actions

    /// Creator's "Reset selected": zero the selected vertices' offsets.
    func resetSelectedDeform() {
        for d in deformTargets {
            guard let sel = deform.selection[d.uuid], !sel.isEmpty else { continue }
            var o = offsets(d)
            for i in sel where i < o.count { o[i] = .zero }
            setOffsets(d, o)
        }
        changed("Reset selected vertices")
    }

    /// Creator's "Flip selected from mirror": copy the mirrored deformation
    /// from the flip partner (or the part itself) for the selected vertices.
    func flipSelectedFromMirror() {
        guard let puppet, let p = armed, let k = armedKeypoint else { return }
        for d in deformTargets {
            guard let sel = deform.selection[d.uuid], !sel.isEmpty,
                  let b = p.getOrAddBinding(node: d, target: "deform") else { continue }
            let partner = puppet.mirrorBinding(p, node: d, target: "deform", create: false)
            puppet.autoFlip(dest: b, src: partner === b ? nil : partner, at: k, axis: 0, extrapolate: true, selected: Array(sel))
        }
        changed("Flip selected from mirror")
    }

    // MARK: Path deform

    func setPathTransform(_ on: Bool) {
        guard on != deform.pathTransform else { return }
        if on {
            guard deform.path.points.count >= 2 else {
                message = "Draw a path first: double-tap to add at least two points along the part."
                return
            }
            deform.pathTarget = deform.path
            deform.pathBindings = [:]
            for d in deformTargets {
                var st = DeformSession.PathState()
                st.startPositions = drawn(d)
                st.startOffsets = offsets(d)
                st.binding.map(st.startPositions, reference: deform.path, target: deform.path)
                deform.pathBindings[d.uuid] = st
            }
            for n in deformNodeTargets {
                guard let puppet else { continue }
                var st = DeformSession.PathState()
                st.startPositions = [puppet.transform.matrix.apply(n.transform().matrix.origin)]
                st.startValues = (value(n, "transform.t.x"), value(n, "transform.t.y"), value(n, "transform.r.z"))
                st.binding.map(st.startPositions, reference: deform.path, target: deform.path)
                deform.pathBindings[n.uuid] = st
            }
        } else {
            // Re-define the path on the deformed shape.
            if let t = deform.pathTarget { deform.path = t }
            deform.pathTarget = nil
            deform.pathBindings = [:]
            commitPending()
        }
        deform.pathTransform = on
        deform.lockedPoint = nil
        revision &+= 1
    }

    private func dragPathPoint(_ i: Int, to p: Vec2, drag: DeformSession.Drag) {
        if !deform.pathTransform {
            deform.path.points[i] = p
            deform.path.interpolate()
            return
        }
        guard var target = deform.pathTarget, target.points.indices.contains(i) else { return }
        if let lock = deform.lockedPoint, lock != i, target.points.indices.contains(lock) {
            let c = target.points[lock]
            let angle = atan2(p.y - c.y, p.x - c.x) - atan2(drag.last.y - c.y, drag.last.x - c.x)
            let step = i > lock ? 1 : -1
            var j = lock + step
            while target.points.indices.contains(j) {
                let v = target.points[j] - c
                target.points[j] = c + Vec2(v.x * cos(angle) - v.y * sin(angle), v.x * sin(angle) + v.y * cos(angle))
                j += step
            }
        } else if shift {
            target.points[i] = deform.path.eval(deform.path.closestOffset(to: p))
        } else {
            target.points[i] += p - drag.last
        }
        target.interpolate()
        deform.pathTarget = target
        applyPath(target)
    }

    private func applyPath(_ target: CatmullSpline) {
        guard let puppet else { return }
        for d in deformTargets {
            guard let st = deform.pathBindings[d.uuid] else { continue }
            let sel = deform.selection[d.uuid]
            let positions = st.binding.positions(target: target, selected: sel)
            var o = st.startOffsets
            for (i, np) in positions.enumerated() where i < o.count && i < st.startPositions.count {
                guard let np else { continue }
                o[i] = st.startOffsets[i] + localDelta(d, np - st.startPositions[i])
            }
            setOffsets(d, o)
        }
        for n in deformNodeTargets {
            guard let st = deform.pathBindings[n.uuid], let np = st.binding.positions(target: target).first ?? nil,
                  let start = st.startPositions.first else { continue }
            let local = puppet.localDelta(n, from: np - start)
            let rot = st.binding.rotation(0, target: target)
            if armed != nil {
                setBound(n, "transform.t.x", st.startValues.0 + local.x)
                setBound(n, "transform.t.y", st.startValues.1 + local.y)
                if abs(rot) > 0.0001 { setBound(n, "transform.r.z", st.startValues.2 + rot) }
            }
        }
        changed("Path deform", commit: false)
    }
}

extension DeformSession {
    /// The path being edited: the target in Transform mode, else the reference.
    var editedPath: CatmullSpline { pathTransform ? (pathTarget ?? path) : path }
}
