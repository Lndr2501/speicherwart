import Foundation

struct CloudFile: Identifiable, Sendable, Hashable {
    let url: URL
    let size: Int64
    /// false = lokale Änderung noch nicht hochgeladen → nicht entfernbar.
    let canEvict: Bool
    var id: String { url.path }
    var name: String { url.lastPathComponent }
}

struct CloudDomain: Identifiable, Sendable {
    let url: URL
    /// true = aktives Cloud-Konto (File Provider); false = verwaiste lokale Kopie.
    let isActive: Bool
    let localSize: Int64
    /// Lokal geladene Dateien (nur aktive Konten), größte zuerst.
    let files: [CloudFile]
    var id: String { url.path }

    var folderName: String { url.lastPathComponent }
    /// "SeaDrive-accounts(seafile.drydev.eu)" → "SeaDrive"
    var provider: String { String(folderName.split(separator: "-", maxSplits: 1).first ?? Substring(folderName)) }
    var account: String {
        let parts = folderName.split(separator: "-", maxSplits: 1)
        return parts.count > 1 ? String(parts[1]) : ""
    }
    var evictableSize: Int64 { files.filter(\.canEvict).reduce(0) { $0 + $1.size } }
    var blockedCount: Int { files.filter { !$0.canEvict }.count }
}

enum CloudScanner {
    static let root = Paths.inHome("Library/CloudStorage")

    private static let keys: [URLResourceKey] = [
        .isRegularFileKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
        .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .ubiquitousItemIsUploadedKey,
        .ubiquitousItemHasUnresolvedConflictsKey,
    ]

    static func scan() -> [CloudDomain] {
        let kids = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        var result: [CloudDomain] = []
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: kids.count) { i in
            let d = scanDomain(kids[i])
            lock.lock(); result.append(d); lock.unlock()
        }
        return result.sorted { ($0.isActive ? 0 : 1, -$0.localSize) < ($1.isActive ? 0 : 1, -$1.localSize) }
    }

    private static func scanDomain(_ url: URL) -> CloudDomain {
        // Verwaiste Kopien (Konto entfernt) liefern keine Cloud-Eigenschaften mehr.
        let active = (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true
        guard active else {
            return CloudDomain(url: url, isActive: false, localSize: SizeScanner.allocatedSize(of: url), files: [])
        }
        var total: Int64 = 0
        var files: [CloudFile] = []
        if let en = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }
        ) {
            for case let file as URL in en {
                guard let v = try? file.resourceValues(forKeys: Set(keys)),
                      v.isRegularFile == true, v.isSymbolicLink != true else { continue }
                let size = Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
                guard size > 0 else { continue }
                total += size
                let evictable = v.isUbiquitousItem == true
                    && v.ubiquitousItemDownloadingStatus == .current
                    && v.ubiquitousItemIsUploaded != false
                    && v.ubiquitousItemHasUnresolvedConflicts != true
                if file.lastPathComponent != ".DS_Store" {
                    files.append(CloudFile(url: file, size: size, canEvict: evictable))
                }
            }
        }
        return CloudDomain(url: url, isActive: true, localSize: total, files: files.sorted { $0.size > $1.size })
    }

    /// Entfernt lokale Kopien; die Dateien bleiben in der Cloud und laden beim Öffnen neu.
    static func evict(_ files: [CloudFile]) -> (freed: Int64, failures: [String]) {
        var freed: Int64 = 0
        var failures: [String] = []
        for f in files {
            guard f.canEvict, f.url.path.hasPrefix(root.path + "/") else {
                failures.append("\(f.name): noch nicht hochgeladen")
                continue
            }
            do {
                try FileManager.default.evictUbiquitousItem(at: f.url)
                freed += f.size
            } catch {
                failures.append("\(f.name): \(error.localizedDescription)")
            }
        }
        return (freed, failures)
    }
}
