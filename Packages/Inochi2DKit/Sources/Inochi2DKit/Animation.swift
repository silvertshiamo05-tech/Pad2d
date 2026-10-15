// Port of the Inochi2D 0.8 animation system (inochi2d.core.animation).
// Copyright © 2022, Inochi2D Project. Distributed under the 2-Clause BSD License.

import Foundation

public struct Keyframe: Equatable, Sendable {
    public var frame: Int
    public var value: Float
    public var tension: Float

    public init(frame: Int, value: Float, tension: Float = 0.5) {
        self.frame = frame
        self.value = value
        self.tension = tension
    }
}

/// Keyframes driving one axis of one parameter.
public final class AnimationLane {
    public var paramUUID: UInt32
    public var axis: Int
    public internal(set) weak var parameter: Parameter?
    public var frames: [Keyframe]
    public var interpolation: InterpolateMode
    public var mergeMode: ParamMergeMode

    public init(parameter: Parameter, axis: Int, frames: [Keyframe] = [],
                interpolation: InterpolateMode = .linear, mergeMode: ParamMergeMode = .forced) {
        paramUUID = parameter.uuid
        self.parameter = parameter
        self.axis = axis
        self.frames = frames
        self.interpolation = interpolation
        self.mergeMode = mergeMode
    }

    init(json: [String: Any]) {
        paramUUID = json.uint32("uuid") ?? .max
        axis = (json["target"] as? NSNumber)?.intValue ?? 0
        interpolation = json["interpolation"] == nil ? .nearest : InterpolateMode(json["interpolation"])
        if let m = json.string("merge_mode"), let mode = ParamMergeMode(rawValue: m.lowercased()) {
            mergeMode = mode
        } else {
            mergeMode = .forced
        }
        frames = (json.array("keyframes") ?? []).compactMap { k in
            guard let k = k as? [String: Any] else { return nil }
            return Keyframe(frame: (k["frame"] as? NSNumber)?.intValue ?? 0,
                            value: k.float("value") ?? 0, tension: k.float("tension") ?? 0.5)
        }
    }

    func serialize() -> [String: Any] {
        ["interpolation": interpolation.name, "uuid": paramUUID, "target": axis,
         "keyframes": frames.map { ["frame": $0.frame, "value": $0.value, "tension": $0.tension] as [String: Any] },
         "merge_mode": mergeMode.name]
    }

    func finalize(_ puppet: Puppet) {
        parameter = puppet.parameters.first { $0.uuid == paramUUID }
    }

    /// Stable-sorts keyframes by frame.
    public func updateFrames() {
        frames = frames.enumerated().sorted { $0.element.frame != $1.element.frame ? $0.element.frame < $1.element.frame : $0.offset < $1.offset }.map(\.element)
    }

    /// The lane's value at a (fractional) frame.
    public func value(at frame: Float, snapSubframes: Bool = false) -> Float {
        guard !frames.isEmpty else { return 0 }
        let f = snapSubframes ? frame.rounded(.down) : frame
        if frames.count == 1 { return frames[0].value }
        guard let i = frames.firstIndex(where: { Float($0.frame) >= f }) else { return frames[frames.count - 1].value }
        if i == 0 { return frames[0].value }
        let tonext = Float(frames[i].frame) - f
        let ilen = Float(frames[i].frame - frames[i - 1].frame)
        let t = 1 - tonext / ilen
        let a = frames[i - 1].value, b = frames[i].value
        switch interpolation {
        case .nearest: return t > 0.5 ? b : a
        case .stepped: return a
        case .linear: return a * (1 - t) + b * t
        case .cubic:
            let p0 = frames[Swift.max(i - 2, 0)].value
            let p3 = frames[Swift.min(i + 1, frames.count - 1)].value
            return cubic(p0, a, b, p3, t)
        case .bezier:
            let tension = frames[i].tension
            func hermite(_ x: Float, _ tx: Float, _ y: Float, _ ty: Float, _ t: Float) -> Float {
                let t2 = t * t, t3 = t2 * t
                let h1 = 2 * t3 - 3 * t2 + 1, h2 = -2 * t3 + 3 * t2
                let h3 = t3 - 2 * t2 + t, h4 = t3 - t2
                return h1 * x + h3 * tx + h2 * y + h4 * ty
            }
            let k = clamp(hermite(0, 2 * tension, 1, 2 * tension, t), 0, 1)
            return a * (1 - k) + b * k
        }
    }
}

public final class Animation {
    public var timestep: Float = 1 / 60
    public var additive = false
    public var weight: Float = 1
    public var lanes: [AnimationLane] = []
    /// Length in frames.
    public var length = 100
    /// Frame where the lead-in ends (-1: none).
    public var leadIn = -1
    /// Frame where the lead-out starts (-1: none).
    public var leadOut = -1

    public init() {}

    init(json: [String: Any]) {
        timestep = json.float("timestep") ?? 0.0166
        additive = json.bool("additive") ?? false
        weight = json.float("animationWeight") ?? 1
        length = (json["length"] as? NSNumber)?.intValue ?? 0
        leadIn = (json["leadIn"] as? NSNumber)?.intValue ?? -1
        leadOut = (json["leadOut"] as? NSNumber)?.intValue ?? -1
        lanes = (json.array("lanes") ?? []).compactMap { ($0 as? [String: Any]).map(AnimationLane.init(json:)) }
    }

