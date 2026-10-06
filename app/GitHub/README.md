# AlfredHelp

**AlfredHelp übersetzt den Mac-Ton live und hilft bei Fragen im Gespräch. Die Verarbeitung bleibt auf deinem Mac.**

[![CI](https://github.com/PalescoDev/AlfredHelp/actions/workflows/ci.yml/badge.svg)](https://github.com/PalescoDev/AlfredHelp/actions/workflows/ci.yml)
[![Lizenz: MIT](https://img.shields.io/badge/Lizenz-MIT-blue.svg)](LICENSE)

© 2026 PalescoDev

## Was die App macht

- Sie erfasst den Systemton, zum Beispiel aus Teams, Zoom oder dem Browser.
- Sie übersetzt live ins Deutsche und erkennt Fragen.
- Sie schlägt kurze Antworten vor.
- Sie kann das eigene Fenster bei einer Bildschirmfreigabe verbergen.

## KI-Unterstützung

AlfredHelp wurde mit KI-Unterstützung entwickelt. Davon getrennt nutzt die App selbst lokale KI über Ollama für Übersetzung, Frageerkennung, Antwortvorschläge und Gesprächszusammenfassungen.

Wie ich KI im Entwicklungsprozess eingesetzt habe, welche Aufgaben die Subagenten übernahmen und wie ich die Ergebnisse geprüft habe, steht in der [Dokumentation zum KI-Entwicklungsprozess](app/docs/KI-Entwicklungsprozess.md). Die Laufzeit-Prompts der App liegen zentral in [`Prompts.swift`](app/Sources/AlfredHelpCore/Intelligence/Prompts.swift).

## Installation

Nach dem Release findest du das signierte ZIP auf der [Release-Seite](https://github.com/PalescoDev/AlfredHelp/releases). Entpacke es und ziehe `dist/AlfredHelp.app` in den Programme-Ordner.

Beim ersten Start richtet AlfredHelp fehlende Komponenten ein. Dafür braucht es Internet. Für die Nutzung danach nicht.

## Voraussetzungen

- macOS 26 oder neuer und ein Apple-Chip
- 16 GB Arbeitsspeicher für `gemma3:4b`, 24 GB für `gemma3:12b`

## Datenschutz

- Mithören startet erst nach einem Klick. Der Autostart ist standardmäßig aus.
- Der Ton wird verarbeitet, aber nicht als Audiodatei gespeichert.
- Spracherkennung, Übersetzung und Antworten laufen lokal.
- Gesprächsprotokolle werden unter `~/Library/Application Support/AlfredHelp/Protokolle` gespeichert. Du kannst das in den Einstellungen abschalten.
- macOS verwaltet die nötige Freigabe. AlfredHelp fragt sie höchstens einmal ab.

## Bedienung

| Tastenkürzel | Funktion |
|---|---|
| `⌥⌘L` | Mithören starten oder stoppen |
| `⌥⌘O` | Fenster ein- oder ausblenden |
| `⌥⌘A` | Letzte Äußerung beantworten |

## Entwicklung

Quellcode, Bauanleitung und Tests liegen in [`app/`](app/README.md). Messwerte und technische Details stehen in der [Dokumentation](app/docs/Technische-Dokumentation.md).

```bash
./build.sh
(cd app && swift test)
```

Release-Unterlagen und Versionsskript liegen in [`PalescoDev/`](PalescoDev/README.md).

## Lizenz

[MIT](LICENSE). Ollama ist ein eigenständiges Projekt unter eigener MIT-Lizenz.
