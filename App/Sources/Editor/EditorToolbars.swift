import SwiftUI
import Inochi2DKit

/// What the canvas is doing right now (recording, mesh editing, tracking).
struct StatusBanner: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        let _ = model.revision
        HStack(spacing: 8) {
            if model.mode == .mesh, let d = model.meshTarget, let s = model.meshSession {
                chip("Editing mesh of \(d.name) — \(s.mesh.points.count) vertices, \(s.mesh.triangleCount) triangles",
                     icon: "square.grid.3x3", color: .accentColor)
            } else if model.mode == .model, let p = model.armed {
                let k = p.nearestKeypoint
                let v = p.value(at: k)
                chip("Recording \(p.name) at " + (p.isVec2 ? String(format: "%.2f, %.2f", v.x, v.y) : String(format: "%.2f", v.x)),
                     icon: "record.circle", color: .red)
            } else if model.mode == .test, let s = model.trackingStatus {
                chip(s, icon: "faceid", color: .gray)
            }
        }
    }

    private func chip(_ text: String, icon: String, color: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.callout.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(color.opacity(0.9), in: Capsule())
    }
}

/// Modifier toggles: Creator's Ctrl / Shift / Alt for touch.
struct ModifierToggles: View {
    @ObservedObject var model: EditorModel
    var showAlt = true

    var body: some View {
        HStack(spacing: 6) {
            Toggle(isOn: $model.modAdd) { Text("Ctrl").font(.caption.weight(.semibold)) }
                .toggleStyle(.button)
                .help("Create / remove, snap, lock point")
            Toggle(isOn: $model.modExtend) { Text("Shift").font(.caption.weight(.semibold)) }
                .toggleStyle(.button)
                .help("Add to selection, lock axis, slide along path")
            if showAlt {
                Toggle(isOn: $model.modSelect) { Text("Alt").font(.caption.weight(.semibold)) }
                    .toggleStyle(.button)
                    .help("Select vertices with the brush and path tools")
            }
        }
        .controlSize(.small)
    }
}

