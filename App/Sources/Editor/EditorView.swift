import SwiftUI
import UniformTypeIdentifiers
import Inochi2DKit

/// Sheets the editor can show.
enum EditorSheet: Identifiable {
    case history, settings, autoMesh, flipPairs, testBinding
    case editAnimation(String?)
    case exportPuppet, exportImage, exportVideo
    case textures, mergePSD(URL)

    var id: String {
        switch self {
        case .history: return "history"
        case .settings: return "settings"
        case .autoMesh: return "automesh"
        case .flipPairs: return "flip"
        case .testBinding: return "testbinding"
        case .editAnimation(let n): return "anim-\(n ?? "")"
        case .exportPuppet: return "export-inp"
        case .exportImage: return "export-image"
        case .exportVideo: return "export-video"
        case .textures: return "textures"
        case .mergePSD(let u): return "merge-\(u.path)"
        }
    }
}

/// The puppet editor (Inochi Creator's main window): panels on the left,
/// the canvas in the middle, the inspector or mode panel on the right.
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
    @State private var mergingPSD = false
    @State private var playURL: URL?
    @State private var confirmLeave = false
    @State private var sheet: EditorSheet?
    @State private var askRecovery = false
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
        decorated
            .fileExporter(isPresented: $exporting, document: exportDocument, contentType: exportType,
                          defaultFilename: model.name) { result in
                if case let .failure(error) = result { model.message = error.localizedDescription }
            }
            .background {
                Color.clear.fileImporter(isPresented: $addingImage, allowedContentTypes: [.png, .jpeg, .image],
                                         allowsMultipleSelection: true) { result in
                    guard case let .success(urls) = result else { return }
                    for url in urls { addImage(url) }
                }
            }
            .background {
                Color.clear.fileImporter(isPresented: $mergingPSD, allowedContentTypes: [.photoshop, .photoshopLarge, .data]) { result in
                    if case let .success(url) = result { sheet = .mergePSD(url) }
                }
            }
            .navigationDestination(item: $playURL) { url in
                StageView(url: url, canEdit: false)
            }
    }

    private var messageShown: Binding<Bool> {
        Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })
    }

    private var pickShown: Binding<Bool> {
        Binding(get: { !model.pickList.isEmpty }, set: { if !$0 { model.pickList = [] } })
    }

    private var decorated: some View {
        layout
            .navigationTitle(model.name + (model.dirty ? " •" : ""))
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(true)
            .toolbar { toolbar }
            .task { await start() }
            .alert(model.message ?? "", isPresented: messageShown) {
                Button("OK", role: .cancel) {}
            }
            .confirmationDialog("Save changes to \(model.name)?", isPresented: $confirmLeave, titleVisibility: .visible) {
                leaveButtons
            }
            .confirmationDialog("Parts here", isPresented: pickShown, titleVisibility: .visible) {
                pickButtons
            }
            .alert("Restore from backup?", isPresented: $askRecovery) {
                Button("Restore") { Task { await restoreBackup() } }
                Button("Discard", role: .destructive) { Autosave.releaseLock(model.saveURL) }
            } message: {
                Text("Pad2D closed unexpectedly while editing this file. Restore the latest autosave?")
            }
            .sheet(item: $sheet) { s in sheetView(s) }
    }

    @ViewBuilder
    private var leaveButtons: some View {
        Button("Save") { Task { if await model.save() { leave() } } }
        Button("Discard Changes", role: .destructive) { leave() }
        Button("Cancel", role: .cancel) {}
    }

    @ViewBuilder
    private var pickButtons: some View {
        ForEach(model.pickList, id: \.uuid) { part in
            Button(part.name) { model.select(part, extend: model.shift) }
        }
        Button("Cancel", role: .cancel) {}
    }

    private func leave() {
        Autosave.releaseLock(model.saveURL)
        model.stopTest()
        dismiss()
    }

    private func start() async {
        if let newPuppet {
            model.loadNew(newPuppet)
        } else {
            await model.load()
            if Autosave.needsRecovery(model.saveURL) { askRecovery = true }
        }
        RecentProjects.add(model.url)
    }

    private func restoreBackup() async {
        guard let latest = Autosave.backups(for: model.saveURL).last,
              let data = try? Data(contentsOf: latest), let p = try? Puppet(data: data) else {
            model.message = "The backup couldn't be read."
            return
        }
        model.loadNew(p)
    }

    @ViewBuilder
    private func sheetView(_ s: EditorSheet) -> some View {
        switch s {
        case .history: HistoryView(model: model)
        case .settings: SettingsView(model: model)
        case .autoMesh: AutoMeshSheet(model: model)
        case .flipPairs: FlipPairsView(model: model)
        case .testBinding: TrackingBindingSheet(model: model)
        case .editAnimation(let name): EditAnimationSheet(model: model, name: name)
        case .exportPuppet: PuppetExportSheet(model: model)
        case .exportImage: ImageExportSheet(model: model)
        case .exportVideo: VideoExportSheet(model: model)
        case .textures: TextureViewer(model: model)
        case .mergePSD(let url): PSDMergeSheet(model: model, url: url)
        }
    }

    private var ready: Bool { model.state == .ready }

    private var layout: some View {
        HStack(spacing: 0) {
            if showSidebar && ready && model.mode != .mesh {
                sidebar
                Divider()
            }
            VStack(spacing: 0) {
                ZStack {
                    EditorCanvas(model: model)
                        .ignoresSafeArea(edges: .bottom)
                    canvasOverlay
                }
                if model.mode == .animation && ready {
                    Divider()
                    TimelineView(model: model) { sheet = $0 }
                        .frame(height: 260)
                }
            }
            if showInspector && ready {
                Divider()
                rightPanel
                    .frame(width: 310)
            }
        }
    }

    @ViewBuilder
    private var rightPanel: some View {
        switch model.mode {
        case .mesh: MeshOptionsView(model: model) { sheet = $0 }
        case .test: TestPanel(model: model) { sheet = $0 }
        default: InspectorView(model: model) { sheet = $0 }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            if model.mode == .animation {
                AnimationList(model: model) { sheet = $0 }
            } else {
                Picker("Panel", selection: $sidebarTab) {
                    ForEach(SidebarTab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(8)
                Divider()
                if sidebarTab == .nodes {
                    NodeTreeView(model: model, addingImage: $addingImage)
                } else {
                    ParameterEditorList(model: model) { sheet = $0 }
                }
            }
        }
        .frame(width: 290)
        .background(Color(.secondarySystemBackground))
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarLeading) {
            Button {
                model.commitPending()
                if model.dirty && AppSettings.saveOnClose == "Ask" { confirmLeave = true } else { leave() }
            } label: {
                Label("Library", systemImage: "chevron.backward")
            }
            Button { withAnimation { showSidebar.toggle() } } label: { Image(systemName: "sidebar.left") }
            Button { undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!(model.canUndo || (model.meshSession?.canUndo ?? false)))
                .keyboardShortcut("z", modifiers: .command)
            Button { redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!(model.canRedo || (model.meshSession?.canRedo ?? false)))
                .keyboardShortcut("z", modifiers: [.command, .shift])
            Button { sheet = .history } label: { Image(systemName: "clock.arrow.circlepath") }
        }
        ToolbarItem(placement: .principal) {
            Picker("Mode", selection: Binding(get: { model.mode }, set: { model.setMode($0) })) {
                ForEach(EditorModel.Mode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 320)
            .disabled(!ready)
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if model.saving { ProgressView() }
            Button { Task { _ = await model.save() } } label: { Image(systemName: "square.and.arrow.down") }
                .disabled(!ready)
                .keyboardShortcut("s", modifiers: .command)
            mainMenu
            Button {
                Task { if await model.save() { playURL = model.url } }
            } label: {
                Label("Play", systemImage: "play.fill")
            }
            .disabled(!ready)
            Button { withAnimation { showInspector.toggle() } } label: { Image(systemName: "sidebar.right") }
        }
    }

    private func undo() {
        if model.mode == .mesh, let s = model.meshSession, s.undo() {
            model.revision &+= 1
        } else {
            model.undo()
        }
    }

    private func redo() {
        if model.mode == .mesh, let s = model.meshSession, s.redo() {
            model.revision &+= 1
        } else {
            model.redo()
        }
    }

    /// Creator's File / Edit / View / Tools menus, combined.
    private var mainMenu: some View {
        Menu {
            Section("File") {
                Button { export(.inochiCreatorProject) } label: { Label("Save a Copy (.inx)", systemImage: "doc.on.doc") }
                Menu {
                    Button { sheet = .exportPuppet } label: { Label("Inochi2D Puppet (.inp)…", systemImage: "person.crop.square") }
                    Button { sheet = .exportImage } label: { Label("Image…", systemImage: "photo") }
                    Button { sheet = .exportVideo } label: { Label("Video…", systemImage: "film") }
                } label: { Label("Export", systemImage: "square.and.arrow.up") }
                Menu {
                    Button { mergingPSD = true } label: { Label("Photoshop Document…", systemImage: "square.3.layers.3d") }
                    Button { addingImage = true } label: { Label("Image Files…", systemImage: "photo.on.rectangle") }
                } label: { Label("Merge", systemImage: "arrow.triangle.merge") }
            }
            Section("Edit") {
                Button { model.selectAll() } label: { Label("Select All", systemImage: "checkmark.circle") }
                Button { sheet = .settings } label: { Label("Settings…", systemImage: "gearshape") }
            }
            Section("View") {
                Picker("Background", selection: $model.background) {
                    ForEach(BackgroundStyle.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Mirror View", isOn: $model.mirrorView)
                Toggle("Show Vertices", isOn: $model.showVertices)
                Toggle("Show Bounds", isOn: $model.showBounds)
                Toggle("Show Orientation", isOn: $model.showOrientation)
                Toggle("Physics", isOn: $model.physicsPreview)
                Button { model.puppet?.resetDrivers() } label: { Label("Reset Physics", systemImage: "arrow.counterclockwise") }
                Button { model.resetParameters() } label: { Label("Reset Parameters", systemImage: "slider.horizontal.below.rectangle") }
                Button { model.focusSelection() } label: { Label("Focus Selection", systemImage: "scope") }
                Button { model.resetView() } label: { Label("Reset View", systemImage: "viewfinder") }
            }
            Section("Tools") {
                Button { sheet = .flipPairs } label: { Label("Configure Flip Pairings…", systemImage: "arrow.left.and.right.square") }
                Button { sheet = .textures } label: { Label("Texture Viewer…", systemImage: "photo.stack") }
                Menu {
                    Button("Premultiply Textures") { model.premultiplyTextures() }
                    Button("Bleed Textures") { model.bleedTextures() }
                    Button("Generate Fake Layer Names") { model.generateLayerNames() }
                } label: { Label("Puppet Texturing", systemImage: "paintpalette") }
                Menu {
                    Button("Attempt Full Repair") { model.repairPuppet() }
                    Button("Regenerate Node IDs") { model.regenerateNodeIDs() }
                } label: { Label("Puppet Recovery", systemImage: "bandage") }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .disabled(!ready)
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
            model.message = "\(url.lastPathComponent) is not supported."
            return
        }
        TGADecoder.premultiply(&px)
        let limit = 8192
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
                switch model.mode {
                case .mesh: MeshToolBar(model: model)
                case .model: ModelToolBar(model: model)
                case .animation, .test: EmptyView()
                }
            }
            .padding(12)
        }
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
