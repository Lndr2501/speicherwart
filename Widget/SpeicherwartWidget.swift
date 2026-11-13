import SwiftUI
import WidgetKit

struct DiskEntry: TimelineEntry {
    let date: Date
    let free: Int64
    let total: Int64
    let junk: Int64?
    let change7d: Int64?
    let thresholdGB: Int

    var used: Int64 { max(0, total - free) }
    var isLow: Bool { free < Int64(thresholdGB) * 1_000_000_000 }

    static let placeholder = DiskEntry(
        date: Date(), free: 200_000_000_000, total: 494_000_000_000,
        junk: 36_000_000_000, change7d: -4_000_000_000, thresholdGB: 50
    )

    /// Freier Speicher wird direkt gelesen, Müll und Trend kommen von der App.
    static func current() -> DiskEntry {
        let snap = WidgetStore.load()
        let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [
            .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        ])
        let total = v?.volumeTotalCapacity.map(Int64.init) ?? snap?.total ?? 0
        let free = v?.volumeAvailableCapacityForImportantUsage ?? snap?.free ?? 0
        return DiskEntry(
            date: Date(), free: free, total: total, junk: snap?.junk,
            change7d: snap?.change7d, thresholdGB: snap?.thresholdGB ?? 50
        )
    }
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> DiskEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (DiskEntry) -> Void) {
        completion(context.isPreview ? .placeholder : .current())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<DiskEntry>) -> Void) {
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date()
        completion(Timeline(entries: [.current()], policy: .after(next)))
    }
}

private func bytes(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }

struct UsageBar: View {
    let entry: DiskEntry
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(entry.isLow ? Color.red : Color.accentColor)
                    .frame(width: entry.total > 0 ? geo.size.width * CGFloat(entry.used) / CGFloat(entry.total) : 0)
            }
        }
        .frame(height: 8)
    }
}

struct SmallView: View {
    let entry: DiskEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: entry.isLow ? "exclamationmark.triangle.fill" : "internaldrive")
                    .foregroundStyle(entry.isLow ? .red : .secondary)
                Text("Speicher").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text(bytes(entry.free)).font(.title2.bold()).monospacedDigit().minimumScaleFactor(0.6).lineLimit(1)
            Text("frei von \(bytes(entry.total))").font(.caption2).foregroundStyle(.secondary)
            UsageBar(entry: entry)
            if let junk = entry.junk, junk >= 1_000_000_000 {
                Text("\(bytes(junk)) aufräumbar").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

struct MediumView: View {
    let entry: DiskEntry
    var body: some View {
        HStack(spacing: 16) {
            SmallView(entry: entry)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                row("Belegt", bytes(entry.used), icon: "chart.bar.fill")
                if let junk = entry.junk { row("Aufräumbar", bytes(junk), icon: "trash") }
                if let c = entry.change7d {
                    row("7 Tage", (c >= 0 ? "+" : "−") + bytes(abs(c)) + " frei",
                        icon: c >= 0 ? "arrow.up.right" : "arrow.down.right")
                }
                if entry.isLow {
                    Text("Unter \(entry.thresholdGB) GB frei").font(.caption.bold()).foregroundStyle(.red)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func row(_ title: String, _ value: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 14)
            Text(title).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.caption.bold()).monospacedDigit()
        }
    }
}

struct SpeicherwartWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: DiskEntry
    var body: some View {
        Group {
            if family == .systemMedium { MediumView(entry: entry) } else { SmallView(entry: entry) }
        }
        .containerBackground(.background, for: .widget)
    }
}

@main
struct SpeicherwartWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SpeicherwartWidget", provider: Provider()) { entry in
            SpeicherwartWidgetView(entry: entry)
        }
        .configurationDisplayName("Speicher")
        .description("Freier Speicher, Müll und Trend der letzten 7 Tage.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