/// Tools for Model mode: Select, and the deform tools while a parameter is armed.
struct ModelToolBar: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        let _ = model.revision
        let armed = model.armed != nil
        HStack(spacing: 12) {
            if armed {
                Picker("Tool", selection: $model.tool) {
                    ForEach(EditorModel.Tool.allCases) { t in
                        Label(t.title, systemImage: t.icon).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 420)
                Divider().frame(height: 24)
                Toggle(isOn: Binding(get: { model.deform.mirrorH }, set: { model.deform.mirrorH = $0; model.revision &+= 1 })) {
                    Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                }
                .toggleStyle(.button)
                .help("Mirror horizontally")
                Toggle(isOn: Binding(get: { model.deform.mirrorV }, set: { model.deform.mirrorV = $0; model.revision &+= 1 })) {
                    Image(systemName: "arrow.up.and.down.righttriangle.up.righttriangle.down")
                }
                .toggleStyle(.button)
                .help("Mirror vertically")
                Menu {
                    Button("Reset Selected") { model.resetSelectedDeform() }
                        .disabled(!model.deform.hasSelection)
                    Button("Flip Selected from Mirror") { model.flipSelectedFromMirror() }
                        .disabled(!model.deform.hasSelection)
                    Button("Select All Vertices") {
                        for d in model.deformTargets { model.deform.selection[d.uuid] = Set(d.vertices.indices) }
                        model.revision &+= 1
                    }
                    Button("Clear Selection") { model.deform.selection = [:]; model.revision &+= 1 }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            } else {
                Label("Select", systemImage: "cursorarrow")
                    .font(.callout)
                Text("Tap a part to select it. Drag it or the handles to move, scale, rotate. Long-press for parts underneath.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 360)
            }
            Divider().frame(height: 24)
            ModifierToggles(model: model, showAlt: armed)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

/// Tools for Mesh mode.
struct MeshToolBar: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        let _ = model.revision
        if let s = model.meshSession {
            HStack(spacing: 12) {
                Picker("Mesh tool", selection: Binding(get: { s.tool }, set: { s.tool = $0; model.revision &+= 1 })) {
                    ForEach(MeshEditSession.Tool.allCases) { t in Label(t.title, systemImage: t.icon).tag(t) }
                }
                .pickerStyle(.segmented)
                .frame(width: 330)
                Divider().frame(height: 24)
                ModifierToggles(model: model, showAlt: false)
                Divider().frame(height: 24)
                Button(role: .destructive) { model.deleteKey() } label: { Image(systemName: "trash") }
                    .disabled(s.selection.isEmpty)
                Button("Cancel", role: .cancel) { model.exitMeshMode(apply: false) }
                Button("Apply") { model.exitMeshMode(apply: true) }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
    }
}

/// Mesh mode side panel: tool hints and options, auto-mesh, flips, copy mesh.
struct MeshOptionsView: View {
    @ObservedObject var model: EditorModel
    let present: (EditorSheet) -> Void

    var body: some View {
        let _ = model.revision
        Form {
            if let s = model.meshSession {
                Section("Tool") {
                    Text(hint(s.tool)).font(.callout).foregroundStyle(.secondary)
                    if s.tool == .points {
                        Toggle("Auto-connect vertices", isOn: bind(s, \.autoConnect))
                    }
                    if s.tool == .lasso {
                        Picker("Lasso", selection: bind(s, \.polyLasso)) {
                            Text("Freehand").tag(false)
                            Text("Polygon").tag(true)
                        }
                        .pickerStyle(.segmented)
                    }
                }
                Section("Mirror") {
                    Toggle("Mirror horizontally", isOn: bind(s, \.mirrorH))
                    Toggle("Mirror vertically", isOn: bind(s, \.mirrorV))
                    HStack {
                        Button("Flip Horizontally") { s.flip(horizontal: true); model.revision &+= 1 }
                        Spacer()
                        Button("Flip Vertically") { s.flip(horizontal: false); model.revision &+= 1 }
                    }
                    .buttonStyle(.bordered)
                }
                Section("Triangulation") {
                    Toggle("Preview triangulation", isOn: bind(s, \.previewTriangulation))
                    Button("Triangulate Now") { s.bakeTriangulation(); model.revision &+= 1 }
                        .disabled(s.mesh.points.count < 3)
                }
                Section("Generate") {
                    Button { present(.autoMesh) } label: { Label("Auto Mesh…", systemImage: "wand.and.stars") }
                    Menu {
                        ForEach(otherDrawables(), id: \.uuid) { d in
                            Button(d.name) { model.copyMesh(from: d) }
                        }
                    } label: {
                        Label("Copy Mesh From…", systemImage: "doc.on.doc")
                    }
                    Button { s.revert(); model.revision &+= 1 } label: { Label("Revert to Original", systemImage: "arrow.uturn.backward") }
                }
                Section("Selection") {
                    LabeledContent("Selected", value: "\(s.selection.count) of \(s.mesh.points.count)")
                    Button("Select All") { s.selectAll(); model.revision &+= 1 }
                    Button("Delete Selected", role: .destructive) { model.deleteKey() }
                        .disabled(s.selection.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func bind<T>(_ s: MeshEditSession, _ kp: ReferenceWritableKeyPath<MeshEditSession, T>) -> Binding<T> {
        Binding(get: { s[keyPath: kp] }, set: { s[keyPath: kp] = $0; model.revision &+= 1 })
    }

    private func otherDrawables() -> [Drawable] {
        (model.puppet?.root.allNodes() ?? []).compactMap { $0 as? Drawable }.filter { $0.uuid != model.meshSession?.targetID }
    }

    private func hint(_ t: MeshEditSession.Tool) -> String {
        switch t {
        case .points:
            return "Tap to select (Shift adds). Double-tap or Ctrl+tap empty space to add a vertex; double-tap a selected vertex or Ctrl+tap one to remove it. Drag vertices to move them; drag empty space to box-select."
        case .edges:
            return "Tap two vertices to connect them, or tap two connected ones to disconnect. With Shift the last vertex stays selected so you can chain edges."
        case .grid:
            return "Drag on empty space to create a grid. Drag a vertex to move its grid lines. Double-tap empty space to add lines; double-tap a vertex to remove its lines."
        case .lasso:
            return "Draw around vertices to select them (Shift adds, Ctrl removes). In polygon mode, tap points and tap the first one to close."
        }
    }
}

/// Deform tool settings (brush, path) shown at the top of the inspector.
struct DeformToolOptions: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        let _ = model.revision
        let d = model.deform
        switch model.tool {
        case .brush:
            Section("Brush") {
                Picker("Brush", selection: Binding(get: { d.brushKind }, set: { d.brushKind = $0; model.revision &+= 1 })) {
                    ForEach(DeformSession.BrushKind.allCases) { Text($0.title).tag($0) }
                }
                switch d.brushKind {
                case .circle:
                    size("Radius", Binding(get: { d.radius }, set: { d.radius = $0 }))
                case .doubleThreshold:
                    size("Radius", Binding(get: { d.radius }, set: { d.radius = $0 }))
                    size("Inner radius", Binding(get: { d.innerRadius }, set: { d.innerRadius = $0 }))
                case .rectangle:
                    size("Width", Binding(get: { d.rectWidth }, set: { d.rectWidth = $0 }))
                    size("Height", Binding(get: { d.rectHeight }, set: { d.rectHeight = $0 }))
                }
                Picker("Mode", selection: Binding(get: { d.flow }, set: { d.flow = $0; model.revision &+= 1 })) {
                    Text("Drag").tag(false)
                    Text("Flow").tag(true)
                }
                .pickerStyle(.segmented)
                Text("Drag pushes vertices under the brush. Selected vertices limit the brush. Shift locks to one axis; Alt selects vertices.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .path:
            Section("Path") {
                Picker("Mode", selection: Binding(get: { d.pathTransform }, set: { model.setPathTransform($0) })) {
                    Text("Define path").tag(false)
                    Text("Transform path").tag(true)
                }
                .pickerStyle(.segmented)
                Text(d.pathTransform
                     ? "Drag path points to bend the mesh. Ctrl+tap a point to lock it and rotate around it; Shift slides points along the path."
                     : "Double-tap along the part to add path points; double-tap a point to remove it. Then switch to Transform.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Clear Path") { d.path = CatmullSpline(); d.pathTarget = nil; d.pathTransform = false; model.revision &+= 1 }
            }
        case .lasso:
            Section("Lasso") {
                Picker("Lasso", selection: Binding(get: { d.polyLasso }, set: { d.polyLasso = $0; model.revision &+= 1 })) {
                    Text("Freehand").tag(false)
                    Text("Polygon").tag(true)
                }
                .pickerStyle(.segmented)
            }
        case .points:
            Section("Vertices") {
                Text("Tap or box-select vertices, then drag them. Shift adds to the selection; mirror toggles move counterparts too. Arrow keys nudge.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .select:
            EmptyView()
        }
    }

    private func size(_ title: String, _ value: Binding<Float>) -> some View {
        VStack(alignment: .leading) {
            Text("\(title): \(Int(value.wrappedValue))").font(.caption)
            Slider(value: value, in: 1...2000) { _ in model.revision &+= 1 }
        }
    }
}

/// Auto-mesh options: contour (with Creator's presets) or grid.
struct AutoMeshSheet: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var useGrid = false
    @State private var preset = ContourAutoMesh.Preset.normal
    @State private var contour = ContourAutoMesh.preset(.normal)
    @State private var grid = GridAutoMesh()
    @State private var xSegments = 2
    @State private var ySegments = 2
    @State private var margin: Float = 0.1

    var body: some View {
        NavigationStack {
            Form {
                Picker("Processor", selection: $useGrid) {
                    Text("Contours").tag(false)
                    Text("Grid").tag(true)
                }
                .pickerStyle(.segmented)
                if useGrid {
                    Section("Auto Segmentation") {
                        Stepper("X segments: \(xSegments)", value: $xSegments, in: 2...20)
                        Stepper("Y segments: \(ySegments)", value: $ySegments, in: 2...20)
                        number("Margin", $margin, 0...1)
                        number("Mask threshold", $grid.maskThreshold, 1...200)
                    }
                } else {
                    Section("Preset") {
                        Picker("Preset", selection: $preset) {
                            ForEach(ContourAutoMesh.Preset.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .onChange(of: preset) { _, p in contour = ContourAutoMesh.preset(p) }
                    }
                    Section("Details") {
                        number("Sampling rate", $contour.samplingStep, 1...200)
                        number("Mask threshold", $contour.maskThreshold, 1...200)
                        number("Minimum distance", $contour.minDistance, 1...200)
                        number("Maximum distance", $contour.maxDistance, 1...400)
                        TextField("Scales", text: Binding(
                            get: { contour.scales.map { String(format: "%.2f", $0) }.joined(separator: ", ") },
                            set: { contour.scales = $0.split(separator: ",").compactMap { Float($0.trimmingCharacters(in: .whitespaces)) } }))
                        Text("Vertices are placed along the outline at each scale (1 = on the outline, 0 = centre).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if model.meshSession?.mirrorH == true {
                    Text("Mirror horizontally is on: the mesh will be symmetric around the part's centre.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Auto Mesh")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Generate") {
                        if useGrid {
                            grid.xScales = GridAutoMesh.scales(segments: xSegments, margin: margin)
                            grid.yScales = GridAutoMesh.scales(segments: ySegments, margin: margin)
                            model.runAutoMesh(contour: nil, grid: grid)
                        } else {
                            model.runAutoMesh(contour: contour, grid: nil)
                        }
                        dismiss()
                    }
                }
            }
        }
    }

    private func number(_ title: String, _ v: Binding<Float>, _ range: ClosedRange<Float>) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: v, in: range)
                Text(String(format: "%.1f", v.wrappedValue)).monospacedDigit().frame(width: 52, alignment: .trailing)
            }
            .frame(width: 220)
        }
    }
}
