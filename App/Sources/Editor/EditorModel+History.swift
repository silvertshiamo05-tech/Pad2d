import SwiftUI
import Inochi2DKit

/// One step of undo history: the state after a named change.
struct HistoryEntry: Identifiable {
    let id = UUID()
    let label: String
    let snapshot: PuppetSnapshot
}

extension EditorModel {
    /// Starts history with the current state as "Opened".
    func resetHistory() {
        guard let puppet else { return }
        history = [HistoryEntry(label: "Opened", snapshot: puppet.snapshot())]
        historyIndex = 0
        pendingCommit = false
        objectWillChange.send()
    }

    var canUndo: Bool { historyIndex > 0 || pendingCommit }
    var canRedo: Bool { historyIndex < history.count - 1 }

    /// Call after changing the puppet. `commit` false for continuous edits
    /// (slider drags, gestures), followed by `commitPending()` when they end.
    func changed(_ label: String = "Edit", commit: Bool = true) {
        revision &+= 1
        dirty = true
        pendingCommit = true
        pendingLabel = label
        if commit { commitPending() }
    }

    func commitPending() {
        guard pendingCommit, let puppet else { return }
        pendingCommit = false
        history.removeSubrange((historyIndex + 1)...)
        history.append(HistoryEntry(label: pendingLabel, snapshot: puppet.snapshot()))
        historyIndex = history.count - 1
        // Keep within the configured length and ~150 MB.
        let limit = max(maxUndo, 1)
        var total = history.reduce(0) { $0 + $1.snapshot.byteCount }
        while history.count > limit + 1 || (total > 150 << 20 && history.count > 2) {
            total -= history.removeFirst().snapshot.byteCount
            historyIndex -= 1
        }
        Autosave.tick(self)
        objectWillChange.send()
    }

    func undo() {
        commitPending()
        guard historyIndex > 0 else { return }
        jump(to: historyIndex - 1)
    }

    func redo() {
        commitPending()
        guard historyIndex < history.count - 1 else { return }
        jump(to: historyIndex + 1)
    }

    /// Restores the state after history entry `i` (Creator's history panel).
    func jump(to i: Int) {
        commitPending()
        guard history.indices.contains(i), i != historyIndex else { return }
        historyIndex = i
        restore(history[i].snapshot)
    }

    func clearHistory() {
        resetHistory()
    }

    func setMaxUndo(_ n: Int) {
        maxUndo = min(max(n, 1), 1000)
        UserDefaults.standard.set(maxUndo, forKey: "MaxUndoHistory")
    }

    private func restore(_ snap: PuppetSnapshot) {
        let values = Dictionary((puppet?.parameters ?? []).map { ($0.uuid, $0.value) }, uniquingKeysWith: { a, _ in a })
        guard let p = try? Puppet(snapshot: snap) else { return }
        for param in p.parameters { if let v = values[param.uuid] { param.value = v } }
        if mode == .mesh {
            mode = .model
            meshSession = nil
        }
        install(p)
        syncTextures()
        selectedIDs = selectedIDs.filter { p.root.find(uuid: $0) != nil }
        if let id = armedID, !p.parameters.contains(where: { $0.uuid == id }) { armedID = nil }
        if let a = currentAnimation, p.animations[a] == nil { currentAnimation = nil }
        deform.reset()
        revision &+= 1
        dirty = true
    }
}
