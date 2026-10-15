import XCTest
@testable import Inochi2DKit

/// Puppet with two mirrored quad parts and a 1D parameter (-1...1, keypoint at 0).
private func makePair() -> (Puppet, Part, Part, Parameter) {
    let puppet = Puppet()
    let px = [UInt8](repeating: 255, count: 4 * 4 * 4)
    let slot = puppet.addTexture(rgba: px, width: 4, height: 4)
    let left = puppet.makePart(name: "Eye L", textureSlot: slot, width: 20, height: 10)
    let right = puppet.makePart(name: "Eye R", textureSlot: slot, width: 20, height: 10)
    left.localTransform.translation = Vec3(-30, 0, 0)
    right.localTransform.translation = Vec3(30, 0, 0)
    puppet.add(left, to: puppet.root)
    puppet.add(right, to: puppet.root)
    let p = puppet.createParameter(name: "Look", isVec2: false, min: Vec2(-1, 0), max: Vec2(1, 0))
    puppet.addKeypoint(p, axis: 0, at: 0.5)
    return (puppet, left, right, p)
}

final class AnimationTests: XCTestCase {
    func testLaneInterpolation() {
        let p = Parameter(json: [:])
        let lane = AnimationLane(parameter: p, axis: 0, frames: [Keyframe(frame: 0, value: 0), Keyframe(frame: 10, value: 1)])
        XCTAssertEqual(lane.value(at: 5), 0.5, accuracy: 1e-5)
        lane.interpolation = .stepped
        XCTAssertEqual(lane.value(at: 9), 0)
        lane.interpolation = .nearest
        XCTAssertEqual(lane.value(at: 6), 1)
        lane.interpolation = .bezier
        XCTAssertEqual(lane.value(at: 5), 0.5, accuracy: 1e-5)
        XCTAssertEqual(lane.value(at: 20), 1)
    }

    func testRoundTripAndPlayback() throws {
        let (puppet, left, _, p) = makePair()
        puppet.setValue(p, left, target: "transform.t.y", at: Keypoint(2, 0), value: 10)
        let anim = Animation()
        anim.length = 60
        anim.lanes = [AnimationLane(parameter: p, axis: 0, frames: [Keyframe(frame: 0, value: -1), Keyframe(frame: 59, value: 1)])]
        puppet.animations["Wave"] = anim

        let reloaded = try Puppet(data: puppet.fileData())
        let a = try XCTUnwrap(reloaded.animations["Wave"])
        XCTAssertEqual(a.length, 60)
        XCTAssertEqual(a.lanes.first?.frames.count, 2)
        XCTAssertTrue(a.lanes.first?.parameter === reloaded.parameter(named: "Look"))

        let player = AnimationPlayer(puppet: reloaded)
        let pb = try XCTUnwrap(player.play("Wave", loop: true))
        player.update(1.0 / 60 * 59)
        XCTAssertEqual(pb.frame, 59)
        XCTAssertEqual(reloaded.parameter(named: "Look")!.value.x, 1, accuracy: 0.02)
    }
}

final class FormatTests: XCTestCase {
    func testGroupsCameraAndMergeMode() throws {
        let (puppet, _, _, p) = makePair()
        let g = puppet.addGroup(name: "Eyes")
        g.color = Vec3(0.25, 0.15, 0.15)
        p.groupUUID = g.uuid
        let cam = puppet.makeNode(.camera, name: "Camera") as! Camera
        cam.viewport = Vec2(1280, 720)
        puppet.add(cam, to: puppet.root)

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONWriter.encode(puppet.serializeJSON())) as? [String: Any])
        let pj = try XCTUnwrap((json["param"] as? [[String: Any]])?.first)
        XCTAssertEqual(pj["merge_mode"] as? String, "Additive")

        let r = try Puppet(data: puppet.fileData())
        XCTAssertEqual(r.groups.map(\.name), ["Eyes"])
        XCTAssertEqual(r.parameter(named: "Look")?.groupUUID, g.uuid)
        let c = try XCTUnwrap(r.root.allNodes().compactMap { $0 as? Camera }.first)
        XCTAssertEqual(c.viewport, Vec2(1280, 720))
    }

    func testThreeTextureSlots() throws {
        let (puppet, left, _, _) = makePair()
        left.textureIDs = [0, nil, 0]
        let r = try Puppet(data: puppet.fileData())
        let part = try XCTUnwrap(r.parts.first { $0.name == "Eye L" })
        XCTAssertEqual(part.textureIDs, [0, nil, 0])
        XCTAssertEqual(part.textureSlots, [0, 0])
    }

    func testPhysicsAutomationRuns() throws {
        let (puppet, _, _, p) = makePair()
        let q = puppet.createParameter(name: "Tail", isVec2: false, min: Vec2(-1, 0), max: Vec2(1, 0))
        let auto = PhysicsAutomation()
        auto.bind(AutomationBinding(param: p, axis: 0, range: Vec2(-1, 1)))
        auto.bind(AutomationBinding(param: q, axis: 0, range: Vec2(-1, 1)))
        puppet.automation = [auto]
        let r = try Puppet(data: puppet.fileData())
        XCTAssertTrue(r.automation.first is PhysicsAutomation)
        XCTAssertEqual(r.automation.first?.bindings.count, 2)
        for _ in 0..<10 { r.update(deltaTime: 1 / 60) }
    }
}

