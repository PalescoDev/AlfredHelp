# AlfredHelp 1.0.0

**AlfredHelp hört den Mac-Ton mit, übersetzt live ins Deutsche und beantwortet Fragen der Gegenseite. Alles läuft lokal – ohne Konto, Cloud oder Internet während der Nutzung.**

Erste Veröffentlichung.

## Signatur und erster Start

Offizielle Release-Archive sind mit einer Developer ID signiert und von Apple notarisiert. Nach dem Kopieren in den Programme-Ordner lassen sie sich normal öffnen.

Lokal gebaute Versionen ohne Developer ID können einen Rechtsklick und *Öffnen* erfordern. In Version 1.0.0 konnte macOS bei ad-hoc-Signatur nach jedem Neubau erneut nach der Systemton-Freigabe fragen.

## Installation

`AlfredHelp-v1.0.0.zip` laden und entpacken. In `dist/` liegt `AlfredHelp.app`. Die App in den Programme-Ordner ziehen und öffnen.

## Einrichtung

Beim ersten Start lädt die App fehlende Bestandteile: Ollama (ca. 180 MB, Signatur des Anbieters geprüft), das Sprachmodell `gemma3:4b` (3,3 GB) und die Spracherkennungsdaten für die gewählte Sprache. Das Einrichtungsfenster zeigt den Fortschritt. Vorhandene Ollama-Installationen und eigene Modelle bleiben unangetastet.

Die Freigabe für Systemton kann nur macOS erteilen. Das Einrichtungsfenster führt durch die Freigabe und prüft danach mit echten Tonproben, ob sie wirkt.

**Voraussetzungen:** macOS 26 oder neuer, Apple-Chip, 16 GB Arbeitsspeicher.

## Enthalten

- Systemtonaufnahme aus jeder App
- Live-Übersetzung ins Deutsche, Satz für Satz
- Zweistufige Fragenerkennung: **Präzision und Trefferquote je 1,000** auf 162 markierten deutschen und englischen Beispielen; mittlere Erkennung **0 ms** nach Satzende
- Antwortkarten mit vorlesbarem Satz und ausklappbarer Begründung
- Antwort auf einzelne Äußerungen per Klick, wenn die automatische Erkennung eine Frage übersieht
- Bei Bildschirmfreigaben unsichtbares Fenster, prüfbar mit `--privacy-check`
- Modellauswahl mit Messwerten

## Datenschutz

Ton wird nie auf die Festplatte geschrieben. Übersetzung, Fragenerkennung und Antworten laufen über Ollama auf `127.0.0.1`. Der HTTP-Client ist auf Loopback festgelegt und verwendet keinen Proxy. Der einzige ausgehende Netzwerkzugriff ist der Ollama-Download bei der Ersteinrichtung.

## Tastenkürzel

| Tastenkürzel | Funktion |
|---|---|
| `⌥⌘L` | Mithören starten oder stoppen |
| `⌥⌘O` | Fenster ein- oder ausblenden |
| `⌥⌘A` | Antwort auf die letzte Äußerung anfordern |

## Fehlerdiagnose

```bash
"/Applications/AlfredHelp.app/Contents/MacOS/AlfredHelp" --selftest
```

Die Ausgabe zeigt in wenigen Zeilen, wo es hakt. Sie gehört zu jedem Fehlerbericht.

Vollständige Änderungen stehen im [Änderungsprotokoll](https://github.com/PalescoDev/AlfredHelp/blob/main/CHANGELOG.md). Hintergrund und Messwerte enthält die technische Dokumentation.

<sub>AlfredHelp · PalescoDev</sub>
