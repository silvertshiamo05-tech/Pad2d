import SwiftUI
import Inochi2DKit

/// Parameter panel operations (Creator's panels/parameters.d).
@MainActor
final class ParameterClipboard {
    var parameter: Parameter?
    var keypoint: Keypoint?
    var bindings: [ParameterBinding] = []
}

extension EditorModel {
    static let clipboard = ParameterClipboard()

    func addParameter(_ preset: ParameterPreset) {
        guard let p = puppet?.addPresetParameter(preset) else { return }
        changed("Add parameter")
        _ = p
    }

    func deleteParameter(_ p: Parameter) {
        if armedID == p.uuid { arm(nil) }
        puppet?.deleteParameter(p)
        for a in puppet?.animations.values.map({ $0 }) ?? [] { a.lanes.removeAll { $0.parameter === p } }
        changed("Delete \(p.name)")
    }

    func duplicateParameter(_ p: Parameter) {
        puppet?.duplicateParameter(p)
        changed("Duplicate \(p.name)")
    }

    func setStartingPosition(_ p: Parameter) {
        p.defaults = p.value
        changed("Set starting position")
    }

    func flipAxis(_ p: Parameter, axis: Int) {
        p.reverseAxis(axis)
        changed("Flip axis")
    }

    func mirrorAll(_ p: Parameter, axis: Int) {
        p.mirrorAll(axis: axis)
        changed("Mirror all")
    }

    func mirroredAutofill(_ p: Parameter, axis: Int, upperHalf: Bool) {
        let range: ClosedRange<Float> = upperHalf ? 0.5001...1 : 0...0.4999
        puppet?.mirroredAutofill(p, axis: axis, range: range)
        changed("Mirrored autofill")
    }

    func convertTo2D(_ p: Parameter) {
        guard let n = puppet?.convertTo2D(p) else { return }
        if armedID == p.uuid { armedID = n.uuid }
        changed("Convert to 2D")
    }

    func copyParameter(_ p: Parameter) {
        Self.clipboard.parameter = puppet?.detachedCopy(p)
        revision &+= 1
    }

    func pasteParameter(into p: Parameter, flip: Bool) {
        guard let src = Self.clipboard.parameter else { return }
        puppet?.pasteParameter(src, into: p, flip: flip)
        changed(flip ? "Paste and flip" : "Paste")
    }

    func rename(_ p: Parameter, to name: String) -> String? {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, puppet?.parameters.contains(where: { $0 !== p && $0.name == n }) != true else {
            return "Name is already taken or empty"
        }
        puppet?.renameParameter(p, to: n)
        for a in puppet?.automation ?? [] { for i in a.bindings.indices where a.bindings[i].param === p { a.bindings[i].paramName = n } }
        return nil
    }

    func setMergeMode(_ p: Parameter, _ m: ParamMergeMode) {
        p.mergeMode = m
        changed("Merge mode")
    }

    // MARK: Keypoint actions (at the keypoint nearest the value)

    func keypointAction(_ p: Parameter, _ bindings: [ParameterBinding]?, _ action: KeypointAction) {
        let k = p.nearestKeypoint
        let list = bindings ?? p.bindings
        switch action {
        case .unset: for b in list { b.unset(k) }
        case .setCurrent: for b in list { b.setCurrent(k) }
        case .reset: for b in list { b.reset(k) }
        case .invert: for b in list { b.scaleValue(at: k, axis: -1, scale: -1) }
        case .mirror(let axis): for b in list { b.scaleValue(at: k, axis: axis, scale: -1) }
        case .flipDeform: for b in list where b.isDeform { puppet?.flipDeformation(b, at: k) }
        case .setFromMirror(let axis): puppet?.setFromMirror(p, bindings: bindings, at: k, axis: axis)
        case .copy:
            Self.clipboard.keypoint = k
            Self.clipboard.bindings = list
            revision &+= 1
            return
        case .paste:
            guard let ck = Self.clipboard.keypoint else { return }
            let clip = Self.clipboard.bindings
            var done = false
            for b in list {
                if let src = clip.first(where: { $0.node === b.node && $0.target == b.target }) {
                    src.copyKeypoint(ck, to: b, at: k)
                    done = true
                }
            }
            if !done, list.count == 1, clip.count == 1, let src = clip.first, let dest = list.first,
               src.isDeform == dest.isDeform {
                puppet?.pasteKeypoint(from: src, at: ck, to: dest, at: k)
            }
        }
        deform.reset()
        changed(action.title)
    }

    // MARK: Bindings

    func setInterpolation(_ bindings: [ParameterBinding], _ m: InterpolateMode) {
        for b in bindings { b.interpolation = m }
        changed("Interpolation")
    }

    func removeBindings(_ p: Parameter, _ bindings: [ParameterBinding]) {
        p.bindings.removeAll { b in bindings.contains { $0 === b } }
        changed("Remove binding")
    }

    /// Creator's "Copy to": copies the current keypoint of the bindings to another node.
    func copyBindings(_ p: Parameter, _ bindings: [ParameterBinding], to node: Node, swap: Bool) {
        let k = p.nearestKeypoint
        for b in bindings {
            guard let dest = p.getOrAddBinding(node: node, target: b.target) else { continue }
            if swap { b.swapKeypoint(k, with: dest, at: k) } else { b.copyKeypoint(k, to: dest, at: k) }
        }
        changed(swap ? "Swap bindings" : "Copy bindings")
    }

    /// Nodes the given bindings (all from one node) could be copied to.
    func compatibleNodes(_ p: Parameter, _ bindings: [ParameterBinding]) -> [Node] {
        guard let src = bindings.first?.node, bindings.allSatisfy({ $0.node === src }) else { return [] }
        let candidates = Set(p.bindings.compactMap { $0.node?.uuid })
        return (puppet?.root.allNodes() ?? []).filter { n in
            n !== src && candidates.contains(n.uuid) && bindings.allSatisfy { $0.isCompatible(with: n) }
        }
    }

    // MARK: Groups

    func newGroup(with params: [Parameter]) {
        guard let g = puppet?.addGroup(name: "New Parameter Group") else { return }
        for p in params { p.groupUUID = g.uuid }
        changed("New group")
    }

    func setGroup(_ p: Parameter, _ g: ParameterGroup?) {
        p.groupUUID = g?.uuid
        changed("Move parameter")
    }

    func deleteGroup(_ g: ParameterGroup) {
        puppet?.removeGroup(g)
        changed("Delete group")
    }

    // MARK: Axes

    func applyAxes(_ p: Parameter, axis: Int, points: [(position: Float, original: Int?)]) {
        puppet?.setAxisPoints(p, axis: axis, interior: points)
        changed("Edit axis points")
    }

    func split(_ p: Parameter, moving nodes: [Node]) {
        guard puppet?.splitParameter(p, moving: nodes) != nil else { return }
        changed("Split parameter")
    }
}

enum KeypointAction {
    case unset, setCurrent, reset, invert, flipDeform, copy, paste
    case mirror(Int)
    case setFromMirror(Int)

    var title: String {
        switch self {
        case .unset: return "Unset"
        case .setCurrent: return "Set to current"
        case .reset: return "Reset"
        case .invert: return "Invert"
        case .flipDeform: return "Flip deform"
        case .copy: return "Copy"
        case .paste: return "Paste"
        case .mirror: return "Mirror"
        case .setFromMirror: return "Set from mirror"
        }
    }
}
