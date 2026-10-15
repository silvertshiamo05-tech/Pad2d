import SwiftUI
import UniformTypeIdentifiers
import Inochi2DKit

/// Creator's Action History panel: tap an entry to go back to that state.
struct HistoryView: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(model.history.enumerated()), id: \.element.id) { i, entry in
                    Button {
                        model.jump(to: i)
                    } label: {
                        HStack {
                            Text(entry.label)
                                .foregroundStyle(i <= model.historyIndex ? .primary : .secondary)
                            Spacer()
                            if i == model.historyIndex { Image(systemName: "arrowtriangle.left.fill").foregroundStyle(.tint) }
                        }
                    }
                }
            }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Clear History") { model.clearHistory() } }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .bottomBar) {
                    Text("\(model.history.count - 1) of \(model.maxUndo)").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Creator's Settings window.
struct SettingsView: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var autosave = AppSettings.autosaveEnabled
    @State private var interval = AppSettings.autosaveInterval
    @State private var limit = AppSettings.autosaveLimit
    @State private var keepFolders = AppSettings.keepLayerFolder
    @State private var saveOnClose = AppSettings.saveOnClose
    @State private var scrollToArmed = AppSettings.scrollToArmed
    @State private var zoomSpeed = AppSettings.zoomSpeed

    var body: some View {
        NavigationStack {
            Form {
                Section("Undo History") {
                    Stepper("Maximum steps: \(model.maxUndo)", value: Binding(get: { model.maxUndo }, set: { model.setMaxUndo($0) }),
                            in: 1...1000, step: 10)
                }
                Section("Autosaves") {
                    Toggle("Enable autosaves", isOn: $autosave)
                    Stepper("Save every \(interval) min", value: $interval, in: 1...1440, step: 1)
                    Stepper("Keep \(limit) autosaves", value: $limit, in: 1...1000)
                }
                Section("Import") {
                    Picker("PSD folder structure", selection: $keepFolders) {
                        Text("Always ask").tag("Ask")
                        Text("Preserve").tag("Preserve")
                        Text("Don't preserve").tag("NotPreserve")
                    }
                }
                Section("On close project") {
                    Picker("Save project", selection: $saveOnClose) {
                        Text("Always ask").tag("Ask")
                        Text("Don't save").tag("dontSave")
                    }
                }
                Section("Accessibility") {
                    Toggle("Scroll to armed parameter", isOn: $scrollToArmed)
                }
                Section("Viewport") {
                    LabeledContent("Zoom speed (mouse wheel)") {
                        Slider(value: $zoomSpeed, in: 1...50).frame(width: 200)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        AppSettings.autosaveEnabled = autosave
                        AppSettings.autosaveInterval = interval
                        AppSettings.autosaveLimit = limit
                        AppSettings.keepLayerFolder = keepFolders
                        AppSettings.saveOnClose = saveOnClose
                        AppSettings.scrollToArmed = scrollToArmed
                        AppSettings.zoomSpeed = zoomSpeed
                        dismiss()
                    }
                }
            }
        }
    }
}

/// Creator's Flip Pairing window: which nodes mirror each other.
struct FlipPairsView: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var pairs: [FlipPair] = []
    @State private var pattern1 = "L"
    @State private var pattern2 = "R"
    @State private var pending: UInt32?

    var body: some View {
        let nodes = (model.puppet?.root.allNodes() ?? []).dropFirst()
        let paired = Set(pairs.flatMap { [$0.first, $0.second] })
        NavigationStack {
            HStack(spacing: 0) {
                List {
                    Section("Unpaired — tap two to pair") {
                        ForEach(nodes.filter { !paired.contains($0.uuid) }, id: \.uuid) { n in
                            Button {
                                if let p = pending, p != n.uuid {
                                    pairs.append(FlipPair(p, n.uuid))
                                    pending = nil
                                } else {
                                    pending = pending == n.uuid ? nil : n.uuid
                                }
                            } label: {
                                HStack {
                                    Image(systemName: n.kindIcon)
                                    Text(n.name)
                                    Spacer()
                                    if pending == n.uuid { Image(systemName: "checkmark.circle.fill") }
                                }
                            }
                        }
                    }
                }
                .frame(width: 300)
                Divider()
                List {
                    Section("Auto pair") {
                        HStack {
                            TextField("Part 1 pattern", text: $pattern1).textFieldStyle(.roundedBorder)
                            Image(systemName: "arrow.left.and.right")
                            TextField("Part 2 pattern", text: $pattern2).textFieldStyle(.roundedBorder)
                            Button("Pair") {
                                let saved = model.puppet?.flipPairs ?? []
                                model.puppet?.flipPairs = pairs
                                pairs = model.puppet?.autoPair(pattern1, pattern2) ?? pairs
                                model.puppet?.flipPairs = saved
                            }
                        }
                    }
                    Section("Pairs") {
                        ForEach(Array(pairs.enumerated()), id: \.offset) { i, p in
                            HStack {
                                Text(name(p.first))
                                Image(systemName: "arrow.left.and.right").foregroundStyle(.secondary)
                                Text(name(p.second))
                            }
                        }
                        .onDelete { pairs.remove(atOffsets: $0) }
                    }
                }
            }
            .navigationTitle("Flip Pairing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        model.puppet?.flipPairs = pairs
                        model.changed("Flip pairs")
                        dismiss()
                    }
                }
            }
            .onAppear { pairs = model.puppet?.flipPairs ?? [] }
        }
    }

    private func name(_ id: UInt32) -> String {
        id == .max ? "<< Not assigned >>" : (model.puppet?.root.find(uuid: id)?.name ?? "?")
    }
}

