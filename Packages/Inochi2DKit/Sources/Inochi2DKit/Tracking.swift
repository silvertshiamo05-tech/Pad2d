import Foundation

/// A tracked input. Signed sources range -1...1, unsigned ones 0...1.
public enum TrackingSource: String, Codable, CaseIterable, Sendable {
    case none
    case headYaw, headPitch, headRoll
    case gazeX, gazeY
    case eyeBlinkLeft, eyeBlinkRight
    case jawOpen, mouthSmile

    public var isSigned: Bool {
        switch self {
        case .headYaw, .headPitch, .headRoll, .gazeX, .gazeY: return true
        default: return false
        }
    }

    public var title: String {
        switch self {
        case .none: return "None"
        case .headYaw: return "Head turn"
        case .headPitch: return "Head nod"
        case .headRoll: return "Head tilt"
        case .gazeX: return "Look left/right"
        case .gazeY: return "Look up/down"
        case .eyeBlinkLeft: return "Left eye blink"
        case .eyeBlinkRight: return "Right eye blink"
        case .jawOpen: return "Mouth open"
        case .mouthSmile: return "Smile"
        }
    }
}

/// Connects one axis of a parameter to a tracked input.
public struct TrackingMapping: Codable, Equatable, Sendable {
    public var parameter: String
    public var axis: Int
    public var source: TrackingSource
    public var invert: Bool
    /// Multiplier on the input (e.g. 0.5 so the body follows the head less).
    public var scale: Float

    public init(parameter: String, axis: Int, source: TrackingSource, invert: Bool = false, scale: Float = 1) {
        self.parameter = parameter
        self.axis = axis
        self.source = source
        self.invert = invert
        self.scale = scale
    }
}

public enum TrackingMapper {
    /// Guesses mappings from parameter names. Inochi2D has no naming standard,
    /// so this looks for the common words riggers use ("Head", "Yaw", "Blink"...).
    public static func automaticMappings(for params: [Parameter]) -> [TrackingMapping] {
        var out: [TrackingMapping] = []
        for p in params {
            let n = p.name.lowercased()
            func has(_ words: String...) -> Bool { words.contains { n.contains($0) } }
            if has("physics", "phys") { continue }
            let isBody = has("body", "torso", "chest")
            let isHead = has("head", "face", "neck") && !isBody
            let left = has("left", " l ", ":: l", "_l", ".l") || n.hasSuffix(" l")
            let right = has("right", " r ", ":: r", "_r", ".r") || n.hasSuffix(" r")

            if isHead || isBody {
                let scale: Float = isBody ? 0.5 : 1
                if has("roll", "tilt", "angle z", "anglez") {
                    out.append(.init(parameter: p.name, axis: 0, source: .headRoll, scale: scale))
                } else if p.isVec2 && has("yaw", "pitch", "angle", "xy", "turn") {
                    out.append(.init(parameter: p.name, axis: 0, source: .headYaw, scale: scale))
                    out.append(.init(parameter: p.name, axis: 1, source: .headPitch, scale: scale))
                } else if has("yaw", "angle x", "anglex", "turn") {
                    out.append(.init(parameter: p.name, axis: 0, source: .headYaw, scale: scale))
                } else if has("pitch", "angle y", "angley", "nod") {
                    out.append(.init(parameter: p.name, axis: 0, source: .headPitch, scale: scale))
                } else if isBody && has(":: x", " x ", "x::", "move x") {
                    out.append(.init(parameter: p.name, axis: 0, source: .headYaw, scale: 0.3))
                }
                continue
            }
            if has("eye", "brow") && !has("brow") {
                if has("blink", "open", "close", "lid") {
                    // Parameters named "...Open" count the other way.
                    let src: TrackingSource = right && !left ? .eyeBlinkRight : .eyeBlinkLeft
                    out.append(.init(parameter: p.name, axis: 0, source: src, invert: has("open")))
                } else if has("move", "look", "ball", "gaze", "pupil", "iris") {
                    out.append(.init(parameter: p.name, axis: 0, source: .gazeX))
                    if p.isVec2 { out.append(.init(parameter: p.name, axis: 1, source: .gazeY)) }
                }
                continue
            }
            if has("mouth", "jaw", "lip") {
                if p.isVec2 {
                    out.append(.init(parameter: p.name, axis: 0, source: .mouthSmile))
                    out.append(.init(parameter: p.name, axis: 1, source: .jawOpen))
                } else if has("open", "jaw") {
                    out.append(.init(parameter: p.name, axis: 0, source: .jawOpen))
                } else if has("smile", "form", "width", "shape") {
                    out.append(.init(parameter: p.name, axis: 0, source: .mouthSmile))
                }
            }
        }
        return out
    }

    /// Maps an input onto a parameter axis. Signed inputs swing around the
    /// default value; unsigned inputs sweep from the minimum to the maximum.
    public static func value(for input: Float, mapping m: TrackingMapping, parameter p: Parameter) -> Float {
        let lo = m.axis == 0 ? p.min.x : p.min.y
        let hi = m.axis == 0 ? p.max.x : p.max.y
        let def = m.axis == 0 ? p.defaults.x : p.defaults.y
        if m.source.isSigned {
            var v = Swift.max(-1, Swift.min(1, input * m.scale))
            if m.invert { v = -v }
            return v >= 0 ? def + v * (hi - def) : def + v * (def - lo)
        }
        var v = Swift.max(0, Swift.min(1, input * m.scale))
        if m.invert { v = 1 - v }
        return lo + v * (hi - lo)
    }

    /// Writes all mapped inputs into their parameters.
    public static func apply(_ inputs: [TrackingSource: Float], mappings: [TrackingMapping], to puppet: Puppet,
                             skip: Set<String> = []) {
        for m in mappings where m.source != .none && !skip.contains(m.parameter) {
            guard let input = inputs[m.source], let p = puppet.parameter(named: m.parameter), !puppet.isDriven(p) else { continue }
            let v = value(for: input, mapping: m, parameter: p)
            if m.axis == 0 { p.value.x = v } else { p.value.y = v }
        }
    }
}