final class BindingOpsTests: XCTestCase {
    func testScaleExtrapolateCopySwap() {
        let (puppet, left, right, p) = makePair()
        let k0 = Keypoint(0, 0), k2 = Keypoint(2, 0)
        puppet.setValue(p, left, target: "transform.t.x", at: k2, value: 8)
        let b = p.binding(node: left, target: "transform.t.x")!
        b.extrapolateValue(at: k0, axis: 0)
        XCTAssertEqual(b.floatValue(k0), -8)
        b.scaleValue(at: k0, axis: 1, scale: -1) // t.x isn't vertical: unchanged
        XCTAssertEqual(b.floatValue(k0), -8)

        let other = p.getOrAddBinding(node: right, target: "transform.t.x")!
        b.copyKeypoint(k2, to: other, at: k2)
        XCTAssertEqual(other.floatValue(k2), 8)
        other.setFloat(k0, 3)
        b.swapKeypoint(k0, with: other, at: k0)
        XCTAssertEqual(b.floatValue(k0), 3)
        XCTAssertEqual(other.floatValue(k0), -8)

        p.reverseAxis(0)
        XCTAssertEqual(b.floatValue(Keypoint(0, 0)), 8)
        XCTAssertEqual(p.axisKeypoints[0], [0, 0.5, 1])
    }

    func testTransferDeformation() {
        let (_, left, _, _) = makePair()
        let offsets = left.vertices.map { Vec2($0.x * 0.1, 2) }
        let same = transferDeformation(to: left.vertices, from: left.vertices, indices: left.indices,
                                       offsets: offsets, flipHorizontally: false)
        for (a, b) in zip(same, offsets) { XCTAssertEqual(a.distance(to: b), 0, accuracy: 1e-4) }
        let flipped = transferDeformation(to: left.vertices, from: left.vertices, indices: left.indices,
                                          offsets: offsets, flipHorizontally: true)
        // x offsets are symmetric (x*0.1 mirrored is still x*0.1 on the mirrored vertex), y unchanged.
        for (a, b) in zip(flipped, offsets) { XCTAssertEqual(a.distance(to: b), 0, accuracy: 1e-4) }
    }

    func testMirroredAutofillUsesPartner() {
        let (puppet, left, right, p) = makePair()
        puppet.flipPairs = puppet.autoPair(" L", " R")
        XCTAssertTrue(puppet.flipPartner(of: left) === right)
        let k2 = Keypoint(2, 0), k0 = Keypoint(0, 0)
        puppet.setValue(p, left, target: "transform.t.x", at: k2, value: 5)
        // Right side looking right mirrors left side looking left.
        puppet.mirroredAutofill(p, axis: 0, range: 0...0.4999)
        let rb = p.binding(node: right, target: "transform.t.x")
        XCTAssertEqual(rb?.floatValue(k0), -5)

        let r = try! Puppet(data: puppet.fileData())
        XCTAssertEqual(r.flipPairs.count, 1)
    }

