import Foundation

struct HistorySample: Codable, Sendable, Identifiable, Hashable {
    let date: Date
    let free: Int64
    let used: Int64
    /// Größen der Balken-Kategorien zum Zeitpunkt (falls ein Scan vorlag).
    let categories: [String: Int64]?
    var id: Date { date }
}

/// Speichert höchstens einen Messpunkt pro Stunde, ein Jahr lang.
enum History {
    private static var url: URL {
        Paths.inHome("Library/Application Support/Speicherwart/history.json")
    }

    static func load() -> [HistorySample] {
        guard let data = try? Data(contentsOf: url),
              let samples = try? JSONDecoder().decode([HistorySample].self, from: data) else { return [] }
        return samples
    }

    /// Hängt einen Messpunkt an, wenn der letzte älter als eine Stunde ist. Gibt die neue Liste zurück.
    static func recordIfDue(_ samples: [HistorySample], disk: DiskInfo, categories: [String: Int64]) -> [HistorySample]? {
        if let last = samples.last, Date().timeIntervalSince(last.date) < 3_600 { return nil }
        let cutoff = Date().addingTimeInterval(-365 * 86_400)
        var updated = samples.filter { $0.date > cutoff }
        updated.append(HistorySample(
            date: Date(), free: disk.available, used: disk.used,
            categories: categories.isEmpty ? nil : categories
        ))
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(updated).write(to: url, options: .atomic)
        return updated
    }

    /// Änderung des freien Speichers in den letzten `days` Tagen (positiv = mehr frei).
    static func freeChange(_ samples: [HistorySample], days: Int, now: DiskInfo?) -> Int64? {
        guard let now else { return nil }
        let since = Date().addingTimeInterval(-Double(days) * 86_400)
        guard let first = samples.first(where: { $0.date >= since }),
              Date().timeIntervalSince(first.date) > 3_600 else { return nil }
        return now.available - first.free
    }
}
