import Foundation

/// Kapazität des Startvolumes.
struct DiskInfo: Sendable {
    let name: String
    let total: Int64
    /// Frei inkl. löschbarer Daten (wie im Finder angezeigt).
    let available: Int64

    var used: Int64 { max(0, total - available) }

    static func current() -> DiskInfo? {
        let url = URL(fileURLWithPath: "/")
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
            .volumeLocalizedNameKey,
        ]
        guard let v = try? url.resourceValues(forKeys: keys), let total = v.volumeTotalCapacity else {
            return nil
        }
        let available = v.volumeAvailableCapacityForImportantUsage ?? Int64(v.volumeAvailableCapacity ?? 0)
        return DiskInfo(name: v.volumeLocalizedName ?? "Macintosh HD", total: Int64(total), available: available)
    }
}

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static func inHome(_ relative: String) -> URL { home.appendingPathComponent(relative) }
    static let temp = FileManager.default.temporaryDirectory
}

/// Merkt sich Dateien mit mehreren Hardlinks, damit sie nur einmal zählen (wie `du`).
final class HardlinkTracker: @unchecked Sendable {
    private var seen = Set<UInt64>()
    private let lock = NSLock()

    /// true, wenn die Datei zum ersten Mal gesehen wird (oder nur einen Link hat).
    func firstSighting(_ url: URL, linkCount: Int?) -> Bool {
        guard let linkCount, linkCount > 1 else { return true }
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return true }
        let key = (UInt64(UInt32(bitPattern: st.st_dev)) << 40) ^ UInt64(st.st_ino)
        lock.lock(); defer { lock.unlock() }
        return seen.insert(key).inserted
    }
}

enum SizeScanner {
    static let keys: [URLResourceKey] = [
        .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey, .linkCountKey,
        .isSymbolicLinkKey, .isDirectoryKey, .contentModificationDateKey,
    ]

    /// Belegter Speicher einer Datei oder eines Ordners (rekursiv), Hardlinks einmal gezählt.
    /// Mit `cutoff` zählen nur Dateien, die vor diesem Datum zuletzt geändert wurden.
    static func allocatedSize(
        of url: URL, olderThan cutoff: Date? = nil, tracker: HardlinkTracker = HardlinkTracker()
    ) -> Int64 {
        guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return 0 }
        if v.isSymbolicLink == true { return 0 }
        if v.isDirectory != true { return fileSize(url, v, cutoff, tracker) }
        guard let en = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }
        ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in en {
            if let fv = try? file.resourceValues(forKeys: Set(keys)) { total += fileSize(file, fv, cutoff, tracker) }
        }
        return total
    }

    static func fileSize(_ url: URL, _ v: URLResourceValues, _ cutoff: Date?, _ tracker: HardlinkTracker) -> Int64 {
        guard v.isRegularFile == true else { return 0 }
        if let cutoff, let modified = v.contentModificationDate, modified > cutoff { return 0 }
        guard tracker.firstSighting(url, linkCount: v.linkCount) else { return 0 }
        return Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
    }
}

enum Shell {
    @discardableResult
    static func run(_ path: String, _ args: [String]) -> (status: Int32, output: Data)? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, data)
    }
}

/// Prüft, ob die App Festplattenvollzugriff hat (TCC-Datenbank ist sonst gesperrt).
enum Permissions {
    static var hasFullDiskAccess: Bool {
        let fd = open("/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)
        if fd >= 0 { close(fd); return true }
        return false
    }

    static let fullDiskAccessSettings = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    )!
}

func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
