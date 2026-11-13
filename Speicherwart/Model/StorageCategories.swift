import Foundation

/// Kategorien für den Balken. Die Größe ergibt sich aus den Ordnern in `roots`.
struct BarCategory: Identifiable, Sendable {
    let id: String
    let name: String
    let roots: [URL]

    func contains(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return roots.contains { path.hasPrefix($0.standardizedFileURL.path + "/") }
    }

    /// Standard-Ordner im Home, die nicht zu "Eigene Ordner" zählen.
    static let standardHomeFolders: Set<String> = [
        "Library", "Documents", "Desktop", "Downloads", "Pictures", "Movies", "Music",
        "Applications", "Developer", "Projects", "Public", "Sites", "go",
    ]

    /// Ordner direkt im Home, die keinem Standard-Ordner entsprechen (z.B. Projekt-Ordner).
    static var ownHomeFolders: [URL] {
        let kids = (try? FileManager.default.contentsOfDirectory(
            at: Paths.home, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []
        return kids.filter {
            !standardHomeFolders.contains($0.lastPathComponent)
                && (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
    }

    /// Reihenfolge = Farb-Slot (fest, nie nach Größe umsortiert).
    static var all: [BarCategory] {
        [
            BarCategory(id: "apps", name: "Apps", roots: [
                URL(fileURLWithPath: "/Applications"), Paths.inHome("Applications"),
            ]),
            BarCategory(id: "appData", name: "App-Daten", roots: [
                Paths.inHome("Library/Application Support"), Paths.inHome("Library/Containers"),
                Paths.inHome("Library/Group Containers"),
            ]),
            BarCategory(id: "docs", name: "Dokumente", roots: [
                Paths.inHome("Documents"), Paths.inHome("Desktop"), Paths.inHome("Downloads"),
            ]),
            BarCategory(id: "own", name: "Eigene Ordner", roots: ownHomeFolders),
            BarCategory(id: "media", name: "Fotos & Medien", roots: [
                Paths.inHome("Pictures"), Paths.inHome("Movies"), Paths.inHome("Music"),
            ]),
            BarCategory(id: "dev", name: "Entwickler", roots: [
                Paths.inHome("Library/Developer"), Paths.inHome("Developer"), Paths.inHome("Projects"),
                Paths.inHome(".npm"), Paths.inHome(".gradle"), Paths.inHome(".cargo"), Paths.inHome(".cache"),
                Paths.inHome(".rustup"), Paths.inHome("go"), URL(fileURLWithPath: "/opt/homebrew"),
            ]),
            BarCategory(id: "cloud", name: "Cloud (lokal)", roots: [
                Paths.inHome("Library/CloudStorage"), Paths.inHome("Library/Mobile Documents"),
            ]),
        ]
    }
}

struct ScanResult: Sendable {
    var categorySizes: [String: Int64]
    var cleanup: [String: CollectResult]
    var hasFullDiskAccess: Bool
}

enum Scanner {
    /// Scannt Balken-Kategorien und alle Müll-Ziele parallel.
    static func fullScan(_ ctx: CleanupContext) -> ScanResult {
        let lock = NSLock()
        var sizes: [String: Int64] = [:]
        var cleanup: [String: CollectResult] = [:]

        let categories = BarCategory.all
        let targets = CleanupCatalog.targets
        let jobs = categories.count + targets.count

        let tracker = HardlinkTracker()
        DispatchQueue.concurrentPerform(iterations: jobs) { i in
            if i < categories.count {
                let c = categories[i]
                let size = c.roots.reduce(Int64(0)) { $0 + SizeScanner.allocatedSize(of: $1, tracker: tracker) }
                lock.lock(); sizes[c.id] = size; lock.unlock()
            } else {
                let t = targets[i - categories.count]
                let r = t.collect(ctx)
                lock.lock(); cleanup[t.id] = r; lock.unlock()
            }
        }
        return ScanResult(categorySizes: sizes, cleanup: cleanup, hasFullDiskAccess: Permissions.hasFullDiskAccess)
    }
}
