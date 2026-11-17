import AppKit
import SwiftUI

struct CloudView: View {
    let state: AppState
    @State private var pendingEvict: [CloudFile] = []

    var body: some View {
        let active = state.cloud.filter(\.isActive)
        let orphans = state.cloud.filter { !$0.isActive && $0.localSize > 0 }

        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Cloud-Konten").font(.headline)
                    Text("„Download entfernen“ löscht nur die lokale Kopie. Die Datei bleibt in der Cloud sichtbar und lädt beim Öffnen neu.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if active.isEmpty && state.cloudLoaded {
                    Text("Keine aktiven Cloud-Konten gefunden").foregroundStyle(.secondary)
                }
                ForEach(active) { domainSection($0) }

                if !orphans.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Verwaiste Kopien", systemImage: "exclamationmark.triangle").font(.headline)
                        Text("Lokale Kopien von entfernten Konten. Sie werden nicht mehr synchronisiert. Prüfe im Finder, ob alles in der Cloud liegt, dann kannst du sie löschen.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(orphans) { orphanRow($0) }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay { if !state.cloudLoaded || state.isEvicting { ProgressView() } }
        .task { if !state.cloudLoaded { await state.loadCloud() } }
        .confirmationDialog(
            "\(pendingEvict.count) Download(s) entfernen?",
            isPresented: Binding(get: { !pendingEvict.isEmpty }, set: { if !$0 { pendingEvict = [] } })
        ) {
            Button("Downloads entfernen") {
                let files = pendingEvict
                pendingEvict = []
                Task { await state.evict(files) }
            }
        } message: {
            Text("Gibt \(formatBytes(pendingEvict.reduce(0) { $0 + $1.size })) frei. Die Dateien bleiben in der Cloud.")
        }
    }

    private func domainSection(_ d: CloudDomain) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "icloud").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(d.provider).font(.body.bold())
                    Text(d.account).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text("\(formatBytes(d.localSize)) lokal").monospacedDigit()
                Button("Alle Downloads entfernen …") { pendingEvict = d.files.filter(\.canEvict) }
                    .disabled(d.evictableSize == 0 || state.isEvicting)
            }
            if d.blockedCount > 0 {
                Text("\(d.blockedCount) Datei(en) sind noch nicht hochgeladen und bleiben lokal.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if d.files.isEmpty {
                Text("Nichts lokal geladen").font(.caption).foregroundStyle(.secondary).padding(.leading, 26)
            }
            ForEach(d.files.prefix(12)) { f in
                HStack {
                    Text(f.name).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(formatBytes(f.size)).monospacedDigit().foregroundStyle(.secondary)
                    Button("Download entfernen") { pendingEvict = [f] }
                        .controlSize(.small)
                        .disabled(!f.canEvict || state.isEvicting)
                        .help(f.canEvict ? "" : "Noch nicht hochgeladen")
                }
                .font(.callout)
                .padding(.leading, 26)
                .contextMenu {
                    Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([f.url]) }
                }
            }
            if d.files.count > 12 {
                Text("+ \(d.files.count - 12) weitere").font(.caption).foregroundStyle(.tertiary).padding(.leading, 26)
            }
        }
    }

    private func orphanRow(_ d: CloudDomain) -> some View {
        HStack {
            Image(systemName: "folder.badge.questionmark").foregroundStyle(.orange).frame(width: 22)
            Text(d.folderName).lineLimit(1).truncationMode(.middle)
            Spacer()
            Text(formatBytes(d.localSize)).monospacedDigit()
            Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([d.url]) }
                .controlSize(.small)
            Button("Löschen …") {
                state.requestDelete([DeleteTarget(url: d.url, size: d.localSize, name: d.folderName)])
            }
            .controlSize(.small)
        }
    }
}
