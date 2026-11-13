import AppKit
import Charts
import SwiftUI

struct MenuBarLabel: View {
    let state: AppState

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: state.isLow ? "exclamationmark.triangle.fill" : "internaldrive")
            if state.showFreeInMenuBar, let disk = state.disk {
                Text(String(format: "%.0f GB", Double(disk.available) / 1e9))
            }
        }
    }
}

enum SegmentColor {
    /// Feste Zuordnung Kategorie → Palette-Slot; "Müll" ist immer Rot (Slot 7).
    static func color(_ id: String) -> Color {
        switch id {
        case "apps": Palette.slot(0)
        case "appData": Palette.slot(1)
        case "docs": Palette.slot(2)
        case "own": Palette.slot(3)
        case "media": Palette.slot(4)
        case "dev": Palette.slot(5)
        case "cloud": Palette.slot(6)
        case "junk": Palette.slot(7)
        default: Palette.other
        }
    }
}

struct PopoverView: View {
    @Bindable var state: AppState
    @State private var confirming = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            StorageBarView(state: state)
            trend
            Button {
                openWindow(id: "analysis")
                NSApp.activate()
            } label: {
                Label("Analyse öffnen: große Dateien, Backups …", systemImage: "chart.pie")
                    .frame(maxWidth: .infinity)
            }
            if !state.hasFullDiskAccess { accessBanner }
            Divider()
            cleanupSection
            Divider()
            settings
        }
        .padding(14)
        .frame(width: 380)
        .task { await state.scanIfStale() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(state.disk?.name ?? "Macintosh HD").font(.headline)
            Spacer()
            if let disk = state.disk {
                Text("\(formatBytes(disk.available)) frei von \(formatBytes(disk.total))")
                    .font(.subheadline)
                    .foregroundStyle(state.isLow ? .red : .secondary)
            }
        }
    }

    @ViewBuilder private var trend: some View {
        let week = state.history.filter { $0.date > Date().addingTimeInterval(-7 * 86_400) }
        if let change = History.freeChange(state.history, days: 7, now: state.disk), week.count >= 2 {
            HStack(spacing: 6) {
                Image(systemName: change >= 0 ? "arrow.up.right" : "arrow.down.right").foregroundStyle(.secondary)
                Text(change >= 0 ? "\(formatBytes(change)) mehr frei seit 7 Tagen"
                                 : "\(formatBytes(-change)) weniger frei seit 7 Tagen")
                    .font(.caption)
                Spacer()
                FreeSparkline(samples: week)
            }
        }
    }

    private var accessBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Festplattenvollzugriff fehlt").font(.subheadline.bold())
                Text("Ohne ihn sind Papierkorb und manche Ordner nicht lesbar.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Einstellungen öffnen") { NSWorkspace.shared.open(Permissions.fullDiskAccessSettings) }
                    .controlSize(.small)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    private var cleanupSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Aufräumbar").font(.headline)
                if state.isScanning || state.isCleaning { ProgressView().controlSize(.small) }
                Spacer()
                Text(formatBytes(state.selectedTotal)).font(.headline).monospacedDigit()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(CleanupGroup.allCases) { group in
                        Text(group.title).font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                        ForEach(CleanupCatalog.targets.filter { $0.group == group }) { target in
                            TargetRow(state: state, target: target)
                        }
                    }
                }
            }
            .frame(maxHeight: 320)

            if confirming {
                HStack {
                    Text("\(formatBytes(state.selectedTotal)) endgültig löschen?").font(.subheadline)
                    Spacer()
                    Button("Abbrechen") { confirming = false }
                    Button("Löschen", role: .destructive) {
                        confirming = false
                        Task { await state.clean() }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            } else {
                HStack {
                    Button {
                        Task { await state.scan() }
                    } label: {
                        Label("Neu scannen", systemImage: "arrow.clockwise")
                    }
                    .disabled(state.isScanning)
                    Spacer()
                    Button("Aufräumen …") { confirming = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(state.selectedTotal == 0 || state.isScanning || state.isCleaning)
                }
            }
            if let msg = state.lastCleanMessage {
                Text(msg).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 6) {
            Stepper("Warnen unter \(state.thresholdGB) GB frei", value: $state.thresholdGB, in: 10...300, step: 10)
            Toggle("Freien Speicher in der Menüleiste zeigen", isOn: $state.showFreeInMenuBar)
            Toggle("Beim Anmelden starten", isOn: $state.launchAtLogin)
            HStack {
                if let last = state.lastScan {
                    Text("Gescannt \(last.formatted(.relative(presentation: .named)))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Beenden") { NSApp.terminate(nil) }
            }
        }
        .font(.subheadline)
    }
}

struct StorageBarView: View {
    let state: AppState

    var body: some View {
        let segments = state.segments
        let disk = state.disk
        let used = segments.reduce(Int64(0)) { $0 + $1.bytes }
        let domain = Double(max(disk?.total ?? 1, used + (disk?.available ?? 0)))

        VStack(alignment: .leading, spacing: 8) {
            if segments.isEmpty {
                ProgressView(value: Double(disk?.used ?? 0), total: Double(disk?.total ?? 1))
                Text(state.isScanning ? "Analysiere Speicher …" : "Noch keine Analyse")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Chart(Array(stacked(segments).enumerated()), id: \.offset) { _, s in
                    BarMark(
                        xStart: .value("Start", s.start),
                        xEnd: .value("Ende", s.end),
                        y: .value("Volume", "Disk"),
                        height: .ratio(1)
                    )
                    .foregroundStyle(SegmentColor.color(s.segment.id))
                }
                .chartXScale(domain: 0...domain)
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartLegend(.hidden)
                .frame(height: 22)
                .background(Color.secondary.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 5))

                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                          spacing: 4) {
                    ForEach(segments) { s in
                        HStack(spacing: 5) {
                            Circle().fill(SegmentColor.color(s.id)).frame(width: 8, height: 8)
                            Text(s.name).lineLimit(1)
                            Spacer(minLength: 2)
                            Text(formatBytes(s.bytes)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                }
            }
        }
    }

    private struct Stacked { let segment: Segment; let start: Double; let end: Double }

    private func stacked(_ segments: [Segment]) -> [Stacked] {
        var x = 0.0
        let gap = Double(segments.reduce(Int64(0)) { $0 + $1.bytes }) * 0.004  // 2px-Lücke zwischen Segmenten
        return segments.map { s in
            defer { x += Double(s.bytes) }
            return Stacked(segment: s, start: x, end: max(x, x + Double(s.bytes) - gap))
        }
    }
}

struct TargetRow: View {
    let state: AppState
    let target: CleanupTarget
    @State private var expanded = false

    var body: some View {
        let result = state.results[target.id]
        let items = result?.items ?? []

        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Toggle("", isOn: state.binding(for: target.id))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                VStack(alignment: .leading, spacing: 1) {
                    Text(target.name)
                    Text(target.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if result?.accessDenied == true {
                    Image(systemName: "lock.fill").foregroundStyle(.orange)
                        .help("Kein Zugriff: Festplattenvollzugriff erteilen")
                }
                Text(result.map { formatBytes($0.total) } ?? "–")
                    .monospacedDigit().foregroundStyle(.secondary)
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 14)
                }
                .buttonStyle(.plain)
                .disabled(items.isEmpty)
                .help("Vorschau")
            }
            if expanded {
                ForEach(items.prefix(15)) { item in
                    HStack {
                        Text(item.name).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(formatBytes(item.size)).monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 26)
                    .contentShape(Rectangle())
                    .contextMenu {
                        Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                    }
                }
                if items.count > 15 {
                    Text("+ \(items.count - 15) weitere").font(.caption).foregroundStyle(.tertiary)
                        .padding(.leading, 26)
                }
            }
        }
    }
}
