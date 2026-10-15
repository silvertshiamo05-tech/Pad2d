// Port of Inochi2D 0.8 SimplePhysics driver and physics systems
// (inochi2d.core.nodes.drivers.simplephysics, inochi2d.phys.system).
// Copyright © 2022, Inochi2D Project. Distributed under the 2-Clause BSD License.

import Foundation

/// RK4 integrator over a flat state vector.
class PhysicsSystem {
    var state: [Float] = []
    var t: Float = 0

    func derivative(_ s: [Float]) -> [Float] { [Float](repeating: 0, count: s.count) }

    func tick(_ h: Float) {
        let cur = state
        let k1 = derivative(cur)
        let k2 = derivative(zip(cur, k1).map { $0 + h * $1 / 2 })
        let k3 = derivative(zip(cur, k2).map { $0 + h * $1 / 2 })
        let k4 = derivative(zip(cur, k3).map { $0 + h * $1 })
        var next = cur
        for i in cur.indices {
            next[i] = cur[i] + h * (k1[i] + 2 * k2[i] + 2 * k3[i] + k4[i]) / 6
            if !next[i].isFinite {
                next = cur
                break
            }
        }
        state = next
        t += h
    }

    func updateAnchor() {}
}

/// Rigid pendulum: state = [angle, dAngle].
final class Pendulum: PhysicsSystem {
    unowned let driver: SimplePhysics
    var bob: Vec2

    init(driver: SimplePhysics) {
        self.driver = driver
        bob = driver.anchor + Vec2(0, driver.effectiveLength)
        super.init()
        state = [0, 0]
    }

    override func derivative(_ s: [Float]) -> [Float] {
        let angle = s[0], dAngle = s[1]
        let lengthRatio = driver.effectiveGravity / driver.effectiveLength
        let critDamp = 2 * lengthRatio.squareRoot()
        var dd = -lengthRatio * sin(angle)
        dd -= dAngle * driver.effectiveAngleDamping * critDamp
        return [dAngle, dd]
    }

    override func tick(_ h: Float) {
        let dBob = bob - driver.anchor
        state[0] = atan2(-dBob.x, dBob.y)
        super.tick(h)
        let dir = Vec2(-sin(state[0]), cos(state[0]))
        bob = driver.anchor + dir * driver.effectiveLength
        driver.output = bob
    }

    override func updateAnchor() {
        bob = driver.anchor + Vec2(0, driver.effectiveLength)
    }
}

/// Pendulum on a spring: state = [bob.x, bob.y, dBob.x, dBob.y].
final class SpringPendulum: PhysicsSystem {
    unowned let driver: SimplePhysics

    init(driver: SimplePhysics) {
        self.driver = driver
        super.init()
        let bob = driver.anchor + Vec2(0, driver.effectiveLength)
        state = [bob.x, bob.y, 0, 0]
    }

    override func derivative(_ s: [Float]) -> [Float] {
        let bob = Vec2(s[0], s[1]), dBob = Vec2(s[2], s[3])
        let springKsqrt = driver.effectiveFrequency * 2 * Float.pi
        let springK = springKsqrt * springKsqrt
        let g = driver.effectiveGravity
        let restLength = driver.effectiveLength - g / springK
        let offPos = bob - driver.anchor
        let offPosNorm = offPos.normalized
        let lengthRatio = g / driver.effectiveLength
        let critDampAngle = 2 * lengthRatio.squareRoot()
        let critDampLength = 2 * springKsqrt
        let dist = abs(driver.anchor.distance(to: bob))
        var force = Vec2(0, g)
        force -= offPosNorm * ((dist - restLength) * springK)
        var ddBob = force
        let dBobRot = Vec2(dBob.x * offPosNorm.y + dBob.y * offPosNorm.x,
                           dBob.y * offPosNorm.y - dBob.x * offPosNorm.x)
        let ddBobRot = -Vec2(dBobRot.x * driver.effectiveAngleDamping * critDampAngle,
                             dBobRot.y * driver.effectiveLengthDamping * critDampLength)
        let ddBobDamping = Vec2(ddBobRot.x * offPosNorm.y - dBobRot.y * offPosNorm.x,
                                ddBobRot.y * offPosNorm.y + dBobRot.x * offPosNorm.x)
        ddBob += ddBobDamping
        return [dBob.x, dBob.y, ddBob.x, ddBob.y]
    }

