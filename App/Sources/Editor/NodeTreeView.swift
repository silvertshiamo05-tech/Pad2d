import SwiftUI
import Inochi2DKit

extension Node {
    var kindIcon: String {
        switch self {
        case is Part: return "photo"
        case is Composite: return "square.3.layers.3d"
        case is MeshGroup: return "square.grid.3x3.topleft.filled"
        case is SimplePhysics: return "wind"
        case is Camera: return "video"
        default: return "folder"
        }
    }

    var kindTitle: String {
        switch self {
        case is Part: return "Part"
        case is Composite: return "Composite"
        case is MeshGroup: return "Mesh Group"
        case is SimplePhysics: return "Simple Physics"
        case is Camera: return "Camera"
        default: return "Node"
        }
    }
}

/// Inochi Creator's Nodes panel: the puppet hierarchy.
struct NodeTreeView: View {
    @ObservedObject var model: EditorModel
    @Binding var addingImage: Bool
    @State private var collapsed = Set<UInt32>()
    @State private var renaming: Node?
    @State private var renameText = ""
    @State private var moving: [Node] = []
    @State private var info: Node?
    @State private var search = ""
    @State private var reversed = false

    private struct Row: Identifiable {
        let node: Node
        let depth: Int
        var id: UInt32 { node.uuid }
    }

    private func rows() -> [Row] {
        guard let root = model.puppet?.root else { return [] }
        var out: [Row] = []
        let q = search.lowercased()
        func matches(_ n: Node) -> Bool {
            q.isEmpty || n.name.lowercased().contains(q) || n.children.contains(where: matches)
        }
        func walk(_ n: Node, _ depth: Int) {
            let kids = reversed ? n.children.reversed() : n.children
            for c in kids where matches(c) {
                out.append(Row(node: c, depth: depth))
                if !collapsed.contains(c.uuid) || !q.isEmpty { walk(c, depth + 1) }
            }
        }
        walk(root, 0)
        return out
    }