    func testDuplicateConvertSplit() {
        let (puppet, left, right, p) = makePair()
        puppet.setValue(p, left, target: "transform.t.x", at: Keypoint(2, 0), value: 5)
        puppet.setValue(p, right, target: "transform.t.x", at: Keypoint(2, 0), value: 6)
        let d = puppet.duplicateParameter(p)
        XCTAssertEqual(d.name, "Look (Copy)")
        XCTAssertEqual(d.binding(node: left, target: "transform.t.x")?.floatValue(Keypoint(2, 0)), 5)

        let s = puppet.splitParameter(p, moving: [right])!
        XCTAssertEqual(p.bindingCount, 1)
        XCTAssertEqual(s.binding(node: right, target: "transform.t.x")?.floatValue(Keypoint(2, 0)), 6)
        XCTAssertEqual(s.min, p.min)

        let two = puppet.convertTo2D(p)!
        XCTAssertTrue(two.isVec2)
        XCTAssertEqual(two.uuid, p.uuid)
        XCTAssertEqual(two.binding(node: left, target: "transform.t.x")?.floatValue(Keypoint(2, 0)), 5)
    }
}

final class MeshEditingTests: XCTestCase {
    func testTrianglesFromEdges() {
        // A square with a centre vertex connected to all corners: 4 faces, and
        // the outer triangles formed by the square's edges + diagonal-free
        // ring aren't produced.
        var m = EditableMesh(points: [Vec2(0, 0), Vec2(10, 0), Vec2(10, 10), Vec2(0, 10), Vec2(5, 5)])
        for i in 0..<4 { m.connect(i, (i + 1) % 4); m.connect(i, 4) }
        XCTAssertEqual(m.triangleCount, 4)
        // Adding a diagonal creates triangles that enclose the centre: rejected.
        m.connect(0, 2)
        XCTAssertEqual(m.triangleCount, 4)
        m.remove(4)
        XCTAssertEqual(m.triangleCount, 2)
    }

    func testGridAndLasso() {
        let g = EditableMesh.grid([[0, 5, 10], [0, 10, 20]])
        XCTAssertEqual(g.points.count, 9)
        XCTAssertEqual(g.exportIndices().count, 8 * 3)
        XCTAssertTrue(g.isGrid)
        let inside = g.vertices(inPolygon: [Vec2(-1, -1), Vec2(11, -1), Vec2(11, 11), Vec2(-1, 11)])
        XCTAssertEqual(Set(inside), [0, 1, 3, 4, 6, 7])
    }

    func testContourAutoMeshOnDisc() {
        let w = 128, h = 128
        let alpha: (Int, Int) -> UInt8 = { x, y in pow(Float(x - 64), 2) + pow(Float(y - 64), 2) < 1600 ? 255 : 0 }
        let pts = ContourAutoMesh.preset(.normal).points(alpha: alpha, width: w, height: h)
        XCTAssertGreaterThan(pts.count, 6)
        // Outer ring is ~1.1 × radius 40 from the centre.
        let far = pts.map { $0.distance(to: Vec2(64, 64)) }.max()!
        XCTAssertGreaterThan(far, 40)
        XCTAssertLessThan(far, 50)
        var m = EditableMesh(points: pts)
        m.triangulate()
        XCTAssertGreaterThan(m.triangleCount, 4)
    }

    func testApplyMeshKeepsDeformation() throws {
        let (puppet, left, _, p) = makePair()
        let offsets = left.vertices.map { _ in Vec2(0, 5) }
        puppet.setDeformation(p, left, at: Keypoint(2, 0), offsets: offsets)
        var m = EditableMesh(left)
        let c = m.add(Vec2(0, 0))
        for i in 0..<4 { m.connect(i, c) }
        XCTAssertTrue(puppet.applyMesh(m, to: left))
        XCTAssertEqual(left.vertices.count, 5)
        let d = puppet.deformation(p, left, at: Keypoint(2, 0))
        for o in d { XCTAssertEqual(o.y, 5, accuracy: 1e-3) }
    }
}

final class SplineTests: XCTestCase {
    func testEvalAndClosest() {
        let s = CatmullSpline(points: [Vec2(0, 0), Vec2(100, 0), Vec2(200, 0), Vec2(300, 0)])
        XCTAssertEqual(s.eval(1.5).x, 150, accuracy: 1)
        XCTAssertEqual(s.eval(1.5).y, 0, accuracy: 1e-3)
        XCTAssertEqual(s.closestOffset(to: Vec2(150, 40)), 1.5, accuracy: 0.02)
    }

