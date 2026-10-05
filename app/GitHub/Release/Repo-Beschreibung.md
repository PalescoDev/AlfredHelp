# Einstellungen des GitHub-Repositorys

Diese Angaben betreffen Auffindbarkeit und Darstellung, nicht die Funktion der App.

## Beschreibung

Unter *Einstellungen → Allgemein → Kurzbeschreibung* einfügen (maximal 350 Zeichen):

```
Hört den Mac-Ton mit, schreibt eine Live-Mitschrift, übersetzt ins Deutsche, erkennt Fragen und formuliert Antworten. Läuft lokal über Ollama – ohne Cloud, Konto oder Internet im Betrieb. Richtet sich beim ersten Start selbst ein.
```

## Website

Leer lassen oder später eine Projektseite eintragen.

## Themen

Unter *Repository → About → Themen* eintragen:

```
macos  swift  swiftui  ollama  llm  local-llm  speech-recognition
speech-to-text  translation  meeting-assistant  privacy  on-device
screencapturekit  german  real-time
```

## Anzeigen im Repository

- [x] Veröffentlichungen
- [ ] Pakete
- [ ] Bereitstellungen
- [ ] Umgebungen

## Repository-Einstellungen

Unter *Einstellungen → Allgemein*:

| Einstellung | Wert | Grund |
|---|---|---|
| Standard-Branch | `main` | |
| Wikis | Aus | Die Dokumentation bleibt mit dem Code zusammen. |
| Issues | An | |
| Diskussionen | An | Die Vorlagen verweisen darauf. |
| Projekte | Aus | |
| Merge-Commits erlauben | An | |
| Squash-Merge erlauben | An | |
| Rebase-Merge erlauben | Aus | |
| Quell-Branches automatisch löschen | An | |

Unter *Einstellungen → Branches → Regel für `main`*:

- Pull Request vor dem Zusammenführen verlangen
- Erfolgreiche Statusprüfung `Bauen und testen` verlangen
- Aktuellen Stand von `main` vor dem Zusammenführen verlangen

Unter *Einstellungen → Aktionen → Allgemein* Leseberechtigung für Inhalte und Schreibberechtigung für Veröffentlichungen aktivieren. Der Release-Ablauf benötigt sie, um den Entwurf anzulegen.

## Vorschaubild

Unter *Einstellungen → Allgemein → Social Preview* ein Bild mit 1280 × 640 Pixeln eintragen.

Ein Bild des laufenden Overlays zeigt besser als ein Logo, was die App macht: links das Gespräch, rechts eine Antwortkarte. Das Bild muss unter `app/docs/bilder/overlay.png` liegen. Erst wenn es vorhanden ist, einen Link in die README aufnehmen.

## Erster Eindruck

Die README erklärt die drei wichtigsten Punkte:

1. **Läuft lokal.** Der einzige Netzwerkweg im Betrieb geht zu `127.0.0.1`; für die Einrichtung gibt es einen Ollama-Download.
2. **Zahlen sind gemessen.** Präzision, Trefferquote, Latenzen und Modellauswahl stammen aus `app/Benchmarks/`.
3. **Richtet sich selbst ein.** Laden, öffnen, fertig. Kein Terminal und kein Homebrew nötig.
