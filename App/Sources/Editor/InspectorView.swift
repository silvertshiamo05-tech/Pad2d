import SwiftUI
import UniformTypeIdentifiers
import Inochi2DKit

/// Inochi Creator's inspector. While a parameter is armed, bindable values
/// show and record that parameter's values at the nearest keypoint.
struct InspectorView: View {
    @ObservedObject var model: EditorModel
    let present: (EditorSheet) -> Void

    var body: some View {
        let _ = model.revision
        Form {
            if model.armed != nil && model.mode == .model {
                DeformToolOptions(model: model)
            }
            if model.mode == .animation {
                AnimationParameterKeys(model: model)
            } else if model.selectedNodes.count > 1 {
                Section {
                    Text("Can only inspect a single node. \(model.selectedNodes.count) nodes are selected.")
                        .foregroundStyle(.secondary)
                }
            } else if let node = model.selected, node !== model.puppet?.root {
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
        Section("General") {
            LabeledContent("Version", value: "v0.8.7")
            LabeledContent("Parts", value: "\(puppet.parts.count)")
            TextRow(title: "Name", text: puppet.meta.name ?? "") { puppet.meta.name = $0; model.changed("Edit info") }
            TextRow(title: "Artist(s)", text: puppet.meta.artist ?? "") { puppet.meta.artist = $0; model.changed("Edit info") }
            TextRow(title: "Rigger(s)", text: puppet.meta.rigger ?? "") { puppet.meta.rigger = $0; model.changed("Edit info") }
            TextRow(title: "Contact", text: puppet.meta.contact ?? "") { puppet.meta.contact = $0; model.changed("Edit info") }
        }
        Section("Licensing") {
            TextRow(title: "License URL", text: puppet.meta.licenseURL ?? "") { puppet.meta.licenseURL = $0; model.changed("Edit info") }
            TextRow(title: "Copyright", text: puppet.meta.copyright ?? "") { puppet.meta.copyright = $0; model.changed("Edit info") }
            TextRow(title: "Origin", text: puppet.meta.reference ?? "") { puppet.meta.reference = $0; model.changed("Edit info") }
        }
        Section("Physics Globals") {
            NumberRow(title: "Pixels per meter", value: puppet.physics.pixelsPerMeter, range: 1...100_000) { v, commit in
                puppet.physics.pixelsPerMeter = v; model.changed("Physics", commit: commit)
            }
            NumberRow(title: "Gravity (m/s²)", value: puppet.physics.gravity, step: 0.01, range: 0...1000) { v, commit in
                puppet.physics.gravity = v; model.changed("Physics", commit: commit)
            }
        }
        Section("Rendering") {
            Toggle("Use Point Filtering", isOn: Binding(get: { puppet.meta.preservePixels },
                                                       set: { puppet.meta.preservePixels = $0; model.changed("Rendering") }))
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
        let armed = model.armed != nil
        Section {
            if armed {
                LabeledContent(node.name, value: node.kindTitle)
            } else {
                TextRow(title: "Name", text: node.name) { model.rename(node, $0) }
                Toggle("Visible", isOn: Binding(get: { node.enabled }, set: { _ in model.toggleVisible(node) }))
                LabeledContent("Type", value: node.kindTitle)
            }
        }

        if let p = model.armed {
            Section {
                Label {
                    Text("Changes below are recorded into \(p.name) at the nearest keypoint.")
                } icon: {
                    Image(systemName: "record.circle").foregroundStyle(.red)
                }
                .font(.callout)
            }
        }

        Section("Transform") {
            bindable("Translation X", "transform.t.x")
            bindable("Translation Y", "transform.t.y")
            bindable("Translation Z", "transform.t.z")
            if !armed {
                Toggle("Lock to Root Node", isOn: Binding(get: { node.lockToRoot }, set: {
                    node.setLockToRoot($0); model.changed("Lock to root")
                }))
            }
            bindable("Rotation X (°)", "transform.r.x", scale: 180 / .pi, step: 0.5)
            bindable("Rotation Y (°)", "transform.r.y", scale: 180 / .pi, step: 0.5)
            bindable("Rotation Z (°)", "transform.r.z", scale: 180 / .pi, step: 0.5)
            bindable("Scale X", "transform.s.x", step: 0.01)
            bindable("Scale Y", "transform.s.y", step: 0.01)
            bindable("Sorting", "zSort", step: 0.01)
        }

        if let cam = node as? Camera, !armed {
            Section("Camera") {
                NumberRow(title: "Viewport width", value: cam.viewport.x, step: 2, range: 2...16384) { v, c in
                    cam.viewport.x = v.rounded(); model.changed("Camera", commit: c)
                }
                NumberRow(title: "Viewport height", value: cam.viewport.y, step: 2, range: 2...16384) { v, c in
                    cam.viewport.y = v.rounded(); model.changed("Camera", commit: c)
                }
                if Int(cam.viewport.x) % 2 != 0 || Int(cam.viewport.y) % 2 != 0 {
                    Text("Camera size must be divisible by 2 for video export.").font(.caption).foregroundStyle(.red)
                }
            }
        }
        if let c = node as? Composite {
            CompositeSection(model: model, composite: c)
        }
        if let d = node as? Drawable, !armed {
            Section("Drawable") {
                NumberRow(title: "Texture offset X", value: d.origin.x) { v, c in d.setOrigin(Vec2(v, d.origin.y)); model.changed("Texture offset", commit: c) }
                NumberRow(title: "Texture offset Y", value: d.origin.y) { v, c in d.setOrigin(Vec2(d.origin.x, v)); model.changed("Texture offset", commit: c) }
                LabeledContent("Vertices", value: "\(d.vertices.count)")
                LabeledContent("Triangles", value: "\(d.indices.count / 3)")
                Button { model.setMode(.mesh) } label: { Label("Edit Mesh", systemImage: "square.grid.3x3") }
            }
        }
        if let part = node as? Part {
            PartSection(model: model, part: part)
        }
        if let s = node as? SimplePhysics {
            PhysicsSection(model: model, physics: s)
        }
        if let g = node as? MeshGroup, !armed {
            Section("Mesh Group") {
                Toggle("Dynamic Deformation (slower)", isOn: Binding(get: { g.dynamic }, set: { g.setDynamic($0); model.changed("Mesh group") }))
                Toggle("Translate origins", isOn: Binding(get: { g.translateChildren }, set: { g.setTranslateChildren($0); model.changed("Mesh group") }))
            }
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
    @State private var loadingSlot: Int?
    @State private var exportSlot: ExportedImage?

    struct ExportedImage: Identifiable {
        let id = UUID()
        let doc: PNGDocument
        let name: String
    }

    var body: some View {
        let armed = model.armed != nil
        if !armed {
            Section("Textures") {
                ForEach(0..<3, id: \.self) { slot in
                    TextureSlotRow(model: model, part: part, slot: slot,
                                   load: { loadingSlot = slot },
                                   save: { if let png = model.pngData(part: part, slot: slot) {
                                       exportSlot = ExportedImage(doc: PNGDocument(data: png), name: part.name + ["", "_emissive", "_bump"][slot])
                                   } })
                }
            }
            .fileImporter(isPresented: Binding(get: { loadingSlot != nil }, set: { if !$0 { loadingSlot = nil } }),
                          allowedContentTypes: [.png, .jpeg, .image]) { result in
                if case let .success(url) = result, let slot = loadingSlot { model.loadTexture(url, into: part, slot: slot) }
                loadingSlot = nil
            }
            .fileExporter(isPresented: Binding(get: { exportSlot != nil }, set: { if !$0 { exportSlot = nil } }),
                          document: exportSlot?.doc, contentType: .png, defaultFilename: exportSlot?.name) { _ in }
        }
        Section("Appearance") {
            if armed {
                colorRows("Tint", "tint")
                colorRows("Screen tint", "screenTint")
            } else {
                ColorPicker("Tint (Multiply)", selection: Binding(get: { color(part.tint) }, set: { part.tint = vec($0); model.changed("Tint") }),
                            supportsOpacity: false)
                ColorPicker("Tint (Screen)", selection: Binding(get: { color(part.screenTint) },
                                                                set: { part.screenTint = vec($0); model.changed("Screen tint") }),
                            supportsOpacity: false)
                Picker("Blending", selection: Binding(get: { part.blendMode }, set: { part.blendMode = $0; model.changed("Blending") })) {
                    ForEach(BlendMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            NumberRow(title: "Emission strength (%)", value: model.value(part, "emissionStrength") * 100, step: 1,
                      bound: model.isBound(part, "emissionStrength")) { v, commit in
                model.setValue(part, "emissionStrength", max(armed ? -100 : 0, v) / 100, commit: commit)
            }
            SliderRow(title: "Opacity", value: model.value(part, "opacity"), bound: model.isBound(part, "opacity")) { v, c in
                model.setValue(part, "opacity", v, commit: c)
            }
        }
        if !armed {
            MaskSection(model: model, node: part, masks: part.masks)
        }
        Section("Masks") {
            SliderRow(title: "Threshold", value: armed ? model.value(part, "alphaThreshold") : part.maskAlphaThreshold,
                      bound: model.isBound(part, "alphaThreshold")) { v, c in
                if armed { model.setValue(part, "alphaThreshold", v, commit: c) } else {
                    part.maskAlphaThreshold = v
                    model.changed("Mask threshold", commit: c)
                }
            }
        }
    }

    private func colorRows(_ title: String, _ prefix: String) -> some View {
        ForEach(["r", "g", "b"], id: \.self) { ch in
            SliderRow(title: "\(title) \(ch.uppercased())", value: model.value(part, "\(prefix).\(ch)"),
                      bound: model.isBound(part, "\(prefix).\(ch)")) { v, c in
                model.setValue(part, "\(prefix).\(ch)", v, commit: c)
            }
        }
    }
}

private struct TextureSlotRow: View {
    @ObservedObject var model: EditorModel
    let part: Part
    let slot: Int
    let load: () -> Void
    let save: () -> Void

    var body: some View {
        let id = part.textureIDs[slot]
        HStack {
            Text(["Albedo", "Emissive", "Bumpmap"][slot])
            Spacer()
            if let id {
                if let img = model.thumbnail(texture: id) {
                    Image(uiImage: img).resizable().interpolation(.medium).scaledToFit()
                        .frame(width: 40, height: 40)
                        .background(Color.gray.opacity(0.2))
                }
                Text("#\(id)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            } else {
                Text("Empty").foregroundStyle(.secondary)
            }
            Menu {
                Button("Load from File…", action: load)
                if id != nil { Button("Save to File…", action: save) }
                if slot > 0 && id != nil {
                    Button("Remove", role: .destructive) {
                        model.puppet?.setTexture(part, slot: slot, texture: nil)
                        model.changed("Remove texture")
                    }
                }
                if slot == 0, let a = id {
                    Button("Make Emissive") {
                        model.puppet?.setTexture(part, slot: 1, texture: a)
                        model.changed("Make emissive")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }
}

private struct CompositeSection: View {
    @ObservedObject var model: EditorModel
    let composite: Composite

    var body: some View {
        let armed = model.armed != nil
        Section("Composite") {
            if armed {
                ForEach(["tint.r", "tint.g", "tint.b", "screenTint.r", "screenTint.g", "screenTint.b"], id: \.self) { t in
                    SliderRow(title: t, value: model.value(composite, t), bound: model.isBound(composite, t)) { v, c in
                        model.setValue(composite, t, v, commit: c)
                    }
                }
                SliderRow(title: "Opacity", value: model.value(composite, "opacity"), bound: model.isBound(composite, "opacity")) { v, c in
                    model.setValue(composite, "opacity", v, commit: c)
                }
            } else {
                ColorPicker("Tint (Multiply)", selection: Binding(get: { color(composite.tint) }, set: { composite.tint = vec($0); model.changed("Tint") }),
                            supportsOpacity: false)
                ColorPicker("Tint (Screen)", selection: Binding(get: { color(composite.screenTint) },
                                                                set: { composite.screenTint = vec($0); model.changed("Screen tint") }),
                            supportsOpacity: false)
                Picker("Blending", selection: Binding(get: { composite.blendMode }, set: { composite.blendMode = $0; model.changed("Blending") })) {
                    ForEach(BlendMode.allCases.filter { $0 != .clipToLower && $0 != .sliceFromLower }, id: \.self) { Text($0.title).tag($0) }
                }
                SliderRow(title: "Opacity", value: composite.opacity) { v, c in composite.opacity = v; model.changed("Opacity", commit: c) }
                SliderRow(title: "Threshold", value: composite.threshold) { v, c in composite.threshold = v; model.changed("Threshold", commit: c) }
                Toggle("Propagate MeshGroup", isOn: Binding(get: { composite.propagateMeshGroup }, set: {
                    composite.propagateMeshGroup = $0
                    model.puppet?.rebuild()
                    model.changed("Propagate mesh group")
                }))
            }
        }
        if !armed {
            MaskSection(model: model, node: composite, masks: composite.masks)
        }
    }
}

/// Mask sources: which drawables clip (or cut out) this node; reorderable.
private struct MaskSection: View {
    @ObservedObject var model: EditorModel
    let node: Node
    let masks: [MaskBinding]

    var body: some View {
        Section {
            ForEach(Array(masks.enumerated()), id: \.offset) { i, m in
                HStack {
                    Text(model.puppet?.root.find(uuid: m.sourceID)?.name ?? "Missing").lineLimit(1)
                    Spacer()
                    Picker("", selection: Binding(get: { m.mode == .mask ? 0 : 1 }, set: { setMode(i, $0 == 0 ? .mask : .dodge) })) {
                        Text("Mask").tag(0)
                        Text("Dodge").tag(1)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            .onMove { from, to in
                var list = current()
                list.move(fromOffsets: from, toOffset: to)
                apply(list, "Reorder masks")
            }
            .onDelete { idx in
                var list = current()
                list.remove(atOffsets: idx)
                apply(list, "Remove mask")
            }
            Menu {
                ForEach(candidates(), id: \.uuid) { d in
                    Button(d.name) { apply(current() + [(d.uuid, .mask)], "Add mask") }
                }
            } label: {
                Label("Add Mask Source", systemImage: "plus.circle")
            }
        } header: {
            HStack {
                Text("Mask Sources")
                Spacer()
                EditButton().font(.caption)
            }
        } footer: {
            Text("Mask shows this only where the sources are drawn; Dodge hides it there.")
        }
    }

    private func candidates() -> [Drawable] {
        let used = Set(masks.map(\.sourceID))
        return (model.puppet?.root.allNodes() ?? []).compactMap { $0 as? Drawable }
            .filter { $0 !== node && !used.contains($0.uuid) }
    }

    private func current() -> [(UInt32, MaskBinding.Mode)] { masks.map { ($0.sourceID, $0.mode) } }

    private func apply(_ list: [(UInt32, MaskBinding.Mode)], _ label: String) {
        model.puppet?.setMasks(node, sources: list)
        model.changed(label)
    }

    private func setMode(_ i: Int, _ mode: MaskBinding.Mode) {
        var list = current()
        list[i].1 = mode
        apply(list, "Mask mode")
    }
}

private struct PhysicsSection: View {
    @ObservedObject var model: EditorModel
    let physics: SimplePhysics

    var body: some View {
        if model.armed == nil {
            Section {
                Picker("Parameter", selection: Binding(get: { physics.param?.uuid ?? 0 }, set: { id in
                    physics.setParameter(model.puppet?.parameter(uuid: id))
                    model.puppet?.rebuild()
                    model.changed("Physics parameter")
                })) {
                    Text("None").tag(UInt32(0))
                    ForEach(model.puppet?.parameters ?? [], id: \.uuid) { p in Text(p.name).tag(p.uuid) }
                }
                Picker("Type", selection: Binding(get: { physics.model }, set: {
                    physics.model = $0
                    model.puppet?.applyPhysicsSettings(physics)
                    model.changed("Physics type")
                })) {
                    Text("Pendulum").tag(SimplePhysics.Model.pendulum)
                    Text("Spring Pendulum").tag(SimplePhysics.Model.springPendulum)
                }
                Picker("Mapping mode", selection: Binding(get: { physics.mapMode }, set: { physics.mapMode = $0; model.changed("Mapping mode") })) {
                    Text("AngleLength").tag(SimplePhysics.MapMode.angleLength)
                    Text("XY").tag(SimplePhysics.MapMode.xy)
                    Text("LengthAngle").tag(SimplePhysics.MapMode.lengthAngle)
                    Text("YX").tag(SimplePhysics.MapMode.yx)
                }
                Toggle("Local Transform Lock", isOn: Binding(get: { physics.localOnly }, set: { physics.localOnly = $0; model.changed("Physics") }))
            } header: {
                Text("Simple Physics")
            } footer: {
                Text("Turn on Physics in the ••• menu (View) to preview.")
            }
        }
        Section("Simulation") {
            row("Gravity scale", "gravity", 0.01, nil)
            row("Length", "length", 0.01, 0...100_000)
            row("Resonant frequency", "frequency", 0.01, 0.01...30)
            row("Angle damping", "angleDamping", 0.01, 0...5)
            row("Length damping", "lengthDamping", 0.01, 0...5)
            row("Output scale X", "outputScale.x", 0.01, 0...1000)
            row("Output scale Y", "outputScale.y", 0.01, 0...1000)
        }
    }

    private func row(_ title: String, _ target: String, _ step: Float, _ range: ClosedRange<Float>?) -> some View {
        NumberRow(title: title, value: model.value(physics, target), step: step, range: model.armed == nil ? range : nil,
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
        if let p = model.armed, let k = model.armedKeypoint {
            let list = p.bindings.filter { $0.node === node }
            if !list.isEmpty {
                Section("Bindings in \(p.name)") {
                    ForEach(Array(list.enumerated()), id: \.offset) { _, b in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(bindingTitle(b.target))
                                Text(b.isSet(k) ? "Set at this keypoint" : "Interpolated here")
                                    .font(.caption)
                                    .foregroundStyle(b.isSet(k) ? Color.red : Color.secondary)
                            }
                            Spacer()
                            Menu {
                                KeypointActionItems(model: model, parameter: p, bindings: [b])
                                Divider()
                                Button(role: .destructive) { p.bindings.removeAll { $0 === b }; model.changed("Remove binding") } label: {
                                    Label("Remove Binding", systemImage: "trash")
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                        }
                    }
                }
            }
        }
    }
}

func bindingTitle(_ target: String) -> String {
    switch target {
    case "deform": return "Deformation"
    case "transform.t.x": return "Translation X"
    case "transform.t.y": return "Translation Y"
    case "transform.t.z": return "Translation Z"
    case "transform.r.x": return "Rotation X"
    case "transform.r.y": return "Rotation Y"
    case "transform.r.z": return "Rotation Z"
    case "transform.s.x": return "Scale X"
    case "transform.s.y": return "Scale Y"
    case "zSort": return "Sorting"
    default: return target
    }
}

// MARK: - Controls

func color(_ v: Vec3) -> Color {
    Color(red: Double(v.x), green: Double(v.y), blue: Double(v.z))
}

func vec(_ c: Color) -> Vec3 {
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

/// A 0...1 slider with a value label.
struct SliderRow: View {
    let title: String
    let value: Float
    var bound = false
    let onSet: (Float, Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                if bound { Circle().fill(.red).frame(width: 6, height: 6) }
                Text(title)
                Spacer()
                Text(String(format: "%.2f", value)).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { Double(value) }, set: { onSet(Float($0), false) }), in: 0...1) { editing in
                if !editing { onSet(value, true) }
            }
        }
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

/// A PNG for the Files exporter.
struct PNGDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.png] }
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
