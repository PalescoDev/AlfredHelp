# AlfredHelp – Projektcode

Dieses Verzeichnis enthält die aktive macOS-App, ihre Tests und Bauanleitung.

## Voraussetzungen

macOS 26 oder neuer, Apple-Chip und Xcode mit Swift. Für `gemma3:4b` werden 16 GB Arbeitsspeicher empfohlen.

## Bauen

```bash
./build.sh
open dist/AlfredHelp.app
```

Das fertige App-Bündel liegt in `dist/`. Ohne Entwicklerzertifikat wird es lokal signiert. Für eine Veröffentlichung sind Developer-ID-Signatur und Apple-Notarisierung nötig.

## Testen

```bash
swift test
```

Der Laufzeittest prüft Ollama, installierte Modelle, Spracherkennung und den gewählten Audio-Pfad. Er speichert keine Audiodaten oder Transkripte. `--privacy-check` prüft die Bildschirmfreigabe mit einem Fenstervergleich.

## Ordner

- `Sources/AlfredHelpApp/` – Menüleiste, Fenster und Einstellungen
- `Sources/AlfredHelpCore/` – Audio, Erkennung, Pipeline und Ollama
- `Tests/` – automatisierte Tests
- `Benchmarks/` – Messdaten und Auswertung
- `docs/` – technische Dokumentation und Fehlerhilfe
- `../PalescoDev/` – Release-Unterlagen und Versionsskript

Die Oberfläche und die Nutzerdokumentation sind auf Deutsch. Lizenz: [MIT](LICENSE).
