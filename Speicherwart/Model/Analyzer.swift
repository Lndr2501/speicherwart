import CoreServices
import Foundation

struct FileEntry: Codable, Sendable, Identifiable, Hashable {
    let path: String
    let size: Int64
    let modified: Date?
    /// Aus Spotlight („Zuletzt geöffnet“); fehlt oft in ~/Library.
    let lastUsed: Date?
    let isPackage: Bool

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
    var name: String {
        let n = url.lastPathComponent
        // Hugging-Face-Modelle: "models--Systran--faster-whisper" → "Systran/faster-whisper"
        if n.hasPrefix("models--") { return n.dropFirst(8).replacingOccurrences(of: "--", with: "/") }
        if url.deletingLastPathComponent().lastPathComponent == "Backup",
           let device = NSDictionary(contentsOf: url.appendingPathComponent("Info.plist"))?["Device Name"] as? String {
            return "iOS-Backup: \(device)"
        }
        return n
    }
    var lastActivity: Date? { lastUsed ?? modified }
    var displayFolder: String { Analyzer.tilde(url.deletingLastPathComponent().path) }
    var isInDownloads: Bool { path.hasPrefix(Paths.inHome("Downloads").path + "/") }
    var isInCloud: Bool { path.hasPrefix(Paths.inHome("Library/CloudStorage").path + "/") }
    var isApp: Bool { path.hasSuffix(".app") }
}

struct FolderUsage: Codable, Sendable, Identifiable, Hashable {
    let path: String
    let size: Int64
    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
    var displayName: String { path == "/Applications" ? "Programme" : Analyzer.tilde(path) }
}

struct AnalysisResult: Codable, Sendable {
    let date: Date
    let duration: Double
    let homeTotal: Int64
    let folders: [FolderUsage]
    let bigFiles: [FileEntry]
}

/// Tiefenscan: geht das ganze Home + /Applications durch (dauert ca. 1–3 Minuten).
enum Analyzer {
    static let bigFileThreshold: Int64 = 100_000_000

    static func tilde(_ path: String) -> String {
        path.hasPrefix(Paths.home.path) ? "~" + path.dropFirst(Paths.home.path.count) : path
    }

    /// Ordner, die einzeln gemessen werden. ~/Library und Application Support werden aufgeklappt,
    /// weil dort sonst große Brocken (z.B. iOS-Backups) unsichtbar bleiben.
    static func buckets() -> [URL] {
        let fm = FileManager.default
        func kids(_ url: URL) -> [URL] {
            (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        }
        let library = Paths.inHome("Library")
        let appSupport = library.appendingPathComponent("Application Support")
        var result: [URL] = [URL(fileURLWithPath: "/Applications")]
        for k in kids(Paths.home) where k.lastPathComponent != "Library" { result.append(k) }
        for k in kids(library) where k.lastPathComponent != "Application Support" { result.append(k) }
        result += kids(appSupport)
        return result
    }

    /// Unterordner hiervon sind undurchsichtige Einheiten (z.B. ein iOS-Backup, ein KI-Modell)
    /// und erscheinen als ein Eintrag statt als hunderte Dateien mit Hash-Namen.
    static let opaqueParents: Set<String> = [
        "Library/Application Support/MobileSync/Backup",
        ".cache/huggingface/hub",
        "Library/Developer/CoreSimulator/Devices",
        "Library/Developer/Xcode/DerivedData",
        "Library/Developer/Xcode/Archives",
    ].reduce(into: Set<String>()) { $0.insert(Paths.inHome($1).path) }

    static func run(progress: @escaping @Sendable (Double) -> Void) -> AnalysisResult {
        let start = Date()
        let tracker = HardlinkTracker()
        let roots = buckets()
        let trash = Paths.inHome(".Trash").path
        let lock = NSLock()
        var folders: [FolderUsage] = []
        var big: [FileEntry] = []
        var done = 0

        DispatchQueue.concurrentPerform(iterations: roots.count) { i in
            let root = roots[i]
            var localBig: [FileEntry] = []
            let size = walk(root, collectBig: root.path != trash, tracker: tracker, big: &localBig)
            lock.lock()
            folders.append(FolderUsage(path: root.path, size: size))
            big += localBig
            done += 1
            let fraction = Double(done) / Double(roots.count)
            lock.unlock()
            progress(fraction)
        }

        let homeTotal = folders.filter { $0.path != "/Applications" }.reduce(Int64(0)) { $0 + $1.size }
        let withUsage = big.map { e in
            FileEntry(path: e.path, size: e.size, modified: e.modified, lastUsed: spotlightLastUsed(e.path), isPackage: e.isPackage)
        }
        return AnalysisResult(
            date: Date(),
            duration: Date().timeIntervalSince(start),
            homeTotal: homeTotal,
            folders: folders.filter { $0.size > 0 }.sorted { $0.size > $1.size },
            bigFiles: Array(withUsage.sorted { $0.size > $1.size }.prefix(1_000))
        )
    }

    private static let keys: [URLResourceKey] = SizeScanner.keys + [.isPackageKey]

    /// Summiert die Größe; Pakete (.app, .photoslibrary, VM-Bundles …) zählen als eine Datei.
    private static func walk(_ root: URL, collectBig: Bool, tracker: HardlinkTracker, big: inout [FileEntry]) -> Int64 {
        guard let rv = try? root.resourceValues(forKeys: Set(keys)), rv.isSymbolicLink != true else { return 0 }
        func record(_ url: URL, _ size: Int64, _ modified: Date?, package: Bool) {
            if collectBig, size >= bigFileThreshold {
                big.append(FileEntry(path: url.path, size: size, modified: modified, lastUsed: nil, isPackage: package))
            }
        }
        if rv.isDirectory != true || rv.isPackage == true {
            let size = SizeScanner.allocatedSize(of: root, tracker: tracker)
            record(root, size, rv.contentModificationDate, package: rv.isPackage == true)
            return size
        }
        guard let en = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in en {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isSymbolicLink != true else { continue }
            if v.isDirectory == true {
                if v.isPackage == true || opaqueParents.contains(url.deletingLastPathComponent().path) {
                    en.skipDescendants()
                    let size = SizeScanner.allocatedSize(of: url, tracker: tracker)
                    total += size
                    record(url, size, v.contentModificationDate, package: true)
                }
                continue
            }
            guard v.isRegularFile == true else { continue }
            let size = SizeScanner.fileSize(url, v, nil, tracker)
            guard size > 0 else { continue }
            total += size
            record(url, size, v.contentModificationDate, package: false)
        }
        return total
    }

    static func spotlightLastUsed(_ path: String) -> Date? {
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    // MARK: - Zwischenspeicher

    private static var cacheURL: URL {
        Paths.inHome("Library/Application Support/Speicherwart/analysis.json")
    }

    static func load() -> AnalysisResult? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? JSONDecoder().decode(AnalysisResult.self, from: data)
    }

    static func save(_ result: AnalysisResult) {
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(result).write(to: cacheURL, options: .atomic)
    }
}
