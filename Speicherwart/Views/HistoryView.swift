import Charts
import SwiftUI

struct HistoryView: View {
    let state: AppState
    @State private var days = 30
    @State private var hoverDate: Date?

    var body: some View {
        let since = Date().addingTimeInterval(-Double(days) * 86_400)
        let samples = state.history.filter { $0.date >= since }
        let hovered = hoverDate.flatMap { d in samples.min { abs($0.date.timeIntervalSince(d)) < abs($1.date.timeIntervalSince(d)) } }
        let warnUsed = state.disk.map { Double($0.total - Int64(state.thresholdGB) * 1_000_000_000) / 1e9 }

        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Belegter Speicher").font(.headline)
                if let change = History.freeChange(state.history, days: days, now: state.disk) {
                    Text(changeText(change, days: days)).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Zeitraum", selection: $days) {
                    Text("7 Tage").tag(7)
                    Text("30 Tage").tag(30)
                    Text("90 Tage").tag(90)
                    Text("1 Jahr").tag(365)
                }
                .pickerStyle(.segmented)
                .frame(width: 300)
            }

            if samples.count < 2 {
                VStack(spacing: 6) {
                    Image(systemName: "chart.xyaxis.line").font(.largeTitle).foregroundStyle(.secondary)
                    Text("Der Verlauf wird gerade aufgebaut").font(.headline)
                    Text("Speicherwart misst einmal pro Stunde. Nach ein paar Stunden erscheint hier die Kurve.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 260)
            } else {
                Chart {
                    ForEach(samples) { s in
                        AreaMark(x: .value("Zeit", s.date), y: .value("Belegt (GB)", Double(s.used) / 1e9))
                            .foregroundStyle(Palette.slot(0).opacity(0.12))
                        LineMark(x: .value("Zeit", s.date), y: .value("Belegt (GB)", Double(s.used) / 1e9))
                            .foregroundStyle(Palette.slot(0))
                            .lineStyle(StrokeStyle(lineWidth: 2))
                    }
                    if let warnUsed {
                        RuleMark(y: .value("Warnschwelle", warnUsed))
                            .foregroundStyle(.secondary)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                            .annotation(position: .top, alignment: .leading) {
                                Text("Warnung ab \(state.thresholdGB) GB frei").font(.caption2).foregroundStyle(.secondary)
                            }
                    }
                    if let h = hovered {
                        RuleMark(x: .value("Zeit", h.date)).foregroundStyle(.secondary.opacity(0.5))
                        PointMark(x: .value("Zeit", h.date), y: .value("Belegt (GB)", Double(h.used) / 1e9))
                            .foregroundStyle(Palette.slot(0))
                            .symbolSize(60)
                            .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(h.date.formatted(date: .abbreviated, time: .shortened)).font(.caption2)
                                    Text("\(formatBytes(h.used)) belegt").font(.caption.bold())
                                    Text("\(formatBytes(h.free)) frei").font(.caption2).foregroundStyle(.secondary)
                                }
                                .padding(6)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                            }
                    }
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .chartYAxisLabel("GB")
                .chartXSelection(value: $hoverDate)
                .frame(minHeight: 260)

                categoryChanges(samples)
            }
        }
        .padding(20)
    }

    private func changeText(_ change: Int64, days: Int) -> String {
        let label = days == 365 ? "im letzten Jahr" : "in \(days) Tagen"
        return change >= 0 ? "\(formatBytes(change)) mehr frei \(label)" : "\(formatBytes(-change)) weniger frei \(label)"
    }

    /// Welche Kategorie ist im Zeitraum gewachsen/geschrumpft?
    @ViewBuilder private func categoryChanges(_ samples: [HistorySample]) -> some View {
        if let first = samples.first(where: { $0.categories != nil })?.categories,
           let last = samples.last(where: { $0.categories != nil })?.categories {
            let rows = BarCategory.all.map { c in
                (name: c.name, id: c.id, delta: (last[c.id] ?? 0) - (first[c.id] ?? 0))
            }
            .filter { abs($0.delta) >= 100_000_000 }
            .sorted { abs($0.delta) > abs($1.delta) }
            VStack(alignment: .leading, spacing: 6) {
                Text("Veränderung nach Kategorie").font(.headline)
                if rows.isEmpty {
                    Text("Keine Kategorie hat sich um mehr als 100 MB verändert.").foregroundStyle(.secondary)
                }
                ForEach(rows, id: \.id) { r in
                    HStack {
                        Circle().fill(SegmentColor.color(r.id)).frame(width: 8, height: 8)
                        Text(r.name)
                        Spacer()
                        Image(systemName: r.delta > 0 ? "arrow.up.right" : "arrow.down.right")
                            .foregroundStyle(.secondary)
                        Text((r.delta > 0 ? "+" : "−") + formatBytes(abs(r.delta))).monospacedDigit()
                    }
                    .font(.callout)
                }
            }
        }
    }
}

/// Mini-Kurve des freien Speichers für das Menüleisten-Fenster.
struct FreeSparkline: View {
    let samples: [HistorySample]

    var body: some View {
        Chart(samples) { s in
            LineMark(x: .value("Zeit", s.date), y: .value("Frei", Double(s.free) / 1e9))
                .foregroundStyle(Palette.slot(0))
                .lineStyle(StrokeStyle(lineWidth: 1.5))
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: .automatic(includesZero: false))
        .frame(width: 70, height: 18)
    }
}
