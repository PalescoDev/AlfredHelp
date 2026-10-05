# Mitwirken

Danke fürs Interesse. Das Projekt hat ein paar Besonderheiten. Hier stehen sie vorab, damit Änderungen leichter passen.

## Einstieg

```bash
git clone https://github.com/PalescoDev/AlfredHelp.git
cd AlfredHelp
cd app
swift test        # läuft ohne Ollama und ohne Grafikprozessor
./build.sh        # erstellt dist/AlfredHelp.app
```

Benötigt werden macOS 26 und Swift 6.4 oder neuer.

## Vier Regeln

### 1. Die Oberfläche ist deutsch

Alle Texte, die Nutzende sehen, sind deutsch: Schaltflächen, Hinweise, Fehler und exportierte Protokolle. Bezeichner und Kommentare richten sich nach der jeweiligen Quelldatei. Innerhalb einer Datei bleibt die Sprache einheitlich.

Fehlerberichte und Änderungsanträge kannst du auf Deutsch einreichen.

### 2. Zahlen werden gemessen

Grenzwerte, Ranglisten und Latenzen stammen aus `app/Benchmarks/`. Änderst du einen Wert, aktualisiere auch die Messung oder ergänze eine neue.

| Messung | Werkzeug oder Datensatz |
|---|---|
| Modellrang, Abdeckung und Geschwindigkeit | `app/Benchmarks/benchmark.py` |
| Fragenerkennung und Fehlermatrix | `app/Benchmarks/frage_benchmark.sh`, `frageerkennung.json` |
| Satzverknüpfung und Zeitfenster | `swift test`, `satzzusammenfuehrung.json` |
| Erkennungszeit | `AlfredHelp --recognition-latency <datei> <sprache>` |
| Antwortformat | `app/Benchmarks/antwort_ab.py` |

Der Regelteil der Fragenerkennung läuft bei jedem `swift test`. Er hält die Trefferquote bei 1,000 und erzeugt dabei keine sofortigen Fehlalarme. Der vollständige Messlauf braucht einen freien Grafikprozessor. Messungen während ein anderer Auftrag läuft, sind nicht aussagekräftig.

### 3. Gesprächsdaten verlassen den Mac nicht

Die App hat genau zwei Netzwerkwege:

1. `OllamaClient` — fest auf `127.0.0.1`, ohne Proxy.
2. `OllamaInstaller` — lädt Ollama einmalig und prüft Signatur und Team-ID vor der Installation.

Ein weiterer Netzwerkweg kommt nur nach vorheriger Diskussion infrage. Gesprächsinhalte werden an keinen anderen Dienst gesendet.

### 4. Signatur beachten

Ohne Entwicklerzertifikat ist die App ad-hoc signiert. macOS bindet die Systemton-Freigabe an die Prüfsumme des Programms. Nach einem Neubau kann die Freigabe fehlen; AlfredHelp führt dann in die Systemeinstellungen. Aufnahmefehler zeigt die App an.

Beim ersten Lauf erklärt `build.sh`, wie die lokale Signaturidentität *AlfredHelp Local Signing* eingerichtet wird. Danach bleibt die Freigabe über Neubauten hinweg erhalten.

## Änderungen einreichen

1. Erstelle einen Branch von `main`.
2. `swift test` muss erfolgreich durchlaufen.
3. Sichtbare Änderungen kommen in `CHANGELOG.md` unter *Noch nicht veröffentlicht*.
4. Erstelle einen Änderungsantrag (Pull Request) und fülle die Vorlage aus.

Commit-Titel beschreiben die Änderung kurz und direkt, zum Beispiel „Erkennungszeit an den Tonpegel binden“.

**Willkommen:** Fehlerberichte mit `--selftest`-Ausgabe, neue markierte Beispiele unter `app/Benchmarks/frageerkennung.json` und Messungen, die eine bestehende Aussage widerlegen.

**Bitte zuerst ein Issue öffnen:** neue Abhängigkeiten, ein weiterer Netzwerkweg oder Änderungen an der Unsichtbarkeit des Fensters bei einer Bildschirmfreigabe.

## Fehler melden

Nutze die Issue-Vorlage und füge diese Ausgabe bei:

```bash
"/Applications/AlfredHelp.app/Contents/MacOS/AlfredHelp" --selftest
```

Sie zeigt, ob Ollama läuft, ein Modell vorhanden ist, die Audioberechtigung funktioniert und die Spracherkennung bereitsteht.

**Keine Gesprächsprotokolle oder Gesprächsinhalte in Issues einfügen.** Für einen einzelnen Satz reicht ein nachgestelltes Beispiel.
