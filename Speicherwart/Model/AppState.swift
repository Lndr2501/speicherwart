import AppKit
import Observation
import ServiceManagement
import SwiftUI
import UserNotifications
import WidgetKit

struct Segment: Identifiable {
    let id: String
    let name: String
    let bytes: Int64
}

@MainActor
@Observable
final class AppState {
    var disk: DiskInfo? = DiskInfo.current()
    var categorySizes: [String: Int64] = [:]
    var results: [String: CollectResult] = [:]
    var hasFullDiskAccess = Permissions.hasFullDiskAccess
    var isScanning = false
    var isCleaning = false
    var lastScan: Date?
    var lastCleanMessage: String?

    // Phase 2: Tiefenanalyse
    var analysis: AnalysisResult? = Analyzer.load()
    /// nil = keine Analyse läuft
    var analysisProgress: Double?
    var backups = BackupsResult()
    var backupsLoaded = false
    var trashMessage: String?
    /// Wartet auf Bestätigung im Löschdialog (gemeinsam für alle Ansichten).
    var pendingDelete: [DeleteTarget] = []
    var isRemoving = false
    /// Zuletzt entfernte Einträge; `removalTick` zählt hoch, damit Ansichten (Treemap) nachziehen.
    var lastRemoved: [DeleteTarget] = []
    var removalTick = 0

    // Phase 3: Cloud, Verlauf, Autostart
    var cloud: [CloudDomain] = []
    var cloudLoaded = false
    var isEvicting = false
    var history: [HistorySample] = History.load()

