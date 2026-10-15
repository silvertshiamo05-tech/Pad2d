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
