# Speicherwart

Menüleisten-App für macOS, die den Speicher im Blick behält: zeigt, was wie viel Platz belegt, findet Müll und warnt, wenn es eng wird. Aufgeräumt wird nie automatisch, nur nach Bestätigung.

*A macOS menu bar app that watches your disk space, finds junk and large files, and warns you before the disk fills up. UI is in German.*

## Funktionen

**Menüleiste**
- Freier Speicher direkt in der Menüleiste, Warnsymbol und Mitteilung unter einer einstellbaren Grenze (Standard: 50 GB)
- Balken nach Kategorien: Apps, App-Daten, Dokumente, eigene Ordner, Medien, Entwickler, Cloud, Müll, System
- Müll-Liste mit Haken und Vorschau:
  - Standard: Papierkorb, App-Caches, Temp-Dateien & Logs
  - Optional (Entwickler): Xcode DerivedData, Simulatoren, Geräte-Support, Homebrew, Paket-Caches (npm, pip, Yarn …), Rust-`target`-Ordner, `~/.cache`
- 7-Tage-Trend mit Mini-Kurve

**Analyse-Fenster**
- **Übersicht:** Kreisdiagramm „Was frisst am meisten“
- **Treemap:** Ordner als Rechtecke, Klick zum Hineinzoomen
- **Große Dateien:** filterbar nach Downloads, Cloud-Ordnern, Apps
- **Lange ungenutzt:** große Dateien und Apps, die laut Spotlight seit Monaten nicht geöffnet wurden
- **Duplikate:** Vergleich per SHA-256, pro Gruppe bleibt immer eine Datei erhalten
- **Backups:** iPhone-/iPad-Backups, iOS-Updates, lokale Time-Machine-Schnappschüsse
- **Cloud:** lokal geladene Dateien von File-Provider-Konten (iCloud, SeaDrive, Nextcloud …) per „Download entfernen“ freigeben, verwaiste Kopien entfernter Konten erkennen
- **Verlauf:** stündliche Messung, Kurve und Veränderung pro Kategorie

**Widget** (klein und mittel) für Schreibtisch und Mitteilungszentrale.

## Sicherheit

- Gelöscht wird nur innerhalb fest definierter Ordner (Caches, Logs, Temp, Papierkorb …). Rust-`target`-Ordner nur, wenn daneben eine `Cargo.toml` liegt.
- Caches laufender Apps und von `com.apple.*` bleiben unangetastet.
- Große Dateien, Backups und Duplikate wandern in den Papierkorb, nicht direkt ins Nichts.
- Cloud-Dateien werden nur „entladen“, wenn sie vollständig hochgeladen sind.
- Cloud-Ordner werden beim Duplikat-Vergleich nie gelesen, damit nichts heruntergeladen wird.

## Voraussetzungen

- macOS 26 oder neuer
- Xcode 26 oder neuer
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- Ein Apple-Development-Zertifikat (kostenloser Apple-Account in Xcode reicht)

## Bauen

```bash
./scripts/build.sh            # nur bauen
./scripts/build.sh --install  # nach /Applications kopieren und starten
```

Das Skript erzeugt das Xcode-Projekt mit XcodeGen, baut ohne Signatur und signiert danach App und Widget. Per SSH funktioniert das ebenfalls: Signiert wird über die angemeldete GUI-Sitzung, weil der Schlüsselbund per SSH gesperrt ist.

**Zertifikat wählen:** Standard ist `Apple Development`. Bei mehreren Zertifikaten den SHA-1-Wert aus `security find-identity -v -p codesigning` in die Datei `.signing-identity` schreiben (wird nicht eingecheckt) oder `SIGN_IDENTITY=…` setzen.

**Eigenes Team:** Die App-Gruppe fürs Widget enthält die Team-ID. Für ein anderes Team `PKK5ZQ9PNH` ersetzen in:
`project.yml`, `Config/App.entitlements`, `Config/Widget.entitlements`, `Speicherwart/Shared/WidgetShared.swift`.

Nach dem ersten Start: **Systemeinstellungen → Datenschutz & Sicherheit → Festplattenvollzugriff → Speicherwart** aktivieren. Ohne diesen Zugriff sind Papierkorb und manche Ordner nicht lesbar.

## Im Terminal testen (löscht nichts)

```bash
S=/Applications/Speicherwart.app/Contents/MacOS/Speicherwart
$S --report      # Kategorien und Müll
$S --analyze     # Tiefenanalyse, große Dateien, Backups, Cloud
$S --duplicates  # Duplikate ab 10 MB
```

## Aufbau

```
Speicherwart/
  App.swift              Einstieg, Menüleiste, Analyse-Fenster, Terminal-Modi
  Model/                 Scanner, Müll-Katalog, Analyse, Cloud, Verlauf, Duplikate
  Views/                 Popover, Analyse-Bereiche, Treemap, Palette
  Shared/                Datenaustausch App ↔ Widget
Widget/                  WidgetKit-Erweiterung
Config/                  Entitlements und Widget-Info.plist
scripts/build.sh         Bauen, signieren, installieren
```

Die App läuft ohne Sandbox, weil sie fremde Caches lesen und löschen muss. Sie ist daher nicht für den App Store gedacht.
