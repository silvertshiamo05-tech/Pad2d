// Port of Inochi2D 0.8 parameters and bindings (inochi2d.core.param).
// Copyright © 2022, Inochi2D Project. Distributed under the 2-Clause BSD License.

import Foundation

public enum ParamMergeMode: String, Sendable {
    case additive, weighted, multiplicative, forced, passthrough
}

public enum InterpolateMode: Sendable {
    case nearest, linear, cubic

    init(_ any: Any?) {
        if let s = any as? String {
            switch s.lowercased() {
            case "nearest", "stepped": self = .nearest
            case "cubic": self = .cubic
            default: self = .linear
            }
        } else if let n = any as? NSNumber {
            self = n.intValue == 0 ? .nearest : (n.intValue == 2 ? .cubic : .linear)
        } else {
            self = .linear
        }
    }
}

/// A user-facing control (e.g. "Head:: Yaw-Pitch") that drives bindings.
public final class Parameter {
    public internal(set) var uuid: UInt32 = 0
    public internal(set) var name = ""
    public var active = true
    public internal(set) var isVec2 = false
    public internal(set) var min = Vec2(0, 0)
    public internal(set) var max = Vec2(1, 1)
    public internal(set) var defaults = Vec2(0, 0)
    public var value = Vec2(0, 0)
    public internal(set) var lastInternal = Vec2(0, 0)
    var mergeMode = ParamMergeMode.passthrough
    var axisPoints: [[Float]] = [[0, 1], [0, 1]]
    var bindings: [Binding] = []

    private var addSum = Vec2.zero
    private var addCount = 0
    private var mulSum = Vec2.zero
    private var mulCount = 0

    /// Number of bindings (for diagnostics).
    public var bindingCount: Int { bindings.count }

    init(json: [String: Any]) {
        uuid = json.uint32("uuid") ?? 0
        name = json.string("name") ?? ""
        isVec2 = json.bool("is_vec2") ?? false
        min = json.vec2("min") ?? min
        max = json.vec2("max") ?? max
        if let ap = json["axis_points"] as? [[NSNumber]], ap.count >= 2 {
            axisPoints = [ap[0].map(\.floatValue), ap[1].map(\.floatValue)]
        }
        defaults = json.vec2("defaults") ?? defaults
        if let m = json.string("merge_mode"), let mode = ParamMergeMode(rawValue: m.lowercased()) {
            mergeMode = mode
        }
        for case let b as [String: Any] in json.array("bindings") ?? [] {
            guard let target = b.string("param_name") else { continue }
            let binding: Binding? = target == "deform"
                ? DeformBinding(parameter: self, json: b)
                : ValueBinding(parameter: self, json: b)
            if let binding { bindings.append(binding) }
        }
    }

    func finalize(_ puppet: Puppet) {
        value = defaults
        bindings = bindings.filter { b in
            guard let node = puppet.root.find(uuid: b.nodeRef) else { return false }
            b.node = node
            return b.validate()
        }
    }

    /// Normalised (0...1) position of a value within the parameter's range.
    public func mapValue(_ v: Vec2) -> Vec2 {
        let range = max - min
        let off = Vec2((v.x - min.x) / range.x, (v.y - min.y) / range.y)
        return Vec2(off.x.isNaN ? off.x : clamp(off.x, 0, 1), off.y.isNaN ? off.y : clamp(off.y, 0, 1))
    }

    public func unmapValue(_ offset: Vec2) -> Vec2 {
        let range = max - min
        return Vec2(range.x * offset.x, range.y * offset.y) + min
    }

    /// Normalised value, as used by sliders.
    public var normalizedValue: Vec2 {
        get { mapValue(value) }
        set { value = unmapValue(newValue) }
    }

    func findOffset(_ offset: Vec2) -> (index: (Int, Int), offset: Vec2) {
        func interpAxis(_ axis: Int, _ val: Float) -> (Int, Float) {
            let pos = axisPoints[axis]
            guard pos.count >= 2 else { return (0, 0) }
            for i in 0..<(pos.count - 1) where pos[i + 1] > val || i == pos.count - 2 {
                return (i, (val - pos[i]) / (pos[i + 1] - pos[i]))
            }
            return (0, 0)
        }
        let x = interpAxis(0, offset.x)
        let y = isVec2 ? interpAxis(1, offset.y) : (0, Float(0))
        return ((x.0, y.0), Vec2(x.1, y.1))
    }

    func update() {
        guard active else { return }
        let mul = mulCount == 0 ? Vec2(1, 1) : mulSum / Float(mulCount)
        lastInternal = (value + addSum) * mul
        let (index, offset) = findOffset(mapValue(lastInternal))
        for b in bindings { b.apply(index, offset) }
        addSum = .zero
        addCount = 0
        mulSum = .zero
        mulCount = 0
    }

    func pushOffset(_ offset: Vec2, mode: ParamMergeMode = .passthrough, weight: Float = 1) {
        let m = mode == .passthrough ? mergeMode : mode
        switch m {
        case .forced: value = offset
        case .additive: addSum += offset; addCount += 1
        case .multiplicative: mulSum += offset; mulCount += 1
        case .weighted: mulSum += offset * weight; mulCount += 1
        case .passthrough: break
        }
    }

