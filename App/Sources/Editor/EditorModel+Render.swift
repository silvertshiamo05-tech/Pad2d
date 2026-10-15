import SwiftUI
import simd
import Inochi2DKit

/// Per-frame update, camera and editor overlays.
extension EditorModel {
    func renderFrame(deltaTime dt: Double, viewSize size: CGSize) -> RenderFrame? {
        guard let puppet, state == .ready else { return nil }
        viewSize = size
        switch mode {
        case .test:
            applyTestTracking()
            puppet.update(deltaTime: dt)
        case .animation:
            updateAnimation(dt)
            puppet.update(deltaTime: physicsPreview ? dt : 0)
        default:
            puppet.update(deltaTime: physicsPreview && armed == nil ? dt : 0)
        }
        let list = puppet.draw()
        lastList = list
        return RenderFrame(list: list, viewProjection: viewProjection(size),
                           preservePixels: puppet.meta.preservePixels, textures: textures,
                           overlay: buildOverlay(puppet, size))
    }

    var backgroundColor: SIMD4<Float>? {
        guard background == .custom else { return nil }
        let c = UIColor(customBackground)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        return SIMD4(Float(r), Float(g), Float(b), 1)
    }

    // MARK: Camera

    var scale: Float {
        guard let b = bounds else { return 1 }
        let w = CGFloat(b.2 - b.0), h = CGFloat(b.3 - b.1)
        guard w > 0, h > 0 else { return 1 }
        return Float(min(viewSize.width / w, viewSize.height / h) * 0.9 * zoom)
    }

    var center: Vec2 {
        let b = bounds ?? (-500, -500, 500, 500)
        return Vec2((b.0 + b.2) / 2, (b.1 + b.3) / 2)
    }

    private var flip: Float { mirrorView ? -1 : 1 }

    func viewProjection(_ size: CGSize) -> simd_float4x4 {
        let c = center, s = scale
        let w = Float(size.width), h = Float(size.height)
        let px = Float(pan.x), py = Float(pan.y)
        return simd_float4x4(columns: (
            SIMD4(2 * s / w * flip, 0, 0, 0),
            SIMD4(0, -2 * s / h, 0, 0),
            SIMD4(0, 0, 1, 0),
            SIMD4((-c.x * s * flip + px) * 2 / w, -(-c.y * s + py) * 2 / h, 0, 1)))
    }

    /// Model space -> drawable pixels.
    func toPixels(_ p: Vec2) -> Vec2 {
        let s = scale, c = center
        return Vec2((p.x - c.x) * s * flip + Float(pan.x) + Float(viewSize.width) / 2,
                    (p.y - c.y) * s + Float(pan.y) + Float(viewSize.height) / 2)
    }

    /// Drawable pixels -> model space.
    func toModel(_ p: Vec2) -> Vec2 {
        let s = scale, c = center
        return Vec2((p.x - Float(pan.x) - Float(viewSize.width) / 2) / (s * flip) + c.x,
                    (p.y - Float(pan.y) - Float(viewSize.height) / 2) / s + c.y)
    }

    func resetView() {
        zoom = 1
        pan = .zero
    }

    /// Centres the view on the selection.
    func focusSelection() {
        guard let b = selectionBounds() else { return }
        let c = Vec2((b.0 + b.2) / 2, (b.1 + b.3) / 2)
        let p = toPixels(c)
        pan.x -= CGFloat(p.x) - viewSize.width / 2
        pan.y -= CGFloat(p.y) - viewSize.height / 2
    }

    // MARK: Overlay

    struct OverlayBuilder {
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

        mutating func outlinedLine(_ a: Vec2, _ b: Vec2, _ width: Float, _ color: SIMD4<Float>) {
            line(a, b, width * 2.2, SIMD4(0, 0, 0, 0.8))
            line(a, b, width, color)
        }

        mutating func dot(_ c: Vec2, _ r: Float, _ color: SIMD4<Float>) {
            let n = 10
            let center = ndc(c)
            for i in 0..<n {
                let a0 = Float(i) / Float(n) * 2 * .pi, a1 = Float(i + 1) / Float(n) * 2 * .pi
                verts.append(OverlayVertex(position: center, color: color))
                verts.append(OverlayVertex(position: ndc(c + Vec2(cos(a0), sin(a0)) * r), color: color))
                verts.append(OverlayVertex(position: ndc(c + Vec2(cos(a1), sin(a1)) * r), color: color))
            }
        }

