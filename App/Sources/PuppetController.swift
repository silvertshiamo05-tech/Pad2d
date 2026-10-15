import SwiftUI
import MetalKit
import simd
import Inochi2DKit

extension Puppet: @unchecked Sendable {}

enum BackgroundStyle: String, CaseIterable, Identifiable {
    case checker, dark, light, greenScreen, blueScreen, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .checker: return "Checkerboard"
        case .dark: return "Dark"
        case .light: return "Light"
        case .greenScreen: return "Green screen"
        case .blueScreen: return "Blue screen"
        case .custom: return "Custom colour"
        }
    }
}

enum TrackingMode: String, CaseIterable, Identifiable {
    case off, touch, face
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: return "Off"
        case .touch: return "Follow finger"
        case .face: return "Face (camera)"
        }
    }
}

/// Something the Metal renderer can draw.
@MainActor
protocol RenderSource: AnyObject {
    var background: BackgroundStyle { get }
    /// A custom background colour (used when `background` is `.custom`).
    var backgroundColor: SIMD4<Float>? { get }
    func renderFrame(deltaTime: Double, viewSize: CGSize) -> RenderFrame?
}

extension RenderSource {
    var backgroundColor: SIMD4<Float>? { nil }
}

/// A coloured vertex for editor overlays, in clip space.
struct OverlayVertex {
    var position: SIMD2<Float>
    var color: SIMD4<Float>
}

/// What the renderer needs for one frame.
struct RenderFrame {
    let list: DrawList
    let viewProjection: simd_float4x4
    let preservePixels: Bool
    let textures: [MTLTexture?]
    var overlay: [OverlayVertex] = []

    func texture(_ slot: Int) -> MTLTexture? {
        slot >= 0 && slot < textures.count ? textures[slot] : nil
    }
}

/// Owns a loaded puppet and everything that drives it each frame.
@MainActor
final class PuppetController: ObservableObject, RenderSource {
    enum State: Equatable {
        case loading
        case ready
        case failed(String)
    }

    @Published private(set) var state = State.loading
    @Published var background: BackgroundStyle = .checker
    @Published var physicsEnabled = true {
        didSet { puppet?.enableDrivers = physicsEnabled; if physicsEnabled { puppet?.resetDrivers() } }
    }
    @Published var idleBreathing = true
    @Published var idleBlinking = true
    @Published var trackingMode = TrackingMode.off {
        didSet { updateFaceTracking() }
    }
    @Published var mirror = true
    @Published var mappings: [TrackingMapping] = [] {
        didSet { saveMappings() }
    }
    @Published private(set) var textureNote: String?
    @Published private(set) var trackingStatus: String?
    /// Bumped a few times a second so parameter panels can follow tracking.
    @Published private(set) var tick = 0

    let modelURL: URL
    let modelName: String
    private(set) var puppet: Puppet?
    private var textures: [MTLTexture?] = []

    // Camera
    var zoom: CGFloat = 1
    var pan = CGPoint.zero
    private var bounds: (Float, Float, Float, Float)?

    // Input
    var touchTarget: CGPoint? // -1...1 in view space
    var editingParameters: Set<String> = []
    private let faceTracker = FaceTracker()
    private var smoothed: [TrackingSource: Float] = [:]
    private var time: Double = 0
    private var nextBlink: Double = 2
    private var tickAccumulator: Double = 0

    init(url: URL) {
        modelURL = url
        modelName = url.deletingPathExtension().lastPathComponent
    }

    // MARK: Loading

