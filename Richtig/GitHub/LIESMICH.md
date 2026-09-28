# GitHub-Unterlagen

Die GitHub-Workflows und Pflichtdateien liegen im Repository-Hauptordner. Dieser Ordner enthält vorbereitete Kopien und Release-Unterlagen.

<sub>PalescoDev</sub>

## Inhalt

- `README.md`, `CONTRIBUTING.md`, `CHANGELOG.md`, `SECURITY.md` und `CODE_OF_CONDUCT.md` — deutschsprachige Repository-Texte.
- `.github/` — Issue- und Pull-Request-Vorlagen sowie CI- und Release-Ablauf.
- `Release/` — Release-Checkliste und die Notiz zur ersten Fassung.
- `Bereitstellen.command` — stellt GitHub-Dateien am erwarteten Ort bereit.

Das vollständige Release-Kit liegt unter [`PalescoDev/`](../../PalescoDev/README.md). Die Versionsvorbereitung zeigt zunächst eine Vorschau und schreibt erst mit `--anwenden` Änderungen. Sie erstellt keinen Commit und keinen Tag.

## Veröffentlichung

Ein lokales Programmbündel ist nicht automatisch veröffentlichungsfertig. Der GitHub-Release-Ablauf verlangt Developer-ID-Signatur und Apple-Notarisierung, prüft den Tag gegen die Quellversion und erstellt danach nur einen Entwurf. Erst nach manueller Prüfung wird veröffentlicht.