    // Phase 4
    var duplicates: [DuplicateGroup]?
    var duplicateProgress: String?
    var launchAtLogin = SMAppService.mainApp.status == .enabled {
        didSet {
            guard launchAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }

    var enabled: Set<String> {
        didSet { UserDefaults.standard.set(Array(enabled), forKey: Keys.enabled) }
    }
    var thresholdGB: Int {
        didSet { UserDefaults.standard.set(thresholdGB, forKey: Keys.threshold); refreshDisk() }
    }
    var showFreeInMenuBar: Bool {
        didSet { UserDefaults.standard.set(showFreeInMenuBar, forKey: Keys.showFree) }
    }

    private enum Keys {
        static let enabled = "enabledTargets"
        static let threshold = "warningThresholdGB"
        static let showFree = "showFreeInMenuBar"
        static let lastWarning = "lastWarningDate"
    }

    init() {
        let d = UserDefaults.standard
        if let saved = d.stringArray(forKey: Keys.enabled) {
            enabled = Set(saved)
        } else {
            enabled = Set(CleanupCatalog.targets.filter(\.enabledByDefault).map(\.id))
        }
        thresholdGB = d.object(forKey: Keys.threshold) as? Int ?? 50
        showFreeInMenuBar = d.object(forKey: Keys.showFree) as? Bool ?? true

        Notifier.shared.setUp()
        // Beim ersten Start automatisch als Anmeldeobjekt eintragen.
        if !d.bool(forKey: "didSetUpLaunchAtLogin") {
            d.set(true, forKey: "didSetUpLaunchAtLogin")
            // didSet greift im init nicht, darum direkt registrieren.
            try? SMAppService.mainApp.register()
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
        Task { await scan() }
        Task { [weak self] in
            while !Task.isCancelled {
                self?.refreshDisk()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    // MARK: - Abgeleitete Werte

    var isLow: Bool {
        guard let disk else { return false }
        return disk.available < Int64(thresholdGB) * 1_000_000_000
    }

    var selectedItems: [CleanupItem] {
        CleanupCatalog.targets
            .filter { enabled.contains($0.id) }
            .flatMap { results[$0.id]?.items ?? [] }
    }

    var selectedTotal: Int64 { selectedItems.reduce(0) { $0 + $1.size } }

    /// Balken-Segmente; ausgewählter Müll wird aus seiner Kategorie herausgerechnet.
    var segments: [Segment] {
        guard let disk, !categorySizes.isEmpty else { return [] }
        var sizes = categorySizes
        let junk = selectedItems
        for item in junk {
            if let cat = BarCategory.all.first(where: { $0.contains(item.url) }) {
                sizes[cat.id, default: 0] -= item.size
            }
        }
        var segs = BarCategory.all.map { Segment(id: $0.id, name: $0.name, bytes: max(0, sizes[$0.id] ?? 0)) }
        segs.append(Segment(id: "junk", name: "Müll", bytes: junk.reduce(0) { $0 + $1.size }))
        let known = segs.reduce(Int64(0)) { $0 + $1.bytes }
        segs.append(Segment(id: "other", name: "System & Sonstiges", bytes: max(0, disk.used - known)))
        return segs.filter { $0.bytes > 0 }
    }

    func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { self.enabled.contains(id) },
            set: { on in if on { self.enabled.insert(id) } else { self.enabled.remove(id) } }
        )
    }

    // MARK: - Aktionen

    func refreshDisk() {
        disk = DiskInfo.current()
        if let disk, let updated = History.recordIfDue(history, disk: disk, categories: categorySizes) {
            history = updated
            publishWidget(reload: true)
        } else {
            publishWidget(reload: false)
        }
        let d = UserDefaults.standard
        if isLow, let disk {
            let last = d.object(forKey: Keys.lastWarning) as? Date
            if last == nil || Date().timeIntervalSince(last!) > 86_400 {
                Notifier.shared.warnLowSpace(free: disk.available, thresholdGB: thresholdGB)
                d.set(Date(), forKey: Keys.lastWarning)
            }
        } else {
            // Wieder genug frei: beim nächsten Unterschreiten sofort warnen.
            d.removeObject(forKey: Keys.lastWarning)
        }
    }

    func scanIfStale() async {
        if let lastScan, Date().timeIntervalSince(lastScan) < 7_200 { return }
        await scan()
    }

    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        let ctx = CleanupContext.current()
        let result = await Task.detached(priority: .utility) { Scanner.fullScan(ctx) }.value
        categorySizes = result.categorySizes
        results = result.cleanup
        hasFullDiskAccess = result.hasFullDiskAccess
        lastScan = Date()
        isScanning = false
        refreshDisk()
        publishWidget(reload: true)
    }

    func clean() async {
        let items = selectedItems
        guard !items.isEmpty, !isCleaning else { return }
        isCleaning = true
        let result = await Task.detached(priority: .userInitiated) { Cleaner.perform(items) }.value
        isCleaning = false
        var msg = "\(formatBytes(result.freed)) freigegeben"
        if !result.failures.isEmpty { msg += " · \(result.failures.count) übersprungen (in Benutzung oder gesperrt)" }
        lastCleanMessage = msg
        await scan()
    }
}

extension AppState {
    func analyzeIfStale() async {
        if let a = analysis, Date().timeIntervalSince(a.date) < 86_400 { return }
        await analyze()
    }

    func analyze() async {
        guard analysisProgress == nil else { return }
        analysisProgress = 0
        let result = await Task.detached(priority: .utility) {
            Analyzer.run { p in
                Task { @MainActor [weak self] in
                    if let current = self?.analysisProgress, p > current { self?.analysisProgress = p }
                }
            }
        }.value
        Analyzer.save(result)
        analysis = result
        analysisProgress = nil
    }

    /// Schreibt die Werte fürs Widget in den App-Gruppen-Ordner.
    func publishWidget(reload: Bool) {
        guard let disk else { return }
        let wasLow = WidgetStore.load().map { $0.free < Int64($0.thresholdGB) * 1_000_000_000 }
        WidgetStore.save(WidgetSnapshot(
            date: Date(), free: disk.available, total: disk.total,
            junk: lastScan == nil ? nil : selectedTotal,
            change7d: History.freeChange(history, days: 7, now: disk),
            thresholdGB: thresholdGB
        ))
        if reload || wasLow != isLow { WidgetCenter.shared.reloadAllTimelines() }
    }

    func findDuplicates(minSize: Int64) async {
        guard duplicateProgress == nil else { return }
        duplicateProgress = "Suche Dateien …"
        let groups = await Task.detached(priority: .utility) {
            DuplicateFinder.find(minSize: minSize) { msg in
                Task { @MainActor [weak self] in
                    if self?.duplicateProgress != nil { self?.duplicateProgress = msg }
                }
            }
        }.value
        duplicates = groups
        duplicateProgress = nil
    }

    func loadCloud() async {
        cloud = await Task.detached(priority: .utility) { CloudScanner.scan() }.value
        cloudLoaded = true
    }

    func evict(_ files: [CloudFile]) async {
        guard !isEvicting else { return }
        isEvicting = true
        let r = await Task.detached(priority: .userInitiated) { CloudScanner.evict(files) }.value
        isEvicting = false
        var msg = "\(formatBytes(r.freed)) Downloads entfernt, Dateien bleiben in der Cloud"
        if !r.failures.isEmpty { msg += " · \(r.failures.count) übersprungen (noch nicht hochgeladen oder in Benutzung)" }
        trashMessage = msg
        await loadCloud()
        refreshDisk()
    }

    func loadBackups() async {
        backups = await Task.detached(priority: .utility) { Backups.load() }.value
        backupsLoaded = true
    }

    /// Öffnet den Löschdialog. Geschützte Einträge werden aussortiert und gemeldet.
    func requestDelete(_ targets: [DeleteTarget]) {
        guard !isRemoving else { return }
        var allowed: [DeleteTarget] = []
        var blocked: [String] = []
        for t in DeleteGuard.collapsed(targets) {
            if let reason = DeleteGuard.blockReason(t.url) {
                blocked.append("\(t.name): \(reason)")
            } else {
                allowed.append(t)
            }
        }
        if !blocked.isEmpty { trashMessage = "Nicht gelöscht: " + blocked.joined(separator: " · ") }
        pendingDelete = allowed
    }

    /// Führt die bestätigte Löschung aus und zieht Analyse, Listen und Balken nach.
    func confirmDelete(_ targets: [DeleteTarget], permanent: Bool) async {
        guard !targets.isEmpty, !isRemoving else { return }
        isRemoving = true
        let urls = targets.map(\.url)
        let result = await Task.detached(priority: .userInitiated) {
            Trasher.remove(urls, permanent: permanent)
        }.value
        let moved = Set(result.moved.map(\.path))
        let done = targets.filter { moved.contains($0.url.path) }

        if let a = analysis {
            analysis = a.removing(done, toTrash: !permanent)
            Analyzer.save(analysis!)
        }
        if var groups = duplicates {
            for i in groups.indices { groups[i].files.removeAll { moved.contains($0.url.path) } }
            duplicates = groups.filter { $0.files.count > 1 }
        }
        lastRemoved = done
        removalTick += 1
        refreshDisk()

        let size = formatBytes(done.reduce(0) { $0 + $1.size })
        var msg = permanent
            ? "\(done.count) endgültig gelöscht (\(size) frei)"
            : "\(done.count) in den Papierkorb verschoben (\(size)). Frei wird der Platz erst nach dem Leeren."
        if !result.failures.isEmpty { msg += " · Fehler: " + result.failures.joined(separator: ", ") }
        trashMessage = msg
        isRemoving = false

        await loadBackups()
        await loadCloud()
        await scan()
    }
}

final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    func setUp() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func warnLowSpace(free: Int64, thresholdGB: Int) {
        let content = UNMutableNotificationContent()
        content.title = "Speicher wird knapp"
        content.body = "Nur noch \(formatBytes(free)) frei (Grenze: \(thresholdGB) GB). Klick aufs Menüleisten-Icon zum Aufräumen."
        content.sound = .default
        let request = UNNotificationRequest(identifier: "lowSpace", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
