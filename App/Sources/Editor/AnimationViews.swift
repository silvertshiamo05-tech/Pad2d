import SwiftUI
import Inochi2DKit

/// Creator's Animation List panel.
struct AnimationList: View {
    @ObservedObject var model: EditorModel
    let present: (EditorSheet) -> Void

    var body: some View {
        let _ = model.revision
        VStack(spacing: 0) {
            HStack {
                Text("Animations").font(.headline)
                Spacer()
                Button { present(.editAnimation(nil)) } label: { Image(systemName: "plus.circle.fill").font(.title2) }
            }
            .padding(10)
            Divider()
            if model.animationNames.isEmpty {
                ContentUnavailableView("No animations", systemImage: "film",
                                       description: Text("Create an animation, then add keyframes from the parameters panel or the timeline."))
            }
            List {
                ForEach(model.animationNames, id: \.self) { name in
                    Button { model.selectAnimation(name) } label: {
                        HStack {
                            Image(systemName: "film")
                            Text(name)
                            Spacer()
                            if model.currentAnimation == name { Image(systemName: "checkmark").foregroundStyle(.tint) }
                        }
                    }
                    .contextMenu {
                        Button { model.duplicateAnimation(name) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                        Button { present(.editAnimation(name)) } label: { Label("Edit…", systemImage: "pencil") }
                        Button(role: .destructive) { model.deleteAnimation(name) } label: { Label("Delete", systemImage: "trash") }
                    }
                }
            }
            .listStyle(.plain)
            Divider()
            ParameterEditorList(model: model) { present($0) }
                .frame(maxHeight: .infinity)
        }
    }
}

/// Parameters panel content in Animation mode (keyframe buttons live in each row).
struct AnimationParameterKeys: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        Section("Keyframes") {
            if let a = model.currentAnim {
                LabeledContent("Frame", value: "\(model.animationFrame) / \(a.length)")
                Button("Key All Lanes at This Frame") { model.keyAllLanes() }
                Button("Remove Keyframes at This Frame", role: .destructive) { model.removeKeysAtFrame() }
                Text("Use the ◆ button on a parameter to key its current value. Double-tap a lane in the timeline to add or remove a keyframe there.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Select or create an animation.").foregroundStyle(.secondary)
            }
        }
    }
}

/// Creator's Timeline panel.
struct TimelineView: View {
    @ObservedObject var model: EditorModel
    let present: (EditorSheet) -> Void
    @State private var frameWidth: CGFloat = 12
    @State private var headerWidth: CGFloat = 220
    @State private var dragKey: (lane: ObjectIdentifier, frame: Int)?

    var body: some View {
        let _ = model.revision
        VStack(spacing: 0) {
            controls
            Divider()
            if let anim = model.currentAnim {
                ScrollView(.vertical) {
                    HStack(alignment: .top, spacing: 0) {
                        VStack(spacing: 0) {
                            Color.clear.frame(height: 22)
                            ForEach(Array(anim.lanes.enumerated()), id: \.offset) { _, lane in
                                laneHeader(lane).frame(height: 44)
                                Divider()
                            }
                        }
                        .frame(width: headerWidth)
                        Divider()
                        ScrollView(.horizontal) {
                            VStack(spacing: 0) {
                                ruler(anim).frame(height: 22)
                                ForEach(Array(anim.lanes.enumerated()), id: \.offset) { _, lane in
                                    laneTrack(lane, anim).frame(height: 44)
                                    Divider()
                                }
                            }
                            .frame(width: CGFloat(anim.length) * frameWidth + 20, alignment: .leading)
                        }
                    }
                }
            } else {
                ContentUnavailableView("No animation selected", systemImage: "film")
            }
        }
        .background(Color(.secondarySystemBackground))
    }

