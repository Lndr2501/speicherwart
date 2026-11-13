import AppKit
import Charts
import SwiftUI

struct AnalysisView: View {
    @Bindable var state: AppState
    @State private var tab: Tab? = .overview

    enum Tab: String, CaseIterable, Identifiable {
        case overview = "Übersicht"
        case treemap = "Treemap"
        case big = "Große Dateien"
        case unused = "Lange ungenutzt"
        case duplicates = "Duplikate"
        case backups = "Backups"
        case cloud = "Cloud"
        case history = "Verlauf"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .overview: "chart.pie"
            case .treemap: "square.grid.3x3.square"
            case .big: "doc.badge.ellipsis"
            case .unused: "clock.badge.questionmark"
            case .duplicates: "doc.on.doc"
            case .backups: "iphone"
            case .cloud: "icloud"
            case .history: "chart.xyaxis.line"
            }
        }
        /// Braucht die Tiefenanalyse.
        var needsAnalysis: Bool { [.overview, .treemap, .big, .unused].contains(self) }
    }

    var body: some View {
        NavigationSplitView {
            List(Tab.allCases, selection: $tab) { t in
                Label(t.rawValue, systemImage: t.icon).tag(t)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            VStack(spacing: 0) {
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
                if let msg = state.trashMessage {
                    Divider()
                    HStack {
                        Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
                        Text(msg).font(.caption)
                        Spacer()
                        Button("Papierkorb öffnen") { NSWorkspace.shared.open(Paths.inHome(".Trash")) }
                            .controlSize(.small)
                        Button {
                            state.trashMessage = nil
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                }
            }
            .navigationTitle(tab?.rawValue ?? "Speicher-Analyse")
            .toolbar {
                ToolbarItemGroup { status }
            }
        }
        .frame(minWidth: 900, minHeight: 580)
        .task {
            async let a: () = state.analyzeIfStale()
            async let b: () = state.loadBackups()
            _ = await (a, b)
        }
    }

    @ViewBuilder private var status: some View {
        if let p = state.analysisProgress {
            ProgressView(value: p).frame(width: 100)
            Text("Analysiere … \(Int(p * 100)) %").font(.caption).monospacedDigit()
        } else {
            if let a = state.analysis {
                Text("Stand \(a.date.formatted(.relative(presentation: .named)))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button {
                Task { await state.analyze() }
            } label: {
                Label("Neu analysieren", systemImage: "arrow.clockwise")
            }
            .help("Tiefenanalyse neu starten")
        }
    }

    @ViewBuilder private var content: some View {
        switch tab ?? .overview {
        case .backups: BackupsView(state: state)
        case .cloud: CloudView(state: state)
        case .history: HistoryView(state: state)
        case .duplicates: DuplicatesView(state: state)
        case let t where t.needsAnalysis:
            if let a = state.analysis {
                switch t {
                case .overview: OverviewView(state: state, analysis: a)
                case .treemap: TreemapView(state: state, analysis: a)
                case .big: BigFilesView(state: state, files: a.bigFiles)
                default: UnusedFilesView(state: state, files: a.bigFiles)
                }
            } else {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Erste Analyse läuft").font(.headline)
                    Text("Das ganze Home wird einmal durchgegangen, das dauert ca. 15 Sekunden bis 3 Minuten.")
                        .foregroundStyle(.secondary)
                }
            }
        default: EmptyView()
        }
    }
}

// MARK: - Übersicht

private struct Slice: Identifiable {
    let id: String
    let name: String
    let bytes: Int64
    let slot: Int
    let url: URL?
}

struct OverviewView: View {
    let state: AppState
    let analysis: AnalysisResult
    @State private var selectedAngle: Double?

    private var slices: [Slice] {
        var entries: [(id: String, name: String, bytes: Int64, url: URL?)] =
            analysis.folders.map { ($0.path, $0.displayName, $0.size, $0.url) }
        if let disk = state.disk {
            let apps = analysis.folders.first { $0.path == "/Applications" }?.size ?? 0
            let system = disk.used - analysis.homeTotal - apps
            if system > 0 { entries.append(("system", "macOS & System", system, nil)) }
        }
        entries.sort { $0.bytes > $1.bytes }
        var result = entries.prefix(7).enumerated().map { i, e in
            Slice(id: e.id, name: e.name, bytes: e.bytes, slot: i, url: e.url)
        }
        let rest = entries.dropFirst(7).reduce(Int64(0)) { $0 + $1.bytes }
        if rest > 0 { result.append(Slice(id: "rest", name: "Weitere", bytes: rest, slot: 99, url: nil)) }
        return result
    }

    private func slice(at angle: Double?, in slices: [Slice]) -> Slice? {
        guard let angle else { return nil }
        var acc = 0.0
        for s in slices {
            acc += Double(s.bytes)
            if angle <= acc { return s }
        }
        return nil
    }

    var body: some View {
        let slices = slices
        let total = slices.reduce(Int64(0)) { $0 + $1.bytes }
        let selected = slice(at: selectedAngle, in: slices)

        HStack(alignment: .top, spacing: 24) {
            VStack(spacing: 8) {
                Chart(slices) { s in
                    SectorMark(
                        angle: .value("Größe", Double(s.bytes)),
                        innerRadius: .ratio(0.6),
                        angularInset: 1.5
                    )
                    .cornerRadius(3)
                    .foregroundStyle(s.slot < 8 ? Palette.slot(s.slot) : Palette.other)
                    .opacity(selected == nil || selected?.id == s.id ? 1 : 0.35)
                }
                .chartLegend(.hidden)
                .chartAngleSelection(value: $selectedAngle)
                .frame(width: 260, height: 260)
                .overlay {
                    VStack(spacing: 2) {
                        Text(formatBytes(selected?.bytes ?? total)).font(.title2.bold()).monospacedDigit()
                        Text(selected?.name ?? "belegt").font(.caption).foregroundStyle(.secondary)
                            .lineLimit(2).multilineTextAlignment(.center).frame(maxWidth: 130)
                    }
                }
                Text("Was frisst am meisten Speicher").font(.caption).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(slices) { s in
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(s.slot < 8 ? Palette.slot(s.slot) : Palette.other)
                            .frame(width: 10, height: 10)
                        Text(s.name).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(formatBytes(s.bytes)).monospacedDigit()
                        Text(total > 0 ? "\(Int((Double(s.bytes) / Double(total) * 100).rounded())) %" : "")
                            .monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                    }
                    .font(.callout)
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                    .onTapGesture { if let url = s.url { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
                    .help(s.url == nil ? "" : "Klicken: im Finder zeigen")
                }
                Divider().padding(.vertical, 6)
                Text("Größte Ordner").font(.headline)
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(analysis.folders.prefix(40)) { f in
                            HStack {
                                Text(f.displayName).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text(formatBytes(f.size)).monospacedDigit().foregroundStyle(.secondary)
                                Button {
                                    NSWorkspace.shared.activateFileViewerSelecting([f.url])
                                } label: {
                                    Image(systemName: "magnifyingglass")
                                }
                                .buttonStyle(.borderless)
                                .help("Im Finder zeigen")
                            }
                            .font(.callout)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(20)
    }
}

// MARK: - Dateilisten

struct BigFilesView: View {
    let state: AppState
    let files: [FileEntry]
    @State private var scope: Scope = .all
    @State private var minSize: Int64 = 500_000_000

    enum Scope: String, CaseIterable, Identifiable {
        case all = "Überall", downloads = "Downloads", cloud = "Cloud-Ordner", apps = "Apps"
        var id: String { rawValue }
    }

    var body: some View {
        let filtered = files.filter { f in
            guard f.size >= minSize else { return false }
            switch scope {
            case .all: return true
            case .downloads: return f.isInDownloads
            case .cloud: return f.isInCloud
            case .apps: return f.isApp
            }
        }
        VStack(spacing: 0) {
            HStack {
                Picker("Bereich", selection: $scope) {
                    ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 380)
                Spacer()
                Picker("Ab", selection: $minSize) {
                    Text("100 MB").tag(Int64(100_000_000))
                    Text("500 MB").tag(Int64(500_000_000))
                    Text("1 GB").tag(Int64(1_000_000_000))
                    Text("5 GB").tag(Int64(5_000_000_000))
                }
                .frame(width: 130)
            }
            .padding(10)
            FileTable(state: state, entries: filtered)
        }
    }
}

struct UnusedFilesView: View {
    let state: AppState
    let files: [FileEntry]
    @State private var months = 6

    var body: some View {
        let cutoff = Calendar.current.date(byAdding: .month, value: -months, to: Date()) ?? Date()
        let filtered = files.filter { f in
            guard let last = f.lastActivity else { return false }
            return last < cutoff
        }
        VStack(spacing: 0) {
            HStack {
                Text("Große Dateien und Apps (ab 100 MB), die lange nicht geöffnet wurden")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Picker("Nicht benutzt seit", selection: $months) {
                    Text("3 Monaten").tag(3)
                    Text("6 Monaten").tag(6)
                    Text("1 Jahr").tag(12)
                    Text("2 Jahren").tag(24)
                }
                .frame(width: 240)
            }
            .padding(10)
            FileTable(state: state, entries: filtered)
        }
    }
}

struct FileTable: View {
    let state: AppState
    let entries: [FileEntry]
    @State private var selection = Set<FileEntry.ID>()
    @State private var sortOrder = [KeyPathComparator(\FileEntry.size, order: .reverse)]
    @State private var confirming = false

    private var selectedEntries: [FileEntry] { entries.filter { selection.contains($0.id) } }

    var body: some View {
        let rows = entries.sorted(using: sortOrder)
        let total = entries.reduce(Int64(0)) { $0 + $1.size }
        let selectedSize = selectedEntries.reduce(Int64(0)) { $0 + $1.size }

        VStack(spacing: 0) {
            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Name", value: \.name) { e in
                    HStack(spacing: 6) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: e.path))
                            .resizable().frame(width: 16, height: 16)
                        Text(e.name).lineLimit(1).truncationMode(.middle)
                        if e.isInCloud {
                            Image(systemName: "icloud").foregroundStyle(.secondary)
                                .help("Liegt in einem Cloud-Ordner (z.B. SeaDrive)")
                        }
                    }
                }
                TableColumn("Ordner", value: \.displayFolder) { e in
                    Text(e.displayFolder).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
                TableColumn("Größe", value: \.size) { e in
                    Text(formatBytes(e.size)).monospacedDigit()
                }
                .width(min: 70, ideal: 85)
                TableColumn("Zuletzt benutzt", value: \.sortDate) { e in
                    Text(e.lastActivity.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "–")
                        .foregroundStyle(e.lastUsed == nil ? .secondary : .primary)
                        .help(e.lastUsed == nil ? "Kein Spotlight-Datum, zeigt Änderungsdatum" : "Laut Spotlight")
                }
                .width(min: 90, ideal: 110)
            }
            .contextMenu(forSelectionType: FileEntry.ID.self) { ids in
                Button("Im Finder zeigen") {
                    NSWorkspace.shared.activateFileViewerSelecting(ids.map { URL(fileURLWithPath: $0) })
                }
                Button("In den Papierkorb …") {
                    selection = ids
                    confirming = true
                }
            } primaryAction: { ids in
                NSWorkspace.shared.activateFileViewerSelecting(ids.map { URL(fileURLWithPath: $0) })
            }

            Divider()
            HStack {
                Text("\(entries.count) Einträge · \(formatBytes(total))")
                if !selection.isEmpty {
                    Text("· \(selection.count) ausgewählt (\(formatBytes(selectedSize)))").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Im Finder zeigen") {
                    NSWorkspace.shared.activateFileViewerSelecting(selectedEntries.map(\.url))
                }
                .disabled(selection.isEmpty)
                Button("In den Papierkorb …") { confirming = true }
                    .disabled(selection.isEmpty)
            }
            .font(.callout)
            .padding(10)
        }
        .confirmationDialog(
            "\(selection.count) Objekt(e) in den Papierkorb verschieben?",
            isPresented: $confirming
        ) {
            Button("In den Papierkorb", role: .destructive) {
                let urls = selectedEntries.map(\.url)
                selection = []
                Task { await state.moveToTrash(urls) }
            }
        } message: {
            Text("Zusammen \(formatBytes(selectedSize)). Du kannst sie aus dem Papierkorb zurückholen.")
        }
    }
}

extension FileEntry {
    var sortDate: Date { lastActivity ?? .distantPast }
}

// MARK: - Backups

struct BackupsView: View {
    let state: AppState
    @State private var pending: BackupEntry?

    var body: some View {
        let b = state.backups
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                section(
                    "iPhone- & iPad-Backups",
                    note: "Lokale Geräte-Backups vom Finder. Backups alter Geräte kannst du meist löschen."
                ) {
                    if b.iosBackups.isEmpty { empty }
                    ForEach(b.iosBackups) { row($0, icon: "iphone") }
                }
                section("iOS-Update-Dateien", note: "Heruntergeladene Updates, werden bei Bedarf neu geladen.") {
                    if b.iosUpdates.isEmpty { empty }
                    ForEach(b.iosUpdates) { row($0, icon: "arrow.down.circle") }
                }
                section(
                    "Lokale Time-Machine-Schnappschüsse",
                    note: "macOS löscht diese automatisch, sobald Platz gebraucht wird. Darum zählen sie als frei."
                ) {
                    if b.snapshots.isEmpty { empty }
                    ForEach(b.snapshots) { s in
                        HStack {
                            Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary).frame(width: 22)
                            Text(s.date?.formatted(date: .abbreviated, time: .shortened) ?? s.name)
                            Spacer()
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay { if !state.backupsLoaded { ProgressView() } }
        .confirmationDialog(
            "„\(pending?.title ?? "")“ in den Papierkorb verschieben?",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })
        ) {
            Button("In den Papierkorb", role: .destructive) {
                if let p = pending { Task { await state.moveToTrash([p.url]) } }
                pending = nil
            }
        } message: {
            Text("\(formatBytes(pending?.size ?? 0)). Erst wenn du den Papierkorb leerst, ist der Platz frei.")
        }
    }

    private var empty: some View {
        Text("Nichts gefunden").foregroundStyle(.secondary).font(.callout)
    }

    private func section<Content: View>(_ title: String, note: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(note).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }

    private func row(_ e: BackupEntry, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(e.title)
                if !e.subtitle.isEmpty { Text(e.subtitle).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            if let d = e.date {
                Text(d.formatted(date: .abbreviated, time: .omitted)).foregroundStyle(.secondary)
            }
            Text(formatBytes(e.size)).monospacedDigit().frame(width: 80, alignment: .trailing)
            Button("In den Papierkorb …") { pending = e }
                .controlSize(.small)
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([e.url]) }
        }
    }
}
