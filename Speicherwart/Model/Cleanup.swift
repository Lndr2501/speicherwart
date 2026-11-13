import AppKit

enum CleanupGroup: String, CaseIterable, Identifiable, Sendable {
    case standard, developer
    var id: String { rawValue }
    var title: String {
        switch self {
        case .standard: "Standard"
        case .developer: "Entwickler (optional)"
        }
    }
}

enum DeleteAction: Sendable, Hashable {
    /// Löscht das Element. Mit `minAgeDays` nur Dateien darin, die älter sind.
    case remove(minAgeDays: Int?)
    case simctlDelete(udid: String)
    /// Rust-Build-Ordner `target`; nur gültig mit `Cargo.toml` daneben.
    case removeRustTarget
}

struct CleanupItem: Identifiable, Sendable, Hashable {
    var id: String { url.path }
    let url: URL
    let name: String
    let size: Int64
    let action: DeleteAction
}

struct CollectResult: Sendable {
    var items: [CleanupItem] = []
    var accessDenied = false
    var total: Int64 { items.reduce(0) { $0 + $1.size } }

    static func + (a: CollectResult, b: CollectResult) -> CollectResult {
        CollectResult(
            items: (a.items + b.items).sorted { $0.size > $1.size },
            accessDenied: a.accessDenied || b.accessDenied
        )
    }
}

struct CleanupContext: Sendable {
    /// Bundle-IDs und Namen laufender Apps; deren Caches bleiben unangetastet.
    var runningApps: Set<String>

    @MainActor static func current() -> CleanupContext {
        let apps = NSWorkspace.shared.runningApplications
        return CleanupContext(runningApps: Set(apps.compactMap(\.bundleIdentifier) + apps.compactMap(\.localizedName)))
    }
}

struct CleanupTarget: Identifiable, Sendable {
    let id: String
    let name: String
    let detail: String
    let group: CleanupGroup
    let enabledByDefault: Bool
    let collect: @Sendable (CleanupContext) -> CollectResult
}

enum CleanupCatalog {
    /// Cache-Ordner unter ~/Library/Caches, die zu "Entwickler" gehören statt zu "App-Caches".
    static let devCacheNames: Set<String> = [
        "Homebrew", "pip", "Yarn", "CocoaPods", "go-build", "pnpm", "node-gyp", "ms-playwright",
    ]

    static let targets: [CleanupTarget] = [
        CleanupTarget(
            id: "trash", name: "Papierkorb", detail: "Alles im Papierkorb",
            group: .standard, enabledByDefault: true
        ) { _ in
            children(of: Paths.inHome(".Trash"))
        },
        CleanupTarget(
            id: "appCaches", name: "App-Caches", detail: "~/Library/Caches, ohne laufende Apps und System",
            group: .standard, enabledByDefault: true
        ) { ctx in
            children(of: Paths.inHome("Library/Caches")) { name in
                name.hasPrefix("com.apple.") || devCacheNames.contains(name)
                    || ctx.runningApps.contains(name) || name == Bundle.main.bundleIdentifier
            }
        },
        CleanupTarget(
            id: "tempLogs", name: "Temp-Dateien & Logs", detail: "Temp älter als 3 Tage, Logs älter als 7 Tage",
            group: .standard, enabledByDefault: true
        ) { _ in
            children(of: Paths.temp, minAgeDays: 3, prefix: "Temp: ")
                + children(of: Paths.inHome("Library/Logs"), minAgeDays: 7, prefix: "Logs: ")
        },
        CleanupTarget(
            id: "derivedData", name: "Xcode DerivedData", detail: "Build-Zwischenstände, werden neu erzeugt",
            group: .developer, enabledByDefault: false
        ) { _ in
            children(of: Paths.inHome("Library/Developer/Xcode/DerivedData"))
        },
        CleanupTarget(
            id: "deviceSupport", name: "Geräte-Support-Dateien", detail: "Werden beim Anschließen neu geladen",
            group: .developer, enabledByDefault: false
        ) { _ in
            deviceSupportDirs.reduce(CollectResult()) { $0 + children(of: $1, prefix: $1.lastPathComponent + ": ") }
        },
        CleanupTarget(
            id: "simulators", name: "Simulatoren", detail: "Nicht mehr verfügbare Geräte + Simulator-Caches",
            group: .developer, enabledByDefault: false
        ) { _ in
            unavailableSimulators()
                + children(of: Paths.inHome("Library/Developer/CoreSimulator/Caches"), prefix: "Cache: ")
        },
        CleanupTarget(
            id: "homebrew", name: "Homebrew-Cache", detail: "Heruntergeladene Pakete",
            group: .developer, enabledByDefault: false
        ) { _ in
            children(of: Paths.inHome("Library/Caches/Homebrew"))
        },
        CleanupTarget(
            id: "rustTargets", name: "Rust-Build-Ordner", detail: "target-Ordner neben Cargo.toml, wird beim Bauen neu erzeugt",
            group: .developer, enabledByDefault: false
        ) { _ in
            rustTargets()
        },
        CleanupTarget(
            id: "toolCaches", name: "Tool-Caches (~/.cache)", detail: "KI-Modelle, uv, Whisper … werden bei Bedarf neu geladen",
            group: .developer, enabledByDefault: false
        ) { _ in
            children(of: Paths.inHome(".cache"))
        },
        CleanupTarget(
            id: "packageCaches", name: "Paket-Caches", detail: "npm, pip, Yarn, pnpm, CocoaPods, Gradle, Go …",
            group: .developer, enabledByDefault: false
        ) { _ in
            packageCaches()
        },
    ]

