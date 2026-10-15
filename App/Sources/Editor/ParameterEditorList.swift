import SwiftUI
import Inochi2DKit

/// Parameters panel: create parameters, arm one to record, manage keypoints.
struct ParameterEditorList: View {
    @ObservedObject var model: EditorModel
    @State private var search = ""
    @State private var editing: ParameterDraft?

    var body: some View {
        let _ = model.revision
        let params = (model.puppet?.parameters ?? []).filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
        VStack(spacing: 0) {
            HStack {
                TextField("Filter", text: $search)
                    .textFieldStyle(.roundedBorder)
                Menu {
                    Button { editing = ParameterDraft(isVec2: false) } label: { Label("New 1D Parameter", systemImage: "slider.horizontal.below.rectangle") }
                    Button { editing = ParameterDraft(isVec2: true) } label: { Label("New 2D Parameter", systemImage: "square.grid.3x3.middle.filled") }
                } label: {
                    Image(systemName: "plus.circle.fill").font(.title2)
                }
            }
            .padding(8)
            if params.isEmpty {
                ContentUnavailableView("No parameters", systemImage: "slider.horizontal.3",
                                       description: Text("Add a parameter (like Head Yaw or Eye Blink), arm it, then deform parts at its keypoints."))
            }
            List {
                ForEach(params, id: \.uuid) { p in
                    ParameterEditorRow(model: model, parameter: p) { editing = ParameterDraft(p) }
                }
            }
            .listStyle(.plain)
        }
        .sheet(item: $editing) { draft in
            ParameterSheet(model: model, draft: draft)
        }
    }
}

private struct ParameterEditorRow: View {
    @ObservedObject var model: EditorModel
    let parameter: Parameter
    let edit: () -> Void

    var body: some View {
        let armed = model.armedID == parameter.uuid
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button {
                    model.arm(armed ? nil : parameter)
                } label: {
                    Image(systemName: armed ? "record.circle.fill" : "record.circle")
                        .font(.title3)
                        .foregroundStyle(armed ? Color.red : Color.secondary)
                }
                .buttonStyle(.borderless)
                Text(parameter.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                Spacer()
                Text(parameter.isVec2
                     ? String(format: "%.2f, %.2f", parameter.value.x, parameter.value.y)
                     : String(format: "%.2f", parameter.value.x))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Menu {
                    menuItems
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .buttonStyle(.borderless)
            }
            KeypointPad(model: model, parameter: parameter, armed: armed)
                .frame(height: parameter.isVec2 ? 170 : 40)
        }
        .padding(.vertical, 4)
        .listRowBackground(armed ? Color.red.opacity(0.08) : Color.clear)
    }

    @ViewBuilder
    private var menuItems: some View {
        Button { edit() } label: { Label("Edit…", systemImage: "pencil") }
        Button { model.setValue(parameter, parameter.defaults) } label: { Label("Reset Value", systemImage: "arrow.uturn.backward") }
        Divider()
        let n = parameter.normalizedValue
        Button {
            model.puppet?.addKeypoint(parameter, axis: 0, at: n.x)
            model.changed()
        } label: { Label(parameter.isVec2 ? "Add Keypoint Column Here" : "Add Keypoint Here", systemImage: "plus") }
        if parameter.isVec2 {
            Button {
                model.puppet?.addKeypoint(parameter, axis: 1, at: n.y)
                model.changed()
            } label: { Label("Add Keypoint Row Here", systemImage: "plus") }
        }
        if let k = parameter.currentKeypoint {
            if k.x > 0 && k.x < parameter.axisKeypoints[0].count - 1 {
                Button(role: .destructive) {
                    model.puppet?.removeKeypoint(parameter, axis: 0, index: k.x)
                    model.changed()
                } label: { Label(parameter.isVec2 ? "Remove Keypoint Column" : "Remove Keypoint", systemImage: "minus") }
            }
            if parameter.isVec2 && k.y > 0 && k.y < parameter.axisKeypoints[1].count - 1 {
                Button(role: .destructive) {
                    model.puppet?.removeKeypoint(parameter, axis: 1, index: k.y)
                    model.changed()
                } label: { Label("Remove Keypoint Row", systemImage: "minus") }
            }
        }
        Divider()
        Button(role: .destructive) {
            if model.armedID == parameter.uuid { model.arm(nil) }
            model.puppet?.deleteParameter(parameter)
            model.changed()
        } label: { Label("Delete Parameter", systemImage: "trash") }
    }
}

/// Value control with the keypoint grid. Keypoints the selected node has
/// recorded values at are filled. While armed, releasing snaps to the
/// nearest keypoint.
private struct KeypointPad: View {
    @ObservedObject var model: EditorModel
    let parameter: Parameter
    let armed: Bool

    private var inset: CGFloat { 10 }

    private func pos(_ x: CGFloat, _ y: CGFloat, _ size: CGSize) -> CGPoint {
        CGPoint(x: inset + x * (size.width - 2 * inset), y: inset + (1 - y) * (size.height - 2 * inset))
    }

    private var xs: [Float] { parameter.axisKeypoints[0] }
    private var ys: [Float] { parameter.isVec2 ? parameter.axisKeypoints[1] : [0.5] }

    private func grid(_ size: CGSize) -> Path {
        Path { p in
            for x in xs {
                p.move(to: pos(CGFloat(x), 0, size))
                p.addLine(to: pos(CGFloat(x), 1, size))
            }
            for y in ys {
                p.move(to: pos(0, CGFloat(y), size))
                p.addLine(to: pos(1, CGFloat(y), size))
            }
        }
    }

