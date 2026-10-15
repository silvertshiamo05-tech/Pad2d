import SwiftUI
import Inochi2DKit

/// Sliders for 1D parameters and XY pads for 2D ones.
struct ParameterPanel: View {
    @ObservedObject var controller: PuppetController
    @State private var showPhysics = false
    @State private var search = ""

    var body: some View {
        let _ = controller.tick // refresh while tracking moves values
        let params = controller.puppet?.parameters ?? []
        let filtered = search.isEmpty ? params : params.filter { $0.name.localizedCaseInsensitiveContains(search) }
        let driven = filtered.filter { controller.puppet?.isDriven($0) == true }
        let manual = filtered.filter { controller.puppet?.isDriven($0) != true }

        List {
            Section {
                ForEach(manual, id: \.uuid) { p in
                    ParameterRow(controller: controller, parameter: p)
                }
            } header: {
                Text("Parameters (\(manual.count))")
            } footer: {
                if controller.trackingMode != .off {
                    Text("Parameters marked with a tracking icon follow the camera or your finger. Drag a control to override it.")
                }
            }
            if !driven.isEmpty {
                Section {
                    DisclosureGroup("Driven by physics (\(driven.count))", isExpanded: $showPhysics) {
                        ForEach(driven, id: \.uuid) { p in
                            HStack {
                                Text(p.name).font(.callout)
                                Spacer()
                                Text(String(format: "%.2f", p.value.x)).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $search, placement: .sidebar, prompt: "Filter")
    }
}

private struct ParameterRow: View {
    @ObservedObject var controller: PuppetController
    let parameter: Parameter

    var body: some View {
        let tracked = controller.isTracked(parameter.name)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(parameter.name).font(.subheadline.weight(.medium)).lineLimit(2)
                if tracked {
                    Image(systemName: controller.trackingMode == .face ? "faceid" : "hand.point.up.left")
                        .font(.caption).foregroundStyle(.tint)
                }
                Spacer()
                Text(parameter.isVec2
                     ? String(format: "%.2f, %.2f", parameter.value.x, parameter.value.y)
                     : String(format: "%.2f", parameter.value.x))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if parameter.isVec2 {
                XYPad(parameter: parameter, onEditing: editing)
                    .frame(height: 150)
            } else {
                Slider(value: Binding(get: { Double(parameter.value.x) },
                                      set: { parameter.value.x = Float($0); controller.objectWillChange.send() }),
                       in: Double(parameter.min.x)...Double(max(parameter.max.x, parameter.min.x + 0.0001)),
                       onEditingChanged: editing)
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button { parameter.value = parameter.defaults } label: { Label("Reset to Default", systemImage: "arrow.uturn.backward") }
        }
    }

    private func editing(_ active: Bool) {
        if active { controller.editingParameters.insert(parameter.name) }
        else { controller.editingParameters.remove(parameter.name) }
    }
}

/// A square pad controlling both axes of a 2D parameter. Up is the maximum Y.
private struct XYPad: View {
    let parameter: Parameter
    let onEditing: (Bool) -> Void
    @State private var dragging = false

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let n = parameter.normalizedValue
            let nx = n.x.isFinite ? CGFloat(n.x) : 0.5
            let ny = n.y.isFinite ? CGFloat(n.y) : 0.5
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(.quaternary)
                Path { p in
                    p.move(to: CGPoint(x: side / 2, y: 0)); p.addLine(to: CGPoint(x: side / 2, y: side))
                    p.move(to: CGPoint(x: 0, y: side / 2)); p.addLine(to: CGPoint(x: side, y: side / 2))
                }
                .stroke(.secondary.opacity(0.4), lineWidth: 1)
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 18, height: 18)
                    .position(x: nx * side, y: (1 - ny) * side)
            }
            .frame(width: side, height: side)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if !dragging { dragging = true; onEditing(true) }
                    let x = Float(max(0, min(1, g.location.x / side)))
                    let y = Float(max(0, min(1, 1 - g.location.y / side)))
                    parameter.normalizedValue = Vec2(x, y)
                }
                .onEnded { _ in dragging = false; onEditing(false) })
            .frame(maxWidth: .infinity)
        }
    }
}