    // MARK: - Sammeln

    static let deviceSupportDirs: [URL] = ["iOS", "watchOS", "tvOS", "visionOS", "macOS"].map {
        Paths.inHome("Library/Developer/Xcode/\($0) DeviceSupport")
    }

    /// Jedes direkte Kind von `dir` wird ein Eintrag.
    static func children(
        of dir: URL, minAgeDays: Int? = nil, prefix: String = "", skip: (String) -> Bool = { _ in false }
    ) -> CollectResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { return CollectResult() }
        guard let kids = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return CollectResult(accessDenied: true)
        }
        let cutoff = minAgeDays.map { Date().addingTimeInterval(-Double($0) * 86_400) }
        var items: [CleanupItem] = []
        for kid in kids where !skip(kid.lastPathComponent) {
            let size = SizeScanner.allocatedSize(of: kid, olderThan: cutoff)
            guard size > 0 else { continue }
            items.append(CleanupItem(
                url: kid, name: prefix + kid.lastPathComponent, size: size,
                action: .remove(minAgeDays: minAgeDays)
            ))
        }
        return CollectResult(items: items.sorted { $0.size > $1.size })
    }

    static func packageCaches() -> CollectResult {
        let candidates: [(String, URL)] = [
            ("npm", Paths.inHome(".npm/_cacache")),
            ("Gradle", Paths.inHome(".gradle/caches")),
        ] + devCacheNames.subtracting(["Homebrew"]).sorted().map {
            ($0, Paths.inHome("Library/Caches/\($0)"))
        }
        var items: [CleanupItem] = []
        for (name, url) in candidates where FileManager.default.fileExists(atPath: url.path) {
            let size = SizeScanner.allocatedSize(of: url)
            if size > 0 { items.append(CleanupItem(url: url, name: name, size: size, action: .remove(minAgeDays: nil))) }
        }
        return CollectResult(items: items.sorted { $0.size > $1.size })
    }

    /// Sucht `target`-Ordner von Rust-Projekten im Home (max. 5 Ebenen tief, ohne ~/Library).
    static func rustTargets() -> CollectResult {
        let fm = FileManager.default
        let skip: Set<String> = ["Library", "node_modules", "Pods", "DerivedData", "build", "dist"]
        guard let en = fm.enumerator(
            at: Paths.home, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in true }
        ) else { return CollectResult() }
        var items: [CleanupItem] = []
        for case let url as URL in en {
            guard let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  v.isDirectory == true, v.isSymbolicLink != true else { continue }
            let name = url.lastPathComponent
            if name == "target", Cleaner.isRustTarget(url) {
                en.skipDescendants()
                let size = SizeScanner.allocatedSize(of: url)
                if size > 0 {
                    let project = url.deletingLastPathComponent().path
                        .replacingOccurrences(of: Paths.home.path + "/", with: "~/")
                    items.append(CleanupItem(url: url, name: project, size: size, action: .removeRustTarget))
                }
            } else if skip.contains(name) || en.level >= 5 {
                en.skipDescendants()
            }
        }
        return CollectResult(items: items.sorted { $0.size > $1.size })
    }

    static func unavailableSimulators() -> CollectResult {
        guard let out = Shell.run("/usr/bin/xcrun", ["simctl", "list", "devices", "unavailable", "-j"]),
              out.status == 0,
              let json = try? JSONSerialization.jsonObject(with: out.output) as? [String: Any],
              let byRuntime = json["devices"] as? [String: [[String: Any]]]
        else { return CollectResult() }

        var items: [CleanupItem] = []
        for (runtime, devices) in byRuntime {
            let runtimeName = runtime.split(separator: ".").last.map(String.init) ?? runtime
            for d in devices {
                guard let udid = d["udid"] as? String else { continue }
                let name = d["name"] as? String ?? udid
                let dir = Paths.inHome("Library/Developer/CoreSimulator/Devices/\(udid)")
                let size = SizeScanner.allocatedSize(of: dir)
                items.append(CleanupItem(
                    url: dir, name: "\(name) (\(runtimeName))", size: size, action: .simctlDelete(udid: udid)
                ))
            }
        }
        return CollectResult(items: items.sorted { $0.size > $1.size })
    }
}

