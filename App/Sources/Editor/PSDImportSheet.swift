import SwiftUI
import Inochi2DKit

struct PSDSource: Identifiable {
    let url: URL
    var id: URL { url }
}

/// Options for turning a layered PSD into a new puppet, then the import itself.
struct PSDImportSheet: View {
    let source: PSDSource
    let onCreated: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var options = PSDImportOptions()
    @State private var progress: Double?
    @State private var error: String?

    init(source: PSDSource, onCreated: @escaping (URL) -> Void) {
        self.source = source
        self.onCreated = onCreated
        _name = State(initialValue: source.url.deletingPathExtension().lastPathComponent)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("New Puppet") {
                    TextField("Name", text: $name)
                    LabeledContent("From", value: source.url.lastPathComponent)
                }
                Section {
                    Toggle("Keep folders as groups", isOn: $options.keepFolders)
                    Toggle("Generate meshes", isOn: $options.autoMesh)
                    if options.autoMesh {
                        LabeledContent("Mesh detail") {
                            Picker("Mesh detail", selection: $options.meshSpacing) {
                                Text("Low").tag(Float(128))
                                Text("Medium").tag(Float(64))
                                Text("High").tag(Float(32))
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 220)
                        }
                    }
                    Picker("Largest texture", selection: $options.maxTextureSize) {
                        Text("2048 px").tag(2048)
                        Text("4096 px").tag(4096)
                    }
                } header: {
                    Text("Options")
                } footer: {
                    Text("Every visible and hidden pixel layer becomes a part, placed where it is in the PSD. Folders with a blend mode other than Normal or Pass Through become composites. Save the PSD as 8-bit RGB.")
                }
                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    }
                }
                if let progress {
                    Section {
                        ProgressView(value: progress) { Text("Importing layers…") }
                    }
                }
            }
            .navigationTitle("New from PSD")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(progress != nil)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { start() }
                        .disabled(progress != nil || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .interactiveDismissDisabled(progress != nil)
        }
    }

    private func start() {
        error = nil
        progress = 0
        let url = source.url
        let options = self.options
        let fileName = name.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-")
        var dest = ModelLibrary.importedDirectory.appendingPathComponent(fileName + ".inx")
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = ModelLibrary.importedDirectory.appendingPathComponent("\(fileName) \(n).inx")
            n += 1
        }
        let target = dest
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let data = try Data(contentsOf: url, options: .alwaysMapped)
                    let puppet = try Puppet.importPSD(data, options: options) { p in
                        Task { @MainActor in progress = p }
                    }
                    puppet.meta.name = fileName
                    try puppet.fileData().write(to: target, options: .atomic)
                }.value
                dismiss()
                onCreated(target)
            } catch {
                self.error = error.localizedDescription
                progress = nil
            }
        }
    }
}
