import Foundation

/// Werte, die die App fürs Widget bereitstellt (App-Gruppe).
struct WidgetSnapshot: Codable, Sendable {
    let date: Date
    let free: Int64
    let total: Int64
    /// Aufräumbarer Müll (ausgewählte Kategorien), nil = noch kein Scan.
    let junk: Int64?
    /// Änderung des freien Speichers in 7 Tagen (positiv = mehr frei).
    let change7d: Int64?
    let thresholdGB: Int
}

enum WidgetStore {
    static let groupID = "PKK5ZQ9PNH.ch.semlitsch.speicherwart"

    static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)?
            .appendingPathComponent("widget.json")
    }

    static func save(_ snapshot: WidgetSnapshot) {
        guard let url = fileURL else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
    }

    static func load() -> WidgetSnapshot? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }
}