    func testPathBendsVertices() {
        let ref = CatmullSpline(points: [Vec2(0, 0), Vec2(100, 0), Vec2(200, 0)])
        var target = ref
        var b = PathBinding()
        let verts = [Vec2(50, 10), Vec2(150, -10), Vec2(-50, 0)]
        b.map(verts, reference: ref, target: target)
        // Unmoved path keeps vertices in place; vertices past the ends aren't bound.
        let same = b.positions(target: target)
        XCTAssertEqual(same[0]!.distance(to: verts[0]), 0, accuracy: 0.5)
        XCTAssertNil(same[2])
        // Shifting the whole path moves the vertices with it.
        target.points = target.points.map { $0 + Vec2(0, 30) }
        target.interpolate()
        let moved = b.positions(target: target)
        XCTAssertEqual(moved[0]!.y, 40, accuracy: 0.5)
        XCTAssertEqual(moved[1]!.y, 20, accuracy: 0.5)
    }

    func testBrushes() {
        XCTAssertEqual(DeformBrush.circle(radius: 100).weight(Vec2(50, 0)), 0.5, accuracy: 1e-5)
        XCTAssertEqual(DeformBrush.doubleThreshold(radius: 100, inner: 50).weight(Vec2(40, 0)), 1)
        XCTAssertEqual(DeformBrush.rectangle(width: 100, height: 50).weight(Vec2(0, 25)), 0.5, accuracy: 1e-5)
    }
}

final class ToolsTests: XCTestCase {
    func testColorBleed() {
        // 3x1: red opaque, then two transparent pixels.
        var px: [UInt8] = [255, 0, 0, 255, 0, 0, 0, 0, 0, 0, 0, 0]
        colorBleed(&px, width: 3, height: 1)
        XCTAssertEqual(Array(px[4..<8]), [255, 0, 0, 0])
        XCTAssertEqual(Array(px[8..<12]), [255, 0, 0, 0])
    }

    func testRegenerateIDsKeepsLinks() throws {
        let (puppet, left, right, p) = makePair()
        puppet.setMasks(right, sources: [(left.uuid, .mask)])
        puppet.setValue(p, left, target: "transform.t.x", at: Keypoint(2, 0), value: 3)
        puppet.flipPairs = [FlipPair(left.uuid, right.uuid)]
        let oldLeft = left.uuid
        puppet.regenerateNodeIDs()
        XCTAssertNotEqual(left.uuid, oldLeft)
        XCTAssertEqual(right.masks.first?.sourceID, left.uuid)
        XCTAssertTrue(p.binding(node: left, target: "transform.t.x") != nil)
        XCTAssertTrue(puppet.flipPartner(of: left) === right)
        let r = try Puppet(data: puppet.fileData())
        XCTAssertEqual(r.parameters.first?.bindingCount, 1)
    }
}

final class ExportTests: XCTestCase {
    func testPackerAndAtlasExport() throws {
        var packer = MaxRectsPacker(width: 100, height: 100)
        XCTAssertNotNil(packer.pack(60, 60))
        XCTAssertNotNil(packer.pack(40, 100))
        XCTAssertNil(packer.pack(50, 50))

        let (puppet, left, right, _) = makePair()
        right.enabled = false
        let cam = puppet.makeNode(.camera, name: "Cam")
        puppet.add(cam, to: puppet.root)
        var s = INPExportSettings()
        s.atlasResolution = 256
        s.padding = 4
        let r = try puppet.exportINP(s) { blob in
            (try? TGADecoder.decode(blob.data)).map { ($0.rgba, $0.width, $0.height) }
        }
        let out = try Puppet(data: r.data)
        XCTAssertEqual(out.textures.count, 1)
        XCTAssertEqual(out.parts.map(\.name), [left.name]) // hidden part pruned
        XCTAssertFalse(out.root.allNodes().contains { $0 is Camera })
        let uv = out.parts[0].uvs
        XCTAssertTrue(uv.allSatisfy { $0.x >= 0 && $0.x <= 1 && $0.y >= 0 && $0.y <= 1 })
        XCTAssertGreaterThan(uv.map(\.x).min()!, 0) // padded
    }
}
