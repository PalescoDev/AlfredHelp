# Messwerte

<sub>AlfredHelp · PalescoDev</sub>

Alle Zahlen stammen aus reproduzierbaren Messungen auf einem Apple M5 mit 24 GB.
Keine Schätzungen, keine übernommenen Fremdangaben. Die Skripte liegen im
Quellprojekt unter `Benchmarks/`.

---

## Modellauswahl

`benchmark.py` stellt jedem Modell dieselben Aufgaben, mit **exakt den Prompts,
die die App verwendet**:

| Aufgabe | Testmenge | Maß |
|---|---|---|
| Übersetzung ins Deutsche | 12 Sätze EN/FR/ES/IT/NL mit Kontext und handgeschriebenen Referenzen | chrF2, Standardmaß der maschinellen Übersetzung |
| Frageerkennung | 16 gelabelte Äußerungen mit Vorkontext | Genauigkeit + JSON-Gültigkeit |
| Antwortqualität | 8 Fachfragen mit definierten Kernpunkten | Anteil abgedeckter Kernpunkte |

### Antwortmodelle

| Modell | Kernpunkte | Deutsch | Tok/s | Größe |
|---|---:|---:|---:|---:|
| **gemma3:12b** | **100 %** | 100 % | 14 | 8,1 GB |
| qwen3:14b | 96 % | 100 % | 9 | 9,3 GB |
| phi4:14b | 96 % | 100 % | 8 | 9,1 GB |
| gemma3:4b | 94 % | 100 % | 24 | 3,3 GB |
| aya-expanse:8b | 94 % | 100 % | 14 | 5,1 GB |
| qwen3:8b | 92 % | 100 % | 14 | 5,2 GB |
| llama3.2:3b | 88 % | 100 % | 32 | 2,0 GB |
| mistral-nemo:12b | 75 % | 100 % | 11 | 7,1 GB |

### Übersetzung (Hilfsmodell)

| Modell | chrF2 | Frageerkennung |
|---|---:|---:|
| **gemma3:4b** | **70,7** | 88 % |
| qwen3:8b | 68,7 | 100 % |
| aya-expanse:8b | 68,7 | 94 % |
| llama3.2:3b | 60,8 | 100 % |

### Zwei Modelle sind durchgefallen

- **`qwen3:4b`** denkt vor jeder Ausgabe laut. Weder `think: false` noch
  `/no_think` schalten das ab; die Begründung landet in der Antwort statt im
  vorgesehenen Feld. Ergebnis: chrF2 18,5 bei 13,6 s pro Satz.
- **`gpt-oss:20b`** stellt jeder Antwort rund 900 Zeichen Analyse voran — 13 bis
  21 Sekunden pro Übersetzung.

Beide werden nie automatisch vorgeschlagen.

---

## Frageerkennung

123 gelabelte deutsche und englische Beispiele über alle Kategorien inklusive
Grenzfällen: direkte Fragen, Ja/Nein-Fragen, indirekte Bitten, Rückfragen,
Kurzfragen („Warum?“, „Und dann?“), Fragen ohne Fragezeichen, unvollständige
Sätze, rhetorische Fragen, Aussagen mit Fragewörtern, Mehrfachfragen und Fragen
innerhalb längerer Aussagen.

| | Ergebnis |
|---|---|
| **Precision** | **1,000** |
| **Recall** | **1,000** |
| False Positives | **0** von 41 Nicht-Fragen |
| False Negatives | **0** von 72 Fragen |
| Erkennungszeit Median | **0 ms** nach Satzende |
| Erkennungszeit p90 | **492 ms** |
| Ohne Modellaufruf erkannt | 45 von 72 Fragen |
| Fragmente korrekt zurückgehalten | 10 von 10 |

### Braucht es das kleine Hilfsmodell?

Gemessen wurde die vollständige Frageerkennung über alle 123 Beispiele, einmal
mit `gemma3:4b` in der Helferrolle und einmal mit `gemma3:12b`, das dann beide
Rollen übernimmt:

| Helfer | Recall | Fehler | Latenz p90 | Gesamtlauf |
|---|---:|---:|---:|---:|
| **gemma3:4b** | **1,000** | **0** | **375 ms** | 23 s |
| gemma3:12b | 0,986 | 1 | 881 ms | 87 s |

Das kleine Modell ist nicht nur schneller, sondern auch genauer — es bleibt
deshalb Bestandteil der empfohlenen Aufstellung. Ohne es funktioniert alles
weiterhin, nur langsamer; die App bietet den Download an, lädt ihn aber nie
ungefragt.