// MARK: - Löschen

struct CleanResult: Sendable {
    var freed: Int64 = 0
    var failures: [String] = []
}

enum Cleaner {
    /// Nur innerhalb dieser Ordner darf gelöscht werden (nie der Ordner selbst).
    static let allowedRoots: [URL] = [
        Paths.inHome(".Trash"),
        Paths.inHome("Library/Caches"),
        Paths.inHome("Library/Logs"),
        Paths.temp,
        Paths.inHome("Library/Developer/Xcode/DerivedData"),
        Paths.inHome("Library/Developer/CoreSimulator/Caches"),
        Paths.inHome(".npm"),
        Paths.inHome(".gradle"),
        Paths.inHome(".cache"),
    ] + CleanupCatalog.deviceSupportDirs

    static func isRustTarget(_ url: URL) -> Bool {
        let fm = FileManager.default
        let v = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
        return url.lastPathComponent == "target"
            && v?.isSymbolicLink != true
            && url.resolvingSymlinksInPath().path.hasPrefix(Paths.home.resolvingSymlinksInPath().path + "/")
            && fm.fileExists(atPath: url.deletingLastPathComponent().appendingPathComponent("Cargo.toml").path)
    }

    static func isSafe(_ url: URL) -> Bool {
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().path
        let full = parent + "/" + url.lastPathComponent
        return allowedRoots.contains { root in
            full.hasPrefix(root.resolvingSymlinksInPath().path + "/")
        }
    }

    static func perform(_ items: [CleanupItem]) -> CleanResult {
        var result = CleanResult()
        let fm = FileManager.default
        for item in items {
            switch item.action {
            case .remove(let minAgeDays):
                guard isSafe(item.url) else {
                    result.failures.append("\(item.name): außerhalb erlaubter Ordner")
                    continue
                }
                if let minAgeDays {
                    let cutoff = Date().addingTimeInterval(-Double(minAgeDays) * 86_400)
                    result.freed += removeOldFiles(in: item.url, cutoff: cutoff, failures: &result.failures)
                } else {
                    do {
                        try fm.removeItem(at: item.url)
                        result.freed += item.size
                    } catch {
                        result.failures.append("\(item.name): \(error.localizedDescription)")
                    }
                }
            case .removeRustTarget:
                guard isRustTarget(item.url) else {
                    result.failures.append("\(item.name): kein Rust-Build-Ordner")
                    continue
                }
                do {
                    try fm.removeItem(at: item.url)
                    result.freed += item.size
                } catch {
                    result.failures.append("\(item.name): \(error.localizedDescription)")
                }
            case .simctlDelete(let udid):
                if Shell.run("/usr/bin/xcrun", ["simctl", "delete", udid])?.status == 0 {
                    result.freed += item.size
                } else {
                    result.failures.append("\(item.name): simctl fehlgeschlagen")
                }
            }
        }
        return result
    }

    private static func removeOldFiles(in url: URL, cutoff: Date, failures: inout [String]) -> Int64 {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
            .contentModificationDateKey, .totalFileAllocatedSizeKey,
        ]
        func removeIfOld(_ file: URL) -> Int64 {
            guard let v = try? file.resourceValues(forKeys: keys),
                  v.isRegularFile == true || v.isSymbolicLink == true,
                  let modified = v.contentModificationDate, modified < cutoff
            else { return 0 }
            do {
                try FileManager.default.removeItem(at: file)
                return Int64(v.totalFileAllocatedSize ?? 0)
            } catch {
                failures.append("\(file.lastPathComponent): \(error.localizedDescription)")
                return 0
            }
        }

        guard let v = try? url.resourceValues(forKeys: keys) else { return 0 }
        if v.isDirectory != true || v.isSymbolicLink == true { return removeIfOld(url) }
        guard let en = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: Array(keys), errorHandler: { _, _ in true }
        ) else { return 0 }
        var freed: Int64 = 0
        for case let file as URL in en { freed += removeIfOld(file) }
        return freed
    }
}
