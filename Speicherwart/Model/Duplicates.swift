import CryptoKit
import Foundation

struct DupFile: Identifiable, Sendable, Hashable {
    let url: URL
    let created: Date?
    /// APFS-Klon möglich: Löschen spart dann evtl. keinen Platz.
    let mayBeClone: Bool
    var id: String { url.path }
    var displayPath: String { Analyzer.tilde(url.path) }
}

struct DuplicateGroup: Identifiable, Sendable {
    let id: String
    let size: Int64
    var files: [DupFile]
    var wasted: Int64 { size * Int64(max(0, files.count - 1)) }
}

enum DuplicateFinder {
    /// Ordner, die nie durchsucht werden (Build-Ausgaben, Abhängigkeiten, Versionsverwaltung).
    static let skipDirs: Set<String> = [
        "Library", "node_modules", "target", ".git", "build", "Build", "dist", "DerivedData", "Pods", ".build",
        "venv", ".venv", "SourcePackages", "Carthage", "Intermediates.noindex", ".swiftpm",
    ]

    static func find(minSize: Int64, progress: @escaping @Sendable (String) -> Void) -> [DuplicateGroup] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .linkCountKey,
            .creationDateKey, .mayShareFileContentKey,
        ]
        let tracker = HardlinkTracker()
        var bySize: [Int64: [URL]] = [:]
        var scanned = 0

        // 1. Alle Dateien ab Mindestgröße nach Größe gruppieren.
        guard let en = fm.enumerator(
            at: Paths.home, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in true }
        ) else { return [] }
        for case let url as URL in en {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isSymbolicLink != true else { continue }
            if v.isDirectory == true {
                if skipDirs.contains(url.lastPathComponent) { en.skipDescendants() }
                continue
            }
            guard v.isRegularFile == true, let size = v.fileSize, Int64(size) >= minSize else { continue }
            guard tracker.firstSighting(url, linkCount: v.linkCount) else { continue }
            bySize[Int64(size), default: []].append(url)
            scanned += 1
            if scanned % 500 == 0 { progress("\(scanned) Dateien gefunden …") }
        }

        // 2. Anfang + Ende vergleichen, 3. bei Treffern komplett hashen.
        let candidates = bySize.filter { $0.value.count > 1 }
        var groups: [DuplicateGroup] = []
        var checked = 0
        for (size, urls) in candidates.sorted(by: { $0.key > $1.key }) {
            checked += 1
            progress("Vergleiche Gruppe \(checked) von \(candidates.count) …")
            let byQuick = Dictionary(grouping: urls) { quickHash($0, size: size) ?? UUID().uuidString }
            for (_, quickSame) in byQuick where quickSame.count > 1 {
                let byFull = Dictionary(grouping: quickSame) { fullHash($0) ?? UUID().uuidString }
                for (hash, same) in byFull where same.count > 1 {
                    let files = same.map { url -> DupFile in
                        let v = try? url.resourceValues(forKeys: Set(keys))
                        return DupFile(url: url, created: v?.creationDate, mayBeClone: v?.mayShareFileContent == true)
                    }
                    .sorted { ($0.created ?? .distantFuture) < ($1.created ?? .distantFuture) }
                    groups.append(DuplicateGroup(id: hash, size: size, files: files))
                }
            }
        }
        return groups.sorted { $0.wasted > $1.wasted }
    }

    private static func quickHash(_ url: URL, size: Int64) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let chunk = 64 * 1024
        var hasher = SHA256()
        if let head = try? h.read(upToCount: chunk) { hasher.update(data: head) }
        if size > Int64(chunk * 2) {
            try? h.seek(toOffset: UInt64(size) - UInt64(chunk))
            if let tail = try? h.read(upToCount: chunk) { hasher.update(data: tail) }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func fullHash(_ url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while true {
            let ok: Bool = autoreleasepool {
                guard let data = try? h.read(upToCount: 4 * 1024 * 1024), !data.isEmpty else { return false }
                hasher.update(data: data)
                return true
            }
            if !ok { break }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
