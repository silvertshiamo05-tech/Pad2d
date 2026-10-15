import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let inochiPuppet = UTType(importedAs: "com.inochi2d.inp", conformingTo: .data)
    static let inochiCreatorProject = UTType(importedAs: "com.inochi2d.inx", conformingTo: .data)
}

@main
struct Pad2DApp: App {
    @StateObject private var library = ModelLibrary()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(library)
                .onOpenURL { url in library.importFiles([url]) }
        }
    }
}

/// Bundled sample models plus models the user imported (copied into Documents/Models).
@MainActor
final class ModelLibrary: ObservableObject {
    struct Model: Identifiable, Hashable {
        var url: URL
        var bundled: Bool
        var id: URL { url }
        var name: String { url.deletingPathExtension().lastPathComponent }
        var size: Int64 {
            (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        }
    }

    @Published private(set) var models: [Model] = []
    @Published var message: String?

    static var importedDirectory: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    init() { refresh() }

    func refresh() {
        let exts = ["inp", "inx"]
        let bundled = exts.flatMap { Bundle.main.urls(forResourcesWithExtension: $0, subdirectory: "Models") ?? [] }
            .map { Model(url: $0, bundled: true) }
        let imported = ((try? FileManager.default.contentsOfDirectory(at: Self.importedDirectory, includingPropertiesForKeys: nil)) ?? [])
            .filter { exts.contains($0.pathExtension.lowercased()) }
            .map { Model(url: $0, bundled: false) }
        models = (imported.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
            + bundled.sorted { $0.name < $1.name }
    }

    func importFiles(_ urls: [URL]) {
        var count = 0
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard ["inp", "inx"].contains(url.pathExtension.lowercased()) else { continue }
            var dest = Self.importedDirectory.appendingPathComponent(url.lastPathComponent)
            var n = 2
            while FileManager.default.fileExists(atPath: dest.path) {
                dest = Self.importedDirectory.appendingPathComponent(
                    "\(url.deletingPathExtension().lastPathComponent) \(n).\(url.pathExtension)")
                n += 1
            }
            do {
                try FileManager.default.copyItem(at: url, to: dest)
                count += 1
            } catch {
                message = "Couldn't import \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
        if count > 0 { message = count == 1 ? "Model imported." : "\(count) models imported." }
        refresh()
    }

    func delete(_ model: Model) {
        guard !model.bundled else { return }
        try? FileManager.default.removeItem(at: model.url)
        refresh()
    }
}

struct LibraryView: View {
    @EnvironmentObject private var library: ModelLibrary
    @State private var importing = false
    @State private var showAbout = false

    private let columns = [GridItem(.adaptive(minimum: 200), spacing: 16)]

    var body: some View {
        NavigationStack {
            ScrollView {
                if library.models.isEmpty {
                    ContentUnavailableView("No models yet", systemImage: "person.crop.square",
                                           description: Text("Import an Inochi2D model (.inp or .inx) from the Files app."))
                        .padding(.top, 80)
                }
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(library.models) { model in
                        NavigationLink(value: model) {
                            ModelCard(model: model)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            if !model.bundled {
                                Button(role: .destructive) { library.delete(model) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Pad2D")
            .navigationDestination(for: ModelLibrary.Model.self) { model in
                StageView(url: model.url)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showAbout = true } label: { Image(systemName: "info.circle") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { importing = true } label: { Label("Import", systemImage: "square.and.arrow.down") }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.inochiPuppet, .inochiCreatorProject, .data],
                          allowsMultipleSelection: true) { result in
                if case let .success(urls) = result { library.importFiles(urls) }
            }
            .sheet(isPresented: $showAbout) { AboutView() }
            .alert(library.message ?? "", isPresented: Binding(get: { library.message != nil },
                                                               set: { if !$0 { library.message = nil } })) {
                Button("OK", role: .cancel) {}
            }
        }
    }
}

private struct ModelCard: View {
    let model: ModelLibrary.Model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(.quaternary)
                Image(systemName: "person.and.background.dotted")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
            }
            .aspectRatio(1, contentMode: .fit)
            Text(model.name).font(.headline).lineLimit(1)
            HStack(spacing: 6) {
                Text(model.url.pathExtension.uppercased())
                Text("·")
                Text(ByteCountFormatter.string(fromByteCount: model.size, countStyle: .file))
                if model.bundled {
                    Text("·")
                    Text("Sample")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 18).fill(.background).shadow(color: .black.opacity(0.08), radius: 6, y: 2))
    }
}