    override func tick(_ h: Float) {
        super.tick(h)
        driver.output = Vec2(state[0], state[1])
    }

    override func updateAnchor() {
        let bob = driver.anchor + Vec2(0, driver.effectiveLength)
        state[0] = bob.x
        state[1] = bob.y
    }
}

/// Drives a parameter from a simulated pendulum hanging off this node.
public final class SimplePhysics: Node {
    public enum Model: String, CaseIterable, Sendable { case pendulum, springPendulum }
    public enum MapMode: String, CaseIterable, Sendable { case angleLength, xy, lengthAngle, yx }

    var paramRef = UInt32.max
    public private(set) weak var param: Parameter?
    public var model = Model.pendulum
    public var mapMode = MapMode.angleLength
    public var localOnly = false
    public var gravity: Float = 1
    public var length: Float = 100
    public var frequency: Float = 1
    public var angleDamping: Float = 0.5
    public var lengthDamping: Float = 0.5
    public var outputScale = Vec2(1, 1)

    var offsetGravity: Float = 1
    var offsetLength: Float = 0
    var offsetFrequency: Float = 1
    var offsetAngleDamping: Float = 0.5
    var offsetLengthDamping: Float = 0.5
    var offsetOutputScale = Vec2(1, 1)

    var anchor = Vec2.zero
    var output = Vec2.zero
    var prevTransMat = Mat4.identity
    var prevAnchorSet = false
    var system: PhysicsSystem?

    override public var typeId: String { "SimplePhysics" }

    override func deserialize(_ json: [String: Any]) {
        super.deserialize(json)
        paramRef = json.uint32("param") ?? .max
        switch (json.string("model_type") ?? "").lowercased() {
        case "springpendulum", "spring_pendulum": model = .springPendulum
        default: model = .pendulum
        }
        switch (json.string("map_mode") ?? "").lowercased() {
        case "xy": mapMode = .xy
        case "yx": mapMode = .yx
        case "lengthangle", "length_angle": mapMode = .lengthAngle
        default: mapMode = .angleLength
        }
        gravity = json.float("gravity") ?? gravity
        length = json.float("length") ?? length
        frequency = json.float("frequency") ?? frequency
        angleDamping = json.float("angle_damping") ?? angleDamping
        lengthDamping = json.float("length_damping") ?? lengthDamping
        outputScale = json.vec2("output_scale") ?? outputScale
        localOnly = json.bool("local_only") ?? false
    }

    override func serialize() -> [String: Any] {
        var j = super.serialize()
        j["param"] = paramRef
        j["model_type"] = model == .pendulum ? "Pendulum" : "SpringPendulum"
        switch mapMode {
        case .angleLength: j["map_mode"] = "AngleLength"
        case .xy: j["map_mode"] = "XY"
        case .lengthAngle: j["map_mode"] = "LengthAngle"
        case .yx: j["map_mode"] = "YX"
        }
        j["gravity"] = gravity
        j["length"] = length
        j["frequency"] = frequency
        j["angle_damping"] = angleDamping
        j["length_damping"] = lengthDamping
        j["output_scale"] = [outputScale.x, outputScale.y]
        j["local_only"] = localOnly
        return j
    }

    /// Points the driver at a parameter (nil to disconnect).
    public func setParameter(_ p: Parameter?) {
        param = p
        paramRef = p?.uuid ?? .max
    }

    override func finalize() {
        param = puppet?.parameters.first { $0.uuid == paramRef }
        super.finalize()
        // Inochi2D 0.8 first resets the driver while the node is constructed,
        // before its own transform is loaded, and that stale transform is still
        // cached when it resets again here. The anchor therefore starts at the
        // parent's origin, giving a small swing on load. Reproduce it so models
        // move exactly as they do in Inochi Session.
        if !localOnly && !prevAnchorSet {
            anchor = parent?.transform().matrix.origin ?? .zero
        }
        system = model == .pendulum ? Pendulum(driver: self) : SpringPendulum(driver: self)
    }

