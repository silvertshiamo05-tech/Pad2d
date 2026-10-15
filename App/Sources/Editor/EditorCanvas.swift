import SwiftUI
import MetalKit
import Inochi2DKit

/// The editor's Metal view.
///
/// - One finger (or Pencil): the current tool. Tap selects; double-tap adds or
///   removes points where the tool supports it; long-press lists the parts
///   under the finger.
/// - Two fingers: pan and pinch to zoom.
/// - With a hardware keyboard: ⌘/⌃, ⇧ and ⌥ act like Creator's Ctrl, Shift and
///   Alt; arrows nudge vertices; Delete removes selected vertices.
struct EditorCanvas: UIViewRepresentable {
    @ObservedObject var model: EditorModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> CanvasView {
        let view = CanvasView(frame: .zero, device: GPU.device)
        view.isMultipleTouchEnabled = true
        view.model = model
        context.coordinator.attach(view)
        return view
    }

    func updateUIView(_ view: CanvasView, context: Context) {}

    /// MTKView that also receives hardware keyboard presses.
    final class CanvasView: MTKView {
        weak var model: EditorModel?

        override var canBecomeFirstResponder: Bool { true }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            becomeFirstResponder()
        }

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            var handled = false
            for p in presses {
                guard let key = p.key, let model else { continue }
                model.hardwareModifiers = key.modifierFlags
                switch key.keyCode {
                case .keyboardLeftArrow: model.nudge(Vec2(-1, 0)); handled = true
                case .keyboardRightArrow: model.nudge(Vec2(1, 0)); handled = true
                case .keyboardUpArrow: model.nudge(Vec2(0, -1)); handled = true
                case .keyboardDownArrow: model.nudge(Vec2(0, 1)); handled = true
                case .keyboardDeleteOrBackspace, .keyboardDeleteForward:
                    model.deleteKey(); handled = true
                case .keyboardSpacebar:
                    if model.mode == .animation { model.togglePlay() }; handled = true
                default: break
                }
            }
            if !handled { super.pressesBegan(presses, with: event) }
        }

        override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            for p in presses {
                guard let key = p.key, let model else { continue }
                let flags = key.modifierFlags
                model.hardwareModifiers = flags.subtracting(Self.modifier(for: key.keyCode))
            }
            super.pressesEnded(presses, with: event)
        }

        private static func modifier(for code: UIKeyboardHIDUsage) -> UIKeyModifierFlags {
            switch code {
            case .keyboardLeftShift, .keyboardRightShift: return .shift
            case .keyboardLeftControl, .keyboardRightControl: return .control
            case .keyboardLeftAlt, .keyboardRightAlt: return .alternate
            case .keyboardLeftGUI, .keyboardRightGUI: return .command
            default: return []
            }
        }
    }

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
            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(onDoubleTap(_:)))
            doubleTap.numberOfTapsRequired = 2
            let longPress = UILongPressGestureRecognizer(target: self, action: #selector(onLongPress(_:)))
            longPress.minimumPressDuration = 0.6
            for g in [pinch, pan2, drag, tap, doubleTap, longPress] as [UIGestureRecognizer] {
                g.delegate = self
                view.addGestureRecognizer(g)
            }
            // Scroll wheel / trackpad zoom.
            let scroll = UIPanGestureRecognizer(target: self, action: #selector(onScroll(_:)))
            scroll.allowedScrollTypesMask = .all
            scroll.maximumNumberOfTouches = 0
            view.addGestureRecognizer(scroll)
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith o: UIGestureRecognizer) -> Bool {
            (g is UIPinchGestureRecognizer && o is UIPanGestureRecognizer) || (o is UIPinchGestureRecognizer && g is UIPanGestureRecognizer)
                || (g is UITapGestureRecognizer && o is UITapGestureRecognizer)
        }

        private var scale: CGFloat { view?.contentScaleFactor ?? 2 }

        private func pixels(_ p: CGPoint) -> Vec2 {
            Vec2(Float(p.x * scale), Float(p.y * scale))
        }

        private func syncModifiers(_ g: UIGestureRecognizer) {
            model.hardwareModifiers = g.modifierFlags
        }

        @objc private func onPinch(_ g: UIPinchGestureRecognizer) {
            guard let view else { return }
            if g.state == .began {
                pinchStart = model.zoom
                model.dragEnded()
            }
            zoom(to: min(max(pinchStart * g.scale, 0.05), 40), around: g.location(in: view))
        }

        private func zoom(to newZoom: CGFloat, around loc: CGPoint) {
            guard let view else { return }
            let c = CGPoint(x: (loc.x - view.bounds.midX) * scale, y: (loc.y - view.bounds.midY) * scale)
            let ratio = newZoom / model.zoom
            model.pan = CGPoint(x: c.x - (c.x - model.pan.x) * ratio, y: c.y - (c.y - model.pan.y) * ratio)
            model.zoom = newZoom
        }

        @objc private func onScroll(_ g: UIPanGestureRecognizer) {
            guard let view else { return }
            let t = g.translation(in: view)
            g.setTranslation(.zero, in: view)
            let speed = CGFloat(AppSettings.zoomSpeed) / 500
            zoom(to: min(max(model.zoom * (1 - t.y * speed), 0.05), 40), around: g.location(in: view))
        }

        @objc private func onPan(_ g: UIPanGestureRecognizer) {
            let t = g.translation(in: view)
            model.pan.x += t.x * scale
            model.pan.y += t.y * scale
            g.setTranslation(.zero, in: view)
        }

        @objc private func onDrag(_ g: UIPanGestureRecognizer) {
            guard let view else { return }
            syncModifiers(g)
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
            syncModifiers(g)
            model.tap(at: pixels(g.location(in: view)))
        }

        @objc private func onDoubleTap(_ g: UITapGestureRecognizer) {
            guard let view else { return }
            syncModifiers(g)
            model.doubleTap(at: pixels(g.location(in: view)))
        }

        @objc private func onLongPress(_ g: UILongPressGestureRecognizer) {
            guard let view, g.state == .began else { return }
            model.longPress(at: pixels(g.location(in: view)))
        }
    }
}
