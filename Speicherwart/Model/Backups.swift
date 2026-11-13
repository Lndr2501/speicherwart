import Foundation

struct BackupEntry: Identifiable, Sendable, Hashable {
    enum Kind: Sendable { case iosBackup, iosUpdate }
    let url: URL
    let title: String
    let subtitle: String
    let date: Date?
    let size: Int64
    let kind: Kind
    var id: String { url.path }
}

struct LocalSnapshot: Identifiable, Sendable, Hashable {
    let name: String
    let date: Date?
    var id: String { name }
}

struct BackupsResult: Sendable {
    var iosBackups: [BackupEntry] = []
    var iosUpdates: [BackupEntry] = []
    var snapshots: [LocalSnapshot] = []
}

enum Backups {
    static func load() -> BackupsResult {
        BackupsResult(iosBackups: iosBackups(), iosUpdates: iosUpdates(), snapshots: localSnapshots())
    }

    /// Geräte-Backups von iPhone/iPad (Finder-Sync).
    static func iosBackups() -> [BackupEntry] {
        let dir = Paths.inHome("Library/Application Support/MobileSync/Backup")
        let kids = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return kids.compactMap { url -> BackupEntry? in
            let info = NSDictionary(contentsOf: url.appendingPathComponent("Info.plist"))
            guard info != nil || FileManager.default.fileExists(atPath: url.appendingPathComponent("Manifest.db").path)
            else { return nil }
            let device = info?["Device Name"] as? String ?? url.lastPathComponent
            let product = info?["Product Type"] as? String
            let version = info?["Product Version"] as? String
            let subtitle = [product, version.map { "iOS \($0)" }].compactMap { $0 }.joined(separator: " · ")
            return BackupEntry(
                url: url, title: device, subtitle: subtitle,
                date: info?["Last Backup Date"] as? Date,
                size: SizeScanner.allocatedSize(of: url), kind: .iosBackup
            )
        }
        .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    /// Heruntergeladene iOS-/iPadOS-Updates (.ipsw).
    static func iosUpdates() -> [BackupEntry] {
        let dirs = ["iPhone Software Updates", "iPad Software Updates", "iPod Software Updates"]
            .map { Paths.inHome("Library/iTunes/\($0)") }
        var result: [BackupEntry] = []
        for dir in dirs {
            let kids = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey]
            )) ?? []
            for url in kids where url.pathExtension == "ipsw" {
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                result.append(BackupEntry(
                    url: url, title: url.lastPathComponent, subtitle: dir.lastPathComponent, date: date,
                    size: SizeScanner.allocatedSize(of: url), kind: .iosUpdate
                ))
            }
        }
        return result.sorted { $0.size > $1.size }
    }

    /// Lokale Time-Machine-Schnappschüsse. macOS gibt sie bei Platzmangel selbst frei.
    static func localSnapshots() -> [LocalSnapshot] {
        guard let out = Shell.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"]), out.status == 0,
              let text = String(data: out.output, encoding: .utf8) else { return [] }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd-HHmmss"
        return text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("com.apple.TimeMachine.") }
            .map { name in
                let stamp = name.replacingOccurrences(of: "com.apple.TimeMachine.", with: "")
                    .replacingOccurrences(of: ".local", with: "")
                return LocalSnapshot(name: name, date: fmt.date(from: stamp))
            }
    }
}

enum Trasher {
    /// Verschiebt Dateien in den Papierkorb (rückgängig machbar). Nur innerhalb von Home und /Applications.
    static func moveToTrash(_ urls: [URL]) -> (moved: [URL], failures: [String]) {
        let home = Paths.home.resolvingSymlinksInPath().path + "/"
        var moved: [URL] = []
        var failures: [String] = []
        for url in urls {
            let path = url.resolvingSymlinksInPath().path
            let trash = Paths.inHome(".Trash").path + "/"
            guard (path.hasPrefix(home) || path.hasPrefix("/Applications/")), !path.hasPrefix(trash) else {
                failures.append("\(url.lastPathComponent): außerhalb erlaubter Ordner")
                continue
            }
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                moved.append(url)
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return (moved, failures)
    }
}