/// Creator's "Bind Tracking to Parameter" window (Test mode).
struct TrackingBindingSheet: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var param: UInt32 = 0
    @State private var key = FaceTracker.inputNames.first ?? ""
    @State private var axis = 0
    @State private var inverse = false

    var body: some View {
        NavigationStack {
            Form {
                Picker("Parameter", selection: $param) {
                    ForEach(model.puppet?.parameters ?? [], id: \.uuid) { Text($0.name).tag($0.uuid) }
                }
                Picker("Bind To", selection: $key) {
                    ForEach(FaceTracker.inputNames, id: \.self) { Text($0).tag($0) }
                }
                if model.puppet?.parameter(uuid: param)?.isVec2 == true {
                    Picker("Binding Axis", selection: $axis) {
                        Text("X").tag(0)
                        Text("Y").tag(1)
                    }
                    .pickerStyle(.segmented)
                }
                Toggle("Invert", isOn: $inverse)
            }
            .navigationTitle("Bind Tracking to Parameter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        model.testBindings.append(TrackingBinding(key: key, paramUUID: param, axis: axis, inverse: inverse))
                        model.saveTestBindings()
                        if model.mode == .test { model.stopTest(); model.startTest() }
                        dismiss()
                    }
                    .disabled(param == 0 || key.isEmpty)
                }
            }
            .onAppear { param = model.puppet?.parameters.first?.uuid ?? 0 }
        }
    }
}

/// Test mode panel: tracking bindings and physics.
struct TestPanel: View {
    @ObservedObject var model: EditorModel
    let present: (EditorSheet) -> Void

