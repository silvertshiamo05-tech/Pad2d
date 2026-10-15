import SwiftUI
import MetalKit
import Inochi2DKit

/// Shared Metal device and queue.
enum GPU {
    static let device: MTLDevice = MTLCreateSystemDefaultDevice()!
    static let queue: MTLCommandQueue = device.makeCommandQueue()!
}

struct StageView: View {
    @StateObject private var controller: PuppetController
    @State private var showPanel = true
    @State private var showTracking = false
    @State private var presenting = false

    private let canEdit: Bool

    init(url: URL, canEdit: Bool = true) {
        _controller = StateObject(wrappedValue: PuppetController(url: url))
        self.canEdit = canEdit
    }

    var body: some View {
        HStack(spacing: 0) {
            ZStack(alignment: .top) {
                PuppetCanvas(controller: controller)
                    .ignoresSafeArea()
                overlay
            }
            if showPanel && !presenting && controller.state == .ready {
                Divider()
                ParameterPanel(controller: controller)
                    .frame(width: 320)
                    .transition(.move(edge: .trailing))
            }
        }
        .navigationTitle(controller.puppet?.meta.name ?? controller.modelName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(presenting ? .hidden : .visible, for: .navigationBar)
        .statusBarHidden(presenting)
        .persistentSystemOverlays(presenting ? .hidden : .automatic)
        .toolbar { toolbar }
        .sheet(isPresented: $showTracking) { TrackingSettingsView(controller: controller) }
        .task { await controller.load(device: GPU.device, queue: GPU.queue) }
        .onDisappear { controller.stop() }
    }

    @ViewBuilder
    private var overlay: some View {
        switch controller.state {
        case .loading:
            ProgressView("Loading model…")
                .padding(20)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .padding(.top, 120)
        case let .failed(message):
            ContentUnavailableView("Couldn't open this model", systemImage: "exclamationmark.triangle",
                                   description: Text(message))
                .padding(.top, 80)
        case .ready:
            VStack(spacing: 8) {
                if presenting {
                    HStack {
                        Button { withAnimation { presenting = false } } label: {
                            Image(systemName: "xmark.circle.fill").font(.title)
                        }
                        .opacity(0.35)
                        Spacer()
                    }
                    .padding()
                } else {
                    if let note = controller.textureNote { Chip(text: note, icon: "memorychip") }
                    if let status = controller.trackingStatus { Chip(text: status, icon: "faceid") }
                }
            }
            .padding(.top, 8)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                Picker("Tracking", selection: $controller.trackingMode) {
                    ForEach(TrackingMode.allCases) { Text($0.title).tag($0) }
                }
                Divider()
                Button { showTracking = true } label: { Label("Tracking Settings…", systemImage: "slider.horizontal.3") }
            } label: {
                Image(systemName: controller.trackingMode == .face ? "faceid"
                      : controller.trackingMode == .touch ? "hand.point.up.left" : "person.and.arrow.left.and.arrow.right")
            }
            Menu {
                Toggle("Physics", isOn: $controller.physicsEnabled)
                Toggle("Breathing", isOn: $controller.idleBreathing)
                Toggle("Auto blink", isOn: $controller.idleBlinking)
                Divider()
                Picker("Background", selection: $controller.background) {
                    ForEach(BackgroundStyle.allCases) { Text($0.title).tag($0) }
                }
                Divider()
                Button { controller.resetPose() } label: { Label("Reset Pose", systemImage: "arrow.counterclockwise") }
                Button { controller.resetView() } label: { Label("Reset View", systemImage: "viewfinder") }
                Button { withAnimation { presenting = true } } label: { Label("Presentation Mode", systemImage: "rectangle.inset.filled") }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            if canEdit {
                NavigationLink(value: Route.edit(controller.modelURL)) {
                    Label("Edit", systemImage: "slider.horizontal.3")
                }
            }
            Button { withAnimation { showPanel.toggle() } } label: { Image(systemName: "sidebar.right") }
        }
    }
}

private struct Chip: View {
    let text: String
    let icon: String
    var body: some View {
        Label(text, systemImage: icon)
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
    }
}

/// The Metal view plus touch handling.
///
/// - Pinch: zoom. Two fingers: pan. Double tap: reset view.
/// - One finger: pans, or steers the head in "Follow finger" tracking.
struct PuppetCanvas: UIViewRepresentable {
    @ObservedObject var controller: PuppetController

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: GPU.device)
        view.isMultipleTouchEnabled = true
        context.coordinator.attach(view)
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let controller: PuppetController
        var renderer: Renderer?
        private weak var view: MTKView?
        private var pinchStart: CGFloat = 1

        init(controller: PuppetController) {
            self.controller = controller
        }

        func attach(_ view: MTKView) {
            self.view = view
            renderer = Renderer(view: view)
            renderer?.source = controller
            view.delegate = renderer

            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(onPinch(_:)))
            let pan2 = UIPanGestureRecognizer(target: self, action: #selector(onPan(_:)))
            pan2.minimumNumberOfTouches = 2
            let pan1 = UIPanGestureRecognizer(target: self, action: #selector(onDrag(_:)))
            pan1.maximumNumberOfTouches = 1
            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(onDoubleTap))
            doubleTap.numberOfTapsRequired = 2
            for g in [pinch, pan2, pan1, doubleTap] as [UIGestureRecognizer] {
                g.delegate = self
                view.addGestureRecognizer(g)
            }
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith o: UIGestureRecognizer) -> Bool {
            (g is UIPinchGestureRecognizer && o is UIPanGestureRecognizer) || (o is UIPinchGestureRecognizer && g is UIPanGestureRecognizer)
        }

        private var scale: CGFloat { view?.contentScaleFactor ?? 2 }

        @objc private func onPinch(_ g: UIPinchGestureRecognizer) {
            guard let view else { return }
            if g.state == .began { pinchStart = controller.zoom }
            let newZoom = min(max(pinchStart * g.scale, 0.2), 12)
            // Zoom around the fingers.
            let loc = g.location(in: view)
            let c = CGPoint(x: (loc.x - view.bounds.midX) * scale, y: (loc.y - view.bounds.midY) * scale)
            let ratio = newZoom / controller.zoom
            controller.pan = CGPoint(x: c.x - (c.x - controller.pan.x) * ratio, y: c.y - (c.y - controller.pan.y) * ratio)
            controller.zoom = newZoom
        }

        @objc private func onPan(_ g: UIPanGestureRecognizer) {
            let t = g.translation(in: view)
            controller.pan.x += t.x * scale
            controller.pan.y += t.y * scale
            g.setTranslation(.zero, in: view)
        }

        @objc private func onDrag(_ g: UIPanGestureRecognizer) {
            guard let view else { return }
            if controller.trackingMode == .touch {
                switch g.state {
                case .began, .changed:
                    let p = g.location(in: view)
                    controller.touchTarget = CGPoint(x: max(-1, min(1, (p.x - view.bounds.midX) / (view.bounds.width / 2))),
                                                     y: max(-1, min(1, (p.y - view.bounds.midY) / (view.bounds.height / 2))))
                default:
                    controller.touchTarget = nil
                }
            } else {
                onPan(g)
            }
        }

        @objc private func onDoubleTap() {
            controller.resetView()
        }
    }
}
