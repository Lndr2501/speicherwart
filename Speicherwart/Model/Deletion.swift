import Foundation

/// Etwas, das der Nutzer löschen will (aus Übersicht, Treemap, Tabellen …).
struct DeleteTarget: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    /// Größe laut Anzeige; nur fürs Nachführen der Ansichten, nicht für die Sicherheit.
    let size: Int64
    var id: String { url.path }

    init(url: URL, size: Int64, name: String? = nil) {
        self.url = url
        self.size = size
        self.name = name ?? url.lastPathComponent
    }
}

extension FileEntry {
    var deleteTarget: DeleteTarget { DeleteTarget(url: url, size: size, name: name) }
}

extension FolderUsage {
    var deleteTarget: DeleteTarget { DeleteTarget(url: url, size: size, name: displayName) }
}

/// Zentrale Sicherung: was darf überhaupt gelöscht werden, und wovor wird vorher gewarnt.
enum DeleteGuard {
    /// Pfad, der tatsächlich entfernt würde: Ordner davor aufgelöst, der Eintrag selbst nicht.
    /// So wird bei einem Symlink nur der Link entfernt, nie sein Ziel.
    private static func effectivePath(_ url: URL) -> String {
        let parent = url.standardizedFileURL.deletingLastPathComponent().resolvingSymlinksInPath()
        return parent.appendingPathComponent(url.lastPathComponent).path
    }

    private static let home = Paths.home.resolvingSymlinksInPath().path

    private static func inHome(_ relative: String) -> String { home + "/" + relative }

    /// Ordner, die als Ganzes nie gelöscht werden; ihre Inhalte schon.
    private static let protectedFolders: Set<String> = {
        let system = ["/", "/Applications", "/Library", "/System", "/Users", "/Volumes", "/private", "/usr", "/bin", "/sbin"]
        let inHomeFolders = [
            "Library", "Library/Application Support", "Library/CloudStorage", "Library/Containers",
            "Library/Group Containers", "Library/Mobile Documents", "Library/Preferences",
            "Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures", "Public", "Applications",
        ].map { home + "/" + $0 }
        return Set(system + [home] + inHomeFolders)
    }()

    /// Alles darunter ist tabu (Schlüssel, Passwörter).
    private static let secretFolders: [String] = ["Library/Keychains", ".ssh", ".gnupg"].map { inHome($0) }

    private static var trashFolder: String { inHome(".Trash") }

    /// Grund, warum nicht gelöscht wird; nil = erlaubt.
    static func blockReason(_ url: URL) -> String? {
        let path = effectivePath(url)
        if path == trashFolder || path.hasPrefix(trashFolder + "/") {
            return "Den Papierkorb leerst du im Menü unter „Müll“."
        }
        if secretFolders.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            return "Enthält Schlüssel oder Passwörter."
        }
        if protectedFolders.contains(path) {
            return "Wichtiger Ordner. Lösche stattdessen einzelne Inhalte."
        }
        guard path.hasPrefix(home + "/") || path.hasPrefix("/Applications/") else {
            return "Liegt außerhalb von Home und Programme."
        }
        return nil
    }

    /// Hinweise, die im Bestätigungsdialog stehen.
    static func warnings(for targets: [DeleteTarget]) -> [String] {
        let fm = FileManager.default
        var out: [String] = []
        let cloudRoots = [inHome("Library/CloudStorage"), inHome("Library/Mobile Documents")]
        if targets.contains(where: { t in cloudRoots.contains { t.url.path.hasPrefix($0 + "/") } }) {
            out.append("Liegt in einem Cloud-Ordner. Bei aktiven Konten wird auch die Cloud-Kopie gelöscht.")
        }
        let repos = targets.filter { fm.fileExists(atPath: $0.url.appendingPathComponent(".git").path) }
        if !repos.isEmpty {
            let names = repos.prefix(2).map(\.name).joined(separator: ", ")
            out.append("Git-Repository (\(names)\(repos.count > 2 ? " …" : "")): Nicht gepushte Änderungen gehen verloren.")
        }
        return out
    }

    /// Entfernt Einträge, deren Elternordner ebenfalls dabei ist, und Doppelte.
    static func collapsed(_ targets: [DeleteTarget]) -> [DeleteTarget] {
        var seen = Set<String>()
        let unique = targets.filter { seen.insert($0.id).inserted }
        return unique.filter { t in
            !unique.contains { $0.id != t.id && t.id.hasPrefix($0.id + "/") }
        }
    }
}

extension AnalysisResult {
    /// Führt eine Löschung nach, ohne neu zu analysieren: Ordnergrößen, Gesamtsumme und Dateiliste.
    /// Im Papierkorb wächst dessen Eintrag um die verschobene Größe (der Platz wird erst beim Leeren frei).
    func removing(_ targets: [DeleteTarget], toTrash: Bool) -> AnalysisResult {
        let homePrefix = Paths.home.path + "/"
        let trash = Paths.inHome(".Trash").path
        var folders = self.folders
        var big = bigFiles
        var homeTotal = self.homeTotal
        var trashGain: Int64 = 0

        for t in targets {
            let p = t.url.path
            folders.removeAll { $0.path == p || $0.path.hasPrefix(p + "/") }
            folders = folders.map { f in
                p.hasPrefix(f.path + "/") ? FolderUsage(path: f.path, size: max(0, f.size - t.size)) : f
            }
            big.removeAll { $0.path == p || $0.path.hasPrefix(p + "/") }
            if p.hasPrefix(homePrefix) { homeTotal = max(0, homeTotal - t.size) }
            if toTrash { trashGain += t.size }
        }
        if trashGain > 0 {
            homeTotal += trashGain
            if let i = folders.firstIndex(where: { $0.path == trash }) {
                folders[i] = FolderUsage(path: trash, size: folders[i].size + trashGain)
            } else {
                folders.append(FolderUsage(path: trash, size: trashGain))
            }
        }
        return AnalysisResult(
            date: date, duration: duration, homeTotal: homeTotal,
            folders: folders.sorted { $0.size > $1.size }, bigFiles: big
        )
    }
}