    func load(device: MTLDevice, queue: MTLCommandQueue) async {
        state = .loading
        let url = modelURL
        do {
            let (puppet, result) = try await Task.detached(priority: .userInitiated) {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let puppet = try Puppet(contentsOf: url)
                let textures = try TextureLoader(device: device, queue: queue).load(puppet.textures)
                return (puppet, textures)
            }.value
            self.puppet = puppet
            textures = result.textures
            if result.scale < 0.999 {
                textureNote = "Textures were reduced to \(Int(result.scale * 100))% to fit this iPad's memory."
            }
            puppet.enableDrivers = physicsEnabled
            puppet.renderParameters = true
            // Fit the camera to the rest pose.
            puppet.update(deltaTime: 0)
            bounds = puppet.draw().bounds
            mappings = loadMappings() ?? TrackingMapper.automaticMappings(for: puppet.parameters)
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: Per frame

    func renderFrame(deltaTime dt: Double, viewSize: CGSize) -> RenderFrame? {
        guard let puppet, state == .ready else { return nil }
        time += dt
        applyInputs(dt: dt)
        puppet.update(deltaTime: dt)
        let list = puppet.draw()

        tickAccumulator += dt
        if tickAccumulator > 0.2 {
            tickAccumulator = 0
            tick &+= 1
        }
        return RenderFrame(list: list, viewProjection: viewProjection(viewSize),
                           preservePixels: puppet.meta.preservePixels, textures: textures)
    }

    /// Model units -> pixels at zoom 1.
    func fitScale(_ size: CGSize) -> CGFloat {
        guard let b = bounds else { return 1 }
        let w = CGFloat(b.2 - b.0), h = CGFloat(b.3 - b.1)
        guard w > 0, h > 0 else { return 1 }
        return min(size.width / w, size.height / h) * 0.92
    }

    private func viewProjection(_ size: CGSize) -> simd_float4x4 {
        let b = bounds ?? (-500, -500, 500, 500)
        let cx = (b.0 + b.2) / 2, cy = (b.1 + b.3) / 2
        let s = Float(fitScale(size) * zoom)
        let w = Float(size.width), h = Float(size.height)
        let px = Float(pan.x), py = Float(pan.y)
        return simd_float4x4(columns: (
            SIMD4(2 * s / w, 0, 0, 0),
            SIMD4(0, -2 * s / h, 0, 0),
            SIMD4(0, 0, 1, 0),
            SIMD4((-cx * s + px) * 2 / w, -(-cy * s + py) * 2 / h, 0, 1)))
    }

    func resetView() {
        zoom = 1
        pan = .zero
    }

    private func applyInputs(dt: Double) {
        guard let puppet else { return }
        var inputs: [TrackingSource: Float] = [:]

        switch trackingMode {
        case .face:
            if let f = faceTracker.latest {
                let m: Float = mirror ? -1 : 1
                inputs[.headYaw] = f.yaw * m
                inputs[.headPitch] = f.pitch
                inputs[.headRoll] = f.roll * m
                inputs[.gazeX] = f.gazeX * m
                inputs[.gazeY] = f.gazeY
                inputs[.eyeBlinkLeft] = mirror ? f.blinkRight : f.blinkLeft
                inputs[.eyeBlinkRight] = mirror ? f.blinkLeft : f.blinkRight
                inputs[.jawOpen] = f.jawOpen
                inputs[.mouthSmile] = f.smile
                setStatus(nil)
            } else {
                setStatus("Looking for your face…")
            }
        case .touch:
            let t = touchTarget ?? .zero
            inputs[.headYaw] = Float(t.x)
            inputs[.headPitch] = Float(-t.y)
            inputs[.gazeX] = Float(t.x)
            inputs[.gazeY] = Float(-t.y)
        case .off:
            break
        }

        // Idle motion where tracking doesn't provide a value.
        if idleBlinking && inputs[.eyeBlinkLeft] == nil {
            if time > nextBlink + 0.15 { nextBlink = time + Double.random(in: 2.5...5.5) }
            let phase = time - nextBlink
            let blink: Float = phase >= 0 && phase < 0.15 ? Float(1 - abs(phase - 0.075) / 0.075) : 0
            inputs[.eyeBlinkLeft] = blink
            inputs[.eyeBlinkRight] = blink
        }

        // Smooth tracked values so the puppet doesn't jitter.
        let k = Float(min(1, dt * 18))
        for (src, v) in inputs {
            let isBlink = src == .eyeBlinkLeft || src == .eyeBlinkRight
            let prev = smoothed[src] ?? v
            smoothed[src] = isBlink ? v : prev + (v - prev) * k
        }
        for src in Array(smoothed.keys) where inputs[src] == nil {
            // Ease back to rest when an input disappears.
            smoothed[src] = (smoothed[src] ?? 0) * (1 - k)
        }
        // With tracking off only idle inputs (blinking) drive the puppet, so
        // manual slider values for head, mouth, etc. stay where the user put them.
        let active = trackingMode == .off ? smoothed.filter { inputs[$0.key] != nil } : smoothed
        if !active.isEmpty {
            TrackingMapper.apply(active, mappings: mappings, to: puppet, skip: editingParameters)
        }

        if idleBreathing {
            let breath = Float(0.5 - 0.5 * cos(time * 2 * .pi / 3.6))
            for p in puppet.parameters where p.name.lowercased().contains("breath") && !editingParameters.contains(p.name) {
                p.value.x = p.min.x + breath * (p.max.x - p.min.x)
            }
        }
    }

    // MARK: Tracking

    /// Only publishes real changes, so SwiftUI isn't invalidated every frame.
    private func setStatus(_ s: String?) {
        if trackingStatus != s { trackingStatus = s }
    }

    var faceTrackingSupported: Bool { FaceTracker.isSupported }

    private func updateFaceTracking() {
        if trackingMode == .face {
            if FaceTracker.isSupported {
                faceTracker.start()
                trackingStatus = "Starting camera…"
            } else {
                trackingStatus = "Face tracking isn't supported on this device."
            }
        } else {
            faceTracker.stop()
            trackingStatus = nil
        }
        smoothed = [:]
    }

    func stop() {
        faceTracker.stop()
    }

    func isTracked(_ name: String) -> Bool {
        guard trackingMode != .off else { return false }
        return mappings.contains { $0.parameter == name && $0.source != .none }
    }

    func resetPose() {
        guard let puppet else { return }
        for p in puppet.parameters { p.value = p.defaults }
        puppet.resetDrivers()
    }

    func resetMappings() {
        guard let puppet else { return }
        mappings = TrackingMapper.automaticMappings(for: puppet.parameters)
    }

    private var mappingsKey: String { "mappings." + modelURL.lastPathComponent }

    private func saveMappings() {
        guard state == .ready, let data = try? JSONEncoder().encode(mappings) else { return }
        UserDefaults.standard.set(data, forKey: mappingsKey)
    }

    private func loadMappings() -> [TrackingMapping]? {
        guard let data = UserDefaults.standard.data(forKey: mappingsKey) else { return nil }
        return try? JSONDecoder().decode([TrackingMapping].self, from: data)
    }
}