    private var controls: some View {
        HStack(spacing: 14) {
            Button { model.stopPlayback(immediate: model.shift) } label: { Image(systemName: "stop.fill") }
            Button { model.togglePlay() } label: { Image(systemName: model.animationPlaying ? "pause.fill" : "play.fill") }
            Button { model.step(-1) } label: { Image(systemName: "backward.frame.fill") }
            Button { model.step(1) } label: { Image(systemName: "forward.frame.fill") }
            Toggle(isOn: Binding(get: { model.player?.snapToFramerate ?? false },
                                 set: { model.player?.snapToFramerate = $0; model.revision &+= 1 })) {
                Image(systemName: "metronome")
            }
            .toggleStyle(.button)
            .help("Snap to framerate")
            Divider().frame(height: 20)
            if let a = model.currentAnim {
                let t = Double(model.animationFrame) * Double(a.timestep)
                Text(String(format: "%04d/%04d", model.animationFrame, a.length)).monospacedDigit()
                Text(String(format: "%ds %03dms", Int(t), Int((t - floor(t)) * 1000))).monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                Button("Key All") { model.keyAllLanes() }
                Button("Delete Keys", role: .destructive) { model.removeKeysAtFrame() }
                Button { present(.editAnimation(model.currentAnimation)) } label: { Image(systemName: "slider.horizontal.3") }
            } else {
                Spacer()
            }
            Slider(value: $frameWidth, in: 4...40).frame(width: 120)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .disabled(model.currentAnim == nil)
    }

    private func laneHeader(_ lane: AnimationLane) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(lane.parameter?.name ?? "Missing").font(.caption.weight(.medium)).lineLimit(1)
                Text(lane.axis == 0 ? "X" : "Y").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Picker("Interpolation", selection: Binding(get: { lane.interpolation }, set: { lane.interpolation = $0; model.changed("Interpolation") })) {
                    Text("Nearest").tag(InterpolateMode.nearest)
                    Text("Stepped").tag(InterpolateMode.stepped)
                    Text("Linear").tag(InterpolateMode.linear)
                    Text("Cubic").tag(InterpolateMode.cubic)
                    Text("Bezier").tag(InterpolateMode.bezier)
                }
                Picker("Merge Mode", selection: Binding(get: { lane.mergeMode }, set: { lane.mergeMode = $0; model.changed("Merge mode") })) {
                    Text("Forced").tag(ParamMergeMode.forced)
                    Text("Additive").tag(ParamMergeMode.additive)
                    Text("Multiplicative").tag(ParamMergeMode.multiplicative)
                }
                Button("Delete Lane", role: .destructive) { model.deleteLane(lane) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
        .padding(.horizontal, 8)
    }

    private func ruler(_ anim: Animation) -> some View {
        Canvas { ctx, size in
            for f in stride(from: 0, through: anim.length, by: 1) {
                let x = CGFloat(f) * frameWidth + 10
                let major = f % 10 == 0
                var p = Path()
                p.move(to: CGPoint(x: x, y: size.height))
                p.addLine(to: CGPoint(x: x, y: major ? 6 : 14))
                ctx.stroke(p, with: .color(.secondary.opacity(major ? 0.8 : 0.4)))
                if major { ctx.draw(Text("\(f)").font(.system(size: 9)), at: CGPoint(x: x + 8, y: 6)) }
            }
            var head = Path()
            let hx = CGFloat(model.animationFrame) * frameWidth + 10
            head.move(to: CGPoint(x: hx, y: 0))
            head.addLine(to: CGPoint(x: hx, y: size.height))
            ctx.stroke(head, with: .color(.red), lineWidth: 2)
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { g in
            model.seek(Int(((g.location.x - 10) / frameWidth).rounded()))
        })
    }

    private func laneTrack(_ lane: AnimationLane, _ anim: Animation) -> some View {
        GeometryReader { geo in
            let h = geo.size.height
            Canvas { ctx, size in
                // Curve.
                if let p = lane.parameter, !lane.frames.isEmpty {
                    var curve = Path()
                    for f in 0...max(anim.length - 1, 0) {
                        let v = lane.value(at: Float(f))
                        let n = lane.axis == 0 ? p.mapValue(Vec2(v, p.min.y)).x : p.mapValue(Vec2(p.min.x, v)).y
                        let pt = CGPoint(x: CGFloat(f) * frameWidth + 10, y: (1 - CGFloat(n.isFinite ? n : 0)) * (size.height - 8) + 4)
                        if f == 0 { curve.move(to: pt) } else { curve.addLine(to: pt) }
                    }
                    ctx.stroke(curve, with: .color(.accentColor.opacity(0.6)), lineWidth: 1.5)
                    for k in lane.frames {
                        let n = lane.axis == 0 ? p.mapValue(Vec2(k.value, p.min.y)).x : p.mapValue(Vec2(p.min.x, k.value)).y
                        let c = CGPoint(x: CGFloat(k.frame) * frameWidth + 10, y: (1 - CGFloat(n.isFinite ? n : 0)) * (size.height - 8) + 4)
                        var d = Path()
                        d.move(to: CGPoint(x: c.x, y: c.y - 6)); d.addLine(to: CGPoint(x: c.x + 6, y: c.y))
                        d.addLine(to: CGPoint(x: c.x, y: c.y + 6)); d.addLine(to: CGPoint(x: c.x - 6, y: c.y)); d.closeSubpath()
                        ctx.fill(d, with: .color(k.frame == model.animationFrame ? .orange : .yellow))
                        ctx.stroke(d, with: .color(.black.opacity(0.6)))
                    }
                }
                var head = Path()
                let hx = CGFloat(model.animationFrame) * frameWidth + 10
                head.move(to: CGPoint(x: hx, y: 0))
                head.addLine(to: CGPoint(x: hx, y: size.height))
                ctx.stroke(head, with: .color(.red.opacity(0.7)), lineWidth: 1)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { loc in
                let f = max(0, min(anim.length - 1, Int(((loc.x - 10) / frameWidth).rounded())))
                let n = Float(1 - (loc.y - 4) / max(h - 8, 1))
                model.toggleKeyframe(lane, frame: f, normalizedValue: min(max(n, 0), 1))
            }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    let f = max(0, min(anim.length - 1, Int(((g.location.x - 10) / frameWidth).rounded())))
                    if dragKey == nil {
                        let start = Int(((g.startLocation.x - 10) / frameWidth).rounded())
                        if lane.frames.contains(where: { $0.frame == start }) {
                            dragKey = (ObjectIdentifier(lane), start)
                        } else {
                            model.seek(f)
                            return
                        }
                    }
                    if let dk = dragKey, dk.lane == ObjectIdentifier(lane), let p = lane.parameter {
                        let n = Float(1 - (g.location.y - 4) / max(h - 8, 1))
                        let nv = min(max(n, 0), 1)
                        let v = lane.axis == 0 ? p.unmapValue(Vec2(nv, 0)).x : p.unmapValue(Vec2(0, nv)).y
                        model.moveKeyframe(lane, from: dk.frame, to: f, value: v)
                        dragKey = (dk.lane, f)
                    }
                }
                .onEnded { _ in
                    if dragKey != nil { model.commitPending() }
                    dragKey = nil
                })
        }
    }
}

