import SwiftUI

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Pad2D plays Inochi2D puppets (.inp and .inx files from Inochi Creator) on iPad, with face tracking, physics and touch control.")
                    Text("Pad2D is an independent, unofficial app. It isn't affiliated with or endorsed by the Inochi2D Project.")
                        .foregroundStyle(.secondary)
                }
                Section("Inochi2D") {
                    Text("Pad2D's runtime is a Swift port of the Inochi2D 0.8 runtime.")
                    Link("github.com/Inochi2D/inochi2d", destination: URL(string: "https://github.com/Inochi2D/inochi2d")!)
                    Text(Self.bsd).font(.caption.monospaced())
                }
                Section("Sample models") {
                    Text("Aka and Midori — design and rigging by seagetch. Licensed under Creative Commons Attribution 4.0 (CC BY 4.0).")
                    Link("creativecommons.org/licenses/by/4.0", destination: URL(string: "https://creativecommons.org/licenses/by/4.0/")!)
                    Link("github.com/Inochi2D/example-models", destination: URL(string: "https://github.com/Inochi2D/example-models")!)
                }
            }
            .navigationTitle("About")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    static let bsd = """
    BSD 2-Clause License

    Copyright (c) 2020, Inochi2D Project
    All rights reserved.

    Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

    1. Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.

    2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

    THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
    """
}
