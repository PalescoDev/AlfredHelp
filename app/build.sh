#!/bin/bash
# Baut AlfredHelp.app – ein fertiges, startfähiges macOS-Bundle.
#
#   ./build.sh            Release-Build
#   ./build.sh debug      Debug-Build
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
CONFIG="${1:-release}"
APP="$ROOT/dist/AlfredHelp.app"
BINARY_NAME="AlfredHelp"

cd "$ROOT"

echo "▸ Kompiliere ($CONFIG) …"
swift build -c "$CONFIG" --product "$BINARY_NAME"
BIN_PATH="$(swift build -c "$CONFIG" --product "$BINARY_NAME" --show-bin-path)/$BINARY_NAME"

echo "▸ Baue Bundle …"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_PATH" "$APP/Contents/MacOS/$BINARY_NAME"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE.txt"
if [ -n "${APP_VERSION:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" \
    "$APP/Contents/Info.plist"
fi
if [ -n "${APP_BUILD:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $APP_BUILD" \
    "$APP/Contents/Info.plist"
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Symbol erzeugen (schlägt lautlos fehl, falls kein Fenster-Server verfügbar ist).
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
if swift "$ROOT/Resources/MakeIcon.swift" "$ICONSET" >/dev/null 2>&1; then
  if iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null; then
    echo "  Symbol erzeugt"
  fi
fi

echo "▸ Signiere …"
# Ohne Entwicklerzertifikat wird ad-hoc signiert. Nach einem Neubau kann macOS
# die Freigabe verwerfen. AlfredHelp fragt nicht erneut, sondern führt bei
# Bedarf in die Systemeinstellungen.
# Die Signatur bestimmt die TCC-Identität der App. Bei ad-hoc-Signatur ändert
# sich der cdhash mit jedem Build – macOS wirft dann alle erteilten
# Berechtigungen weg und liefert stattdessen stumme Audiopuffer.
IDENTITY="${CODESIGN_IDENTITY:-}"
ADHOC=0
if [ -z "$IDENTITY" ]; then
  if security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"; then
    IDENTITY="$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/')"
  else
    # Selbstsignierte Identitäten listet `-v` nicht auf – ihnen fehlt eine
    # vertrauenswürdige Wurzel. Für unseren Zweck ist das gleichgültig: die
    # Anforderung lautet dann `certificate root = H"…"` statt `cdhash`, und
    # genau das lässt die Freigabe einen Neubau überleben. Deshalb wird nach
    # dem Fingerabdruck gesucht statt nach Gültigkeit.
    # `|| true` ist hier nicht Bequemlichkeit, sondern nötig: Das Skript läuft
    # unter `set -euo pipefail`, und findet `grep` keine solche Identität,
    # bricht die Zuweisung den ganzen Bau ab – ausgerechnet auf jedem Rechner,
    # der die Identität nicht hat und deshalb den Ad-hoc-Weg unten nehmen
    # sollte. Genau daran scheiterte der Bau auf einem frischen Klon.
    FINGERPRINT="$(security find-identity 2>/dev/null \
      | grep "AlfredHelp Local Signing" | head -1 | awk '{print $2}' || true)"
    if [ -n "$FINGERPRINT" ]; then
      IDENTITY="$FINGERPRINT"
      echo "  Signaturidentität: AlfredHelp Local Signing ($FINGERPRINT)"
    else
      IDENTITY="-"
      ADHOC=1
    fi
  fi
fi

TIMESTAMP_ARG="--timestamp=none"
if [ "${CODE_SIGN_TIMESTAMP:-0}" = "1" ]; then
  TIMESTAMP_ARG="--timestamp"
fi

if [ "${CODE_SIGN_TIMESTAMP:-0}" = "1" ]; then
  # Ein Release darf bei einem Fehler nicht auf eine schwächere Signatur
  # zurückfallen: ohne Hardened Runtime und sicheren Zeitstempel lehnt Apple
  # die anschließende Notarisierung ab.
  codesign --force --deep \
    --sign "$IDENTITY" \
    --entitlements "$ROOT/Resources/AlfredHelp.entitlements" \
    --options runtime \
    "$TIMESTAMP_ARG" \
    "$APP"
else
  codesign --force --deep \
    --sign "$IDENTITY" \
    --entitlements "$ROOT/Resources/AlfredHelp.entitlements" \
    --options runtime \
    "$TIMESTAMP_ARG" \
    "$APP" 2>/dev/null || codesign --force --deep --sign "$IDENTITY" \
    --entitlements "$ROOT/Resources/AlfredHelp.entitlements" "$APP"
fi

echo "▸ Prüfe …"
codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/  /'

if [ "$ADHOC" = "1" ]; then
  cat <<'WARN'

┌─ Hinweis zur Signatur ───────────────────────────────────────────────┐
│ Ohne Zertifikat wird ad-hoc signiert. macOS bindet die Freigabe für  │
│ die Systemtonaufnahme an die Prüfsumme des Programms – nach jedem    │
│ Neubau ist sie deshalb weg, und die Aufnahme liefert nur noch Stille.│
│                                                                      │
│ Einmalig eine dauerhafte Identität anlegen:                          │
│   Schlüsselbundverwaltung öffnen                                     │
│   → Menü „Zertifikatsassistent“ → „Zertifikat erstellen …“           │
│   → Name: AlfredHelp Local Signing                                     │
│   → Identitätstyp: Selbstsigniertes Stammzertifikat                  │
│   → Zertifikatstyp: Codesignatur                                     │
│ build.sh benutzt sie danach automatisch, und die Freigabe bleibt.    │
└──────────────────────────────────────────────────────────────────────┘
WARN
fi

echo "▸ Lege Unterlagen bei …"
# Die Unterlagen kommen aus dem Quellbaum, damit sie nie veralten.
for doc in LIESMICH.md Fehlersuche.md Messwerte.md; do
  cp "$ROOT/Resources/dist/$doc" "$ROOT/dist/$doc"
  echo "  $doc"
done
# Nach `GitHub/Bereitstellen.command` ist README.md die kurze Startseite des
# Repositorys, und die technische Dokumentation liegt unter docs/. Vorher ist
# README.md selbst die Dokumentation. Beigelegt wird immer die ausführliche.
if [ -f "$ROOT/docs/Technische-Dokumentation.md" ]; then
  cp "$ROOT/docs/Technische-Dokumentation.md" "$ROOT/dist/Technische-Dokumentation.md"
else
  cp "$ROOT/README.md" "$ROOT/dist/Technische-Dokumentation.md"
fi
echo "  Technische-Dokumentation.md"

# Selbsttest zum Doppelklicken – erspart das Tippen des langen Pfades.
cat > "$ROOT/dist/Selbsttest.command" <<'SELFTEST'
#!/bin/bash
# AlfredHelp – Selbsttest. PalescoDev
cd "$(dirname "$0")"
if [ -d "/Applications/AlfredHelp.app" ]; then
  APP="/Applications/AlfredHelp.app"
else
  APP="$(pwd)/AlfredHelp.app"
fi
"$APP/Contents/MacOS/AlfredHelp" --selftest
echo
echo "Fenster kann geschlossen werden."
SELFTEST
chmod +x "$ROOT/dist/Selbsttest.command"
echo "  Selbsttest.command"

echo
echo "Fertig: $APP"
echo "Starten mit:  open \"$APP\""