        mutating func point(_ c: Vec2, _ px: Float, _ color: SIMD4<Float>) {
            dot(c, 5 * px, SIMD4(0, 0, 0, 1))
            dot(c, 3 * px, color)
        }

        mutating func circle(_ c: Vec2, _ r: Float, _ width: Float, _ color: SIMD4<Float>) {
            let n = 48
            for i in 0..<n {
                let a0 = Float(i) / Float(n) * 2 * .pi, a1 = Float(i + 1) / Float(n) * 2 * .pi
                line(c + Vec2(cos(a0), sin(a0)) * r, c + Vec2(cos(a1), sin(a1)) * r, width, color)
            }
        }

        mutating func rect(_ a: Vec2, _ b: Vec2, _ width: Float, _ color: SIMD4<Float>) {
            let c = [a, Vec2(b.x, a.y), b, Vec2(a.x, b.y)]
            for i in 0..<4 { line(c[i], c[(i + 1) % 4], width, color) }
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

        mutating func edges(_ pts: [Vec2], _ edges: Set<MeshEdge>, _ width: Float, _ color: SIMD4<Float>) {
            for e in edges where e.a < pts.count && e.b < pts.count { line(pts[e.a], pts[e.b], width, color) }
        }

        mutating func spline(_ s: CatmullSpline, map: (Vec2) -> Vec2, _ width: Float, _ color: SIMD4<Float>) {
            let pts = s.samples.map(map)
            for i in pts.indices.dropFirst() { outlinedLine(pts[i - 1], pts[i], width, color) }
        }
    }

    static let accent = SIMD4<Float>(0.15, 0.55, 1, 1)
    static let armedColor = SIMD4<Float>(1, 0.25, 0.3, 1)
    static let grey = SIMD4<Float>(0.5, 0.5, 0.5, 1)
    static let selectedColor = SIMD4<Float>(1, 0, 0, 1)
    static let mirrorColor = SIMD4<Float>(1, 0, 1, 1)

    func buildOverlay(_ puppet: Puppet, _ size: CGSize) -> [OverlayVertex] {
        var o = OverlayBuilder(w: Float(size.width), h: Float(size.height))
        let px = Float(contentScale)
        switch mode {
        case .mesh: meshOverlay(&o, puppet, px)
        case .model: modelOverlay(&o, puppet, px)
        default: break
        }
        return o.verts
    }

    private func mirrorAxes(_ o: inout OverlayBuilder, h: Bool, v: Bool, map: (Vec2) -> Vec2, px: Float) {
        let big: Float = 100_000
        let c = SIMD4<Float>(0.8, 0, 0.8, 1)
        if h { o.line(map(Vec2(0, -big)), map(Vec2(0, big)), 1.5 * px, c) }
        if v { o.line(map(Vec2(-big, 0)), map(Vec2(big, 0)), 1.5 * px, c) }
    }

    private func meshOverlay(_ o: inout OverlayBuilder, _ puppet: Puppet, _ px: Float) {
        guard let s = meshSession, let d = meshTarget else { return }
        let m = puppet.meshMatrix(d)
        let map: (Vec2) -> Vec2 = { self.toPixels(m.apply($0 - d.origin)) }
        let pts = s.mesh.points.map(map)
        mirrorAxes(&o, h: s.mirrorH, v: s.mirrorV, map: map, px: px)
        if s.previewTriangulation {
            o.edges(pts, s.mesh.delaunayEdges(), 1.2 * px, SIMD4(0.7, 0.7, 0, 1))
        }
        o.edges(pts, s.mesh.edges, 1.5 * px, SIMD4(0, 0, 0, 0.7))
        o.edges(pts, s.mesh.edges, 0.8 * px, SIMD4(0.75, 0.75, 0.75, 1))
        let mirrored = s.mirrorSelection(radius: localRadius(d))
        for (i, p) in pts.enumerated() {
            let c: SIMD4<Float> = s.selection.contains(i) ? Self.selectedColor : mirrored.contains(i) ? Self.mirrorColor : SIMD4(1, 1, 1, 1)
            o.point(p, px, c)
        }
        if let b = s.box { o.rect(map(b.0), map(b.1), 1.5 * px, shift ? SIMD4(0, 1, 0, 0.8) : Self.selectedColor) }
        if let g = s.gridPreview {
            let a = g.0, b = g.1
            for i in 0..<3 {
                let t = Float(i) / 2
                o.line(map(Vec2(a.x + (b.x - a.x) * t, a.y)), map(Vec2(a.x + (b.x - a.x) * t, b.y)), 1.5 * px, SIMD4(0.2, 0.9, 0.9, 1))
                o.line(map(Vec2(a.x, a.y + (b.y - a.y) * t)), map(Vec2(b.x, a.y + (b.y - a.y) * t)), 1.5 * px, SIMD4(0.2, 0.9, 0.9, 1))
            }
        }
        lassoOverlay(&o, s.lasso.map(map), px)
    }

