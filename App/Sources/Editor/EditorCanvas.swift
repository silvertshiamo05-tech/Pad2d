import SwiftUI
import MetalKit
import Inochi2DKit

/// The editor's Metal view.
///
/// - One finger (or Pencil): the current tool (select, move, deform, mesh edit).
/// - Tap: select a part, or add/delete a vertex in Mesh mode.
/// - Two fingers: pan and pinch to zoom.
struct EditorCanvas: UIViewRepresentable {
    @ObservedObject var model: EditorModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: GPU.device)
        view.isMultipleTouchEnabled = true
        context.coordinator.attach(view)
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let model: EditorModel
        var renderer: Renderer?
        private weak var view: MTKView?
        private var pinchStart: CGFloat = 1

        init(model: EditorModel) {
            self.model = model
        }

        func attach(_ view: MTKView) {
            self.view = view
            renderer = Renderer(view: view)
            renderer?.source = model
            view.delegate = renderer
            model.contentScale = view.contentScaleFactor

            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(onPinch(_:)))
            let pan2 = UIPanGestureRecognizer(target: self, action: #selector(onPan(_:)))
            pan2.minimumNumberOfTouches = 2
            let drag = UIPanGestureRecognizer(target: self, action: #selector(onDrag(_:)))
            drag.maximumNumberOfTouches = 1
            let tap = UITapGestureRecognizer(target: self, action: #selector(onTap(_:)))
            for g in [pinch, pan2, drag, tap] as [UIGestureRecognizer] {
                g.delegate = self
                view.addGestureRecognizer(g)
            }
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith o: UIGestureRecognizer) -> Bool {
            (g is UIPinchGestureRecognizer && o is UIPanGestureRecognizer) || (o is UIPinchGestureRecognizer && g is UIPanGestureRecognizer)
        }

        private var scale: CGFloat { view?.contentScaleFactor ?? 2 }

        private func pixels(_ p: CGPoint) -> Vec2 {
            Vec2(Float(p.x * scale), Float(p.y * scale))
        }

        @objc private func onPinch(_ g: UIPinchGestureRecognizer) {
            guard let view else { return }
            if g.state == .began {
                pinchStart = model.zoom
                model.dragEnded()
            }
            let newZoom = min(max(pinchStart * g.scale, 0.1), 20)
            let loc = g.location(in: view)
            let c = CGPoint(x: (loc.x - view.bounds.midX) * scale, y: (loc.y - view.bounds.midY) * scale)
            let ratio = newZoom / model.zoom
            model.pan = CGPoint(x: c.x - (c.x - model.pan.x) * ratio, y: c.y - (c.y - model.pan.y) * ratio)
            model.zoom = newZoom
        }

        @objc private func onPan(_ g: UIPanGestureRecognizer) {
            let t = g.translation(in: view)
            model.pan.x += t.x * scale
            model.pan.y += t.y * scale
            g.setTranslation(.zero, in: view)
        }

        @objc private func onDrag(_ g: UIPanGestureRecognizer) {
            guard let view else { return }
            let loc = g.location(in: view)
            switch g.state {
            case .began:
                // Start where the finger first touched, not where the pan was recognised.
                let t = g.translation(in: view)
                model.dragBegan(at: pixels(CGPoint(x: loc.x - t.x, y: loc.y - t.y)))
                model.dragChanged(to: pixels(loc))
            case .changed:
                model.dragChanged(to: pixels(loc))
            default:
                model.dragEnded()
            }
        }

        @objc private func onTap(_ g: UITapGestureRecognizer) {
            guard let view else { return }
            model.tap(at: pixels(g.location(in: view)))
        }
    }
}
