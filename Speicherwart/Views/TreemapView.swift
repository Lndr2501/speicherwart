import AppKit
import SwiftUI

struct TreemapItem: Identifiable, Sendable, Hashable {
    let id: String
    let name: String
    let size: Int64
    let url: URL?
    let isDirectory: Bool
}

enum Squarify {
    /// Squarified-Treemap (Bruls et al.): legt Elemente möglichst quadratisch in `rect`.
    static func layout(_ items: [TreemapItem], in rect: CGRect) -> [(TreemapItem, CGRect)] {
        let sorted = items.filter { $0.size > 0 }.sorted { $0.size > $1.size }
        let total = Double(sorted.reduce(Int64(0)) { $0 + $1.size })
        guard total > 0, rect.width > 0, rect.height > 0 else { return [] }
        let scale = Double(rect.width * rect.height) / total
        var result: [(TreemapItem, CGRect)] = []
        var remaining = sorted[...]
        var r = rect

        func worst(_ row: [TreemapItem], _ side: Double) -> Double {
            let areas = row.map { Double($0.size) * scale }
            let s = areas.reduce(0, +)
            guard let mx = areas.max(), let mn = areas.min(), s > 0, mn > 0 else { return .infinity }
            return max(side * side * mx / (s * s), (s * s) / (side * side * mn))
        }

        while !remaining.isEmpty {
            let side = Double(min(r.width, r.height))
            var row: [TreemapItem] = []
            var best = Double.infinity
            for item in remaining {
                let w = worst(row + [item], side)
                if row.isEmpty || w <= best {
                    row.append(item)
                    best = w
                } else {
                    break
                }
            }
            remaining.removeFirst(row.count)
            let rowArea = row.reduce(0.0) { $0 + Double($1.size) * scale }
            if r.width >= r.height {
                let colWidth = CGFloat(rowArea / Double(r.height))
                var y = r.minY
                for item in row {
                    let h = CGFloat(Double(item.size) * scale) / colWidth
                    result.append((item, CGRect(x: r.minX, y: y, width: colWidth, height: h)))
                    y += h
                }
                r = CGRect(x: r.minX + colWidth, y: r.minY, width: r.width - colWidth, height: r.height)
            } else {
                let rowHeight = CGFloat(rowArea / Double(r.width))
                var x = r.minX
                for item in row {
                    let w = CGFloat(Double(item.size) * scale) / rowHeight
                    result.append((item, CGRect(x: x, y: r.minY, width: w, height: rowHeight)))
                    x += w
                }
                r = CGRect(x: r.minX, y: r.minY + rowHeight, width: r.width, height: r.height - rowHeight)
            }
        }
        return result
    }

    /// Größen der direkten Kinder eines Ordners (parallel gemessen).
    static func children(of url: URL) -> [TreemapItem] {
        let kids = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]
        )) ?? []
        var items = [TreemapItem?](repeating: nil, count: kids.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: kids.count) { i in
            let k = kids[i]
            let v = try? k.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey])
            guard v?.isSymbolicLink != true else { return }
            let size = SizeScanner.allocatedSize(of: k)
            let isDir = v?.isDirectory == true && v?.isPackage != true
            let item = TreemapItem(id: k.path, name: k.lastPathComponent, size: size, url: k, isDirectory: isDir)
            lock.lock(); items[i] = item; lock.unlock()
        }
        return items.compactMap { $0 }.filter { $0.size > 0 }
    }
}

struct TreemapView: View {
    let state: AppState
    let analysis: AnalysisResult
    /// Pfad der aufgeklappten Ordner; leer = oberste Ebene.
    @State private var stack: [TreemapItem] = []
    @State private var levelItems: [TreemapItem] = []
    @State private var loading = false
    @State private var hovered: TreemapItem?