    private func lassoOverlay(_ o: inout OverlayBuilder, _ pts: [Vec2], _ px: Float) {
        guard pts.count > 1 else {
            if let p = pts.first { o.dot(p, 4 * px, SIMD4(0.6, 0.6, 0.6, 1)) }
            return
        }
        for i in pts.indices.dropFirst() { o.outlinedLine(pts[i - 1], pts[i], 1 * px, SIMD4(1, 1, 1, 1)) }
        o.dot(pts[0], 5 * px, SIMD4(1, 0.2, 0.2, 1))
    }

    private func modelOverlay(_ o: inout OverlayBuilder, _ puppet: Puppet, _ px: Float) {
        let armedNow = armed != nil
        let color = armedNow ? Self.armedColor : Self.accent
        for node in selectedNodes {
            if let d = node as? Drawable {
                let pts = drawn(d).map(toPixels)
                if showVertices || (armedNow && tool != .select) {
                    o.mesh(pts, d.indices, 1 * px, Self.grey)
                }
                if armedNow && (tool == .points || tool == .brush || tool == .lasso || tool == .path) {
                    let sel = deform.selection[d.uuid] ?? []
                    for (i, p) in pts.enumerated() { o.point(p, px, sel.contains(i) ? Self.selectedColor : SIMD4(1, 1, 1, 1)) }
                }
            }
            if showBounds {
                var b = node.combinedBounds()
                let m = puppet.transform.matrix
                let a = toPixels(m.apply(Vec2(b.0, b.1))), c = toPixels(m.apply(Vec2(b.2, b.3)))
                b = (a.x, a.y, c.x, c.y)
                o.rect(Vec2(b.0, b.1), Vec2(b.2, b.3), 2 * px, SIMD4(0.5, 0.5, 0.5, 1))
            }
            let origin = puppet.transform.matrix.apply(node.transform().matrix.origin)
            if showOrientation {
                let mat = node.transform().matrix
                let ox = puppet.transform.matrix.apply(mat.apply(Vec2(32, 0)))
                let oy = puppet.transform.matrix.apply(mat.apply(Vec2(0, -32)))
                o.line(toPixels(origin), toPixels(ox), 3 * px, SIMD4(1, 0, 0, 0.7))
                o.line(toPixels(origin), toPixels(oy), 3 * px, SIMD4(0, 1, 0, 0.7))
            } else {
                let op = toPixels(origin)
                o.line(op - Vec2(8 * px, 0), op + Vec2(8 * px, 0), 1.5 * px, color)
                o.line(op - Vec2(0, 8 * px), op + Vec2(0, 8 * px), 1.5 * px, color)
            }
            if let s = node as? SimplePhysics {
                let (a, b) = s.debugLine
                let m = puppet.transform.matrix
                o.line(toPixels(m.apply(a)), toPixels(m.apply(b)), 3 * px, SIMD4(1, 0, 1, 1))
            }
            if let cam = node as? Camera {
                let mat = cam.transform().matrix
                let hw = cam.viewport.x / 2, hh = cam.viewport.y / 2
                let corners = [Vec2(-hw, -hh), Vec2(hw, -hh), Vec2(hw, hh), Vec2(-hw, hh)].map { toPixels(puppet.transform.matrix.apply(mat.apply($0))) }
                for i in 0..<4 { o.outlinedLine(corners[i], corners[(i + 1) % 4], 1 * px, SIMD4(1, 1, 1, 1)) }
            }
        }
        // Cameras are always outlined lightly so they can be found.
        for case let cam as Camera in puppet.root.allNodes() where !isSelected(cam) {
            let mat = cam.transform().matrix
            let hw = cam.viewport.x / 2, hh = cam.viewport.y / 2
            let corners = [Vec2(-hw, -hh), Vec2(hw, -hh), Vec2(hw, hh), Vec2(-hw, hh)].map { toPixels(puppet.transform.matrix.apply(mat.apply($0))) }
            for i in 0..<4 { o.line(corners[i], corners[(i + 1) % 4], 1 * px, SIMD4(1, 1, 1, 0.35)) }
        }

        if armedNow {
            mirrorAxesForDeform(&o, puppet, px)
            if tool == .brush, let b = deform.brushPoint, !alt { brushOverlay(&o, b, px) }
            if tool == .path {
                let map: (Vec2) -> Vec2 = { self.toPixels($0) }
                if deform.pathTransform {
                    o.spline(deform.path, map: map, 1.5 * px, SIMD4(0, 0.6, 0.6, 1))
                    if let t = deform.pathTarget { o.spline(t, map: map, 1.5 * px, SIMD4(0, 1, 0, 1)) }
                } else {
                    o.spline(deform.path, map: map, 1.5 * px, SIMD4(0, 1, 1, 1))
                }
                for (i, p) in deform.editedPath.points.enumerated() {
                    o.point(toPixels(p), px * 1.3, deform.lockedPoint == i ? SIMD4(1, 0, 0, 1) : (deform.pathTransform ? SIMD4(0, 1, 0, 1) : SIMD4(0, 1, 1, 1)))
                }
            }
            if let b = deform.box { o.rect(toPixels(b.0), toPixels(b.1), 1.5 * px, shift ? SIMD4(0, 1, 0, 0.8) : Self.selectedColor) }
            lassoOverlay(&o, deform.lasso.map(toPixels), px)
        }

        // Transform handles.
        for (h, p) in handlePositions() {
            let r = 13 * px
            o.dot(p, r + 1.5 * px, SIMD4(0, 0, 0, 0.6))
            o.dot(p, r, armedNow ? Self.armedColor : Self.accent)
            switch h {
            case .move:
                o.line(p - Vec2(7 * px, 0), p + Vec2(7 * px, 0), 2 * px, SIMD4(1, 1, 1, 1))
                o.line(p - Vec2(0, 7 * px), p + Vec2(0, 7 * px), 2 * px, SIMD4(1, 1, 1, 1))
            case .scale:
                o.rect(p - Vec2(5 * px, 5 * px), p + Vec2(5 * px, 5 * px), 2 * px, SIMD4(1, 1, 1, 1))
            case .rotate:
                o.circle(p, 6 * px, 2 * px, SIMD4(1, 1, 1, 1))
            }
        }
    }

