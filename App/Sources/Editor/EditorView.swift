import SwiftUI
import UniformTypeIdentifiers
import Inochi2DKit

/// The puppet editor: node tree and parameters on the left, the canvas in
/// the middle, the inspector on the right.
struct EditorView: View {
    @StateObject private var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var showSidebar = true
    @State private var showInspector = true
    @State private var sidebarTab = SidebarTab.nodes
    @State private var exportDocument: PuppetFileDocument?
    @State private var exporting = false
    @State private var exportType = UTType.inochiCreatorProject
    @State private var addingImage = false
    @State private var playURL: URL?
    @State private var confirmLeave = false
    private let newPuppet: Puppet?

    enum SidebarTab: String, CaseIterable, Identifiable {
        case nodes, parameters
        var id: String { rawValue }
        var title: String { self == .nodes ? "Nodes" : "Parameters" }
    }

    init(url: URL, newPuppet: Puppet? = nil) {
        _model = StateObject(wrappedValue: EditorModel(url: url))
        self.newPuppet = newPuppet
    }

    var body: some View {
        HStack(spacing: 0) {
            if showSidebar && model.state == .ready {
                VStack(spacing: 0) {
                    Picker("Panel", selection: $sidebarTab) {
                        ForEach(SidebarTab.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(8)
                    Divider()
                    switch sidebarTab {
                    case .nodes: NodeTreeView(model: model, addingImage: $addingImage)
                    case .parameters: ParameterEditorList(model: model)
                    }
                }
                .frame(width: 280)
                .background(Color(.secondarySystemBackground))
                Divider()
            }
            ZStack {
                EditorCanvas(model: model)
                    .ignoresSafeArea(edges: .bottom)
                canvasOverlay
            }
            if showInspector && model.state == .ready {
                Divider()
                InspectorView(model: model)
                    .frame(width: 310)
            }
        }
        .navigationTitle(model.name + (model.dirty ? " •" : ""))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar { toolbar }
        .task {
            if let newPuppet { model.loadNew(newPuppet) } else { await model.load() }
        }
        .alert(model.message ?? "", isPresented: Binding(get: { model.message != nil },
                                                         set: { if !$0 { model.message = nil } })) {
            Button("OK", role: .cancel) {}
        }
        .confirmationDialog("Save changes to \(model.name)?", isPresented: $confirmLeave, titleVisibility: .visible) {
            Button("Save") { Task { if await model.save() { dismiss() } } }
            Button("Discard Changes", role: .destructive) { dismiss() }
            Button("Cancel", role: .cancel) {}
        }
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: exportType,
                      defaultFilename: model.name) { result in
            if case let .failure(error) = result { model.message = error.localizedDescription }
        }
        .fileImporter(isPresented: $addingImage, allowedContentTypes: [.png, .image], allowsMultipleSelection: true) { result in
            guard case let .success(urls) = result else { return }
            for url in urls { addImage(url) }
        }
        .navigationDestination(item: $playURL) { url in
            StageView(url: url, canEdit: false)
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarLeading) {
            Button {
                if model.dirty { confirmLeave = true } else { dismiss() }
            } label: {
                Label("Library", systemImage: "chevron.backward")
            }
            Button { withAnimation { showSidebar.toggle() } } label: { Image(systemName: "sidebar.left") }
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!model.canUndo)
                .keyboardShortcut("z", modifiers: .command)
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!model.canRedo)
                .keyboardShortcut("z", modifiers: [.command, .shift])
        }
        ToolbarItem(placement: .principal) {
            Picker("Mode", selection: Binding(get: { model.mode }, set: { model.setMode($0) })) {
                ForEach(EditorModel.Mode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 180)
            .disabled(model.state != .ready)
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if model.saving { ProgressView() }
            Button { Task { _ = await model.save() } } label: { Image(systemName: "square.and.arrow.down") }
                .disabled(model.state != .ready)
                .keyboardShortcut("s", modifiers: .command)
            Menu {
                Button { export(.inochiCreatorProject) } label: { Label("Export Inochi Creator Project (.inx)", systemImage: "doc") }
                Button { export(.inochiPuppet) } label: { Label("Export Puppet for Inochi Session (.inp)", systemImage: "person.crop.square") }
                Divider()
                Picker("Background", selection: $model.background) {
                    ForEach(BackgroundStyle.allCases) { Text($0.title).tag($0) }
                }
                Button { model.resetView() } label: { Label("Reset View", systemImage: "viewfinder") }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .disabled(model.state != .ready)
            Button {
                Task { if await model.save() { playURL = model.url } }
            } label: {
                Label("Play", systemImage: "play.fill")
            }
            .disabled(model.state != .ready)
            Button { withAnimation { showInspector.toggle() } } label: { Image(systemName: "sidebar.right") }
        }
    }

    private func export(_ type: UTType) {
        guard let data = model.exportData() else { return }
        exportType = type
        exportDocument = PuppetFileDocument(data: data)
        exporting = true
    }

    private func addImage(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), var (px, w, h) = TextureLoader.decodeImage(data) else {
            model.message = "Couldn't read \(url.lastPathComponent)."
            return
        }
        TGADecoder.premultiply(&px)
        let limit = 4096
        if max(w, h) > limit {
            let s = Float(limit) / Float(max(w, h))
            let nw = max(1, Int(Float(w) * s)), nh = max(1, Int(Float(h) * s))
            px = TextureLoader.resize(px, w, h, nw, nh)
            w = nw
            h = nh
        }
        model.addImagePart(rgba: px, width: w, height: h, name: url.deletingPathExtension().lastPathComponent)
    }