    func pushOffset(axis: Int, _ offset: Float, mode: ParamMergeMode = .passthrough, weight: Float = 1) {
        let m = mode == .passthrough ? mergeMode : mode
        let v = Vec2(axis == 0 ? offset : 1, axis == 1 ? offset : 1)
        switch m {
        case .forced: if axis == 0 { value.x = offset } else { value.y = offset }
        case .additive: addSum += v; addCount += 1
        case .multiplicative: mulSum += v; mulCount += 1
        case .weighted: mulSum += v * weight; mulCount += 1
        case .passthrough: break
        }
    }
}

// MARK: - Bindings

class Binding {
    unowned let parameter: Parameter
    let nodeRef: UInt32
    let target: String
    let interpolation: InterpolateMode
    var isSet: [[Bool]]
    weak var node: Node?

    init(parameter: Parameter, json: [String: Any]) {
        self.parameter = parameter
        nodeRef = json.uint32("node") ?? 0
        target = json.string("param_name") ?? ""
        interpolation = InterpolateMode(json["interpolate_mode"])
        isSet = (json["isSet"] as? [[NSNumber]])?.map { $0.map(\.boolValue) } ?? []
    }

    var xCount: Int { parameter.axisPoints[0].count }
    var yCount: Int { parameter.axisPoints[1].count }

    func validate() -> Bool { true }

    func apply(_ index: (Int, Int), _ offset: Vec2) {}

    /// The keypoints and weights whose weighted sum is the interpolated value.
    func weights(_ index: (Int, Int), _ offset: Vec2) -> [(x: Int, y: Int, w: Float)] {
        let xMax = xCount - 1, yMax = Swift.max(yCount - 1, 0)
        let ix = Swift.min(Swift.max(index.0, 0), xMax), iy = Swift.min(Swift.max(index.1, 0), yMax)
        let ix1 = Swift.min(ix + 1, xMax), iy1 = Swift.min(iy + 1, yMax)
        let vec2 = parameter.isVec2
        switch interpolation {
        case .nearest:
            let px = offset.x >= 0.5 ? ix1 : ix
            let py = vec2 ? (offset.y >= 0.5 ? iy1 : iy) : 0
            return [(px, py, 1)]
        case .linear:
            if vec2 {
                let ox = offset.x, oy = offset.y
                return [(ix, iy, (1 - ox) * (1 - oy)), (ix, iy1, (1 - ox) * oy),
                        (ix1, iy, ox * (1 - oy)), (ix1, iy1, ox * oy)]
            }
            return [(ix, 0, 1 - offset.x), (ix1, 0, offset.x)]
        case .cubic:
            let wx = cubicWeights(offset.x)
            let xs = [Swift.max(ix - 1, 0), ix, ix1, Swift.min(ix + 2, xMax)]
            let wxs = [wx.0, wx.1, wx.2, wx.3]
            if vec2 {
                let wy = cubicWeights(offset.y)
                let wys = [wy.0, wy.1, wy.2, wy.3]
                var out: [(x: Int, y: Int, w: Float)] = []
                for yk in 0..<4 {
                    let yp = Swift.min(Swift.max(iy + yk - 1, 0), yMax)
                    for xk in 0..<4 { out.append((xs[xk], yp, wxs[xk] * wys[yk])) }
                }
                return out
            }
            return (0..<4).map { (xs[$0], 0, wxs[$0]) }
        }
    }
}

final class ValueBinding: Binding {
    var values: [[Float]]

    override init(parameter: Parameter, json: [String: Any]) {
        values = (json["values"] as? [[NSNumber]])?.map { $0.map(\.floatValue) } ?? []
        super.init(parameter: parameter, json: json)
    }

    override func validate() -> Bool {
        values.count == xCount && values.allSatisfy { $0.count == yCount }
    }

    override func apply(_ index: (Int, Int), _ offset: Vec2) {
        guard let node else { return }
        var v: Float = 0
        for (x, y, w) in weights(index, offset) where w != 0 { v += values[x][y] * w }
        node.setValue(target, v)
    }
}

final class DeformBinding: Binding {
    var values: [[[Vec2]]]

    override init(parameter: Parameter, json: [String: Any]) {
        var vals: [[[Vec2]]] = []
        for case let col as [Any] in (json["values"] as? [Any]) ?? [] {
            var c: [[Vec2]] = []
            for case let cell as [Any] in col {
                c.append(cell.compactMap { p in
                    guard let a = p as? [NSNumber], a.count >= 2 else { return nil }
                    return Vec2(a[0].floatValue, a[1].floatValue)
                })
            }
            vals.append(c)
        }
        values = vals
        super.init(parameter: parameter, json: json)
    }

    override func validate() -> Bool {
        guard values.count == xCount, values.allSatisfy({ $0.count == yCount }) else { return false }
        // A file may store empty offsets for unset keypoints; treat those as zero.
        if let d = node as? Drawable {
            for x in values.indices {
                for y in values[x].indices where values[x][y].count != d.vertices.count {
                    values[x][y] = Array(repeating: .zero, count: d.vertices.count)
                }
            }
        }
        return true
    }

    override func apply(_ index: (Int, Int), _ offset: Vec2) {
        guard let d = node as? Drawable else { return }
        for (x, y, w) in weights(index, offset) where w != 0 {
            d.accumulateDeformation(values[x][y], weight: w)
        }
    }
}
