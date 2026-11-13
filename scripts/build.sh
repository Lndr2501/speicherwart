#!/bin/bash
# Baut Speicherwart. Mit --install: nach /Applications kopieren und neu starten.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="/opt/homebrew/bin:$PATH"
# Signatur-Zertifikat: Umgebungsvariable SIGN_IDENTITY, sonst Datei .signing-identity
# (nicht im Repo, z.B. SHA-1 aus `security find-identity -v -p codesigning`), sonst "Apple Development".
IDENTITY="${SIGN_IDENTITY:-$(cat .signing-identity 2>/dev/null || echo "Apple Development")}"
command -v xcodegen >/dev/null || { echo "XcodeGen fehlt: brew install xcodegen" >&2; exit 1; }
mkdir -p .build
xcodegen generate --quiet
# Signiert wird separat (siehe unten), damit es auch per SSH funktioniert.
xcodebuild -project Speicherwart.xcodeproj -scheme Speicherwart -configuration Release \
  -derivedDataPath .build/dd CODE_SIGNING_ALLOWED=NO build > .build/build.log 2>&1 || {
  grep -E "error:" .build/build.log | cut -c1-300 | sort -u | head -40
  tail -5 .build/build.log | cut -c1-300
  exit 1
}
app="$PWD/.build/dd/Build/Products/Release/Speicherwart.app"

# Per SSH ist der Schlüsselbund gesperrt. Darum codesign als Job in der
# angemeldeten GUI-Sitzung starten. Eine feste Signatur sorgt dafür, dass
# der Festplattenvollzugriff nach einem Neubau erhalten bleibt.
sign() {
  # Erst das Widget (Sandbox + App-Gruppe), dann die App (App-Gruppe).
  local cmds="/usr/bin/codesign --force --sign '$IDENTITY' --entitlements '$PWD/Config/Widget.entitlements' '$app/Contents/PlugIns/SpeicherwartWidget.appex' && /usr/bin/codesign --force --sign '$IDENTITY' --entitlements '$PWD/Config/App.entitlements' '$app'"
  if [[ -z "${SSH_CONNECTION:-}" ]]; then
    sh -c "$cmds"; return
  fi
  local label="ch.semlitsch.speicherwart.sign" log="$PWD/.build/sign.log" plist="$PWD/.build/sign.plist"
  rm -f "$log"
  local esc=${cmds//&/&amp;}; esc=${esc//</&lt;}; esc=${esc//>/&gt;}
  cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$label</string>
<key>ProgramArguments</key><array><string>/bin/sh</string><string>-c</string>
<string>($esc) &gt; '$log' 2&gt;&amp;1; echo rc=\$? &gt;&gt; '$log'</string></array>
<key>RunAtLoad</key><true/>
</dict></plist>
PLIST
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$plist"
  for _ in $(seq 1 30); do grep -q '^rc=' "$log" 2>/dev/null && break; sleep 1; done
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
  grep -q '^rc=0' "$log"
}
if sign; then
  echo "Signiert mit Apple Development"
else
  echo "Signieren fehlgeschlagen, nutze Ad-hoc-Signatur (Festplattenvollzugriff muss nach jedem Build neu erteilt werden)" >&2
  cat .build/sign.log 2>/dev/null >&2 || true
  codesign --force --sign - --entitlements Config/Widget.entitlements "$app/Contents/PlugIns/SpeicherwartWidget.appex"
  codesign --force --sign - "$app"
fi
echo "Gebaut: $app"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Speicherwart 2>/dev/null || true
  sleep 1
  rm -rf /Applications/Speicherwart.app
  ditto "$app" /Applications/Speicherwart.app
  open /Applications/Speicherwart.app
  echo "Installiert und gestartet: /Applications/Speicherwart.app"
fi
