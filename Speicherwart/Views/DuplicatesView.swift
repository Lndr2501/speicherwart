import AppKit
import SwiftUI

struct DuplicatesView: View {
    @Bindable var state: AppState
    @State private var minSize: Int64 = 10_000_000
    @State private var marked = Set<String>()
    @State private var confirming = false

    var body: some View {
        let groups = state.duplicates ?? []
        let wasted = groups.reduce(Int64(0)) { $0 + $1.wasted }
        let markedFiles = groups.flatMap { g in g.files.filter { marked.contains($0.id) }.map { ($0, g.size) } }
        let markedSize = markedFiles.reduce(Int64(0)) { $0 + $1.1 }

        VStack(spacing: 0) {
            HStack {
                Text("Gleiche Dateien im Home (ohne ~/Library, Cloud- und Build-Ordner)")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Picker("Ab", selection: $minSize) {
                    Text("1 MB").tag(Int64(1_000_000))
                    Text("10 MB").tag(Int64(10_000_000))
                    Text("100 MB").tag(Int64(100_000_000))
                }
                .frame(width: 120)
                Button(state.duplicates == nil ? "Duplikate suchen" : "Neu suchen") {
                    marked = []
                    Task { await state.findDuplicates(minSize: minSize) }
                }
                .disabled(state.duplicateProgress != nil)
            }
            .padding(10)
            Divider()

            if let p = state.duplicateProgress {
                VStack(spacing: 8) {
                    ProgressView()
                    Text(p).foregroundStyle(.secondary).monospacedDigit()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if state.duplicates == nil {
                VStack(spacing: 8) {
                    Image(systemName: "doc.on.doc").font(.largeTitle).foregroundStyle(.secondary)
                    Text("Noch nicht gesucht").font(.headline)
                    Text("Die Suche liest Dateien gleicher Größe und vergleicht ihren Inhalt. Dauert ca. 1–5 Minuten.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if groups.isEmpty {
                Text("Keine Duplikate gefunden 🎉").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(groups) { g in
                        Section {
                            ForEach(g.files) { f in
                                HStack(spacing: 8) {
                                    Toggle("", isOn: Binding(
                                        get: { marked.contains(f.id) },
                                        set: { on in if on { marked.insert(f.id) } else { marked.remove(f.id) } }
                                    ))
                                    .toggleStyle(.checkbox).labelsHidden()
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: f.url.path))
                                        .resizable().frame(width: 16, height: 16)
                                    Text(f.displayPath).lineLimit(1).truncationMode(.middle)
                                    if f.mayBeClone {
                                        Image(systemName: "link").foregroundStyle(.secondary)
                                            .help("Evtl. APFS-Klon: teilt Speicher mit der anderen Datei, Löschen spart dann kaum Platz")
                                    }
                                    Spacer()
                                    if let c = f.created {
                                        Text(c.formatted(date: .abbreviated, time: .omitted)).foregroundStyle(.secondary)
                                    }
                                }
                                .contextMenu {
                                    Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([f.url]) }
                                }
                            }
                        } header: {
                            HStack {
                                Text("\(g.files.count) × \(formatBytes(g.size))")
                                Spacer()
                                Text("\(formatBytes(g.wasted)) doppelt").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Divider()
                HStack {
                    Text("\(groups.count) Gruppen · \(formatBytes(wasted)) doppelt")
                    if !marked.isEmpty {
                        Text("· \(marked.count) markiert (\(formatBytes(markedSize)))").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Kopien markieren") {
                        // Pro Gruppe bleibt die älteste Datei stehen.
                        marked = Set(groups.flatMap { $0.files.dropFirst().map(\.id) })
                    }
                    .help("Markiert in jeder Gruppe alles außer der ältesten Datei")
                    Button("Markierung aufheben") { marked = [] }.disabled(marked.isEmpty)
                    Button("In den Papierkorb …") { confirming = true }.disabled(marked.isEmpty)
                }
                .font(.callout)
                .padding(10)
            }
        }
        .confirmationDialog("\(marked.count) Datei(en) in den Papierkorb verschieben?", isPresented: $confirming) {
            Button("In den Papierkorb", role: .destructive) {
                // Sicherung: Sind alle Dateien einer Gruppe markiert, bleibt die älteste stehen.
                let urls = (state.duplicates ?? []).flatMap { g -> [URL] in
                    let m = g.files.filter { marked.contains($0.id) }
                    return (m.count == g.files.count ? Array(m.dropFirst()) : m).map(\.url)
                }
                marked = []
                Task { await state.moveToTrash(urls) }
            }
        } message: {
            Text("Zusammen \(formatBytes(markedSize)). Von jeder Gruppe bleibt immer mindestens eine Datei erhalten.")
        }
    }
}
