import SwiftUI
import Inochi2DKit

/// Animation mode (Inochi Creator's timeline) and Test mode (tracking).
extension EditorModel {
    // MARK: Animation

    var animationNames: [String] { (puppet?.animations.keys).map { $0.sorted() } ?? [] }
    var currentAnim: Animation? { currentAnimation.flatMap { puppet?.animations[$0] } }
    var playback: AnimationPlayback? { currentAnimation.flatMap { player?.playback($0) } }

    func startAnimationMode() {
        player?.stopAll(immediate: true)
        animationPlaying = false
        if currentAnimation == nil { currentAnimation = animationNames.first }
        animationFrame = 0
        playback?.seek(0)
        renderAnimationFrame()
    }

    func stopAnimation() {
        player?.stopAll(immediate: true)
        animationPlaying = false
    }

    func selectAnimation(_ name: String?) {
        player?.stopAll(immediate: true)
        animationPlaying = false
        currentAnimation = name
        animationFrame = 0
        playback?.seek(0)
        renderAnimationFrame()
        revision &+= 1
    }

    /// Called every frame in Animation mode.
    func updateAnimation(_ dt: Double) {
        guard let pb = playback else { return }
        if animationPlaying {
            player?.update(dt)
            if pb.frame != animationFrame { animationFrame = pb.frame }
            if !pb.isRunning { animationPlaying = false }
        }
    }

    /// Applies the lanes at the current frame to the parameters.
    func renderAnimationFrame() {
        guard let pb = playback else { return }
        pb.render()
    }

    func togglePlay() {
        guard let pb = playback else { return }
        if animationPlaying {
            pb.pause()
            animationPlaying = false
        } else {
            pb.play(loop: true)
            animationPlaying = true
        }
        revision &+= 1
    }

    func stopPlayback(immediate: Bool = false) {
        playback?.stop(immediate: immediate)
        animationPlaying = false
        animationFrame = 0
        playback?.seek(0)
        renderAnimationFrame()
        revision &+= 1
    }

    func seek(_ frame: Int) {
        guard let a = currentAnim else { return }
        animationFrame = min(max(frame, 0), max(a.length - 1, 0))
        playback?.seek(animationFrame)
        renderAnimationFrame()
        revision &+= 1
    }

    func step(_ d: Int) { seek(animationFrame + d) }

    /// Adds (or updates) a keyframe for one axis of a parameter at the current frame.
    func addKeyframe(_ p: Parameter, axis: Int, value: Float) {
        guard let a = currentAnim else { return }
        if let lane = a.lane(for: p, axis: axis) {
            if let i = lane.frames.firstIndex(where: { $0.frame == animationFrame }) {
                lane.frames[i].value = value
            } else {
                lane.frames.append(Keyframe(frame: animationFrame, value: value))
                lane.updateFrames()
            }
        } else {
            a.lanes.append(AnimationLane(parameter: p, axis: axis, frames: [Keyframe(frame: animationFrame, value: value)]))
        }
        changed("Add keyframe")
    }

    /// Keyframes for both axes of a parameter from its current value.
    func addKeyframe(_ p: Parameter) {
        addKeyframe(p, axis: 0, value: p.value.x)
        if p.isVec2 { addKeyframe(p, axis: 1, value: p.value.y) }
    }

    /// Creator's N key: a keyframe on every lane from the parameters' values.
    func keyAllLanes() {
        guard let a = currentAnim else { return }
        for l in a.lanes {
            guard let p = l.parameter else { continue }
            addKeyframe(p, axis: l.axis, value: l.axis == 0 ? p.value.x : p.value.y)
        }
    }

    /// Creator's R key: removes keyframes at the current frame from every lane.
    func removeKeysAtFrame() {
        guard let a = currentAnim else { return }
        for l in a.lanes { l.frames.removeAll { $0.frame == animationFrame } }
        changed("Remove keyframes")
    }

    /// Double-tap on a lane: toggles a keyframe at the frame (value from the tap height).
    func toggleKeyframe(_ lane: AnimationLane, frame: Int, normalizedValue: Float) {
        guard let p = lane.parameter else { return }
        if let i = lane.frames.firstIndex(where: { $0.frame == frame }) {
            lane.frames.remove(at: i)
        } else {
            let v = lane.axis == 0 ? p.unmapValue(Vec2(normalizedValue, 0)).x : p.unmapValue(Vec2(0, normalizedValue)).y
            lane.frames.append(Keyframe(frame: frame, value: v))
            lane.updateFrames()
        }
        seek(frame)
        changed("Edit keyframe")
    }

