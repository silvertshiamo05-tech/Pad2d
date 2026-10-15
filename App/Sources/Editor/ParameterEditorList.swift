import SwiftUI
import UniformTypeIdentifiers
import Inochi2DKit

/// Inochi Creator's Parameters panel: groups, arming, keypoint tools.
struct ParameterEditorList: View {
    @ObservedObject var model: EditorModel
    let present: (EditorSheet) -> Void
    @State private var search = ""
    @State private var editing: ParamSheet?
    @State private var collapsedGroups = Set<UInt32>()
    @State private var renamingGroup: ParameterGroup?
    @State private var groupName = ""

    var body: some View {
        let _ = model.revision
        let all = model.puppet?.parameters ?? []
        let q = search.lowercased()
        let match: (Parameter) -> Bool = { q.isEmpty || $0.name.lowercased().contains(q) }
        let armed = all.first { $0.uuid == model.armedID }
        VStack(spacing: 0) {
            HStack {
                TextField("Filter", text: $search)
                    .textFieldStyle(.roundedBorder)
                Menu {
                    ForEach(ParameterPreset.allCases, id: \.self) { p in
                        Button(p.rawValue) { model.addParameter(p) }
                    }
                    Divider()
                    Button("New Group") { model.newGroup(with: []) }
                } label: {
                    Image(systemName: "plus.circle.fill").font(.title2)
                }
            }
            .padding(8)
            if all.isEmpty {
                ContentUnavailableView("No parameters", systemImage: "slider.horizontal.3",
                                       description: Text("Add a parameter (like a head turn or a blink), arm it, then deform parts at its keypoints."))
            }
            List {
                if let armed {
                    ParameterRow(model: model, parameter: armed, edit: { editing = $0 })
                        .listRowBackground(Color.red.opacity(0.08))
                }
                ForEach(model.puppet?.groups ?? [], id: \.uuid) { g in
                    let kids = all.filter { $0.groupUUID == g.uuid && $0 !== armed }
                    if q.isEmpty || g.name.lowercased().contains(q) || kids.contains(where: match) {
                        groupHeader(g, count: kids.count)
                        if !collapsedGroups.contains(g.uuid) {
                            ForEach(kids.filter(match), id: \.uuid) { p in
                                ParameterRow(model: model, parameter: p, edit: { editing = $0 })
                                    .padding(.leading, 10)
                                    .listRowBackground(groupColor(g).opacity(0.25))
                            }
                        }
                    }
                }
                ForEach(all.filter { $0.groupUUID == nil && $0 !== armed && match($0) }, id: \.uuid) { p in
                    ParameterRow(model: model, parameter: p, edit: { editing = $0 })
                        .dropDestination(for: String.self) { items, _ in
                            // Drop a parameter onto another ungrouped one: make a group of both.
                            let dropped = items.compactMap { UInt32($0) }.compactMap { model.puppet?.parameter(uuid: $0) }
                            guard let other = dropped.first, other !== p else { return false }
                            model.newGroup(with: [p, other])
                            return true
                        }
                }
                Color.clear.frame(height: 40)
                    .listRowBackground(Color.clear)
                    .dropDestination(for: String.self) { items, _ in
                        for p in items.compactMap({ UInt32($0) }).compactMap({ model.puppet?.parameter(uuid: $0) }) {
                            model.setGroup(p, nil)
                        }
                        return true
                    }
            }
            .listStyle(.plain)
        }
        .sheet(item: $editing) { s in
            switch s.kind {
            case .properties: ParameterPropertiesSheet(model: model, parameter: s.parameter)
            case .axes: AxesSheet(model: model, parameter: s.parameter)
            case .split: SplitSheet(model: model, parameter: s.parameter)
            }
        }
        .alert("Rename Group", isPresented: Binding(get: { renamingGroup != nil }, set: { if !$0 { renamingGroup = nil } })) {
            TextField("Name", text: $groupName)
            Button("Rename") { renamingGroup?.name = groupName; model.changed("Rename group") }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func groupColor(_ g: ParameterGroup) -> Color {
        g.color.map { Color(red: Double($0.x) * 2, green: Double($0.y) * 2, blue: Double($0.z) * 2) } ?? Color.gray
    }

    private func groupHeader(_ g: ParameterGroup, count: Int) -> some View {
        HStack {
            Image(systemName: collapsedGroups.contains(g.uuid) ? "chevron.right" : "chevron.down").font(.caption)
            Image(systemName: "folder.fill").foregroundStyle(groupColor(g))
            Text(g.name).font(.subheadline.weight(.semibold))
            Text("\(count)").font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if collapsedGroups.contains(g.uuid) { collapsedGroups.remove(g.uuid) } else { collapsedGroups.insert(g.uuid) }
        }
        .contextMenu {
            Button("Rename…") { groupName = g.name; renamingGroup = g }
            Menu("Color") {
                Button("None") { g.color = nil; model.changed("Group colour") }
                ForEach(Self.colors, id: \.0) { name, c in
                    Button(name) { g.color = c; model.changed("Group colour") }
                }
            }
            Button("Delete Group", role: .destructive) { model.deleteGroup(g) }
        }
        .dropDestination(for: String.self) { items, _ in
            for p in items.compactMap({ UInt32($0) }).compactMap({ model.puppet?.parameter(uuid: $0) }) {
                model.setGroup(p, g)
            }
            return true
        }
    }

    static let colors: [(String, Vec3)] = [
        ("Red", Vec3(0.25, 0.15, 0.15)), ("Green", Vec3(0.15, 0.25, 0.15)), ("Blue", Vec3(0.15, 0.15, 0.25)),
        ("Purple", Vec3(0.25, 0.15, 0.25)), ("Cyan", Vec3(0.15, 0.25, 0.25)), ("Yellow", Vec3(0.25, 0.25, 0.15)),
        ("White", Vec3(0.25, 0.25, 0.25)),
    ]
}

/// Which parameter sheet to show.
struct ParamSheet: Identifiable {
    enum Kind { case properties, axes, split }
    let id = UUID()
    let kind: Kind
    let parameter: Parameter
}

private struct ParameterRow: View {
    @ObservedObject var model: EditorModel
    let parameter: Parameter
    let edit: (ParamSheet) -> Void

    var body: some View {
        let armed = model.armedID == parameter.uuid
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if model.mode == .animation {
                    Button { model.addKeyframe(parameter) } label: {
                        Image(systemName: "diamond.fill").foregroundStyle(.orange)
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.currentAnim == nil)
                } else {
                    Button { model.arm(armed ? nil : parameter) } label: {
                        Image(systemName: armed ? "record.circle.fill" : "record.circle")
                            .font(.title3)
                            .foregroundStyle(armed ? Color.red : Color.secondary)
                    }
                    .buttonStyle(.borderless)
                }
                Text(parameter.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                    .draggable(String(parameter.uuid))
                Spacer()
                Text(parameter.isVec2
                     ? String(format: "%.2f %.2f", parameter.value.x, parameter.value.y)
                     : String(format: "%.2f", parameter.value.x))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Menu { menuItems } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless)
            }
            KeypointPad(model: model, parameter: parameter, armed: armed)
                .frame(height: parameter.isVec2 ? 150 : 40)
                .contextMenu {
                    if armed { KeypointActionItems(model: model, parameter: parameter, bindings: nil) }
                }
            if armed {
                BindingList(model: model, parameter: parameter)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var menuItems: some View {
        let p = parameter
        Button { edit(ParamSheet(kind: .properties, parameter: p)) } label: { Label("Edit Properties…", systemImage: "pencil") }
        Button { edit(ParamSheet(kind: .axes, parameter: p)) } label: { Label("Edit Axes Points…", systemImage: "ruler") }
        Button { edit(ParamSheet(kind: .split, parameter: p)) } label: { Label("Split…", systemImage: "scissors") }
        if !p.isVec2 {
            Button { model.convertTo2D(p) } label: { Label("To 2D", systemImage: "square.grid.2x2") }
        }
        if p.isVec2 {
            Button { model.flipAxis(p, axis: 0) } label: { Label("Flip X", systemImage: "arrow.left.and.right") }
            Button { model.flipAxis(p, axis: 1) } label: { Label("Flip Y", systemImage: "arrow.up.and.down") }
        } else {
            Button { model.flipAxis(p, axis: 0) } label: { Label("Flip", systemImage: "arrow.left.and.right") }
        }
        Menu {
            Button("Horizontally") { model.mirrorAll(p, axis: 0) }
            Button("Vertically") { model.mirrorAll(p, axis: 1) }
        } label: { Label("Mirror", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
        Menu {
            Button("Fill Left from Right") { model.mirroredAutofill(p, axis: 0, upperHalf: false) }
            Button("Fill Right from Left") { model.mirroredAutofill(p, axis: 0, upperHalf: true) }
            if p.isVec2 {
                Button("Fill Top from Bottom") { model.mirroredAutofill(p, axis: 1, upperHalf: true) }
                Button("Fill Bottom from Top") { model.mirroredAutofill(p, axis: 1, upperHalf: false) }
            }
        } label: { Label("Mirrored Autofill", systemImage: "wand.and.rays") }
        Divider()
        Button { model.copyParameter(p) } label: { Label("Copy", systemImage: "doc.on.doc") }
        Button { model.pasteParameter(into: p, flip: false) } label: { Label("Paste", systemImage: "doc.on.clipboard") }
            .disabled(EditorModel.clipboard.parameter == nil)
        Button { model.pasteParameter(into: p, flip: true) } label: { Label("Paste and Horizontal Flip", systemImage: "arrow.left.and.right.square") }
            .disabled(EditorModel.clipboard.parameter == nil)
        Button { model.duplicateParameter(p) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
        Divider()
        Button { model.setStartingPosition(p) } label: { Label("Set Starting Position", systemImage: "flag") }
        Button { model.setValue(p, p.defaults) } label: { Label("Reset Value", systemImage: "arrow.uturn.backward") }
        Menu {
            Picker("Merge Mode", selection: Binding(get: { p.mergeMode }, set: { model.setMergeMode(p, $0) })) {
                ForEach(ParamMergeMode.allCases, id: \.self) { Text($0.name).tag($0) }
            }
        } label: { Label("Merge Mode", systemImage: "arrow.triangle.merge") }
        Menu {
            Button("No Group") { model.setGroup(p, nil) }
            ForEach(model.puppet?.groups ?? [], id: \.uuid) { g in Button(g.name) { model.setGroup(p, g) } }
        } label: { Label("Move to Group", systemImage: "folder") }
        Divider()
        Button(role: .destructive) { model.deleteParameter(p) } label: { Label("Delete", systemImage: "trash") }
    }
}

/// Keypoint actions at the keypoint nearest the parameter's value.
struct KeypointActionItems: View {
    @ObservedObject var model: EditorModel
    let parameter: Parameter
    let bindings: [ParameterBinding]?

    var body: some View {
        let p = parameter
        Button("Unset") { model.keypointAction(p, bindings, .unset) }
        Button("Set to Current") { model.keypointAction(p, bindings, .setCurrent) }
        Button("Reset") { model.keypointAction(p, bindings, .reset) }
        Button("Invert") { model.keypointAction(p, bindings, .invert) }
        Menu("Mirror") {
            Button("Horizontally") { model.keypointAction(p, bindings, .mirror(0)) }
            Button("Vertically") { model.keypointAction(p, bindings, .mirror(1)) }
        }
        Button("Flip Deform") { model.keypointAction(p, bindings, .flipDeform) }
        if p.isVec2 {
            Menu("Set from Mirror") {
                Button("Horizontally") { model.keypointAction(p, bindings, .setFromMirror(0)) }
                Button("Vertically") { model.keypointAction(p, bindings, .setFromMirror(1)) }
                Button("Diagonally") { model.keypointAction(p, bindings, .setFromMirror(-1)) }
            }
        } else {
            Button("Set from Mirror") { model.keypointAction(p, bindings, .setFromMirror(0)) }
        }
        Button("Copy") { model.keypointAction(p, bindings, .copy) }
        Button("Paste") { model.keypointAction(p, bindings, .paste) }
            .disabled(EditorModel.clipboard.keypoint == nil)
    }
}

/// Bindings of the armed parameter (Creator's binding list).
private struct BindingList: View {
    @ObservedObject var model: EditorModel
    let parameter: Parameter
    @State private var selectedOnly = false
    @State private var picked = Set<ObjectIdentifier>()

    var body: some View {
        let k = parameter.nearestKeypoint
        let byNode = Dictionary(grouping: parameter.bindings.filter { $0.node != nil }, by: { $0.node!.uuid })
        let nodes = byNode.keys.compactMap { model.puppet?.root.find(uuid: $0) }
            .filter { !selectedOnly || model.isSelected($0) }
            .sorted { $0.name < $1.name }
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Bindings").font(.caption.weight(.semibold))
                Spacer()
                Toggle(isOn: $selectedOnly) { Image(systemName: "line.3.horizontal.decrease.circle") }
                    .toggleStyle(.button).controlSize(.mini)
            }
            ForEach(nodes, id: \.uuid) { node in
                let list = byNode[node.uuid] ?? []
                let anySet = list.contains { $0.isSet(k) }
                HStack {
                    Image(systemName: node.kindIcon).font(.caption2)
                    Text(node.name).font(.caption.weight(.medium)).foregroundStyle(anySet ? .primary : .secondary)
                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture { model.select(node, extend: model.shift) }
                .contextMenu { bindingMenu(list) }
                ForEach(Array(list.enumerated()), id: \.offset) { _, b in
                    HStack {
                        Text(bindingTitle(b.target) + (b.floatValue(k).map { String(format: " (%.2f)", $0) } ?? ""))
                            .font(.caption2)
                            .foregroundStyle(b.isSet(k) ? .primary : .secondary)
                        Spacer()
                        if picked.contains(ObjectIdentifier(b)) { Image(systemName: "checkmark").font(.caption2) }
                    }
                    .padding(.leading, 18)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        let id = ObjectIdentifier(b)
                        if model.shift { if picked.contains(id) { picked.remove(id) } else { picked.insert(id) } } else { picked = [id] }
                    }
                    .contextMenu { bindingMenu(picked.contains(ObjectIdentifier(b)) ? selection(list) : [b]) }
                }
            }
        }
        .padding(6)
        .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
    }

    private func selection(_ fallback: [ParameterBinding]) -> [ParameterBinding] {
        let s = parameter.bindings.filter { picked.contains(ObjectIdentifier($0)) }
        return s.isEmpty ? fallback : s
    }

    @ViewBuilder
    private func bindingMenu(_ list: [ParameterBinding]) -> some View {
        Button(role: .destructive) { model.removeBindings(parameter, list) } label: { Label("Remove", systemImage: "trash") }
        Menu("Keypoint") { KeypointActionItems(model: model, parameter: parameter, bindings: list) }
        Menu("Interpolation Mode") {
            Button("Nearest") { model.setInterpolation(list, .nearest) }
            Button("Linear") { model.setInterpolation(list, .linear) }
            Button("Cubic") { model.setInterpolation(list, .cubic) }
        }
        let compatible = model.compatibleNodes(parameter, list)
        Menu("Copy To") {
            ForEach(compatible, id: \.uuid) { n in Button(n.name) { model.copyBindings(parameter, list, to: n, swap: false) } }
        }
        .disabled(compatible.isEmpty)
        Menu("Swap With") {
            ForEach(compatible, id: \.uuid) { n in Button(n.name) { model.copyBindings(parameter, list, to: n, swap: true) } }
        }
        .disabled(compatible.isEmpty)
    }
}

/// Value control with the keypoint grid (Creator's controller widget).
/// Keypoints are green when every binding is set there, yellow when some are.
/// While armed (or with Shift), the value snaps to keypoints.
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
        let color: Color
    }

    private func dots(_ size: CGSize) -> [Dot] {
        let bs = parameter.allBindings
        var out: [Dot] = []
        for i in xs.indices {
            for j in ys.indices {
                let k = Keypoint(i, parameter.isVec2 ? j : 0)
                let set = bs.filter { $0.isSet(k) }.count
                let c: Color = bs.isEmpty || set == 0 ? Color.secondary.opacity(0.5)
                    : (set == bs.count || !parameter.isVec2 ? Color.green : Color.yellow)
                out.append(Dot(id: i * 1000 + j, point: pos(CGFloat(xs[i]), CGFloat(ys[j]), size), color: c))
            }
        }
        return out
    }

    private func point(_ v: Vec2, _ size: CGSize) -> CGPoint {
        let n = parameter.mapValue(v)
        let nx = n.x.isFinite ? CGFloat(n.x) : 0.5
        let ny: CGFloat = parameter.isVec2 ? (n.y.isFinite ? CGFloat(n.y) : 0.5) : 0.5
        return pos(nx, ny, size)
    }

    private func drag(_ location: CGPoint, _ size: CGSize) {
        let x = Float(max(0, min(1, (location.x - inset) / (size.width - 2 * inset))))
        let y = Float(max(0, min(1, 1 - (location.y - inset) / (size.height - 2 * inset))))
        var v = parameter.unmapValue(Vec2(x, parameter.isVec2 ? y : 0))
        if armed || model.shift { v = parameter.value(at: parameter.nearestKeypoint(to: v)) }
        model.setValue(parameter, v)
    }

    var body: some View {
        GeometryReader { geo in
            pad(geo.size)
        }
    }

    private func pad(_ size: CGSize) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(.quaternary)
            grid(size).stroke(style: StrokeStyle(lineWidth: 1, dash: [3, 3])).foregroundStyle(Color.secondary.opacity(0.5))
            ForEach(dots(size)) { d in
                ZStack {
                    Circle().fill(Color.gray).frame(width: 12, height: 12)
                    Circle().fill(d.color).frame(width: 8, height: 8)
                }
                .position(d.point)
            }
            Circle().fill(Color(red: 0.5, green: 0, blue: 0)).frame(width: 10, height: 10)
                .position(point(parameter.lastInternal, size))
            Circle()
                .strokeBorder(Color.white, lineWidth: 2)
                .background(Circle().fill(armed ? Color.red : Color.accentColor))
                .frame(width: 18, height: 18)
                .position(point(parameter.value, size))
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { g in drag(g.location, size) })
    }
}

