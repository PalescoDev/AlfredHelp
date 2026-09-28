#!/bin/bash
# Bereitet die nächste SemVer-Fassung vor. Erst --anwenden ändert Dateien.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

usage() {
  cat <<'HELP'
Verwendung:
  ./PalescoDev/VERSION_VORBEREITEN.sh {major|minor|patch} [--anwenden]

Ohne --anwenden zeigt das Skript nur die geplanten Änderungen.
Mit --anwenden aktualisiert es die Versionsnummer und Änderungsprotokolle.
Es erstellt weder Commit noch Git-Tag.
HELP
}

if [ "$#" -eq 1 ] && [[ "$1" == "--hilfe" ]]; then
  usage
  exit 0
fi
if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  usage
  exit 2
fi
BUMP="$1"
APPLY="${2:-}"
if [[ "$BUMP" != "major" && "$BUMP" != "minor" && "$BUMP" != "patch" ]]; then
  usage
  exit 2
fi
if [[ -n "$APPLY" && "$APPLY" != "--anwenden" ]]; then
  usage
  exit 2
fi

if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
  echo "Fehler: Das Skript muss in einem Git-Repository laufen." >&2
  exit 1
fi

LATEST_TAG=""
while IFS= read -r CANDIDATE; do
  if [[ "$CANDIDATE" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    LATEST_TAG="$CANDIDATE"
    break
  fi
done < <(git tag --list 'v[0-9]*' --sort=-version:refname)

if [[ -z "$LATEST_TAG" ]]; then
  echo "Fehler: Kein SemVer-Tag wie v1.2.3 gefunden." >&2
  exit 1
fi
if [[ ! "$LATEST_TAG" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  echo "Fehler: Ungültiger letzter Tag: $LATEST_TAG" >&2
  exit 1
fi
BASE_MAJOR="${BASH_REMATCH[1]}"
BASE_MINOR="${BASH_REMATCH[2]}"
BASE_PATCH="${BASH_REMATCH[3]}"
BASE_VERSION="$BASE_MAJOR.$BASE_MINOR.$BASE_PATCH"

PLIST="Richtig/Resources/Info.plist"
SOURCE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
if [[ "$SOURCE_VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  NORMAL_SOURCE_VERSION="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.0"
elif [[ "$SOURCE_VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  NORMAL_SOURCE_VERSION="$SOURCE_VERSION"
else
  echo "Fehler: Info.plist enthält keine gültige SemVer-Version: $SOURCE_VERSION" >&2
  exit 1
fi
if [[ "$NORMAL_SOURCE_VERSION" != "$BASE_VERSION" ]]; then
  echo "Fehler: Letzter Tag ist $LATEST_TAG, Info.plist enthält aber $SOURCE_VERSION." >&2
  echo "Zuerst müssen Quellversion und letzter Release-Tag zusammenpassen." >&2
  exit 1
fi

if ! grep -Fq "## [$BASE_VERSION]" CHANGELOG.md; then
  echo "Fehler: CHANGELOG.md enthält keinen Abschnitt für $BASE_VERSION." >&2
  exit 1
fi
if ! cmp -s CHANGELOG.md Richtig/GitHub/CHANGELOG.md; then
  echo "Fehler: CHANGELOG.md und Richtig/GitHub/CHANGELOG.md sind nicht synchron." >&2
  exit 1
fi
LOCAL_CHANGELOG_TMP="$(mktemp)"
sed 's@Richtig/Benchmarks/@Benchmarks/@g' CHANGELOG.md > "$LOCAL_CHANGELOG_TMP"
if ! cmp -s "$LOCAL_CHANGELOG_TMP" Richtig/CHANGELOG.md; then
  rm -f "$LOCAL_CHANGELOG_TMP"
  echo "Fehler: Richtig/CHANGELOG.md ist nicht mit dem Änderungsprotokoll synchron." >&2
  exit 1
fi
rm -f "$LOCAL_CHANGELOG_TMP"

case "$BUMP" in
  major) NEXT_MAJOR=$((BASE_MAJOR + 1)); NEXT_MINOR=0; NEXT_PATCH=0 ;;
  minor) NEXT_MAJOR="$BASE_MAJOR"; NEXT_MINOR=$((BASE_MINOR + 1)); NEXT_PATCH=0 ;;
  patch) NEXT_MAJOR="$BASE_MAJOR"; NEXT_MINOR="$BASE_MINOR"; NEXT_PATCH=$((BASE_PATCH + 1)) ;;
esac
NEXT_VERSION="$NEXT_MAJOR.$NEXT_MINOR.$NEXT_PATCH"
NEXT_TAG="v$NEXT_VERSION"
if git rev-parse --verify --quiet "refs/tags/$NEXT_TAG" >/dev/null; then
  echo "Fehler: Der Tag $NEXT_TAG existiert bereits." >&2
  exit 1
fi

# Nie über ungespeicherte Änderungen an den Zieldateien schreiben. Die Vorschau
# bleibt erlaubt, damit man die nächste Fassung auch vor dem Commit prüfen kann.
if [[ "$APPLY" == "--anwenden" ]]; then
  for TARGET in "$PLIST" CHANGELOG.md Richtig/CHANGELOG.md Richtig/GitHub/CHANGELOG.md; do
    if [ -n "$(git status --porcelain -- "$TARGET")" ]; then
      echo "Fehler: $TARGET enthält nicht gespeicherte Änderungen." >&2
      echo "Bitte erst prüfen und committen, dann die Fassung vorbereiten." >&2
      exit 1
    fi
  done
fi

RELEASE_DATE="$(date +%Y-%m-%d)"
printf 'Letzter Release:       %s\n' "$LATEST_TAG"
printf 'Quellversion:          %s\n' "$SOURCE_VERSION"
printf 'Erhöhung:              %s\n' "$BUMP"
printf 'Neue Version:          %s\n' "$NEXT_VERSION"
printf 'Änderungsprotokoll:    Noch nicht veröffentlicht → %s (%s)\n' "$NEXT_VERSION" "$RELEASE_DATE"
printf 'Veröffentlichungsnotiz: Richtig/GitHub/Release/Release-Notes-%s.md (vor dem Tag aus Vorlage anlegen und ausfüllen)\n' "$NEXT_TAG"

if [[ "$APPLY" != "--anwenden" ]]; then
  echo "Vorschau: keine Dateien geändert. Für die Änderung --anwenden ergänzen."
  exit 0
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/palescodev-version.XXXXXX")"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT INT TERM

cp "$PLIST" "$TMP_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NEXT_VERSION" "$TMP_DIR/Info.plist" > /dev/null

make_changelog() {
  INPUT="$1"
  OUTPUT="$2"
  LOCAL_PATHS="$3"
  awk -v version="$NEXT_VERSION" -v previous="$BASE_VERSION" -v date="$RELEASE_DATE" '
    /^## \[Noch nicht veröffentlicht\]$/ {
      print "## [Noch nicht veröffentlicht]"
      print ""
      print "## [" version "] – " date
      next
    }
    /^\[Noch nicht veröffentlicht\]:/ {
      print "[Noch nicht veröffentlicht]: https://github.com/PalescoDev/AlfredHelp/compare/v" version "...HEAD"
      print "[" version "]: https://github.com/PalescoDev/AlfredHelp/releases/tag/v" version
      next
    }
    { print }
  ' "$INPUT" > "$OUTPUT"
  if [[ "$LOCAL_PATHS" == "ja" ]]; then
    sed 's@Richtig/Benchmarks/@Benchmarks/@g' "$OUTPUT" > "$OUTPUT.local"
    mv "$OUTPUT.local" "$OUTPUT"
  fi
}

make_changelog CHANGELOG.md "$TMP_DIR/CHANGELOG.md" nein
make_changelog CHANGELOG.md "$TMP_DIR/GitHub-CHANGELOG.md" nein
make_changelog CHANGELOG.md "$TMP_DIR/Richtig-CHANGELOG.md" ja

# Vor dem Ersetzen prüfen, dass alle erzeugten Änderungsprotokolle einen neuen
# Unreleased-Abschnitt und die Versionslinks enthalten.
for FILE in "$TMP_DIR/CHANGELOG.md" "$TMP_DIR/GitHub-CHANGELOG.md" "$TMP_DIR/Richtig-CHANGELOG.md"; do
  grep -Fq "## [$NEXT_VERSION] – $RELEASE_DATE" "$FILE"
  grep -Fq "[$NEXT_VERSION]: https://github.com/PalescoDev/AlfredHelp/releases/tag/$NEXT_TAG" "$FILE"
done

mv "$TMP_DIR/Info.plist" "$PLIST"
mv "$TMP_DIR/CHANGELOG.md" CHANGELOG.md
mv "$TMP_DIR/GitHub-CHANGELOG.md" Richtig/GitHub/CHANGELOG.md
mv "$TMP_DIR/Richtig-CHANGELOG.md" Richtig/CHANGELOG.md

echo "Fassung $NEXT_VERSION vorbereitet. Dateien prüfen, testen und gezielt committen."
echo "Es wurden weder ein Commit noch ein Tag erstellt."
