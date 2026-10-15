import SwiftUI
import Inochi2DKit

/// Chooses which tracked input drives each parameter axis.
struct TrackingSettingsView: View {
    @ObservedObject var controller: PuppetController
    @Environment(\.dismiss) private var dismiss

    private struct Row: Identifiable {
        var parameter: Parameter
        var axis: Int
        var id: String { "\(parameter.uuid)-\(axis)" }
        var title: String {
            parameter.isVec2 ? "\(parameter.name) — \(axis == 0 ? "X" : "Y")" : parameter.name
        }
    }

    private var rows: [Row] {
        (controller.puppet?.parameters ?? [])
            .filter { controller.puppet?.isDriven($0) != true }
            .flatMap { p in (0..<(p.isVec2 ? 2 : 1)).map { Row(parameter: p, axis: $0) } }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Tracking", selection: $controller.trackingMode) {
                        ForEach(TrackingMode.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Mirror (like a selfie)", isOn: $controller.mirror)
                    if !controller.faceTrackingSupported {
                        Text("Face tracking needs ARKit face tracking support (A12 chip or newer).")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Face tracking uses the front camera through ARKit and runs entirely on the iPad. Nothing is recorded or uploaded.")
                }

                Section {
                    ForEach(rows) { row in
                        mappingRow(row)
                    }
                } header: {
                    Text("Parameter Mapping")
                } footer: {
                    Text("Mappings were guessed from parameter names. If something moves the wrong way, turn on Invert.")
                }

                Section {
                    Button("Detect Mappings Again") { controller.resetMappings() }
                }
            }
            .navigationTitle("Tracking")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    @ViewBuilder
    private func mappingRow(_ row: Row) -> some View {
        let index = controller.mappings.firstIndex { $0.parameter == row.parameter.name && $0.axis == row.axis }
        let source = index.map { controller.mappings[$0].source } ?? .none
        VStack(alignment: .leading, spacing: 6) {
            Text(row.title).font(.subheadline.weight(.medium))
            HStack {
                Picker("Input", selection: Binding(
                    get: { source },
                    set: { new in
                        if let i = index {
                            controller.mappings[i].source = new
                        } else {
                            controller.mappings.append(TrackingMapping(parameter: row.parameter.name, axis: row.axis, source: new))
                        }
                    })) {
                    ForEach(TrackingSource.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                Spacer()
                if let i = index, source != .none {
                    Toggle("Invert", isOn: Binding(get: { controller.mappings[i].invert },
                                                   set: { controller.mappings[i].invert = $0 }))
                        .toggleStyle(.button)
                    Stepper(String(format: "×%.2g", controller.mappings[i].scale),
                            value: Binding(get: { Double(controller.mappings[i].scale) },
                                           set: { controller.mappings[i].scale = Float($0) }),
                            in: 0.25...3, step: 0.25)
                        .fixedSize()
                }
            }
        }
    }
}
