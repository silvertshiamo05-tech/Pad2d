import SwiftUI
import Inochi2DKit

/// Properties of the selected node. While a parameter is armed, bindable
/// values show and record that parameter's offsets at the current keypoint.
struct InspectorView: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        let _ = model.revision
        Form {
            if let node = model.selected {
                NodeInspector(model: model, node: node)
            } else if let puppet = model.puppet {
                PuppetInspector(model: model, puppet: puppet)
            }
        }
        .formStyle(.grouped)
        .scrollDismissesKeyboard(.interactively)
    }
}

private struct PuppetInspector: View {
    @ObservedObject var model: EditorModel
    let puppet: Puppet

    var body: some View {
        Section("Puppet") {
            TextRow(title: "Name", text: puppet.meta.name ?? "") { puppet.meta.name = $0; model.changed() }
            TextRow(title: "Artist", text: puppet.meta.artist ?? "") { puppet.meta.artist = $0; model.changed() }
            TextRow(title: "Rigger", text: puppet.meta.rigger ?? "") { puppet.meta.rigger = $0; model.changed() }
            TextRow(title: "Copyright", text: puppet.meta.copyright ?? "") { puppet.meta.copyright = $0; model.changed() }
            TextRow(title: "Contact", text: puppet.meta.contact ?? "") { puppet.meta.contact = $0; model.changed() }
            Toggle("Pixel Art (no smoothing)", isOn: Binding(get: { puppet.meta.preservePixels },
                                                            set: { puppet.meta.preservePixels = $0; model.changed() }))
        }
        Section("Physics") {
            NumberRow(title: "Pixels per metre", value: puppet.physics.pixelsPerMeter) { v, commit in
                puppet.physics.pixelsPerMeter = max(1, v); model.changed(commit: commit)
            }
            NumberRow(title: "Gravity (m/s²)", value: puppet.physics.gravity) { v, commit in
                puppet.physics.gravity = v; model.changed(commit: commit)
            }
        }
        Section {
            Text("Select a node in the tree or tap a part on the canvas to edit it.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

private struct NodeInspector: View {
    @ObservedObject var model: EditorModel
    let node: Node

    var body: some View {
        Section {
            TextRow(title: "Name", text: node.name) { model.rename(node, $0) }
            Toggle("Visible", isOn: Binding(get: { node.enabled }, set: { node.enabled = $0; model.changed() }))
            LabeledContent("Type", value: node.kindTitle)
        }

        if let p = model.armed {
            Section {
                Label {
                    Text(model.armedKeypoint == nil
                         ? "Move \(p.name) onto a keypoint to record."
                         : "Changes below are recorded into \(p.name) at this keypoint, as offsets from the rest pose.")
                } icon: {
                    Image(systemName: "record.circle").foregroundStyle(.red)
                }
                .font(.callout)
            }
        }

        Section("Transform") {
            bindable("X", "transform.t.x")
            bindable("Y", "transform.t.y")
            bindable("Rotation (°)", "transform.r.z", scale: 180 / .pi, step: 0.5)
            bindable("Scale X", "transform.s.x", step: 0.01)
            bindable("Scale Y", "transform.s.y", step: 0.01)
            bindable("Z-sort", "zSort", step: 0.01)
            if model.armed == nil {
                Toggle("Lock to Root", isOn: Binding(get: { node.lockToRoot }, set: { node.lockToRoot = $0; model.changed() }))
            }
        }

        if let part = node as? Part {
            PartSection(model: model, part: part)
        }
        if let c = node as? Composite {
            CompositeSection(model: model, composite: c)
        }
        if let g = node as? MeshGroup {
            Section("Mesh Group") {
                Toggle("Dynamic deformation", isOn: Binding(get: { g.dynamic }, set: { g.dynamic = $0; model.changed() }))
                Toggle("Translate children", isOn: Binding(get: { g.translateChildren }, set: { g.translateChildren = $0; model.changed() }))
            }
        }
        if let d = node as? Drawable {
            Section("Mesh") {
                LabeledContent("Vertices", value: "\(d.vertices.count)")
                LabeledContent("Triangles", value: "\(d.indices.count / 3)")
                Button { model.setMode(.mesh) } label: { Label("Edit Mesh", systemImage: "square.grid.3x3") }
            }
        }
        if let s = node as? SimplePhysics {
            PhysicsSection(model: model, physics: s)
        }
        BindingsSection(model: model, node: node)
    }

    private func bindable(_ title: String, _ target: String, scale: Float = 1, step: Float = 1) -> some View {
        NumberRow(title: title, value: model.value(node, target) * scale, step: step,
                  bound: model.isBound(node, target)) { v, commit in
            model.setValue(node, target, v / scale, commit: commit)
        }
    }
}

private struct PartSection: View {
    @ObservedObject var model: EditorModel
    let part: Part

    var body: some View {
        Section("Appearance") {
            NumberRow(title: "Opacity", value: model.value(part, "opacity"), step: 0.01, range: 0...1,
                      bound: model.isBound(part, "opacity")) { v, commit in
                model.setValue(part, "opacity", v, commit: commit)
            }
            if model.armed == nil {
                Picker("Blend mode", selection: Binding(get: { part.blendMode }, set: { part.blendMode = $0; model.changed() })) {
                    ForEach(BlendMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                ColorPicker("Tint", selection: Binding(get: { color(part.tint) }, set: { part.tint = vec($0); model.changed() }),
                            supportsOpacity: false)
                ColorPicker("Screen tint", selection: Binding(get: { color(part.screenTint) },
                                                              set: { part.screenTint = vec($0); model.changed() }),
                            supportsOpacity: false)
            } else {
                ForEach(["tint.r", "tint.g", "tint.b"], id: \.self) { t in
                    NumberRow(title: "Tint " + t.suffix(1).uppercased(), value: model.value(part, t), step: 0.01,
                              range: 0...1, bound: model.isBound(part, t)) { v, commit in
                        model.setValue(part, t, v, commit: commit)
                    }
                }
            }
        }
        MaskSection(model: model, node: part, masks: part.masks)
        if !part.masks.isEmpty {
            Section {
                NumberRow(title: "Mask threshold", value: model.value(part, "alphaThreshold"), step: 0.01, range: 0...1,
                          bound: model.isBound(part, "alphaThreshold")) { v, commit in
                    model.setValue(part, "alphaThreshold", v, commit: commit)
                }
            }
        }
    }
}

private struct CompositeSection: View {
    @ObservedObject var model: EditorModel
    let composite: Composite

    var body: some View {
        Section("Composite") {
            NumberRow(title: "Opacity", value: composite.opacity, step: 0.01, range: 0...1) { v, commit in
                composite.opacity = v
                model.changed(commit: commit)
            }
            Picker("Blend mode", selection: Binding(get: { composite.blendMode }, set: { composite.blendMode = $0; model.changed() })) {
                ForEach(BlendMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            ColorPicker("Tint", selection: Binding(get: { color(composite.tint) }, set: { composite.tint = vec($0); model.changed() }),
                        supportsOpacity: false)
        }
        MaskSection(model: model, node: composite, masks: composite.masks)
    }
}

/// Masks: which drawables clip (or cut out) this node.
private struct MaskSection: View {
    @ObservedObject var model: EditorModel
    let node: Node
    let masks: [MaskBinding]

    var body: some View {
        Section {
            ForEach(Array(masks.enumerated()), id: \.offset) { i, m in
                HStack {
                    Text(model.puppet?.root.find(uuid: m.sourceID)?.name ?? "Missing")
                        .lineLimit(1)
                    Spacer()
                    Picker("", selection: Binding(get: { m.mode == .mask ? 0 : 1 }, set: { setMode(i, $0 == 0 ? .mask : .dodge) })) {
                        Text("Clip").tag(0)
                        Text("Cut out").tag(1)
                    }
                    .labelsHidden()
                    .fixedSize()
                    Button(role: .destructive) { remove(i) } label: { Image(systemName: "minus.circle.fill") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.red)
                }
            }
            Menu {
                ForEach(candidates(), id: \.uuid) { d in
                    Button(d.name) { add(d) }
                }
            } label: {
                Label("Add Mask", systemImage: "plus.circle")
            }
        } header: {
            Text("Masks")
        } footer: {
            Text("Clip shows this only where the mask parts are drawn; Cut out hides it there.")
        }
    }

    private func candidates() -> [Drawable] {
        let used = Set(masks.map(\.sourceID))
        return (model.puppet?.root.allNodes() ?? []).compactMap { $0 as? Drawable }
            .filter { $0 !== node && !used.contains($0.uuid) }
    }

    private func apply(_ list: [(UInt32, MaskBinding.Mode)]) {
        model.puppet?.setMasks(node, sources: list)
        model.changed()
    }

    private func current() -> [(UInt32, MaskBinding.Mode)] { masks.map { ($0.sourceID, $0.mode) } }

    private func add(_ d: Drawable) { apply(current() + [(d.uuid, .mask)]) }

    private func remove(_ i: Int) {
        var list = current()
        list.remove(at: i)
        apply(list)
    }

    private func setMode(_ i: Int, _ mode: MaskBinding.Mode) {
        var list = current()
        list[i].1 = mode
        apply(list)
    }
}

private struct PhysicsSection: View {
    @ObservedObject var model: EditorModel
    let physics: SimplePhysics

    var body: some View {
        Section {
            Picker("Parameter", selection: Binding(get: { physics.param?.uuid ?? 0 }, set: { id in
                physics.setParameter(model.puppet?.parameters.first { $0.uuid == id })
                model.puppet?.rebuild()
                model.changed()
            })) {
                Text("None").tag(UInt32(0))
                ForEach(model.puppet?.parameters ?? [], id: \.uuid) { p in
                    Text(p.name).tag(p.uuid)
                }
            }
            Picker("Model", selection: Binding(get: { physics.model }, set: {
                physics.model = $0
                model.puppet?.applyPhysicsSettings(physics)
                model.changed()
            })) {
                Text("Pendulum").tag(SimplePhysics.Model.pendulum)
                Text("Spring pendulum").tag(SimplePhysics.Model.springPendulum)
            }
            Picker("Output", selection: Binding(get: { physics.mapMode }, set: { physics.mapMode = $0; model.changed() })) {
                Text("Angle, Length").tag(SimplePhysics.MapMode.angleLength)
                Text("Length, Angle").tag(SimplePhysics.MapMode.lengthAngle)
                Text("X, Y").tag(SimplePhysics.MapMode.xy)
                Text("Y, X").tag(SimplePhysics.MapMode.yx)
            }
            Toggle("Local only", isOn: Binding(get: { physics.localOnly }, set: { physics.localOnly = $0; model.changed() }))
        } header: {
            Text("Physics")
        } footer: {
            Text("Turn on the wind button under the canvas to preview physics.")
        }
        Section("Simulation") {
            row("Gravity", "gravity", 0.01)
            row("Length", "length", 1)
            row("Frequency", "frequency", 0.01)
            row("Angle damping", "angleDamping", 0.01)
            row("Length damping", "lengthDamping", 0.01)
            row("Output scale X", "outputScale.x", 0.01)
            row("Output scale Y", "outputScale.y", 0.01)
        }
    }

    private func row(_ title: String, _ target: String, _ step: Float) -> some View {
        NumberRow(title: title, value: model.value(physics, target), step: step,
                  bound: model.isBound(physics, target)) { v, commit in
            model.setValue(physics, target, v, commit: commit)
        }
    }
}

/// The node's bindings on the armed parameter.
private struct BindingsSection: View {
    @ObservedObject var model: EditorModel
    let node: Node

    var body: some View {
        if let p = model.armed, let puppet = model.puppet {
            let list = puppet.bindings(for: node).filter { $0.0 === p }.map(\.1)
            Section {
                if list.isEmpty {
                    Text(node is Drawable ? "Nothing recorded yet. Use the Deform tool or change a value above."
                                          : "Nothing recorded yet. Change a value above or use the Move tool.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(list.enumerated()), id: \.offset) { _, b in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(title(b.target))
                            if let k = model.armedKeypoint {
                                Text(b.isSet(k) ? "Set at this keypoint" : "Interpolated here")
                                    .font(.caption)
                                    .foregroundStyle(b.isSet(k) ? Color.red : Color.secondary)
                            }
                        }
                        Spacer()
                        Menu {
                            Picker("Interpolation", selection: Binding(get: { b.interpolation }, set: { b.interpolation = $0; model.changed() })) {
                                Text("Nearest").tag(InterpolateMode.nearest)
                                Text("Linear").tag(InterpolateMode.linear)
                                Text("Cubic").tag(InterpolateMode.cubic)
                            }
                            if let k = model.armedKeypoint, b.isSet(k) {
                                Button { puppet.unset(b, at: k); model.changed() } label: {
                                    Label("Clear This Keypoint", systemImage: "eraser")
                                }
                            }
                            Button(role: .destructive) { puppet.removeBinding(b); model.changed() } label: {
                                Label("Remove Binding", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            } header: {
                Text("Recorded in \(p.name)")
            }
        }
    }

    private func title(_ target: String) -> String {
        switch target {
        case "deform": return "Deformation"
        case "transform.t.x": return "X"
        case "transform.t.y": return "Y"
        case "transform.r.z": return "Rotation"
        case "transform.s.x": return "Scale X"
        case "transform.s.y": return "Scale Y"
        case "zSort": return "Z-sort"
        default: return target
        }
    }
}

// MARK: - Controls

private func color(_ v: Vec3) -> Color {
    Color(red: Double(v.x), green: Double(v.y), blue: Double(v.z))
}

private func vec(_ c: Color) -> Vec3 {
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    UIColor(c).getRed(&r, green: &g, blue: &b, alpha: &a)
    return Vec3(Float(min(max(r, 0), 1)), Float(min(max(g, 0), 1)), Float(min(max(b, 0), 1)))
}

/// A text field that commits on return.
struct TextRow: View {
    let title: String
    let text: String
    let onCommit: (String) -> Void
    @State private var editing = ""
    @FocusState private var focused: Bool

    var body: some View {
        LabeledContent(title) {
            TextField(title, text: $editing)
                .multilineTextAlignment(.trailing)
                .focused($focused)
                .onSubmit { if editing != text { onCommit(editing) } }
                .onChange(of: focused) { _, f in if !f && editing != text { onCommit(editing) } }
        }
        .onAppear { editing = text }
        .onChange(of: text) { _, t in if !focused { editing = t } }
    }
}

/// A number with a text field; drag the title sideways to scrub the value.
struct NumberRow: View {
    let title: String
    let value: Float
    var step: Float = 1
    var range: ClosedRange<Float>? = nil
    var bound = false
    let onSet: (Float, Bool) -> Void

    @State private var text = ""
    @State private var scrubStart: Float?
    @FocusState private var focused: Bool

    var body: some View {
        HStack {
            HStack(spacing: 4) {
                if bound { Circle().fill(.red).frame(width: 6, height: 6) }
                Text(title)
                Image(systemName: "arrow.left.and.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 4)
                .onChanged { g in
                    if scrubStart == nil { scrubStart = value }
                    let v = (scrubStart ?? value) + Float(g.translation.width) * step * 0.5
                    onSet(clamped(v), false)
                }
                .onEnded { _ in
                    scrubStart = nil
                    onSet(clamped(value), true)
                })
            Spacer()
            TextField("0", text: $text)
                .keyboardType(.numbersAndPunctuation)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(maxWidth: 110)
                .focused($focused)
                .onSubmit(commitText)
                .onChange(of: focused) { _, f in if !f { commitText() } }
        }
        .onAppear { text = format(value) }
        .onChange(of: value) { _, v in if !focused { text = format(v) } }
    }

    private func commitText() {
        guard let v = Float(text.replacingOccurrences(of: ",", with: ".")) else {
            text = format(value)
            return
        }
        if abs(v - value) > 1e-6 { onSet(clamped(v), true) }
    }

    private func clamped(_ v: Float) -> Float {
        guard let range else { return v }
        return min(max(v, range.lowerBound), range.upperBound)
    }

    private func format(_ v: Float) -> String {
        step < 1 ? String(format: "%.3f", v) : String(format: "%.1f", v)
    }
}