    // MARK: Canvas overlay

    @ViewBuilder
    private var canvasOverlay: some View {
        switch model.state {
        case .loading:
            ProgressView("Loading model…")
                .padding(20)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        case let .failed(message):
            ContentUnavailableView("Couldn't open this model", systemImage: "exclamationmark.triangle",
                                   description: Text(message))
        case .ready:
            VStack {
                StatusBanner(model: model)
                Spacer()
                if model.mode == .mesh {
                    MeshToolbar(model: model)
                } else {
                    ToolBar(model: model)
                }
            }
            .padding(12)
        }
    }
}

/// What the canvas is doing right now (recording, mesh editing).
private struct StatusBanner: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        let _ = model.revision
        if model.mode == .mesh, let d = model.meshTargetNode {
            chip("Editing mesh of \(d.name) — \(model.meshVertices.count) vertices", icon: "square.grid.3x3", color: .accentColor)
        } else if let p = model.armed {
            if let k = model.armedKeypoint {
                let v = p.value(at: k)
                chip("Recording \(p.name) at " + (p.isVec2 ? String(format: "%.2f, %.2f", v.x, v.y) : String(format: "%.2f", v.x)),
                     icon: "record.circle", color: .red)
            } else {
                chip("Move \(p.name) onto a keypoint to record", icon: "exclamationmark.circle", color: .orange)
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

/// Tools for Model mode.
private struct ToolBar: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        HStack(spacing: 14) {
            Picker("Tool", selection: $model.tool) {
                ForEach(EditorModel.Tool.allCases) { t in
                    Label(t.title, systemImage: t.icon).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 300)
            if model.tool == .brush {
                if model.armed == nil {
                    Text("Arm a parameter to deform").font(.caption).foregroundStyle(.secondary)
                } else {
                    labeled("Size") {
                        Slider(value: $model.brushRadius, in: 10...400).frame(width: 110)
                    }
                    labeled("Strength") {
                        Slider(value: $model.brushStrength, in: 0.05...1).frame(width: 90)
                    }
                }
            }
            Divider().frame(height: 24)
            Toggle(isOn: $model.showWireframe) { Image(systemName: "square.grid.3x3") }
                .toggleStyle(.button)
            Toggle(isOn: $model.physicsPreview) { Image(systemName: "wind") }
                .toggleStyle(.button)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

/// Tools for Mesh mode.
private struct MeshToolbar: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        let _ = model.revision
        HStack(spacing: 12) {
            Picker("Mesh tool", selection: $model.meshTool) {
                ForEach(EditorModel.MeshTool.allCases) { t in Label(t.title, systemImage: t.icon).tag(t) }
            }
            .pickerStyle(.segmented)
            .frame(width: 200)
            Divider().frame(height: 24)
            labeled("Spacing \(Int(model.meshSpacing))") {
                Slider(value: $model.meshSpacing, in: 12...300).frame(width: 110)
            }
            Button("Auto Mesh") { model.autoMesh() }
            Menu {
                Button("Simple Quad") { model.quadMesh() }
                Button("Revert Changes") { model.revertMesh() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            Divider().frame(height: 24)
            Button("Cancel", role: .cancel) { model.exitMeshMode(apply: false) }
            Button("Apply") { model.exitMeshMode(apply: true) }
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

private func labeled<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 0) {
        Text(title).font(.caption2).foregroundStyle(.secondary)
        content()
    }
}

/// An `.inx`/`.inp` file for the Files exporter.
struct PuppetFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.inochiCreatorProject, .inochiPuppet] }
    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