// MARK: - Sheets

private struct ParameterPropertiesSheet: View {
    @ObservedObject var model: EditorModel
    let parameter: Parameter
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var minX: Float = 0
    @State private var maxX: Float = 1
    @State private var minY: Float = 0
    @State private var maxY: Float = 1
    @State private var error: String?

    init(model: EditorModel, parameter: Parameter) {
        self.model = model
        self.parameter = parameter
    }

    var body: some View {
        NavigationStack {
            Form {
                Section { TextField("Name", text: $name) } footer: {
                    Text("Names like “Head:: Yaw-Pitch”, “Eye:: Left:: Blink” or “Mouth:: Open” let face tracking connect automatically.")
                }
                Section(parameter.isVec2 ? "X" : "Range") {
                    field("Minimum", $minX)
                    field("Maximum", $maxX)
                }
                if parameter.isVec2 {
                    Section("Y") {
                        field("Minimum", $minY)
                        field("Maximum", $maxY)
                    }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("Parameter Properties")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(minX >= maxX || (parameter.isVec2 && minY >= maxY))
                }
            }
            .onAppear {
                name = parameter.name
                minX = parameter.min.x; maxX = parameter.max.x
                minY = parameter.min.y; maxY = parameter.max.y
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
        if let e = model.rename(parameter, to: name) {
            error = e
            return
        }
        let lo = Vec2(minX, parameter.isVec2 ? minY : 0), hi = Vec2(maxX, parameter.isVec2 ? maxY : 1)
        model.puppet?.setRange(parameter, min: lo, max: hi, defaults: parameter.defaults)
        model.changed("Parameter properties")
        dismiss()
    }
}

/// Creator's "Edit Axes Points": interior keypoint positions in parameter units.
private struct AxesSheet: View {
    @ObservedObject var model: EditorModel
    let parameter: Parameter
    @Environment(\.dismiss) private var dismiss
    @State private var axes: [[AxisPoint]] = [[], []]
    @State private var error: String?

    struct AxisPoint: Identifiable {
        let id = UUID()
        var value: Float
        var original: Int?
    }

    var body: some View {
        NavigationStack {
            Form {
                ForEach(parameter.isVec2 ? [0, 1] : [0], id: \.self) { axis in
                    Section(parameter.isVec2 ? (axis == 0 ? "X" : "Y") : "Breakpoints") {
                        let lo = axis == 0 ? parameter.min.x : parameter.min.y
                        let hi = axis == 0 ? parameter.max.x : parameter.max.y
                        LabeledContent("Start", value: String(format: "%.2f", lo))
                        ForEach($axes[axis]) { $pt in
                            HStack {
                                Slider(value: $pt.value, in: (lo + 0.01)...(hi - 0.01))
                                Text(String(format: "%.2f", pt.value)).monospacedDigit().frame(width: 56)
                                Button(role: .destructive) { axes[axis].removeAll { $0.id == pt.id } } label: {
                                    Image(systemName: "minus.circle.fill")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        LabeledContent("End", value: String(format: "%.2f", hi))
                        Button { axes[axis].append(AxisPoint(value: (lo + hi) / 2, original: nil)) } label: {
                            Label("Add Point", systemImage: "plus.circle")
                        }
                    }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("Parameter Axes Points")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() } }
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        for axis in 0..<2 {
            let pts = parameter.axisKeypoints[axis]
            guard pts.count > 2 else { axes[axis] = []; continue }
            axes[axis] = (1..<(pts.count - 1)).map { i in
                let v = axis == 0 ? parameter.unmapValue(Vec2(pts[i], 0)).x : parameter.unmapValue(Vec2(0, pts[i])).y
                return AxisPoint(value: v, original: i)
            }
        }
    }

    private func save() {
        for axis in 0..<(parameter.isVec2 ? 2 : 1) {
            let norms = axes[axis].map { pt in axis == 0 ? parameter.mapValue(Vec2(pt.value, 0)).x : parameter.mapValue(Vec2(0, pt.value)).y }
            if Set(norms.map { Int($0 * 10000) }).count != norms.count {
                error = "One or more axes points are overlapping, this is not allowed."
                return
            }
        }
        for axis in 0..<(parameter.isVec2 ? 2 : 1) {
            let pts = axes[axis].map { pt -> (position: Float, original: Int?) in
                let n = axis == 0 ? parameter.mapValue(Vec2(pt.value, 0)).x : parameter.mapValue(Vec2(0, pt.value)).y
                return (n, pt.original)
            }
            model.applyAxes(parameter, axis: axis, points: pts)
        }
        dismiss()
    }
}

/// Creator's "Split Parameter": move some nodes' bindings to a new parameter.
private struct SplitSheet: View {
    @ObservedObject var model: EditorModel
    let parameter: Parameter
    @Environment(\.dismiss) private var dismiss
    @State private var take = Set<UInt32>()

    var body: some View {
        let nodes = Array(Set(parameter.allBindings.compactMap { $0.node?.uuid })).compactMap { model.puppet?.root.find(uuid: $0) }
            .sorted { $0.name < $1.name }
        NavigationStack {
            List {
                Section {
                    ForEach(nodes, id: \.uuid) { n in
                        Button {
                            if take.contains(n.uuid) { take.remove(n.uuid) } else { take.insert(n.uuid) }
                        } label: {
                            HStack {
                                Image(systemName: n.kindIcon)
                                Text(n.name)
                                Spacer()
                                Text(take.contains(n.uuid) ? "New" : "Keep").foregroundStyle(take.contains(n.uuid) ? Color.blue : Color.secondary)
                            }
                        }
                    }
                } footer: {
                    Text("Nodes marked New move to “\(parameter.name) (Split)”.")
                }
            }
            .navigationTitle("Split Parameter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        model.split(parameter, moving: nodes.filter { take.contains($0.uuid) })
                        dismiss()
                    }
                    .disabled(take.isEmpty)
                }
            }
        }
    }
}