    func moveKeyframe(_ lane: AnimationLane, from frame: Int, to newFrame: Int, value: Float? = nil) {
        guard let i = lane.frames.firstIndex(where: { $0.frame == frame }) else { return }
        lane.frames.removeAll { $0.frame == newFrame && newFrame != frame }
        guard let j = lane.frames.firstIndex(where: { $0.frame == frame }) else { return }
        _ = i
        lane.frames[j].frame = newFrame
        if let value { lane.frames[j].value = value }
        lane.updateFrames()
        renderAnimationFrame()
        changed("Move keyframe", commit: false)
    }

    func deleteLane(_ lane: AnimationLane) {
        currentAnim?.lanes.removeAll { $0 === lane }
        changed("Delete lane")
    }

    func saveAnimation(oldName: String?, name: String, anim: Animation) -> String? {
        guard let puppet else { return nil }
        let n = name.trimmingCharacters(in: .whitespaces)
        if n.isEmpty { return "Name can not be empty!" }
        if puppet.animations[n] != nil && n != oldName { return "\(n) is already taken!" }
        if let o = oldName, o != n { puppet.animations[o] = nil }
        puppet.animations[n] = anim
        changed(oldName == nil ? "New animation" : "Edit animation")
        selectAnimation(n)
        return nil
    }

    func duplicateAnimation(_ name: String) {
        guard let puppet, let a = puppet.animations[name] else { return }
        var n = name + "_copy"
        while puppet.animations[n] != nil { n += "_copy" }
        puppet.animations[n] = a.copy()
        changed("Duplicate animation")
        selectAnimation(n)
    }

    func deleteAnimation(_ name: String) {
        puppet?.animations[name] = nil
        if currentAnimation == name { currentAnimation = animationNames.first }
        changed("Delete animation")
    }

    // MARK: Test mode

    func startTest() {
        puppet?.enableDrivers = true
        puppet?.resetDrivers()
        if !testBindings.isEmpty || testAutoTracking {
            if FaceTracker.isSupported {
                faceTracker.start()
                trackingStatus = "Starting camera…"
            } else {
                trackingStatus = "Face tracking isn't supported on this device."
            }
        }
    }

    func stopTest() {
        faceTracker.stop()
        trackingStatus = nil
        puppet?.enableDrivers = physicsPreview
        puppet?.resetDrivers()
    }

    var testAutoTracking: Bool {
        get { UserDefaults.standard.bool(forKey: "testAutoTracking." + url.lastPathComponent) }
        set {
            UserDefaults.standard.set(newValue, forKey: "testAutoTracking." + url.lastPathComponent)
            objectWillChange.send()
            if mode == .test { stopTest(); startTest() }
        }
    }

    func applyTestTracking() {
        guard let puppet else { return }
        guard let f = faceTracker.latest else {
            if !testBindings.isEmpty || testAutoTracking, trackingStatus == nil || trackingStatus == "" {
                trackingStatus = "Looking for your face…"
            }
            return
        }
        if trackingStatus != nil { trackingStatus = nil }
        if testAutoTracking {
            let inputs: [TrackingSource: Float] = [
                .headYaw: -f.yaw, .headPitch: f.pitch, .headRoll: -f.roll,
                .gazeX: -f.gazeX, .gazeY: f.gazeY,
                .eyeBlinkLeft: f.blinkRight, .eyeBlinkRight: f.blinkLeft,
                .jawOpen: f.jawOpen, .mouthSmile: f.smile,
            ]
            TrackingMapper.apply(inputs, mappings: TrackingMapper.automaticMappings(for: puppet.parameters), to: puppet, skip: [])
        }
        for b in testBindings {
            guard let p = puppet.parameter(uuid: b.paramUUID), let raw = f.shapes[b.key] else { continue }
            let v = min(max(b.inverse ? 1 - raw : raw, 0), 1)
            let u = p.unmapValue(Vec2(v, v))
            if b.axis == 0 { p.value.x = u.x } else { p.value.y = u.y }
        }
    }

    private var bindingsKey: String { "testBindings." + url.lastPathComponent }

    func loadTestBindings() {
        guard let data = UserDefaults.standard.data(forKey: bindingsKey),
              let list = try? JSONDecoder().decode([TrackingBinding].self, from: data) else { return }
        testBindings = list
    }

    func saveTestBindings() {
        if let data = try? JSONEncoder().encode(testBindings) { UserDefaults.standard.set(data, forKey: bindingsKey) }
    }
}

/// Test-mode binding of a tracking input to a parameter axis (Creator's TrackingBinding).
struct TrackingBinding: Codable, Identifiable, Hashable {
    var id = UUID()
    var key: String
    var paramUUID: UInt32
    var axis: Int
    var inverse: Bool
}