    private var topItems: [TreemapItem] {
        var items = analysis.folders.map { f in
            TreemapItem(id: f.path, name: f.displayName, size: f.size, url: f.url, isDirectory: true)
        }
        if let disk = state.disk {
            let apps = analysis.folders.first { $0.path == "/Applications" }?.size ?? 0
            let system = disk.used - analysis.homeTotal - apps
            if system > 0 {
                items.append(TreemapItem(id: "system", name: "macOS & System", size: system, url: nil, isDirectory: false))
            }
        }
        return items
    }

    /// Höchstens 60 Felder, der Rest wird zu „Weitere“ zusammengefasst.
    private func capped(_ items: [TreemapItem]) -> [TreemapItem] {
        let sorted = items.sorted { $0.size > $1.size }
        guard sorted.count > 60 else { return sorted }
        let rest = sorted.dropFirst(59).reduce(Int64(0)) { $0 + $1.size }
        return Array(sorted.prefix(59)) + [TreemapItem(id: "rest", name: "Weitere", size: rest, url: nil, isDirectory: false)]
    }

    var body: some View {
        let items = capped(stack.isEmpty ? topItems : levelItems)
        let total = items.reduce(Int64(0)) { $0 + $1.size }

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Button {
                    stack.removeLast()
                    Task { await reload() }
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(stack.isEmpty)
                Button("Alles") {
                    stack = []
                }
                .buttonStyle(.link)
                ForEach(Array(stack.enumerated()), id: \.offset) { i, item in
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    Button(i == 0 ? item.name : (item.url?.lastPathComponent ?? item.name)) {
                        stack = Array(stack.prefix(i + 1))
                        Task { await reload() }
                    }
                    .buttonStyle(.link)
                }
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Text(hovered.map { "\($0.name): \(formatBytes($0.size))" } ?? "Gesamt \(formatBytes(total))")
                    .font(.callout).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
            }

            GeometryReader { geo in
                let rects = Squarify.layout(items, in: CGRect(origin: .zero, size: geo.size))
                ZStack(alignment: .topLeading) {
                    ForEach(Array(rects.enumerated()), id: \.element.0.id) { index, pair in
                        tile(pair.0, rect: pair.1, slot: index)
                    }
                }
            }
            .opacity(loading ? 0.4 : 1)

            Text("Klick auf einen Ordner zeigt seinen Inhalt · Doppelklick zeigt ihn im Finder")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
    }

    private func tile(_ item: TreemapItem, rect: CGRect, slot: Int) -> some View {
        let fill = item.id == "rest" || item.id == "system" ? Palette.other : (slot < 8 ? Palette.slot(slot) : Palette.other)
        // Weiße Schrift auf Farbe; auf Gelb (Slot 3) dunkel für Kontrast.
        let ink: Color = slot == 3 && item.id != "rest" && item.id != "system" ? .black : .white
        let inset = rect.insetBy(dx: 1, dy: 1)
        return RoundedRectangle(cornerRadius: 4)
            .fill(fill)
            .opacity(hovered == nil || hovered?.id == item.id ? 1 : 0.75)
            .overlay(alignment: .topLeading) {
                if inset.width > 70, inset.height > 34 {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.url?.lastPathComponent ?? item.name).font(.caption.bold()).lineLimit(1)
                        Text(formatBytes(item.size)).font(.caption2).monospacedDigit()
                    }
                    .foregroundStyle(ink)
                    .padding(5)
                }
            }
            .frame(width: max(0, inset.width), height: max(0, inset.height))
            .offset(x: inset.minX, y: inset.minY)
            .onHover { inside in hovered = inside ? item : (hovered?.id == item.id ? nil : hovered) }
            .onTapGesture(count: 2) {
                if let url = item.url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            .onTapGesture {
                guard item.isDirectory, item.url != nil else { return }
                stack.append(item)
                Task { await reload() }
            }
            .help("\(item.name): \(formatBytes(item.size))")
            .contextMenu {
                if let url = item.url {
                    Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
            }
    }

    private func reload() async {
        guard let url = stack.last?.url else { levelItems = []; return }
        loading = true
        levelItems = await Task.detached(priority: .userInitiated) { Squarify.children(of: url) }.value
        loading = false
    }
}