    var pixelsPerMeter: Float { puppet?.physics.pixelsPerMeter ?? 1000 }
    var effectiveGravity: Float { gravity * offsetGravity * (puppet?.physics.gravity ?? 9.8) * pixelsPerMeter }
    var effectiveLength: Float { length + offsetLength }
    var effectiveFrequency: Float { frequency * offsetFrequency }
    var effectiveAngleDamping: Float { angleDamping * offsetAngleDamping }
    var effectiveLengthDamping: Float { lengthDamping * offsetLengthDamping }
    var effectiveOutputScale: Vec2 { outputScale * offsetOutputScale }

    override func beginUpdate() {
        super.beginUpdate()
        offsetGravity = 1
        offsetLength = 0
        offsetFrequency = 1
        offsetAngleDamping = 1
        offsetLengthDamping = 1
        offsetOutputScale = Vec2(1, 1)
    }

    private func anchorPosition() -> Vec2 {
        if localOnly {
            let t = transformLocal().translation
            return Vec2(t.x, t.y)
        }
        return transform().matrix.origin
    }

    override func preProcess() {
        let prev = anchorPosition()
        super.preProcess()
        let now = anchorPosition()
        if now != prev {
            anchor = now
            prevTransMat = transform().matrix.inverse
            prevAnchorSet = true
        }
    }

    override func postProcess() {
        let prev = anchorPosition()
        super.postProcess()
        let now = anchorPosition()
        if now != prev {
            anchor = now
            prevTransMat = transform().matrix.inverse
            prevAnchorSet = true
        }
    }

    func updateInputs() {
        if !prevAnchorSet { anchor = anchorPosition() }
    }

    func updateDriver(deltaTime: Float) {
        var h = min(deltaTime, 10)
        updateInputs()
        while h > 0.01 {
            system?.tick(0.01)
            h -= 0.01
        }
        system?.tick(h)
        updateOutputs()
        prevAnchorSet = false
    }

    func updateOutputs() {
        guard let param else { return }
        let scale = effectiveOutputScale
        let local: Vec2
        if localOnly {
            local = output
        } else {
            local = (prevAnchorSet ? prevTransMat : transform().matrix.inverse).apply(output)
        }
        let angle = local.normalized
        let relLength = output.distance(to: anchor) / effectiveLength
        var v: Vec2
        switch mapMode {
        case .xy:
            v = angle * relLength - Vec2(0, 1)
            v.y = -v.y
        case .angleLength:
            v = Vec2(atan2(-angle.x, angle.y) / .pi, relLength)
        case .yx:
            v = angle * relLength - Vec2(0, 1)
            v.y = -v.y
            v = Vec2(v.y, v.x)
        case .lengthAngle:
            v = Vec2(relLength, atan2(-angle.x, angle.y) / .pi)
        }
        param.pushOffset(Vec2(v.x * scale.x, v.y * scale.y), mode: .forced)
        param.update()
    }

    func reset() {
        updateInputs()
        system = model == .pendulum ? Pendulum(driver: self) : SpringPendulum(driver: self)
    }

    override func hasParam(_ key: String) -> Bool {
        if super.hasParam(key) { return true }
        return ["gravity", "length", "frequency", "angleDamping", "lengthDamping",
                "outputScale.x", "outputScale.y"].contains(key)
    }

    override func defaultValue(_ key: String) -> Float {
        let d = super.defaultValue(key)
        if !d.isNaN { return d }
        switch key {
        case "gravity", "frequency", "angleDamping", "lengthDamping", "outputScale.x", "outputScale.y": return 1
        case "length": return 0
        default: return .nan
        }
    }

    override func setValue(_ key: String, _ value: Float) -> Bool {
        if super.setValue(key, value) { return true }
        switch key {
        case "gravity": offsetGravity *= value
        case "length": offsetLength += value
        case "frequency": offsetFrequency *= value
        case "angleDamping": offsetAngleDamping *= value
        case "lengthDamping": offsetLengthDamping *= value
        case "outputScale.x": offsetOutputScale.x *= value
        case "outputScale.y": offsetOutputScale.y *= value
        default: return false
        }
        return true
    }
}

public extension SimplePhysics {
    /// Anchor and bob positions (puppet space) for drawing the pendulum.
    var debugLine: (Vec2, Vec2) { (anchor, output) }
}
