import ARKit

/// Front-camera face tracking through ARKit. On iPads without a TrueDepth
/// camera (like the 10th generation) ARKit tracks faces with the regular
/// front camera and the Neural Engine (A12 or later, iPadOS 14+).
final class FaceTracker: NSObject, ARSessionDelegate {
    struct Sample {
        /// Head angles normalised so that ±30° is ±1.
        var yaw: Float, pitch: Float, roll: Float
        var gazeX: Float, gazeY: Float
        var blinkLeft: Float, blinkRight: Float
        var jawOpen: Float, smile: Float
        /// Every ARKit blend shape (0...1) plus head pose, for tracking bindings.
        var shapes: [String: Float] = [:]
    }

    /// Names offered as tracking inputs: head pose first, then ARKit blend shapes.
    static let inputNames: [String] = ["Head Yaw", "Head Pitch", "Head Roll", "Head X", "Head Y", "Head Z"]
        + ARFaceAnchor.BlendShapeLocation.allNames

    static var isSupported: Bool { ARFaceTrackingConfiguration.isSupported }

    private let session = ARSession()
    private let queue = DispatchQueue(label: "face-tracking", qos: .userInteractive)
    private let lock = NSLock()
    private var sample: Sample?
    private var lastUpdate: TimeInterval = 0
    private var running = false

    override init() {
        super.init()
        session.delegate = self
        session.delegateQueue = queue
    }

    /// The most recent face, or nil if none was seen in the last half second.
    var latest: Sample? {
        lock.lock()
        defer { lock.unlock() }
        return ProcessInfo.processInfo.systemUptime - lastUpdate < 0.5 ? sample : nil
    }

    func start() {
        guard Self.isSupported, !running else { return }
        let config = ARFaceTrackingConfiguration()
        config.maximumNumberOfTrackedFaces = 1
        config.isLightEstimationEnabled = false
        // The smallest video format saves power and memory; tracking quality is the same.
        if let small = ARFaceTrackingConfiguration.supportedVideoFormats.min(by: {
            $0.imageResolution.width * $0.imageResolution.height < $1.imageResolution.width * $1.imageResolution.height
        }) {
            config.videoFormat = small
        }
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        running = true
    }

    func stop() {
        guard running else { return }
        session.pause()
        running = false
        lock.lock()
        sample = nil
        lock.unlock()
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard let face = frame.anchors.lazy.compactMap({ $0 as? ARFaceAnchor }).first, face.isTracked else { return }
        let f = face.transform
        let cam = frame.camera.transform.columns.3
        let facePos = SIMD3(f.columns.3.x, f.columns.3.y, f.columns.3.z)
        let toCamera = simd_normalize(SIMD3(cam.x, cam.y, cam.z) - facePos)
        let forward = simd_normalize(SIMD3(f.columns.2.x, f.columns.2.y, f.columns.2.z))
        let side = simd_normalize(SIMD3(f.columns.0.x, f.columns.0.y, f.columns.0.z))

        // Angles relative to looking straight at the camera, measured against
        // gravity (world y is up), so they don't depend on how the iPad is held.
        let yaw = atan2(forward.x, forward.z) - atan2(toCamera.x, toCamera.z)
        let pitch = asin(max(-1, min(1, forward.y))) - asin(max(-1, min(1, toCamera.y)))
        let roll = atan2(side.y, simd_length(SIMD2(side.x, side.z)))

        let b = face.blendShapes
        func v(_ k: ARFaceAnchor.BlendShapeLocation) -> Float { b[k]?.floatValue ?? 0 }
        let degrees: Float = 180 / .pi / 30
        var s = Sample(
            yaw: wrap(yaw) * degrees,
            pitch: pitch * degrees,
            roll: roll * degrees,
            gazeX: (v(.eyeLookInLeft) - v(.eyeLookOutLeft) + v(.eyeLookOutRight) - v(.eyeLookInRight)) / 2,
            gazeY: (v(.eyeLookUpLeft) + v(.eyeLookUpRight) - v(.eyeLookDownLeft) - v(.eyeLookDownRight)) / 2,
            blinkLeft: v(.eyeBlinkLeft),
            blinkRight: v(.eyeBlinkRight),
            jawOpen: min(1, v(.jawOpen) * 1.6),
            smile: (v(.mouthSmileLeft) + v(.mouthSmileRight)) / 2)
        var shapes: [String: Float] = [:]
        for (k, n) in b { shapes[k.rawValue] = n.floatValue }
        // Head pose normalised to 0...1 (±45° and ±20 cm around the centre).
        let quarter: Float = .pi / 4
        shapes["Head Yaw"] = max(0, min(1, (wrap(yaw) / quarter + 1) / 2))
        shapes["Head Pitch"] = max(0, min(1, (pitch / quarter + 1) / 2))
        shapes["Head Roll"] = max(0, min(1, (roll / quarter + 1) / 2))
        shapes["Head X"] = max(0, min(1, (facePos.x / 0.2 + 1) / 2))
        shapes["Head Y"] = max(0, min(1, (facePos.y / 0.2 + 1) / 2))
        shapes["Head Z"] = max(0, min(1, (facePos.z / 0.2 + 1) / 2))
        s.shapes = shapes
        lock.lock()
        sample = s
        lastUpdate = ProcessInfo.processInfo.systemUptime
        lock.unlock()
    }

    private func wrap(_ a: Float) -> Float {
        var x = a
        while x > .pi { x -= 2 * .pi }
        while x < -.pi { x += 2 * .pi }
        return x
    }
}

extension ARFaceAnchor.BlendShapeLocation {
    static let allNames: [String] = [
        "eyeBlinkLeft", "eyeLookDownLeft", "eyeLookInLeft", "eyeLookOutLeft", "eyeLookUpLeft", "eyeSquintLeft", "eyeWideLeft",
        "eyeBlinkRight", "eyeLookDownRight", "eyeLookInRight", "eyeLookOutRight", "eyeLookUpRight", "eyeSquintRight", "eyeWideRight",
        "jawForward", "jawLeft", "jawRight", "jawOpen", "mouthClose", "mouthFunnel", "mouthPucker", "mouthLeft", "mouthRight",
        "mouthSmileLeft", "mouthSmileRight", "mouthFrownLeft", "mouthFrownRight", "mouthDimpleLeft", "mouthDimpleRight",
        "mouthStretchLeft", "mouthStretchRight", "mouthRollLower", "mouthRollUpper", "mouthShrugLower", "mouthShrugUpper",
        "mouthPressLeft", "mouthPressRight", "mouthLowerDownLeft", "mouthLowerDownRight", "mouthUpperUpLeft", "mouthUpperUpRight",
        "browDownLeft", "browDownRight", "browInnerUp", "browOuterUpLeft", "browOuterUpRight", "cheekPuff",
        "cheekSquintLeft", "cheekSquintRight", "noseSneerLeft", "noseSneerRight", "tongueOut",
    ]
}
