import SwiftUI

/// Inochi Creator's settings, stored in UserDefaults.
enum AppSettings {
    private static var d: UserDefaults { .standard }

    static var autosaveEnabled: Bool {
        get { d.object(forKey: "AutosaveEnabled") as? Bool ?? true }
        set { d.set(newValue, forKey: "AutosaveEnabled") }
    }
    /// Minutes between autosaves (1...1440).
    static var autosaveInterval: Int {
        get { d.object(forKey: "AutosaveInterval") as? Int ?? 5 }
        set { d.set(min(max(newValue, 1), 1440), forKey: "AutosaveInterval") }
    }
    /// Autosaves kept per project (1...1000).
    static var autosaveLimit: Int {
        get { d.object(forKey: "AutosaveFileLimit") as? Int ?? 3 }
        set { d.set(min(max(newValue, 1), 1000), forKey: "AutosaveFileLimit") }
    }
    /// "Ask", "Preserve" or "NotPreserve" for PSD folder structure.
    static var keepLayerFolder: String {
        get { d.string(forKey: "KeepLayerFolder") ?? "Ask" }
        set { d.set(newValue, forKey: "KeepLayerFolder") }
    }
    /// "Ask" or "dontSave" when leaving a modified project.
    static var saveOnClose: String {
        get { d.string(forKey: "SaveProjectOnClose") ?? "Ask" }
        set { d.set(newValue, forKey: "SaveProjectOnClose") }
    }
    static var scrollToArmed: Bool {
        get { d.object(forKey: "EnableParamAutoScroll") as? Bool ?? true }
        set { d.set(newValue, forKey: "EnableParamAutoScroll") }
    }
    static var zoomSpeed: Double {
        get { d.object(forKey: "ViewportZoomSpeed") as? Double ?? 5 }
        set { d.set(min(max(newValue, 1), 50), forKey: "ViewportZoomSpeed") }
    }
    static var nerdStats: Bool {
        get { d.bool(forKey: "NerdStats") }
        set { d.set(newValue, forKey: "NerdStats") }
    }
}

/// Recently opened or saved projects (max 10, newest first).
enum RecentProjects {
    static var list: [URL] {
        (UserDefaults.standard.stringArray(forKey: "prev_projects") ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func add(_ url: URL) {
        var l = UserDefaults.standard.stringArray(forKey: "prev_projects") ?? []
        l.removeAll { $0 == url.path }
        l.insert(url.path, at: 0)
        UserDefaults.standard.set(Array(l.prefix(10)), forKey: "prev_projects")
    }
}

/// Periodic backups and crash recovery (Creator's io/autosave.d).
@MainActor
enum Autosave {
    private static var lastSave = Date()

    static var root: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("autosaves", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func folder(for project: URL) -> URL {
        let name = project.deletingPathExtension().lastPathComponent
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func lockFile(_ project: URL) -> URL { folder(for: project).appendingPathComponent("creator-project.lock") }

    /// Backups for a project, oldest first.
    static func backups(for project: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder(for: project), includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension == "inx" }.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a < b
        }
    }

    /// Whether the app stopped unexpectedly after an autosave of this project.
    static func needsRecovery(_ project: URL) -> Bool {
        FileManager.default.fileExists(atPath: lockFile(project).path) && !backups(for: project).isEmpty
    }

    /// Called after every committed edit: saves a backup when the interval has passed.
    static func tick(_ model: EditorModel) {
        guard AppSettings.autosaveEnabled,
              Date().timeIntervalSince(lastSave) >= Double(AppSettings.autosaveInterval) * 60,
              let puppet = model.puppet else { return }
        lastSave = Date()
        let project = model.saveURL
        let data = puppet.fileData()
        let dir = folder(for: project)
        let name = project.deletingPathExtension().lastPathComponent
        let file = dir.appendingPathComponent("\(name)_\(Int(Date().timeIntervalSince1970)).inx")
        let limit = AppSettings.autosaveLimit
        let lock = lockFile(project)
        let existing = backups(for: project)
        Task.detached(priority: .background) {
            try? data.write(to: file, options: .atomic)
            var list = existing
            while list.count >= limit, let first = list.first {
                try? FileManager.default.removeItem(at: first)
                list.removeFirst()
            }
            FileManager.default.createFile(atPath: lock.path, contents: Data())
        }
    }

    static func didSave(_ project: URL) {
        try? FileManager.default.removeItem(at: lockFile(project))
        lastSave = Date()
    }

    static func releaseLock(_ project: URL) {
        try? FileManager.default.removeItem(at: lockFile(project))
    }
}