    var body: some View {
        Form {
            Section("Tracking") {
                Toggle("Automatic face mapping", isOn: Binding(get: { model.testAutoTracking }, set: { model.testAutoTracking = $0 }))
                if !FaceTracker.isSupported {
                    Text("Face tracking isn't supported on this device.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                ForEach(model.testBindings) { b in
                    let pname = model.puppet?.parameter(uuid: b.paramUUID)?.name ?? "?"
                    Text("\(b.key) bound to \(pname)\(b.axis == 1 ? " (Y)" : "")\(b.inverse ? ", inverted" : "")")
                        .font(.callout)
                }
                .onDelete { idx in
                    model.testBindings.remove(atOffsets: idx)
                    model.saveTestBindings()
                }
                Button { present(.testBinding) } label: { Label("Add Binding…", systemImage: "plus") }
            } header: {
                Text("Tracking Bindings")
            } footer: {
                Text("Bind ARKit blend shapes or head pose to parameters. Values 0–1 map onto each parameter's range.")
            }
            Section("Physics") {
                Button("Reset Physics") { model.puppet?.resetDrivers() }
                Button("Reset Parameters") { model.resetParameters() }
            }
        }
        .formStyle(.grouped)
    }
}

/// Creator's INP Export Options: atlases and decoration.
struct PuppetExportSheet: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var settings = INPExportSettings()
    @State private var scalePercent = 100
    @State private var preview: UIImage?
    @State private var forced = false
    @State private var result: Data?
    @State private var exporting = false
    @State private var working = false
    @State private var loadingWatermark = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Atlassing") {
                    if let preview {
                        Image(uiImage: preview).resizable().scaledToFit().frame(maxHeight: 220)
                            .background(Color.gray.opacity(0.2))
                    }
                    Picker("Resolution", selection: $settings.atlasResolution) {
                        Text("2048×2048").tag(2048)
                        Text("4096×4096").tag(4096)
                        Text("8192×8192").tag(8192)
                    }
                    Toggle("Non-linear Scaling", isOn: $settings.nonLinearScaling)
                    Stepper("Texture Scale: \(scalePercent)%", value: $scalePercent, in: 25...200, step: 5)
                    Stepper("Padding: \(settings.padding)", value: $settings.padding, in: 0...128)
                    Toggle("Prune hidden nodes", isOn: $settings.pruneHidden)
                }
                Section("Decoration") {
                    Button(settings.watermark == nil ? "Load Watermark…" : "Replace Watermark…") { loadingWatermark = true }
                    if settings.watermark != nil {
                        Button("Remove Watermark", role: .destructive) { settings.watermark = nil }
                        Picker("Blending", selection: $settings.watermarkBlend) {
                            ForEach(BlendMode.allCases.filter { $0 != .sliceFromLower }, id: \.self) { Text($0.title).tag($0) }
                        }
                        Stepper("Loops: \(settings.watermarkLoops)", value: $settings.watermarkLoops, in: 1...1000)
                        LabeledContent("Opacity") { Slider(value: $settings.watermarkOpacity, in: 0...1).frame(width: 200) }
                    }
                }
                if forced {
                    Text("A texture was too large to fit the texture atlas, the textures have been scaled down.")
                        .foregroundStyle(.red).font(.callout)
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("Export Puppet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if working { ProgressView() } else {
                        Button("Export…") { build(save: true) }
                    }
                }
                ToolbarItem(placement: .bottomBar) { Button("Preview") { build(save: false) } }
            }
            .fileImporter(isPresented: $loadingWatermark, allowedContentTypes: [.png, .jpeg, .image]) { r in
                if case let .success(url) = r {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    if let d = try? Data(contentsOf: url), var (px, w, h) = TextureLoader.decodeImage(d) {
                        TGADecoder.premultiply(&px)
                        settings.watermark = (px, w, h)
                    }
                }
            }
            .fileExporter(isPresented: $exporting, document: result.map(PuppetFileDocument.init(data:)),
                          contentType: .inochiPuppet, defaultFilename: model.name) { _ in dismiss() }
        }
    }

    private func build(save: Bool) {
        working = true
        error = nil
        settings.scale = Float(scalePercent) / 100
        Task { @MainActor in
            await Task.yield()
            do {
                let r = try model.exportINP(settings)
                forced = r.forcedScale < 0.999
                if let p = r.preview { preview = EditorModel.image(p.rgba, p.width, p.height) }
                result = r.data
                if save { exporting = true }
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }
}

/// Creator's Export Image window: renders through a Camera node.
struct ImageExportSheet: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var camera: UInt32 = 0
    @State private var transparent = false
    @State private var format = EditorModel.ImageFormat.png
    @State private var output: Data?
    @State private var exporting = false

    var body: some View {
        NavigationStack {
            Form {
                if model.cameras.isEmpty {
                    Text("No cameras to export from in the scene. Add a Camera node first (Nodes ▸ +).")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Camera", selection: $camera) {
                        ForEach(model.cameras, id: \.uuid) { Text($0.name).tag($0.uuid) }
                    }
                    Picker("Format", selection: $format) {
                        ForEach(EditorModel.ImageFormat.allCases) { Text($0.rawValue.uppercased()).tag($0) }
                    }
                    Toggle("Allow Transparency", isOn: $transparent)
                }
            }
            .navigationTitle("Export Image")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Export…") {
                        guard let cam = model.cameras.first(where: { $0.uuid == camera }) else { return }
                        output = model.exportImage(camera: cam, transparent: transparent, format: format)
                        if output == nil { model.message = "The image couldn't be rendered." } else { exporting = true }
                    }
                    .disabled(model.cameras.isEmpty)
                }
            }
            .onAppear { camera = model.cameras.first?.uuid ?? 0 }
            .fileExporter(isPresented: $exporting, document: output.map { DataDocument(data: $0) },
                          contentType: format == .png ? .png : format == .jpeg ? .jpeg : (UTType(filenameExtension: "tga") ?? .data),
                          defaultFilename: model.name) { _ in dismiss() }
        }
    }
}