    private struct Dot: Identifiable {
        let id: Int
        let point: CGPoint
        let filled: Bool
    }

    private func dots(_ size: CGSize) -> [Dot] {
        let set = recordedKeypoints()
        var out: [Dot] = []
        for i in xs.indices {
            for j in ys.indices {
                let k = Keypoint(i, parameter.isVec2 ? j : 0)
                out.append(Dot(id: i * 1000 + j, point: pos(CGFloat(xs[i]), CGFloat(ys[j]), size), filled: set.contains(k)))
            }
        }
        return out
    }

    private func knob(_ size: CGSize) -> CGPoint {
        let n = parameter.normalizedValue
        let nx = n.x.isFinite ? CGFloat(n.x) : 0.5
        let ny: CGFloat = parameter.isVec2 ? (n.y.isFinite ? CGFloat(n.y) : 0.5) : 0.5
        return pos(nx, ny, size)
    }

    private func drag(_ location: CGPoint, _ size: CGSize) {
        let x = Float(max(0, min(1, (location.x - inset) / (size.width - 2 * inset))))
        let y = Float(max(0, min(1, 1 - (location.y - inset) / (size.height - 2 * inset))))
        parameter.normalizedValue = Vec2(x, parameter.isVec2 ? y : 0)
        model.setValue(parameter, parameter.value)
    }

    var body: some View {
        GeometryReader { geo in
            pad(geo.size)
        }
    }

    private func pad(_ size: CGSize) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(.quaternary)
            grid(size).stroke(Color.secondary.opacity(0.35), lineWidth: 1)
            ForEach(dots(size)) { d in
                Circle()
                    .fill(d.filled ? Color.red : Color.secondary.opacity(0.5))
                    .frame(width: d.filled ? 9 : 6, height: d.filled ? 9 : 6)
                    .position(d.point)
            }
            Circle()
                .strokeBorder(Color.white, lineWidth: 2)
                .background(Circle().fill(armed ? Color.red : Color.accentColor))
                .frame(width: 18, height: 18)
                .position(knob(size))
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { g in drag(g.location, size) }
            .onEnded { _ in
                if armed { model.goTo(parameter, parameter.nearestKeypoint) }
            })
    }

    private func recordedKeypoints() -> Set<Keypoint> {
        guard let node = model.selected, let puppet = model.puppet else { return [] }
        var out = Set<Keypoint>()
        for (p, b) in puppet.bindings(for: node) where p === parameter {
            for i in parameter.axisKeypoints[0].indices {
                for j in parameter.axisKeypoints[1].indices where b.isSet(Keypoint(i, j)) {
                    out.insert(Keypoint(i, j))
                }
            }
        }
        return out
    }
}

/// Values for creating or editing a parameter.
struct ParameterDraft: Identifiable {
    var id = UUID()
    var existing: Parameter?
    var name = ""
    var isVec2: Bool
    var minX: Float = -1, maxX: Float = 1
    var minY: Float = -1, maxY: Float = 1
    var defaultX: Float = 0, defaultY: Float = 0

    init(isVec2: Bool) {
        self.isVec2 = isVec2
        name = isVec2 ? "New 2D Parameter" : "New Parameter"
        if !isVec2 { minX = 0 }
    }

    init(_ p: Parameter) {
        existing = p
        name = p.name
        isVec2 = p.isVec2
        minX = p.min.x
        maxX = p.max.x
        minY = p.min.y
        maxY = p.max.y
        defaultX = p.defaults.x
        defaultY = p.defaults.y
    }
}

private struct ParameterSheet: View {
    @ObservedObject var model: EditorModel
    @State var draft: ParameterDraft
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $draft.name)
                } footer: {
                    Text("Tip: names like “Head:: Yaw-Pitch”, “Eye:: Left:: Blink” or “Mouth:: Open” let Pad2D connect face tracking automatically.")
                }
                Section(draft.isVec2 ? "Horizontal (X)" : "Range") {
                    field("Minimum", $draft.minX)
                    field("Maximum", $draft.maxX)
                    field("Default", $draft.defaultX)
                }
                if draft.isVec2 {
                    Section("Vertical (Y)") {
                        field("Minimum", $draft.minY)
                        field("Maximum", $draft.maxY)
                        field("Default", $draft.defaultY)
                    }
                }
            }
            .navigationTitle(draft.existing == nil ? "New Parameter" : "Edit Parameter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { save() }
                        .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty || draft.minX >= draft.maxX
                                  || (draft.isVec2 && draft.minY >= draft.maxY))
                }
            }
        }
    }

    private func field(_ title: String, _ value: Binding<Float>) -> some View {
        LabeledContent(title) {
            TextField(title, value: value, format: .number)
                .keyboardType(.numbersAndPunctuation)
                .multilineTextAlignment(.trailing)
        }
    }

    private func save() {
        guard let puppet = model.puppet else { return }
        let name = draft.name.trimmingCharacters(in: .whitespaces)
        let lo = Vec2(draft.minX, draft.isVec2 ? draft.minY : 0)
        let hi = Vec2(draft.maxX, draft.isVec2 ? draft.maxY : 1)
        let def = Vec2(draft.defaultX, draft.isVec2 ? draft.defaultY : 0)
        if let p = draft.existing {
            puppet.renameParameter(p, to: name)
            puppet.setRange(p, min: lo, max: hi, defaults: def)
        } else {
            let p = puppet.createParameter(name: name, isVec2: draft.isVec2, min: lo, max: hi, defaults: def)
            model.arm(p)
        }
        model.changed()
        dismiss()
    }
}
