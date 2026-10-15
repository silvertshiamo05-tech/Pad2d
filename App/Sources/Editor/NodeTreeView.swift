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
        case is SimplePhysics: return "Physics"
        case is Camera: return "Camera"
        default: return "Group"
        }
    }
}

/// The puppet's node hierarchy.
struct NodeTreeView: View {
    @ObservedObject var model: EditorModel
    @Binding var addingImage: Bool
    @State private var collapsed = Set<UInt32>()
    @State private var renaming: Node?
    @State private var renameText = ""
    @State private var moving: Node?
    @State private var search = ""

    private struct Row: Identifiable {
        let node: Node
        let depth: Int
        var id: UInt32 { node.uuid }
    }

    private func rows() -> [Row] {
        guard let root = model.puppet?.root else { return [] }
        var out: [Row] = []
        if !search.isEmpty {
            return root.allNodes().dropFirst()
                .filter { $0.name.localizedCaseInsensitiveContains(search) }
                .map { Row(node: $0, depth: 0) }
        }
        func walk(_ n: Node, _ depth: Int) {
            for c in n.children {
                out.append(Row(node: c, depth: depth))
                if !collapsed.contains(c.uuid) { walk(c, depth + 1) }
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
                Menu {
                    Button { addingImage = true } label: { Label("Part from Image…", systemImage: "photo.badge.plus") }
                    Divider()
                    ForEach([NodeKind.node, .composite, .meshGroup, .physics], id: \.self) { kind in
                        Button { model.add(kind) } label: { Label(kind.title, systemImage: icon(kind)) }
                    }
                } label: {
                    Image(systemName: "plus.circle.fill").font(.title2)
                }
            }
            .padding(8)
            ScrollViewReader { proxy in
                List {
                    ForEach(rows()) { row in
                        NodeRow(model: model, node: row.node, depth: row.depth,
                                isCollapsed: collapsed.contains(row.node.uuid),
                                toggle: {
                                    if collapsed.contains(row.node.uuid) { collapsed.remove(row.node.uuid) }
                                    else { collapsed.insert(row.node.uuid) }
                                })
                            .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
                            .listRowBackground(model.selectedID == row.node.uuid ? Color.accentColor.opacity(0.22) : Color.clear)
                            .contextMenu { menu(for: row.node) }
                            .id(row.node.uuid)
                    }
                }
                .listStyle(.plain)
                .environment(\.defaultMinListRowHeight, 34)
                .onChange(of: model.selectedID) { _, id in
                    guard let id, let node = model.puppet?.root.find(uuid: id) else { return }
                    // Reveal the selection.
                    var p = node.parent
                    while let n = p { collapsed.remove(n.uuid); p = n.parent }
                    withAnimation { proxy.scrollTo(id) }
                }
            }
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") { if let n = renaming { model.rename(n, renameText) } }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(item: Binding(get: { moving.map(NodeBox.init) }, set: { moving = $0?.node })) { box in
            MoveNodeSheet(model: model, node: box.node)
        }
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
        Button { renameText = node.name; renaming = node } label: { Label("Rename", systemImage: "pencil") }
        Button { model.duplicate(node) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
        Divider()
        Button { model.reorder(node, by: -1) } label: { Label("Move Up", systemImage: "arrow.up") }
        Button { model.reorder(node, by: 1) } label: { Label("Move Down", systemImage: "arrow.down") }
        if let parent = node.parent, let grand = parent.parent {
            Button { model.move(node, to: grand) } label: { Label("Move Out of \(parent.name)", systemImage: "arrow.up.left") }
        }
        Button { moving = node } label: { Label("Move Into…", systemImage: "folder") }
        Divider()
        Menu {
            ForEach([NodeKind.node, .composite, .meshGroup, .physics], id: \.self) { kind in
                Button(kind.title) { model.add(kind, under: node) }
            }
        } label: {
            Label("Add Child", systemImage: "plus")
        }
        Divider()
        Button(role: .destructive) { model.delete(node) } label: { Label("Delete", systemImage: "trash") }
    }
}

private struct NodeBox: Identifiable {
    let node: Node
    var id: UInt32 { node.uuid }
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
            Image(systemName: node.kindIcon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(node.name)
                .font(.callout)
                .lineLimit(1)
                .foregroundStyle(node.enabled ? .primary : .secondary)
            Spacer(minLength: 4)
            if model.armed != nil, let puppet = model.puppet, let p = model.armed,
               puppet.bindings(for: node).contains(where: { $0.0 === p }) {
                Image(systemName: "record.circle").font(.caption2).foregroundStyle(.red)
            }
            Button {
                node.enabled.toggle()
                model.changed()
            } label: {
                Image(systemName: node.enabled ? "eye" : "eye.slash")
                    .font(.caption)
                    .foregroundStyle(node.enabled ? .secondary : .tertiary)
            }
            .buttonStyle(.plain)
        }
        .frame(minHeight: 34)
        .contentShape(Rectangle())
        .onTapGesture { model.select(node) }
    }
}

/// Picks a new parent for a node.
private struct MoveNodeSheet: View {
    @ObservedObject var model: EditorModel
    let node: Node
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let root = model.puppet?.root {
                    ForEach(targets(root), id: \.node.uuid) { item in
                        let target = item.node, depth = item.depth
                        Button {
                            model.move(node, to: target)
                            dismiss()
                        } label: {
                            HStack {
                                Color.clear.frame(width: CGFloat(depth) * 14, height: 1)
                                Image(systemName: target === root ? "person.crop.square" : target.kindIcon)
                                Text(target === root ? "Puppet (top level)" : target.name)
                                if target === node.parent {
                                    Spacer()
                                    Text("Current").foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Move \(node.name) Into")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private struct Target {
        let node: Node
        let depth: Int
    }

    private func targets(_ root: Node) -> [Target] {
        var out: [Target] = []
        func walk(_ n: Node, _ depth: Int) {
            guard model.puppet?.canMove(node, to: n) == true else { return }
            out.append(Target(node: n, depth: depth))
            for c in n.children { walk(c, depth + 1) }
        }
        walk(root, 0)
        return out
    }
}