    func serialize() -> [String: Any] {
        ["timestep": timestep, "additive": additive, "length": length, "leadIn": leadIn, "leadOut": leadOut,
         "animationWeight": weight.isFinite ? weight : 1,
         "lanes": lanes.filter { $0.parameter != nil }.map { $0.serialize() }]
    }

    func finalize(_ puppet: Puppet) {
        for l in lanes { l.finalize(puppet) }
    }

    public var fps: Int { timestep > 0 ? Int(1000 / (timestep * 1000)) : 60 }

    public func lane(for parameter: Parameter, axis: Int) -> AnimationLane? {
        lanes.first { $0.parameter === parameter && $0.axis == axis }
    }

    /// Deep copy.
    public func copy() -> Animation {
        let a = Animation()
        a.timestep = timestep
        a.additive = additive
        a.weight = weight
        a.length = length
        a.leadIn = leadIn
        a.leadOut = leadOut
        a.lanes = lanes.compactMap { l in
            guard let p = l.parameter else { return nil }
            return AnimationLane(parameter: p, axis: l.axis, frames: l.frames, interpolation: l.interpolation, mergeMode: l.mergeMode)
        }
        return a
    }
}

/// Playback state of one animation (inochi2d AnimationPlayback).
public final class AnimationPlayback {
    public let name: String
    public let animation: Animation
    public private(set) var time: Double = 0
    public private(set) var looped = 0
    public private(set) var isPaused = false
    public private(set) var isPlaying = false
    public private(set) var isLooping = false
    private var playLeadOut = false
    private var stopping = false
    /// 0...1 multiplier applied to every lane.
    public var strength: Float = 1
    public var snapToFramerate = false

    init(name: String, animation: Animation) {
        self.name = name
        self.animation = animation
    }

    var timestep: Double { Double(animation.timestep) }
    public var frame: Int { Int((time / timestep).rounded()) }
    public var hframe: Float { Float(time / timestep) }
    var hasLeadIn: Bool { animation.leadIn > 0 && animation.leadIn + 1 < animation.length }
    var hasLeadOut: Bool { animation.leadOut > 0 && animation.leadOut + 1 < animation.length }
    var loopPointBegin: Int { hasLeadIn ? animation.leadIn : 0 }
    var loopPointEnd: Int { hasLeadOut ? animation.leadOut : animation.length }
    var isPlayingLeadOut: Bool { ((isPlaying && !isLooping) || stopping) && playLeadOut && frame < animation.length }
    public var isRunning: Bool { isPlaying || isPlayingLeadOut }

    public func play(loop: Bool = false, playLeadOut: Bool = true) {
        if isPaused {
            isPaused = false
            return
        }
        looped = 0
        time = 0
        stopping = false
        isPlaying = true
        isLooping = loop
        self.playLeadOut = playLeadOut
    }

    public func pause() { isPaused = true }

    public func stop(immediate: Bool = false) {
        if stopping { return }
        let imm = immediate || frame == 0 || isPaused || !hasLeadOut
        stopping = !imm
        isLooping = false
        isPaused = false
        isPlaying = false
        playLeadOut = !imm
        if imm {
            time = 0
            looped = 0
        }
    }

    public func seek(_ frame: Int) {
        time = Double(Swift.min(Swift.max(frame, 0), animation.length)) * timestep
        looped = 0
    }

    func update(_ delta: Double) {
        guard isRunning else { return }
        if isPaused {
            render()
            return
        }
        time += delta
        if !isPlayingLeadOut && isLooping && frame >= loopPointEnd {
            time = Double(loopPointBegin) * timestep
            looped += 1
        }
        if frame + 1 >= animation.length {
            time = Double(animation.length - 1) * timestep
        }
        render()
        if !isLooping && isPlayingLeadOut && frame + 1 >= animation.length {
            isPlaying = false
            playLeadOut = false
            stopping = false
            time = 0
            looped = 0
        }
    }

    /// Pushes the current frame's values into the parameters.
    public func render() {
        for lane in animation.lanes {
            guard let p = lane.parameter else { continue }
            p.pushOffset(axis: lane.axis, lane.value(at: hframe, snapSubframes: snapToFramerate) * clamp(strength, 0, 1),
                         mode: lane.mergeMode)
        }
    }
}

/// Plays a puppet's animations (inochi2d AnimationPlayer).
public final class AnimationPlayer {
    public unowned let puppet: Puppet
    public private(set) var playbacks: [AnimationPlayback] = []
    public var snapToFramerate = false

    public init(puppet: Puppet) {
        self.puppet = puppet
    }

    public func playback(_ name: String) -> AnimationPlayback? {
        if let p = playbacks.first(where: { $0.name == name && $0.animation === puppet.animations[name] }) { return p }
        guard let a = puppet.animations[name] else { return nil }
        playbacks.removeAll { $0.name == name }
        let p = AnimationPlayback(name: name, animation: a)
        playbacks.append(p)
        return p
    }

    @discardableResult
    public func play(_ name: String, loop: Bool = true) -> AnimationPlayback? {
        let p = playback(name)
        p?.play(loop: loop)
        return p
    }

    public func update(_ delta: Double) {
        for p in playbacks {
            p.snapToFramerate = snapToFramerate
            p.update(delta)
        }
    }

    public func stopAll(immediate: Bool = false) {
        for p in playbacks { p.stop(immediate: immediate) }
    }
}
