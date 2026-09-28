# GitHub-Veröffentlichung

Hier liegen die Anleitung, Checkliste, Vorlagen und das Skript für ein AlfredHelp-Release.

## Dateien

- [`RELEASE-CHECKLISTE.md`](RELEASE-CHECKLISTE.md) — Ablauf von der Versionswahl bis zur Freigabe.
- [`RELEASE-NOTIZEN-VORLAGE.md`](RELEASE-NOTIZEN-VORLAGE.md) — deutscher Text für die GitHub-Veröffentlichung.
- [`RELEASE-MANIFEST.md`](RELEASE-MANIFEST.md) — benötigte Dateien, Geheimnisse und Prüfungen.
- [`VERSION_VORBEREITEN.sh`](VERSION_VORBEREITEN.sh) — SemVer-Vorschau und Versionsvorbereitung.

## Aktueller Stand

Es wird hiermit keine neue Version veröffentlicht. Die vorhandene lokale App-Kopie ist kein Release-Archiv. Für ein offizielles Release signiert der GitHub-Ablauf das Bündel mit Developer ID; Apple notarisiert es anschließend. Erst nach erfolgreicher Prüfung ist es bereit.

Das Skript verändert ohne `--anwenden` keine Dateien. Es erstellt nie selbst einen Commit, Tag oder eine Veröffentlichung.