    private func mirrorAxesForDeform(_ o: inout OverlayBuilder, _ puppet: Puppet, _ px: Float) {
        guard deform.mirrorH || deform.mirrorV, let d = deformTargets.first else { return }
        let m = puppet.meshMatrix(d)
        mirrorAxes(&o, h: deform.mirrorH, v: deform.mirrorV, map: { self.toPixels(m.apply($0 - d.origin)) }, px: px)
    }

    private func brushOverlay(_ o: inout OverlayBuilder, _ b: Vec2, _ px: Float) {
        let c = toPixels(b)
        let unit = toPixels(b + Vec2(1, 0)).x - c.x
        let red = SIMD4<Float>(1, 0.1, 0.1, 1)
        switch deform.brush {
        case .circle(let r):
            o.circle(c, r * abs(unit), 3 * px, SIMD4(0, 0, 0, 0.8))
            o.circle(c, r * abs(unit), 1.5 * px, red)
        case .doubleThreshold(let r, let inner):
            o.circle(c, r * abs(unit), 1.5 * px, red)
            o.circle(c, inner * abs(unit), 1.5 * px, red)
        case .rectangle(let w, let h):
            o.rect(c - Vec2(w, h) * abs(unit), c + Vec2(w, h) * abs(unit), 1.5 * px, red)
        }
        o.line(c - Vec2(6 * px, 0), c + Vec2(6 * px, 0), 1.5 * px, red)
        o.line(c - Vec2(0, 6 * px), c + Vec2(0, 6 * px), 1.5 * px, red)
    }
}