/// Creator's New / Edit Animation window.
struct EditAnimationSheet: View {
    @ObservedObject var model: EditorModel
    let name: String?
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var additive = false
    @State private var weight: Float = 1
    @State private var length = 100
    @State private var leadIn = 0
    @State private var leadOut = 0
    @State private var fpsChoice = 60
    @State private var customFPS: Float = 60
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $newName)
                Toggle("Additive", isOn: $additive)
                LabeledContent("Weight") {
                    Slider(value: $weight, in: 0...1).frame(width: 200)
                }
                Stepper("Frames: \(length)", value: Binding(get: { length }, set: { length = max(1, $0); leadOut = length }), in: 1...100_000)
                Stepper("Lead In: \(leadIn)", value: $leadIn, in: 0...max(length, 0))
                Stepper("Lead Out: \(leadOut)", value: $leadOut, in: 0...max(length, 0))
                Picker("Framerate", selection: $fpsChoice) {
                    Text("120 FPS").tag(120)
                    Text("60 FPS").tag(60)
                    Text("30 FPS").tag(30)
                    Text("25 FPS").tag(25)
                    Text("Custom").tag(0)
                }
                if fpsChoice == 0 {
                    LabeledContent("Custom framerate") {
                        TextField("FPS", value: $customFPS, format: .number).multilineTextAlignment(.trailing)
                    }
                }
                let fps = Double(fpsChoice == 0 ? max(customFPS, 1) : Float(fpsChoice))
                let seconds = Double(length) / fps
                LabeledContent("Duration", value: String(format: "%ds %03dms", Int(seconds), Int((seconds - floor(seconds)) * 1000)))
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle(name == nil ? "New Animation" : "Edit \(name!)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(name == nil ? "Create" : "Save") { save() }
                }
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        guard let name, let a = model.puppet?.animations[name] else {
            newName = "Animation \((model.puppet?.animations.count ?? 0) + 1)"
            return
        }
        newName = name
        additive = a.additive
        weight = a.weight
        length = a.length
        leadIn = max(a.leadIn, 0)
        leadOut = max(a.leadOut, 0)
        let fps = a.fps
        if [120, 60, 30, 25].contains(fps) { fpsChoice = fps } else { fpsChoice = 0; customFPS = Float(fps) }
    }

    private func save() {
        let a = name.flatMap { model.puppet?.animations[$0] } ?? Animation()
        a.additive = additive
        a.weight = weight
        a.length = length
        a.leadIn = leadIn
        a.leadOut = leadOut
        a.timestep = 1 / (fpsChoice == 0 ? max(customFPS, 1) : Float(fpsChoice))
        if let e = model.saveAnimation(oldName: name, name: newName, anim: a) {
            error = e
        } else {
            dismiss()
        }
    }
}