---

## Reaktionszeit

Die Spracherkennung von macOS schließt ein Segment erst ab, wenn sie sich sicher
fühlt — gemessen 4,5 bis 7,0 Sekunden nach Sprechende, oft erst wenn die
*nächste* Äußerung beginnt. AlfredHelp verlangt den Abschluss stattdessen,
sobald im Ton 600 ms Stille liegen.

| | vorher | jetzt |
|---|---:|---:|
| „Wie lange dauert eine vollständige Neuindizierung …?“ | 4 451 ms | **782 ms** |
| „Und was kostet uns das im Monat?“ | 6 991 ms | **1 048 ms** |
| Langer Satz mit drei Binnenpausen | – | **1 178 ms**, ungeteilt |

---

## Antwortformat

Zweiteilig: kurzer Vorlesesatz, darunter ausklappbar der Hintergrund.

| | einteilig | zweiteilig |
|---|---:|---:|
| Abdeckung der Kernpunkte | 95,8 % | **95,8 %** |
| Wartezeit erstes Wort | 547 ms | **543 ms** |
| Länge des Vorlese-Teils | 59,1 Wörter | **28,6 Wörter** |
| tatsächlich vorlesbar¹ | 25 % | **100 %** |

¹ ohne Aufzählungszeichen, Sternchen oder Überschriften.

Inhaltliche Tiefe und Tempo bleiben gleich; was sich ändert, ist die Form.

---

## Signaturidentität statt Prüfsumme

Die App wird mit dem lokalen Zertifikat `AlfredHelp Local Signing` signiert.
Damit hängt die erteilte Freigabe am Zertifikat statt an der Prüfsumme des
Programms. Nachgewiesen über drei aufeinanderfolgende Ausgaben mit einer echten
Codeänderung dazwischen:

| Ausgabe | Prüfsumme | Anforderung |
|---|---|---|
| 1 | `6cbb99a3…` | `certificate root = H"2d6d9d18…"` |
| 2 (Code geändert) | `fa5e07c6…` | unverändert |
| 3 (zurückgenommen) | `6cbb99a3…` | unverändert |

Die Prüfsumme wechselt, die Bedingung nicht. Die Freigabe muss also einmal
erteilt werden und übersteht danach jeden Neubau.

---

## Woran „kein Systemton“ wirklich lag

Die Erfassung greift den Ton hinter Lautstärkeregler und Stummschaltung ab.
Derselbe Testklang, dieselbe Ausgabe, nur die Lautstärke unterschiedlich:

| Ausgabelautstärke | Spitzenpegel | Transkript |
|---|---|---|
| 0 %, stumm | 0,0000 | leer |
| 40 % | 0,9187 | „Guten Tag, wie hoch sind die laufenden Kosten pro Monat? …“ |

Zwei Messfallen kamen dabei ans Licht, beide reproduzierbar:

- **`say` ist untauglich als Testquelle.** Die macOS-Sprachsynthese läuft an
  der Systemtonerfassung vorbei: Pegel 0,0000, auch bei voller Lautstärke.
- **Warntöne sind ebenfalls untauglich.** `/System/Library/Sounds/Glass.aiff`
  wurde mit Pegel 0,175 bzw. 0,240 erfasst, obwohl der Hauptausgang stumm war —
  Signaltöne laufen über einen eigenen Ausgang.

Beides führte zunächst zur falschen Diagnose „Freigabe fehlt“. AlfredHelp
prüft deshalb jetzt den Zustand des Ausgabegeräts und benennt die Stummschaltung
beim Namen, statt auf die Berechtigung zu zeigen.

---

## Verworfene Optimierung

Das Kontextfenster passend zum Prompt zu verkleinern sah nach freiem Speicher
aus. Gemessen am echten Antwortmodell blieb die Abdeckung bei 100 %, aber das
erste Token kam 654 → 777 ms später und der Durchsatz fiel von 13,7 auf
12,4 Tok/s — für 0,4 GB. Zurückgenommen.

---

## Messbedingungen

Apple M5, 24 GB, macOS 26. Die Latenzmessungen der Modelltabelle entstanden bei
**aktiviertem Stromsparmodus** und Systemlast durch andere Programme; die
Rangfolge ist davon nicht betroffen, die absoluten Werte sind eine Obergrenze.
Die Werte zu Reaktionszeit und Antwortformat wurden auf ruhigem System gemessen.

---

<sub>AlfredHelp · PalescoDev</sub>
