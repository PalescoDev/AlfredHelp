#!/bin/bash
# AlfredHelp – stellt Veröffentlichungsunterlagen im GitHub-Repository bereit.
# Vorschau zuerst; kopiert wird nur nach ausdrücklicher Eingabe von "ja".
# PalescoDev
set -euo pipefail

HIER="$(cd "$(dirname "$0")" && pwd)"
PROJEKT="$(cd "$HIER/.." && pwd)"
if WURZEL="$(git -C "$HIER" rev-parse --show-toplevel 2>/dev/null)"; then
  :
else
  WURZEL="$(cd "$PROJEKT/.." && pwd)"
fi

blau()  { printf '\033[0;36m%s\033[0m\n' "$1"; }
gruen() { printf '\033[0;32m%s\033[0m\n' "$1"; }
warn()  { printf '\033[0;33m%s\033[0m\n' "$1"; }

echo
blau "AlfredHelp – Veröffentlichungsunterlagen bereitstellen"
echo "Projekt: $PROJEKT"
echo "GitHub-Wurzel: $WURZEL"
echo

DATEIEN=(README.md LICENSE CHANGELOG.md CONTRIBUTING.md CODE_OF_CONDUCT.md SECURITY.md .gitattributes)
echo "Es wird kopiert:"
for datei in "${DATEIEN[@]}"; do
  if [ -e "$WURZEL/$datei" ]; then
    echo "  Richtig/GitHub/$datei → $datei (vorhandene Datei wird ersetzt)"
  else
    echo "  Richtig/GitHub/$datei → $datei"
  fi
done
echo "  Richtig/GitHub/.github/ → .github/ (Abläufe sowie Formulare für Fehler und Änderungswünsche)"
echo
warn "Die Kopien im GitHub-Wurzelordner bleiben nötig, damit GitHub README, Lizenz und Abläufe erkennt."
echo
printf 'Fortfahren? Bitte "ja" eingeben: '
read -r ANTWORT
if [ "$ANTWORT" != "ja" ]; then
  echo "Abgebrochen. Es wurde nichts verändert."
  exit 0
fi

echo
for datei in "${DATEIEN[@]}"; do
  cp "$HIER/$datei" "$WURZEL/$datei"
  echo "  ✓ $datei"
done
mkdir -p "$WURZEL/.github"
cp -R "$HIER/.github/." "$WURZEL/.github/"
echo "  ✓ .github/"

if [ -f "$PROJEKT/docs/bilder/LIESMICH.md" ]; then
  echo "  ✓ Screenshot-Hinweis liegt unter Richtig/docs/bilder/"
else
  mkdir -p "$PROJEKT/docs/bilder"
  cat > "$PROJEKT/docs/bilder/LIESMICH.md" <<'PLATZHALTER'
# Bilder

`overlay.png` bindet die README ein und wird zusätzlich als Vorschaubild des
Repositorys gebraucht (1280 × 640 px).
PLATZHALTER
  echo "  ✓ Richtig/docs/bilder/ (Screenshot-Hinweis angelegt)"
fi

echo
echo "Noch offene Kontakt-Platzhalter:"
grep -rln "TODO-KONTAKT" "$WURZEL" --include="*.md" \
  --exclude-dir=Archive --exclude-dir=GitHub --exclude-dir=.build --exclude-dir=.git 2>/dev/null \
  | sed "s|^$WURZEL/|  · Kontaktadresse eintragen in: |" || true
[ -f "$PROJEKT/docs/bilder/overlay.png" ] \
  || echo "  · Bildschirmfoto: Richtig/docs/bilder/overlay.png"
echo "  · Versionsnummer: Richtig/Resources/Info.plist"
echo "  · Release-Checkliste: Richtig/GitHub/Release/Release-Checkliste.md"
echo
echo "Dieses Skript kopiert nur lokal. Commit, Push und Veröffentlichung bleiben getrennte Schritte."