/// Creator's Export Video window: an animation through a Camera node.
struct VideoExportSheet: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var camera: UInt32 = 0
    @State private var animation = ""
    @State private var loops = 1
    @State private var fps = -1
    @State private var transparent = false
    @State private var progress: Double?
    @State private var output: URL?
    @State private var exporting = false

    var body: some View {
        let cams = model.cameras
        NavigationStack {
            Form {
                if cams.isEmpty {
                    Text("No cameras to export from in the scene. Add a Camera node first.").foregroundStyle(.secondary)
                } else if model.animationNames.isEmpty {
                    Text("No animations are defined. Create one in Animate mode first.").foregroundStyle(.secondary)
                } else {
                    Picker("Camera", selection: $camera) { ForEach(cams, id: \.uuid) { Text($0.name).tag($0.uuid) } }
                    Picker("Animation", selection: $animation) { ForEach(model.animationNames, id: \.self) { Text($0).tag($0) } }
                    Stepper("Loops: \(loops)", value: $loops, in: 1...100)
                    Stepper(fps < 1 ? "Framerate: Auto" : "Framerate: \(fps)", value: $fps, in: -1...240)
                    Toggle("Allow Transparency (HEVC)", isOn: $transparent)
                    if let c = cams.first(where: { $0.uuid == camera }), Int(c.viewport.x) % 2 != 0 || Int(c.viewport.y) % 2 != 0 {
                        Text("Warning: Camera size must be divisible by 2").foregroundStyle(.red)
                    }
                    if let progress { ProgressView(value: progress) { Text("Encoding…") } }
                }
            }
            .navigationTitle("Export Video")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Export…") { start() }
                        .disabled(cams.isEmpty || model.animationNames.isEmpty || progress != nil)
                }
            }
            .onAppear {
                camera = cams.first?.uuid ?? 0
                animation = model.animationNames.first ?? ""
            }
            .fileExporter(isPresented: $exporting, document: output.flatMap { try? Data(contentsOf: $0) }.map { DataDocument(data: $0) },
                          contentType: .quickTimeMovie, defaultFilename: animation) { _ in dismiss() }
        }
    }

    private func start() {
        guard let cam = model.cameras.first(where: { $0.uuid == camera }) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(model.name)-\(animation).mov")
        progress = 0
        Task { @MainActor in
            do {
                try await model.exportVideo(camera: cam, animation: animation, loops: loops, fps: fps, transparent: transparent,
                                            to: url) { p in progress = p }
                output = url
                exporting = true
            } catch {
                model.message = "Video encoding error: \(error.localizedDescription)"
            }
            progress = nil
        }
    }
}

/// Any file for the Files exporter.
struct DataDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    static var writableContentTypes: [UTType] { [.data, .png, .jpeg, .quickTimeMovie] }
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// Creator's Texture Viewer.
struct TextureViewer: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var zoom: CGFloat = 1

    var body: some View {
        NavigationStack {
            VStack {
                Picker("Texture", selection: $index) {
                    ForEach(0..<(model.puppet?.textures.count ?? 0), id: \.self) { Text("Texture \($0)").tag($0) }
                }
                .pickerStyle(.menu)
                ScrollView([.horizontal, .vertical]) {
                    if let img = model.thumbnail(texture: index) {
                        Image(uiImage: img).resizable().interpolation(.medium)
                            .frame(width: img.size.width * zoom, height: img.size.height * zoom)
                            .background(Color.gray.opacity(0.25))
                    }
                }
                Slider(value: $zoom, in: 0.1...10) { Text("Zoom") }.padding()
            }
            .navigationTitle("Texture Viewer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

/// Creator's PSD Merging window.
struct PSDMergeSheet: View {
    @ObservedObject var model: EditorModel
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var doc: PSDDocument?
    @State private var items: [PSDMergeItem] = []
    @State private var rename = false
    @State private var retranslate = false
    @State private var onlyUnmapped = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Rename mapped nodes to layer names", isOn: $rename)
                    Toggle("Move mapped nodes to the layer position", isOn: $retranslate)
                    Toggle("Only show unmapped layers", isOn: $onlyUnmapped)
                }
                Section("Layers") {
                    ForEach($items) { $item in
                        if !onlyUnmapped || item.target == nil {
                            HStack {
                                Button { item.ignore.toggle() } label: {
                                    Image(systemName: item.ignore ? "eye.slash" : "eye")
                                }
                                .buttonStyle(.borderless)
                                VStack(alignment: .leading) {
                                    Text(item.name).foregroundStyle(item.ignore ? .secondary : .primary)
                                    Text(item.path).font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Picker("", selection: $item.target) {
                                    Text("Add as new part").tag(UInt32?.none)
                                    ForEach(model.puppet?.parts ?? [], id: \.uuid) { p in Text("→ \(p.name)").tag(UInt32?.some(p.uuid)) }
                                }
                                .labelsHidden()
                                .frame(maxWidth: 240)
                            }
                        }
                    }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("PSD Merging")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Merge") { merge() }.disabled(doc == nil)
                }
            }
            .task { load() }
        }
    }

    private func load() {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let d = try PSDDocument(data: try Data(contentsOf: url))
            doc = d
            items = model.puppet?.psdMergePlan(d) ?? []
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func merge() {
        guard let doc, let puppet = model.puppet else { return }
        do {
            try puppet.applyPSDMerge(doc, items: items, rename: rename, retranslate: retranslate)
            model.syncTextures()
            model.changed("Merge PSD")
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
