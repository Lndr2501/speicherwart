import AppKit
import ServiceManagement
import SwiftUI

@main
enum Entry {
    static func main() {
        // `Speicherwart --report` gibt den Scan im Terminal aus, ohne etwas zu löschen.
        if CommandLine.arguments.contains("--duplicates") {
            let start = Date()
            let groups = DuplicateFinder.find(minSize: 10_000_000) { _ in }
            let wasted = groups.reduce(Int64(0)) { $0 + $1.wasted }
            print(String(format: "Duplikate ab 10 MB: %d Gruppen, %@ doppelt, %.1f s", groups.count, formatBytes(wasted), Date().timeIntervalSince(start)))
            for g in groups.prefix(5) {
                print("  \(g.files.count) × \(formatBytes(g.size)): " + g.files.map(\.displayPath).joined(separator: " | "))
            }
            return
        }
        if CommandLine.arguments.contains("--analyze") {
            Report.analyze()
            return
        }
        if CommandLine.arguments.contains("--report") {
            Report.run()
            return
        }
        SpeicherwartApp.main()
    }
}

struct SpeicherwartApp: App {
    @State private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            PopoverView(state: state)
        } label: {
            MenuBarLabel(state: state)
        }
        .menuBarExtraStyle(.window)

        Window("Speicher-Analyse", id: "analysis") {
            AnalysisView(state: state)
        }
        .defaultSize(width: 900, height: 620)
    }
}

enum Report {
    static func run() {
        let start = Date()
        if let d = DiskInfo.current() {
            print("\(d.name): \(formatBytes(d.used)) belegt, \(formatBytes(d.available)) frei von \(formatBytes(d.total))")
        }
        let ctx = MainActor.assumeIsolated { CleanupContext.current() }
        let r = Scanner.fullScan(ctx)
        print("Festplattenvollzugriff: \(r.hasFullDiskAccess ? "ja" : "nein")")
        let login: String = switch SMAppService.mainApp.status {
        case .enabled: "aktiv"
        case .requiresApproval: "wartet auf Freigabe in den Systemeinstellungen"
        case .notRegistered: "aus"
        default: "nicht gefunden"
        }
        print("Autostart beim Anmelden: \(login)")
        print("\nKategorien:")
        for c in BarCategory.all {
            print("  \(c.name): \(formatBytes(r.categorySizes[c.id] ?? 0))")
        }
        print("\nAufräumbar:")
        for t in CleanupCatalog.targets {
            let res = r.cleanup[t.id] ?? CollectResult()
            let flag = t.enabledByDefault ? "[x]" : "[ ]"
            let denied = res.accessDenied ? " (kein Zugriff)" : ""
            print("  \(flag) \(t.name): \(formatBytes(res.total)) in \(res.items.count) Einträgen\(denied)")
            for item in res.items.prefix(3) {
                print("        \(item.name): \(formatBytes(item.size))")
            }
        }
        print(String(format: "\nScan-Dauer: %.1f s", Date().timeIntervalSince(start)))
    }

    static func analyze() {
        let a = Analyzer.run { _ in }
        print(String(format: "Tiefenanalyse: %.1f s, Home gesamt %@", a.duration, formatBytes(a.homeTotal)))
        print("\nGrößte Ordner:")
        for f in a.folders.prefix(10) { print("  \(f.displayName): \(formatBytes(f.size))") }
        print("\nGrößte Dateien (\(a.bigFiles.count) ab 100 MB):")
        for e in a.bigFiles.prefix(8) {
            let used = e.lastUsed.map { "benutzt \($0.formatted(date: .numeric, time: .omitted))" } ?? "ohne Spotlight-Datum"
            print("  \(formatBytes(e.size))  \(e.displayFolder)/\(e.name)  (\(used))")
        }
        let cutoff = Calendar.current.date(byAdding: .month, value: -6, to: Date())!
        let unused = a.bigFiles.filter { ($0.lastActivity ?? .distantFuture) < cutoff }
        print("\nSeit 6 Monaten ungenutzt: \(unused.count) Einträge, \(formatBytes(unused.reduce(0) { $0 + $1.size }))")
        print("Downloads ab 100 MB: \(a.bigFiles.filter(\.isInDownloads).count)")
        let b = Backups.load()
        print("\nBackups:")
        for e in b.iosBackups + b.iosUpdates {
            print("  \(e.title) (\(e.subtitle)) \(e.date.map { $0.formatted(date: .numeric, time: .omitted) } ?? "–"): \(formatBytes(e.size))")
        }
        print("  Time-Machine-Schnappschüsse: \(b.snapshots.count)")
        print("\nCloud:")
        for d in CloudScanner.scan() {
            let kind = d.isActive ? "aktiv" : "VERWAIST"
            print("  [\(kind)] \(d.folderName): \(formatBytes(d.localSize)) lokal, \(d.files.count) Dateien, entfernbar \(formatBytes(d.evictableSize))")
        }
    }
}
