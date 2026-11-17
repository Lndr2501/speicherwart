import SwiftUI

/// Kleiner Papierkorb-Knopf für Listenzeilen. Geschützte Ordner sind ausgegraut, der Tooltip nennt den Grund.
struct DeleteButton: View {
    let state: AppState
    let target: DeleteTarget

    var body: some View {
        let reason = DeleteGuard.blockReason(target.url)
        Button {
            state.requestDelete([target])
        } label: {
            Image(systemName: "trash")
        }
        .buttonStyle(.borderless)
        .disabled(reason != nil || state.isRemoving)
        .help(reason ?? "Löschen …")
    }
}

private struct DeleteConfirmation: ViewModifier {
    @Bindable var state: AppState

    private var title: String {
        let t = state.pendingDelete
        return t.count == 1 ? "„\(t[0].name)“ löschen?" : "\(t.count) Objekte löschen?"
    }

    private var message: String {
        let t = state.pendingDelete
        var lines = [
            "Zusammen \(formatBytes(t.reduce(0) { $0 + $1.size })).",
            "Papierkorb: rückgängig machbar, der Platz wird erst nach dem Leeren frei.",
            "Endgültig: sofort frei, nicht rückgängig.",
        ]
        lines += DeleteGuard.warnings(for: t).map { "⚠︎ " + $0 }
        return lines.joined(separator: "\n")
    }

    /// Auswahl sofort übernehmen: Beim Schließen des Dialogs wird `pendingDelete` geleert.
    private func confirm(permanent: Bool) {
        let targets = state.pendingDelete
        state.pendingDelete = []
        Task { await state.confirmDelete(targets, permanent: permanent) }
    }

    func body(content: Content) -> some View {
        content.confirmationDialog(
            title,
            isPresented: Binding(
                get: { !state.pendingDelete.isEmpty },
                set: { if !$0 { state.pendingDelete = [] } }
            ),
            titleVisibility: .visible
        ) {
            Button("In den Papierkorb") { confirm(permanent: false) }
            Button("Endgültig löschen", role: .destructive) { confirm(permanent: true) }
        } message: {
            Text(message)
        }
    }
}

extension View {
    /// Gemeinsamer Löschdialog für alle Ansichten; ausgelöst durch `AppState.requestDelete`.
    func deleteConfirmation(state: AppState) -> some View {
        modifier(DeleteConfirmation(state: state))
    }
}
