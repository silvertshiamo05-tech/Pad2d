// Port of Inochi2D 0.8 automation (inochi2d.core.automation): sine waves and
// verlet-chain physics that drive parameters.
// Copyright © 2022, Inochi2D Project. Distributed under the 2-Clause BSD License.

import Foundation

public struct AutomationBinding {
    public var paramName: String
    public var axis: Int
    public var range: Vec2
    public internal(set) weak var param: Parameter?

    public init(param: Parameter, axis: Int, range: Vec2) {
        paramName = param.name
        self.param = param
        self.axis = axis
        self.range = range
    }

    init(json: [String: Any]) {
        paramName = json.string("param") ?? ""
        axis = (json["axis"] as? NSNumber)?.intValue ?? 0
        range = json.vec2("range") ?? Vec2(0, 1)
    }

    func serialize() -> [String: Any] {
        ["param": param?.name ?? paramName, "axis": axis, "range": [range.x, range.y]]
    }

    var axisValue: Float {
        guard let p = param else { return .nan }
        return axis == 0 ? p.value.x : axis == 1 ? p.value.y : .nan
    }

    func addAxisOffset(_ v: Float) { param?.pushOffset(axis: axis, v) }
}

/// Base automation. Unknown types are kept as raw JSON.
public class Automation {
    public var name = ""
    public var enabled = true
    public var bindings: [AutomationBinding] = []
    public var typeId: String { "" }
    var raw: [String: Any] = [:]

    init() {}

    init(json: [String: Any]) {
        raw = json
        name = json.string("name") ?? ""
        bindings = (json.array("bindings") ?? []).compactMap { ($0 as? [String: Any]).map(AutomationBinding.init(json:)) }
    }

    func serialize() -> [String: Any] {
        var j = raw
        j["type"] = typeId.isEmpty ? raw["type"] : typeId
        j["name"] = name
        j["bindings"] = bindings.map { $0.serialize() }
        return j
    }

    func finalize(_ puppet: Puppet) {
        for i in bindings.indices {
            bindings[i].param = puppet.parameters.first { $0.name == bindings[i].paramName }
        }
    }

    func update(time: Double, deltaTime: Double) {}

    public func bind(_ b: AutomationBinding) { bindings.append(b) }

    static func make(json: [String: Any]) -> Automation {
        switch json.string("type") {
        case "sine": return SineAutomation(json: json)
        case "physics": return PhysicsAutomation(json: json)
        default: return Automation(json: json)
        }
    }
}

/// Sine-wave automation (type "sine").
public final class SineAutomation: Automation {
    public enum Wave: Int, CaseIterable { case sin, cos, tan }
    public var speed: Float = 1
    public var phase: Float = 0
    public var wave = Wave.sin
    override public var typeId: String { "sine" }

    override public init() { super.init() }

    override init(json: [String: Any]) {
        super.init(json: json)
        speed = json.float("speed") ?? 1
        if let n = json["sine_type"] as? NSNumber {
            wave = Wave(rawValue: n.intValue) ?? .sin
        } else {
            switch (json.string("sine_type") ?? "").lowercased() {
            case "cos": wave = .cos
            case "tan": wave = .tan
            default: wave = .sin
            }
        }
    }

    override func serialize() -> [String: Any] {
        var j = super.serialize()
        j["speed"] = speed
        j["sine_type"] = ["Sin", "Cos", "Tan"][wave.rawValue]
        return j
    }

    override func update(time: Double, deltaTime: Double) {
        guard enabled else { return }
        let x = Float(time) * speed + phase
        let w: Float
        switch wave {
        case .sin: w = (sin(x) + 1) / 2
        case .cos: w = (cos(x) + 1) / 2
        case .tan: w = (tan(x) + 1) / 2
        }
        for b in bindings { b.addAxisOffset(b.range.x + w * (b.range.y - b.range.x)) }
    }
}

/// Verlet-chain automation (type "physics"): the first binding is the hinge,
/// later bindings follow it like a hanging chain.
public final class PhysicsAutomation: Automation {
    public struct VerletNode {
        public var distance: Float = 1
        public var position: Vec2
        public var oldPosition: Vec2
    }

    public var nodes: [VerletNode] = []
    public var damping: Float = 0.05
    public var bounciness: Float = 1
    public var gravity: Float = 20
    override public var typeId: String { "physics" }

    override public init() { super.init() }

    override init(json: [String: Any]) {
        super.init(json: json)
        nodes = (json.array("nodes") ?? []).compactMap { n in
            guard let n = n as? [String: Any] else { return nil }
            return VerletNode(distance: n.float("distance") ?? 1, position: n.vec2("position") ?? .zero,
                              oldPosition: n.vec2("old_position") ?? .zero)
        }
        damping = json.float("damping") ?? 0.05
        bounciness = json.float("bounciness") ?? 1
        gravity = json.float("gravity") ?? 20
    }

    override func serialize() -> [String: Any] {
        var j = super.serialize()
        j["nodes"] = nodes.map { ["distance": $0.distance, "position": [$0.position.x, $0.position.y],
                                  "old_position": [$0.oldPosition.x, $0.oldPosition.y]] as [String: Any] }
        j["damping"] = damping
        j["bounciness"] = bounciness
        j["gravity"] = gravity
        return j
    }

    override public func bind(_ b: AutomationBinding) {
        super.bind(b)
        nodes.append(VerletNode(position: Vec2(0, 1), oldPosition: Vec2(0, 1)))
    }

    override func update(time: Double, deltaTime: Double) {
        guard enabled, bindings.count > 1, nodes.count >= bindings.count else { return }
        let dt = Float(deltaTime)
        for i in bindings.indices {
            let tmp = nodes[i].position
            nodes[i].position = (nodes[i].position - nodes[i].oldPosition) + Vec2(0, gravity) * (dt * dt) * bounciness
            nodes[i].oldPosition = tmp
        }
        for _ in 0..<(4 + bindings.count * 2) { constrain() }
        for i in bindings.indices {
            nodes[i].position.x = clamp(nodes[i].position.x, bindings[i].range.x, bindings[i].range.y)
            bindings[i].addAxisOffset(nodes[i].position.x)
        }
    }

    private func constrain() {
        for i in 0..<(nodes.count - 1) {
            if i == 0 { nodes[0].position = Vec2(bindings[0].axisValue, 0) }
            let d = nodes[i].position - nodes[i + 1].position
            let dist = d.length
            let diff = dist > 0 ? (nodes[i + 1].distance - dist) / dist : 0
            let trans = d * (0.5 * diff)
            nodes[i].position += trans
            nodes[i + 1].position -= trans
            nodes[i + 1].position.y = Swift.max(nodes[i + 1].position.y, nodes[i].position.y)
        }
    }
}