    var body: some View {
        let _ = model.revision
        VStack(spacing: 0) {
            HStack {
                TextField("Filter", text: $search)
                    .textFieldStyle(.roundedBorder)
                Button { reversed.toggle() } label: {
                    Image(systemName: reversed ? "arrow.up.arrow.down.circle.fill" : "arrow.up.arrow.down.circle")
                }
                .help("Reverse node order")
                addMenu(under: nil) {
                    Image(systemName: "plus.circle.fill").font(.title2)
                }
            }
            .padding(8)
            ScrollViewReader { proxy in
                List {
                    PuppetRootRow(model: model)
                    ForEach(rows()) { row in
                        NodeRow(model: model, node: row.node, depth: row.depth,
                                isCollapsed: collapsed.contains(row.node.uuid),
                                toggle: {
                                    if collapsed.contains(row.node.uuid) { collapsed.remove(row.node.uuid) }
                                    else { collapsed.insert(row.node.uuid) }
                                })
                            .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
                            .listRowBackground(model.isSelected(row.node) ? Color.accentColor.opacity(0.22) : Color.clear)
                            .contextMenu { menu(for: row.node) }
                            .id(row.node.uuid)
                    }
                }
                .listStyle(.plain)
                .environment(\.defaultMinListRowHeight, 34)
                .onChange(of: model.selectedIDs) { _, ids in
                    guard let id = ids.last, let node = model.puppet?.root.find(uuid: id) else { return }
                    var p = node.parent
                    while let n = p { collapsed.remove(n.uuid); p = n.parent }
                    withAnimation { proxy.scrollTo(id) }
                }
            }
            Divider()
            HStack {
                Text(model.selectedIDs.isEmpty ? "No selection" : "\(model.selectedIDs.count) selected")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(role: .destructive) { model.delete(model.topLevelSelection()) } label: { Image(systemName: "trash") }
                    .disabled(model.selectedIDs.isEmpty)
                    .dropDestination(for: String.self) { items, _ in
                        let nodes = items.compactMap { UInt32($0) }.compactMap { model.puppet?.root.find(uuid: $0) }
                        model.delete(nodes)
                        return true
                    }
            }
            .padding(8)
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") { if let n = renaming { model.rename(n, renameText) } }
            Button("Cancel", role: .cancel) {}
        }
        .alert(info?.name ?? "", isPresented: Binding(get: { info != nil }, set: { if !$0 { info = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            if let n = info {
                Text("ID: \(n.uuid)" + ((n as? Part)?.layerPath.map { "\nLayer path: \($0)" } ?? "") + "\nPath: \(n.nodePath)")
            }
        }
        .sheet(isPresented: Binding(get: { !moving.isEmpty }, set: { if !$0 { moving = [] } })) {
            MoveNodeSheet(model: model, nodes: moving)
        }
    }

    private func addMenu<L: View>(under parent: Node?, @ViewBuilder label: () -> L) -> some View {
        Menu(content: {
            Button { if let p = parent { model.select(p) }; addingImage = true } label: { Label("Part from Image…", systemImage: "photo.badge.plus") }
            Divider()
            ForEach([NodeKind.node, .composite, .physics, .camera, .meshGroup], id: \.self) { kind in
                Button { model.add(kind, under: parent) } label: { Label(kind.title, systemImage: icon(kind)) }
            }
        }, label: label)
    }

    private func icon(_ kind: NodeKind) -> String {
        switch kind {
        case .node: return "folder"
        case .part: return "photo"
        case .composite: return "square.3.layers.3d"
        case .meshGroup: return "square.grid.3x3.topleft.filled"
        case .physics: return "wind"
        case .camera: return "video"
        }
    }

    @ViewBuilder
    private func menu(for node: Node) -> some View {
        let targets = model.isSelected(node) ? model.topLevelSelection() : [node]
        addMenu(under: node) { Label("Add", systemImage: "plus") }
        if !(node is Camera) {
            Button { model.duplicate(node) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
        }
        Button { renameText = node.name; renaming = node } label: { Label("Rename", systemImage: "pencil") }
        if node is Drawable && model.armed == nil {
            Button { model.select(node); model.setMode(.mesh) } label: { Label("Edit Mesh", systemImage: "square.grid.3x3") }
        }
        Button { model.toggleVisible(node) } label: { Label(node.enabled ? "Hide" : "Show", systemImage: node.enabled ? "eye.slash" : "eye") }
        Divider()
        Button { model.reorder(node, by: -1) } label: { Label("Move Up", systemImage: "arrow.up") }
        Button { model.reorder(node, by: 1) } label: { Label("Move Down", systemImage: "arrow.down") }
        if let parent = node.parent, let grand = parent.parent {
            Button { model.move(targets, to: grand) } label: { Label("Move Out of \(parent.name)", systemImage: "arrow.up.left") }
        }
        Button { moving = targets } label: { Label("Move Into…", systemImage: "folder") }
        Button { model.recalculateOrigin(node) } label: { Label("Recalculate Origin", systemImage: "scope") }
        Button { info = node } label: { Label("More Info", systemImage: "info.circle") }
        Divider()
        Button(role: .destructive) { model.delete(targets) } label: { Label("Delete", systemImage: "trash") }
    }
}

private struct PuppetRootRow: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        HStack {
            Image(systemName: "person.crop.square").foregroundStyle(.secondary)
            Text("Puppet").font(.callout.weight(.medium))
            Spacer()
        }
        .frame(minHeight: 30)
        .contentShape(Rectangle())
        .onTapGesture { model.select(nil) }
        .dropDestination(for: String.self) { items, _ in
            guard let root = model.puppet?.root else { return false }
            let nodes = items.compactMap { UInt32($0) }.compactMap { root.find(uuid: $0) }
            model.move(nodes, to: root, at: 0)
            return true
        }
    }
}

private struct NodeRow: View {
    @ObservedObject var model: EditorModel
    let node: Node
    let depth: Int
    let isCollapsed: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: CGFloat(depth) * 14, height: 1)
            if node.children.isEmpty {
                Color.clear.frame(width: 16, height: 1)
            } else {
                Button(action: toggle) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .frame(width: 16)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            Button { model.toggleVisible(node) } label: {
                Image(systemName: node.kindIcon)
                    .font(.caption)
                    .foregroundStyle(node.enabled ? Color.secondary : Color.red.opacity(0.7))
                    .frame(width: 18)
            }
            .buttonStyle(.plain)
            Text(node.name)
                .font(.callout)
                .lineLimit(1)
                .foregroundStyle(node.enabled ? .primary : .secondary)
            Spacer(minLength: 4)
            if let p = model.armed, p.bindings.contains(where: { $0.node === node }) {
                Image(systemName: "record.circle").font(.caption2).foregroundStyle(.red)
            }
        }
        .frame(minHeight: 34)
        .contentShape(Rectangle())
        .onTapGesture {
            if model.isSelected(node) && model.selectedIDs.count == 1 && !model.shift {
                model.focusSelection()
            } else {
                model.select(node, extend: model.shift)
            }
        }
        .draggable(String(node.uuid))
        .dropDestination(for: String.self) { items, _ in
            let ids = items.compactMap { UInt32($0) }
            var nodes = ids.compactMap { model.puppet?.root.find(uuid: $0) }
            // Dragging one of several selected nodes moves the whole selection.
            if let first = nodes.first, model.isSelected(first) { nodes = model.topLevelSelection() }
            model.move(nodes.filter { $0 !== node }, to: node, at: 0)
            return true
        }
    }
}

/// Picks a new parent for nodes.
private struct MoveNodeSheet: View {
    @ObservedObject var model: EditorModel
    let nodes: [Node]
    @Environment(\.dismiss) private var dismiss

    private struct Target {
        let node: Node
        let depth: Int
    }

    var body: some View {
        NavigationStack {
            List {
                if let root = model.puppet?.root {
                    ForEach(targets(root), id: \.node.uuid) { item in
                        Button {
                            model.move(nodes, to: item.node)
                            dismiss()
                        } label: {
                            HStack {
                                Color.clear.frame(width: CGFloat(item.depth) * 14, height: 1)
                                Image(systemName: item.node === root ? "person.crop.square" : item.node.kindIcon)
                                Text(item.node === root ? "Puppet (top level)" : item.node.name)
                            }
                        }
                    }
                }
            }
            .navigationTitle(nodes.count == 1 ? "Move \(nodes[0].name) Into" : "Move \(nodes.count) Nodes Into")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private func targets(_ root: Node) -> [Target] {
        var out: [Target] = []
        func walk(_ n: Node, _ depth: Int) {
            guard nodes.allSatisfy({ model.puppet?.canMove($0, to: n) == true }) else { return }
            out.append(Target(node: n, depth: depth))
            for c in n.children { walk(c, depth + 1) }
        }
        walk(root, 0)
        return out
    }
}
