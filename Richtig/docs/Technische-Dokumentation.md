# AlfredHelp

<sub>PalescoDev</sub>

Ein macOS-Assistent, der jedem Ton auf diesem Mac zuhört, ihn live ins Deutsche
übersetzt, Fragen der Gegenseite selbstständig erkennt und sofort eine
verwendbare Antwort anzeigt – **vollständig lokal**, ohne Internetverbindung.

Es spielt keine Rolle, aus welcher Anwendung der Ton kommt: Microsoft Teams,
Zoom, Discord, ein Browser-Tab, ein Video. Erfasst wird, was der Mac abspielt.

---

## Was passiert, wenn man auf Start drückt

```
Systemton (ScreenCaptureKit, alle Apps)        ─┐
                                                ├─→ SpeechAnalyzer (on-device)
Mikrofon (AVAudioEngine, optional)             ─┘        │
                                                          │ volatile + finale Ergebnisse
                                                          ▼
                                              Satzweiser Zusammenbau
                                                          │
                          ┌───────────────────────────────┼───────────────────────────┐
                          ▼                               ▼                           ▼
                Übersetzung (Ollama,            Frageerkennung                Rollierende
                 Streaming, seriell)      Heuristik → LLM (Streaming)        Zusammenfassung
                          │                          │                            │
                          ▼                          ▼                            ▼
                  deutsche Zeile            Antwort (Ollama, Streaming) ←── Gesprächsgedächtnis
```

## Frageerkennung: drei Klassen, zwei Stufen

Jede abgeschlossene Äußerung wird einer von drei Klassen zugeordnet – **keine
Frage**, **noch unvollständig**, **beantwortbare Frage** – und das zweistufig:

**Stufe 1 – Heuristik (0 ms, `TextUtilities.assessQuestion`).** Satzweise
Analyse mit verankerten Mustern statt bloßer Schlüsselwortsuche: Frageworte und
Verb-Erst-Stellung am Satzanfang (DE/EN, inklusive Kontraktionen wie
„What's …"), Bestätigungs-Endungen („…, oder?", „…, right?") – auch **ohne**
Fragezeichen („Das schaffen wir bis Freitag, oder"), Kurzfragen-Whitelist
(„Warum?", „Und dann?"), elliptische Kurzfragen („Wie lange"), Bitten am
Satzanfang („Erklär …", „Walk me through …", „Bitte erklären Sie …") und
angekündigte Fragen („Ich wollte noch fragen, ob …"). Bis zu drei Füllwörter
am Satzanfang werden vor der Prüfung geschält – „Also, wie machen wir weiter"
fragt dasselbe wie „Wie machen wir weiter"; nach dem Schälen muss das
Fragewort aber **vorn** stehen, denn Verb-Zweit-Stellung („Genau, das passt …")
ist eine Aussage. Ausgeschlossen werden berichtete
und eingebettete Fragen („Er hat gefragt, ob …", „Ich weiß nicht, warum …"),
Meta-Sätze („Gute Frage …") und rhetorische Muster; eine Frage, die der
Sprecher im selben Atemzug selbst beantwortet („Warum? Weil …"), zählt nicht.
Sätze, die erkennbar mitten im Gedanken abbrechen (Endung auf Konjunktion,
Artikel, Präposition, Komma), gelten als unvollständig – der Zusammenbau
wartet dann 2,6 s statt 1,1 s, und das Fragment wird mit der Fortsetzung
verkettet neu bewertet.

**Stufe 0 – Satzzusammenführung (`UtteranceStitcher`).** Die Spracherkennung
liefert nicht satzweise. Ein gesprochener Satz zerfällt regelmäßig in zwei oder
drei finalisierte Bruchstücke, und umgekehrt kommen mehrere Sätze in einem
Stück. Vor jedem Urteil werden die Teile deshalb wieder zusammengesetzt, über
bis zu vier Teile und 400 Zeichen hinweg. Zwei Fristen, beide aus bereits
gemessenen Zahlen dieses Projekts abgeleitet:

* **Sichtbar abgerissen** („… und dann", „The question is whether the"):
  Fortsetzung bis **2,6 s** akustischer Stille – derselbe Wert, mit dem der
  `UtteranceAssembler` eine Stufe früher auf dieselbe Fortsetzung wartet.
* **Ohne Satzzeichen, aber unauffällig** („Wie lange dauert eine vollständige"):
  hier hat der Erkenner mitten im Satz getrennt. Erkennbar ist das nur an der
  Stille zwischen den Teilen – es gab keine. Zusammengefügt wird deshalb nur
  unterhalb von **0,6 s**, der gemessenen Pause, die einen Satz beendet
  (`SessionCoordinator.speechPauseSeconds`). Fehlt die Zeitachse des Erkenners,
  wird in diesem Fall gar nicht zusammengefügt.

Gemessen wird beides über `Benchmarks/satzzusammenfuehrung.json` (45 Sequenzen
mit Zeitachse) bei jedem `swift test`: der Test fährt beide Fenster durch und
schlägt fehl, sobald der ausgelieferte Wert das Plateau verlässt, auf dem alle
45 Sequenzen richtig herauskommen (lang 1,4–3,0 s, kurz 0,5–1,2 s).

**Zusammenführen verzögert nichts.** Bewertet wird sofort, nur eben auf dem
zusammengesetzten Text. Festgehalten wird ausschließlich, was für sich genommen
keine Antwort trägt; steht hinter einer fertigen Frage noch ein offener Rest
(„Wie sieht euer Rollback aus? Und wie lange dauert das"), wird die Frage sofort
beantwortet **und** der Rest wartet weiter auf seine Fortsetzung. Kommt die
Fortsetzung eines angefangenen Satzes nach, löst die vollständige Frage die
Antwort auf ihr Bruchstück ab; die überholte Karte wird ausdrücklich verworfen.

Beim Verbinden wird die Wiederholung abgezogen, die der Erkenner beim
Finalisieren liefert: „The question is whether the" + „The question is whether
the rollout is on track?" ergibt den Satz einmal, nicht anderthalbmal. Abgezogen
wird aus dem **zweiten** Teil, damit die Interpunktion des ersten stehen bleibt;
ein einzelnes gemeinsames Funktionswort bleibt unangetastet, weil „Wir machen
das" + „Das ist der Plan" sonst zu „Wir machen das ist der Plan" würde.

Umgekehrt gilt: kommen mehrere Sätze in einem Stück, wird nicht der ganze Block
zur Frage. `TextUtilities.questionFocus` dampft ihn auf die tatsächlich
fragenden Sätze ein – der Rest bleibt im Gesprächsgedächtnis, das dem
Antwortmodell ohnehin als Verlauf mitgegeben wird.

**Stufe 1b – die Anrede-Stufe (Konfidenz 0,40).** Was die Heuristik als „keine
Frage" einstuft, bekam das Modell früher **nie** zu sehen – der Pfad endete
sofort. Genau dort gingen als Aussage formulierte Fragen verloren („Ich bin
gespannt, wie ihr das gelöst habt"). Solche Sätze landen jetzt auf einer
eigenen Stufe: mindestens fünf Wörter, erkennbar an den Zuhörer gerichtet
(2. Person, oder groß geschriebenes „Sie" mitten im Satz – klein geschriebenes
„sie" heißt genauso oft „she/they") und mit einem Frage- oder Modalwort darin.
Diese Stufe ist es, die der Regler *Auslöseschwelle* ein- und ausschaltet.

**Stufe 2 – lokales Modell (nur im Graubereich).** Konfidenz ≥ 0,95 antwortet
sofort; der Klassifikator läuft parallel nur noch als Veto. Konfidenz 0,35–0,95
fragt gemma3:4b mit Gesprächskontext: `{"status": "frage" | "keine_frage" |
"unvollstaendig", "eigenstaendig": …}` per JSON-Schema. Entschieden wird beim
**ersten Buchstaben** des Statuswerts im Teilstrom (f/k/u) – nach etwa einem
Dutzend Token. „eigenstaendig" löst Bezüge auf („Warum?" → „Warum wurde gegen
die Cloud-Variante entschieden?") und aktualisiert die Antwortkarte.

**Stufe 0 – der Erkenner muss überhaupt erst fertig werden.** `SpeechAnalyzer`
finalisiert ein Segment, wenn er sich sicher fühlt – gemessen auf dieser
Maschine 4,5 bis 7,0 Sekunden nach Sprechende, oft erst wenn die *nächste*
Äußerung beginnt. Da die Pipeline nur auf finalen Text reagiert, wirkte das im
Betrieb so, als würde eine Frage erst mit der übernächsten beantwortet. AlfredHelp
wartet deshalb nicht mehr ab, sondern verlangt die Finalisierung, sobald der
Sprecher **im Audio** 600 ms still ist (`SessionCoordinator.finalizeAfterSpeechPause`).

Der Auslöser ist bewusst der Pegel und nicht die Texthypothese: Textstabilität
wurde zuerst gebaut und verworfen, weil eine Hypothese auch zwischen zwei
Wörtern stillsteht – das zerschnitt eine gesprochene Frage in drei finalisierte
Bruchstücke. Nachgemessen mit `--recognition-latency` (Datei wird in Echtzeit
durch denselben Erkenner geschoben, nichts wird abgespielt):

| | vorher | nachher |
|---|---:|---:|
| „Wie lange dauert eine vollständige Neuindizierung …?" | 4 451 ms | **782 ms** |
| „Und was kostet uns das im Monat?" | 6 991 ms | **1 048 ms** |
| Langer Satz mit drei Binnenpausen | – | **1 178 ms**, ungeteilt |

Nebeneffekt: die zweite Frage bekommt jetzt auch ihr Fragezeichen, weil sie als
abgeschlossener Satz finalisiert wird statt beim Abbruch des Datenstroms.

**Schutzmechanismen im Betrieb:** Duplikaterkennung über Wortmengen-Ähnlichkeit
(Jaccard ≥ 0,72, 120-s-Fenster) gegen Recognizer-Doppelungen und erneut
gestellte Fragen; schnelle Folgefragen (< 5 s) werden zu einer Antwort
zusammengeführt statt einander zu verwerfen; fällt der Klassifikator aus
(Modell fehlt, VRAM-Engpass), antwortet ab Konfidenz 0,6 nach 8 s die
Heuristik – ein Infrastrukturfehler darf Fragen verzögern, aber nie stumm
verschlucken.

**Handbetrieb als Rettungsanker.** Keine Erkennung fängt jede Formulierung.
Deshalb trägt jede Transkriptzeile der Gegenseite eine Sprechblase (？, auch
per Rechtsklick): ein Klick behandelt genau diese Äußerung als Frage und
startet die Antwort **ohne Veto** – der Klick des Nutzers ist das Urteil, ein
noch laufender automatischer Klassifikator für dieselbe Äußerung wird
abgebrochen, und auch die „Warum? – Weil …"-Rhetorikbremse greift bei manuell
angeforderten Antworten nicht (`AssistantPipeline.answer(utteranceID:)`).
⌥⌘A beantwortet weiterhin die letzte Äußerung.

**Gemessen** über `Benchmarks/frageerkennung.json` – 241 gelabelte DE/EN-Beispiele
über alle geforderten Kategorien inklusive Grenzfällen (Füllwort-Fragen,
Anhängsel ohne Fragezeichen, Ellipsen, höfliche Bitten und als Aussage
formulierte Fragen kamen 2026-08 dazu). Die Heuristik-Stufe läuft bei jedem
`swift test` und hält auf dem erweiterten Datensatz Gate-Recall **1,000**,
**0** Sofort-Fehlalarme und **16/16** zurückgehaltene Fragmente. Der Preis des
genaueren Hinsehens steht in derselben Matrix: 5 von 76 Nicht-Fragen kosten
jetzt einen Modellaufruf – das Modell verwirft sie, aber die Rechenzeit fällt
an. Der volle Pfad läuft über `Benchmarks/frage_benchmark.sh`
(braucht eine freie GPU; unter Live-Last eines Calls sind Latenzen wertlos);
die folgenden Zahlen stammen vom 123er-Stand des Datensatzes:

| | Ergebnis |
|---|---|
| **Precision** | **1,000** |
| **Recall** | **1,000** |
| False Positives | **0** von 41 Nicht-Fragen |
| False Negatives | **0** von 72 Fragen |
| Erkennungszeit Median | **0 ms** nach Satzende |
| Erkennungszeit p90 | **492 ms** |
| Sofort ohne Modellaufruf | 45 von 72 Fragen |
| Fragmente korrekt zurückgehalten | 10/10 |

Der Weg dahin lief über zwei Messrunden: Recall 0,611 → 0,986 → 1,000. Die
erste Runde deckte auf, dass `gemma3:4b` gar nicht mehr installiert war und
Graubereichs-Fragen deshalb still verschwanden; die zweite hinterließ als
einzigen Fehler eine Bitte um Wiederholung („Sorry, you broke up – could you
repeat that?"), die jetzt ohne Modellaufruf sofort erkannt wird.

> **Verworfene Optimierung, dokumentiert statt vergessen:** `num_ctx` passend
> zum Prompt zu verkleinern sah nach freiem VRAM aus. Gemessen am echten
> Antwortmodell (`Benchmarks/ctx_ab.py`, identische Prompts, gemma3:12b) blieb
> die Abdeckung bei 100 %, aber das erste Token kam 654 → 777 ms später und der
> Durchsatz fiel von 13,7 auf 12,4 Tok/s – für 0,4 GB. Gemmas
> Sliding-Window-Attention zahlt ein kleineres Fenster nicht. Zurückgenommen.

## Die Antwort: erst vorlesen, dann nachlesen

Im Gespräch braucht man einen Satz, den man aussprechen kann – keine
Stichpunktliste. Jede Antwort besteht deshalb aus zwei Teilen. Oben, groß
gesetzt, steht der Satz zum Vorlesen; darunter klappt „Ausführlich“ den
Hintergrund auf: Begründung, Zahlen, Randfälle, mögliche Rückfragen. Der
Kopieren-Knopf nimmt bewusst nur den Vorlese-Teil.

Technisch trennt eine Marke (`---MEHR---`) die beiden Teile im Antwortstrom.
Das ist kein Umweg, sondern der Grund, warum sich nichts verlangsamt: der kurze
Teil kommt zuerst und streamt sofort auf den Bildschirm, während der Hintergrund
noch geschrieben wird. `TextUtilities.splitAnswer` teilt streaming-sicher – eine
halb angekommene Marke darf nicht kurz aufblitzen, was sechs Tests absichern.

Gegengemessen am echten Antwortmodell (`Benchmarks/antwort_ab.py`, acht
Fachfragen, gemma3:12b, identische Fragen):

| | einteilig (vorher) | zweiteilig (jetzt) |
|---|---:|---:|
| Abdeckung der Kernpunkte | 95,8 % | **95,8 %** |
| Deutsch | 100 % | 100 % |
| Wartezeit erstes Wort | 547 ms | **543 ms** |
| Länge des Vorlese-Teils | 59,1 Wörter | **28,6 Wörter** |
| tatsächlich vorlesbar¹ | 25 % | **100 %** |
| Langfassung vorhanden | 0 % | **100 %** |

¹ ohne Aufzählungszeichen, Sternchen oder Überschriften im Vorlese-Teil.

Inhaltliche Tiefe und Tempo bleiben also gleich – was sich ändert, ist
ausschließlich die Form: halb so lang und in jedem Fall aussprechbar.

## Warum diese Bausteine

| Aufgabe | Umsetzung | Begründung |
|---|---|---|
| Systemton | ScreenCaptureKit (`SCStream`, `capturesAudio`) | Greift die Systemmischung ab, unabhängig vom Ausgabegerät. Der Core-Audio-Prozess-Tap wäre sparsamer, scheitert auf dieser Maschine aber reproduzierbar – siehe unten. Der Videopfad ist auf 2×2 Pixel alle zwei Sekunden reduziert und wird nie gelesen. |
| Spracherkennung | `SpeechAnalyzer` + `SpeechTranscriber` (macOS 26+) | Läuft auf dem Gerät, streamt vorläufige Ergebnisse in Millisekunden und ist deutlich sparsamer als ein selbst betriebenes Whisper. Zwei getrennte Analyzer trennen die Sprecher sauber. |
| Übersetzung, Frageerkennung, Antworten, Zusammenfassung | Ollama auf `127.0.0.1:11434` | Vorgabe des Projekts und Voraussetzung für echten Offline-Betrieb. |
| Oberfläche | SwiftUI + `NSPanel` (nicht aktivierend, schwebend) | Das Overlay nimmt dem Meeting nie den Fokus und ist per `sharingType = .none` aus Bildschirmfreigaben ausgeblendet. |

Aus den vorhandenen Projekten wurde bewusst nichts übernommen: *Natively* ist
Electron-basiert und ruft Deepgram, OpenAI, Google und ElevenLabs auf – das
Gegenteil von lokal und latenzarm. *MLX Whisper* ist eine Python-Bibliothek und
hätte eine zweite Laufzeit plus Modellverwaltung bedeutet, ohne gegenüber
`SpeechAnalyzer` schneller oder genauer zu sein. Konzeptionell übernommen wurde
die Idee getrennter Rollen für ein schnelles und ein starkes Modell.

---

## Modellauswahl: gemessen, nicht geraten

`Benchmarks/benchmark.py` bewertet jedes lokal installierte Modell (≤ 20 B
Parameter) auf genau den drei Aufgaben, die die App ausführt, mit genau den
Prompts, die sie verwendet:

| Aufgabe | Testmenge | Maß |
|---|---|---|
| Übersetzung ins Deutsche | 12 Sätze aus EN/FR/ES/IT/NL mit Gesprächskontext und handgeschriebenen Referenzen | **chrF2** (Standardmaß der maschinellen Übersetzung) + Sprachprüfung |
| Frageerkennung | 16 gelabelte Äußerungen, je zur Hälfte Frage und Aussage, jeweils mit Vorkontext | Genauigkeit + Gültigkeit der JSON-Ausgabe |
| Antwortqualität | 8 Fachfragen mit definierten Kernpunkten (z. B. „429“, „Retry-After“) | Anteil abgedeckter Kernpunkte |

### Schnellmodell – Übersetzung und Frageerkennung

| Modell | chrF2 | Frage % | JSON % | Übersetzung | Frage (früh) |
|---|---:|---:|---:|---:|---:|
| **gemma3:4b** | **70,7** | 88 | 100 | 2 571 ms | 1 287 ms |
| qwen3:8b | 68,7 | 100 | 100 | 4 453 ms | 2 113 ms |
| aya-expanse:8b | 68,7 | 94 | 100 | — | — |
| llama3.2:3b | 60,8 | 100 | 100 | 2 291 ms | 991 ms |
| mistral-nemo:12b | 72,4 | 100 | 100 | — | — |

`llama3.2:3b` ist rund 12 % schneller, übersetzt aber deutlich schlechter
(chrF2 60,8 gegen 70,7). Da die Übersetzung durchgehend sichtbar ist und die
Frageerkennung ohnehin durch die lokale Heuristik und den vorzeitigen Ausstieg
entlastet wird, fällt die Wahl auf **gemma3:4b**.

### Antwortmodell

| Modell | Kernpunkte | Deutsch | Antwort TTFT | Tok/s | Größe |
|---|---:|---:|---:|---:|---:|
| **gemma3:12b** | **100 %** | 100 % | 2 483 ms | 7 | 8,1 GB |
| qwen3:14b | 96 % | 100 % | 2 277 ms | 9 | 9,3 GB |
| phi4:14b | 96 % | 100 % | 2 947 ms | 6 | 9,1 GB |
| gemma3:4b | 94 % | 100 % | 1 039 ms | 18 | 3,3 GB |
| qwen3:8b | 92 % | 100 % | 1 636 ms | 10 | 5,2 GB |

**Ergebnis: `gemma3:4b` + `gemma3:12b`.** Zusammen 11,4 GB, gleiche Modellfamilie
und damit einheitliche Terminologie zwischen Übersetzung und Antwort. Wer
maximale Geschwindigkeit will, setzt `gemma3:4b` auch als Antwortmodell ein –
das kostet 6 Prozentpunkte Abdeckung und halbiert die Wartezeit.

### Zwei Modelle sind durchgefallen

- **`qwen3:4b`** denkt vor jeder Ausgabe laut. Weder `think: false` noch
  `/no_think` schalten das ab; die Begründung landet dann statt im Feld
  `thinking` direkt in der Antwort. Ergebnis: chrF2 18,5 bei 13,6 s pro Satz.
- **`gpt-oss:20b`** stellt jeder Antwort rund 900 Zeichen Analyse voran. Mit
  ausreichend Token-Budget kommt am Ende eine korrekte Übersetzung heraus – nach
  13 bis 21 Sekunden. Zudem liegt es mit 20,9 B über der 20-B-Grenze.

Beide sind in `ModelCatalog` fest ausgeschlossen und werden auch bei manueller
Auswahl nicht automatisch vorgeschlagen.

> **Zu den Zeiten:** gemessen auf einem M5 mit 24 GB – bei **aktiviertem
> Stromsparmodus** und einer Systemlast von 15–32 durch andere Prozesse. Die
> Rangfolge ist dadurch nicht verzerrt (alle Modelle unter denselben
> Bedingungen), die absoluten Werte sind aber eine Obergrenze. Ohne
> Stromsparmodus und auf einem ruhigen System liegen sie deutlich darunter.
> Nachmessen: `python3 Benchmarks/latency.py gemma3:4b gemma3:12b`.

---

## Installation

Voraussetzungen: macOS 26 oder neuer, Apple Silicon. **Ollama wird nicht
vorausgesetzt** – siehe [Ersteinrichtung](#ersteinrichtung-was-die-app-sich-selbst-holt).

```bash
cd AlfredHelp
./build.sh
open dist/AlfredHelp.app
```

Beim ersten Start öffnet sich ein Fenster mit genau zwei Dingen:

1. **Systemton freigeben** – ein Klick auf *Erlauben*, danach die App einmal neu
   starten. macOS führt diese Freigabe unter „Bildschirm- & Systemaudioaufnahme“.
2. **Sprachmodell wählen** – eine Liste mit gemessenen Werten je Modell:

   | Modell | Antwortqualität | Tempo | Größe |
   |---|---|---|---:|
   | **gemma3:12b** | ●●●●● 100 % | ●●●○○ 14 Tok/s | 8,1 GB |
   | qwen3:14b | ●●●●● 96 % | ●●○○○ 9 Tok/s | 9,3 GB |
   | phi4:14b | ●●●●● 96 % | ●●○○○ 8 Tok/s | 9,1 GB |
   | gemma3:4b | ●●●●○ 94 % | ●●●●○ 24 Tok/s | 3,3 GB |
   | qwen3:8b | ●●●●○ 92 % | ●●●○○ 14 Tok/s | 5,2 GB |
   | llama3.2:3b | ●●●○○ 88 % | ●●●●● 32 Tok/s | 2,0 GB |

   Die Prozentwerte sind die im Benchmark gemessene Abdeckung geforderter
   Kernpunkte, die Tok/s der gemessene Durchsatz – keine Schätzungen.

Ein Klick auf ein Modell genügt. AlfredHelp lädt es bei Bedarf herunter, holt
sich automatisch das kleine Hilfsmodell für Übersetzung und Frageerkennung und
wärmt beide auf. Mithören startest du selbst oder nach bewusst aktiviertem
automatischem Programmstart.

**Ollama muss nicht von Hand gestartet werden.** AlfredHelp startet den Dienst
beim Programmstart selbst – ist Ollama als Programm installiert, wird es im
Hintergrund geöffnet, sonst `ollama serve` gestartet. Nachgewiesen: bei
gestopptem Ollama genügt der Start von AlfredHelp, danach antwortet der Dienst.

Automatisches Zuhören ist zunächst ausgeschaltet. Bei einem Update wird der
bisherige automatische Standard einmalig deaktiviert. Danach lässt sich die
Funktion unter *Einstellungen › Modelle › Beim Start automatisch zuhören*
bewusst einschalten. Wenn sie aktiv ist, startet AlfredHelp die Sitzung beim
Programmstart, sobald Ollama und die gewählten Modelle bereit sind.

### Ersteinrichtung: was die App sich selbst holt

Diese Anwendung wird weitergegeben, indem jemand ein Programmbündel bekommt. Auf
dem fremden Mac ist üblicherweise **nichts** davon vorhanden: kein Ollama, kein
Sprachmodell, keine Erkennungsdaten. Wer die App bekommt, soll sie starten und
benutzen können, statt erst eine Installationsanleitung abzuarbeiten – also holt
`DependencySetup` beim Start nach, was fehlt:

| Schritt | Was passiert | Größe |
|---|---|---|
| 1 | Ollama vom offiziellen Ort laden, prüfen, ablegen | ~180 MB |
| 2 | Dienst starten | – |
| 3 | `gemma3:4b` laden – **nur**, wenn gar kein brauchbares Modell da ist | 3,3 GB |
| 4 | Erkennungsdaten der eingestellten Sprachen | je nach Sprache |

**Vorhandenes wird nie angefasst.** Wer Ollama schon hat oder eigene Modelle
liegen hat, bekommt keinen einzigen Download – Schritt 1 und 3 entfallen dann
stillschweigend. Abschaltbar unter *Einstellungen › Modelle › Dienst*; dann
meldet die App nur noch, was fehlt.

#### Warum die Prüfung so streng ist

Das ist die einzige Stelle, an der diese Anwendung fremden Code aus dem Netz in
den Programme-Ordner legt. Eine bloß *heile* Signatur genügt dafür nicht – die
hat jedes signierte Programm. Geprüft wird deshalb die **Herkunft**:

```
codesign --verify --deep --strict -R '=anchor apple generic
    and certificate leaf[field.1.2.840.113635.100.6.1.13] exists
    and certificate leaf[subject.OU] = "3MU9H2V9Y9"'
```

Drei Aussagen in **einem** Aufruf: die Kette hängt an Apples Wurzel, das
Blattzertifikat trägt die Erweiterung, die es nur auf Entwickler-ID-Programm-
zertifikaten gibt, und die Organisationseinheit ist die Team-Kennung des
Herstellers. Der Rückgabestatus ist damit die vollständige Aussage.

Dass hier ein Anforderungsausdruck steht und nicht ein Textvergleich auf die
Ausgabe von `codesign -dv`, ist Absicht: Das ist ein Diagnoseformat ohne Zusage
über seinen Aufbau, und ein Aufruf, der gar nicht erst zustande kommt, liefert
leeren Text – bei einer Prüfung per `contains` fiele das nur dadurch auf, dass
zufällig nichts passt.

Erst wenn die Prüfung durchläuft, wird verschoben und der Quarantäne-Merker
entfernt – was Gatekeeper prüfen würde, ist zu dem Zeitpunkt bereits geprüft.
Fällt sie durch, wird verworfen statt installiert. Verschoben wird dabei nie
über eine vorhandene Installation hinweg: Die wird beiseitegelegt und erst
weggeworfen, wenn das Verschieben geklappt hat, sonst kommt sie zurück.

Festgehalten ist das in `Tests/AlfredHelpCoreTests/SetupTests.swift`, und zwar
in beide Richtungen: Das echte Ollama **muss** durchkommen, `Calculator.app` –
tadellos signiert, nur eben von Apple – **muss** durchfallen. Ein Test, der nur
die gute Richtung prüft, würde eine kaputte Prüfung nicht bemerken.

Ohne Administratorrechte weicht die Ablage nach `~/Programme` aus. Es gibt keine
Passwortabfrage und keinen privilegierten Helfer.

#### Der Assistent, der im Weg stand

Frisch installiert bringt Ollama einen Einrichtungsassistenten mit, der den
Dienst so lange nicht startet, bis ihn jemand wegklickt. AlfredHelp startet
Ollama aber absichtlich ausgeblendet (`open -g -j`) – dieses Fenster hat vor
einem Meeting nichts zu suchen, und wegklicken kann es dann niemand.

Deshalb wartet `OllamaSupervisor.ensureRunning` nach dem Programmstart nur zehn
Sekunden und startet danach zusätzlich den Server aus dem Bündel direkt
(`Ollama.app/Contents/Resources/ollama serve`) – derselbe Prozess, nur ohne
Assistent davor.

> `build.sh` signiert mit der lokalen Identität `AlfredHelp Local Signing`,
> sofern sie im Schlüsselbund liegt. Dadurch überlebt die Audio-Freigabe jeden
> Neubau. Eine andere Identität lässt sich mit
> `CODESIGN_IDENTITY="Developer ID Application: …" ./build.sh` erzwingen.

### Selbsttest und Diagnose

```bash
"dist/AlfredHelp.app/Contents/MacOS/AlfredHelp" --selftest
"dist/AlfredHelp.app/Contents/MacOS/AlfredHelp" --transcribe-test 20 de-DE
```

`--selftest` prüft Ollama, das Antwortmodell mit einem echten Aufruf, die
Sprachmodelle und den Systemton. `--transcribe-test` fährt die vollständige
Kette Systemton → PCM → Spracherkennung → Text und schreibt einen Bericht nach
`~/Library/Application Support/AlfredHelp/transkriptionstest.txt`.

Weitere Werkzeuge für die Fehlersuche:

| Befehl | Zweck |
|---|---|
| `--audio-devices` | Alle Audiogeräte mit Laufzustand, Standardausgabe markiert |
| `--audio-diagnose` | Acht Tap-/Aggregat-Konfigurationen im Vergleich, mit Rohpegel |
| `--audio-watch 12` | Zeitverlauf der Erfassung, halbsekündlich |
| `--capture-probe` | Erfassung als echter GUI-Prozess, Rohpuffer-Dump |

---

## Der Systemton und die macOS-Freigabe

Das ist der Punkt, an dem diese Anwendung steht und fällt, deshalb ausführlich.

**Zwei Wege, einer davon gewählt.** Zuerst lief die Erfassung über einen
Core-Audio-Prozess-Tap. Der ist sparsamer, hängt aber an einem Aggregatgerät,
das das aktuelle Ausgabegerät einbinden muss. Auf dieser Maschine — USB-DAC als
Standardausgabe, zusätzlich ein virtuelles „Microsoft Teams Audio“-Gerät —
scheitert das reproduzierbar in **allen acht** vermessenen Konfigurationen:
Aggregate mit Ausgabegerät starten nicht (`IOWorkLoopDeinit` rund 95 ms nach
einem erfolgreichen `AudioDeviceStart`), Aggregate ohne Ausgabegerät starten,
liefern aber Stille. Deshalb ist jetzt **ScreenCaptureKit** das Standardverfahren:
es greift die Systemmischung ab und interessiert sich nicht für Ausgabegeräte.
Der Prozess-Tap bleibt in den Einstellungen als Alternative wählbar.

**Warum ein fehlender Zugriff nicht wie ein Fehler aussieht.** macOS meldet bei
fehlender Freigabe keinen Fehlercode. Der Stream startet, liefert korrekt
geformte Puffer in der richtigen Größe und Taktrate — und schreibt lauter Nullen
hinein. Gemessen: 743 040 Rahmen über 15,5 s bei 48 kHz, zwei Puffer zu je
960 Float-Werten, Rohspitzenwert exakt 0,00000, während `say` nachweislich die
Audio-Engine des Ausgabegeräts startet (`IOWorkLoopInit` im coreaudiod-Log).
Genau deshalb prüft AlfredHelp nie nur „läuft der Stream“, sondern immer den
tatsächlichen Pegel.

**Die Falle bei selbst gebauten Ausgaben.** Ohne Entwicklerzertifikat wird
ad-hoc signiert, und macOS bindet jede erteilte Freigabe an die Prüfsumme des
Programms. Jeder Neubau erzeugt eine neue Prüfsumme und entwertet damit die
Freigabe — sichtbar daran, dass `CGPreflightScreenCaptureAccess()` je nach
Ausgabe einmal `true` und einmal `false` meldet, bei identischem Quellcode.
Die App erkennt das inzwischen selbst: sie speichert die Prüfsumme, unter der
die Erfassung zuletzt mit echten Samples verifiziert wurde, und meldet einen
Wechsel ausdrücklich.

**Dauerhaft lösen** – einmalig eine stabile Signaturidentität anlegen:

1. Schlüsselbundverwaltung öffnen
2. Menü *Zertifikatsassistent → Zertifikat erstellen …*
3. Name `AlfredHelp Local Signing`, Identitätstyp *Selbstsigniertes Stammzertifikat*,
   Zertifikatstyp *Codesignatur*
4. `./build.sh` verwendet sie ab dann automatisch

Danach überlebt die Freigabe jeden Neubau.

**Freigabe erteilen:**

1. AlfredHelp starten – beim ersten Start öffnet sich der Einrichtungsdialog
2. Auf *Erlauben* drücken und den macOS-Dialog bestätigen
3. AlfredHelp neu starten (macOS gibt die Entscheidung erst dem nächsten
   Prozessstart mit)
4. Mit *Erneut prüfen* bestätigen: Der Pegel muss deutlich über null liegen,
   während etwas abgespielt wird

Steht in den Systemeinstellungen unter *Datenschutz & Sicherheit →
Bildschirm- & Systemaudioaufnahme* bereits ein alter AlfredHelp-Eintrag, muss er
entfernt und neu erteilt werden – sonst prüft macOS gegen eine Prüfsumme, die
es nicht mehr gibt.

## Bedienung

| Kürzel | Wirkung |
|---|---|
| `⌥⌘L` | Mithören starten / stoppen |
| `⌥⌘O` | Overlay ein- / ausblenden |
| `⌥⌘A` | Antwort zur letzten Äußerung erzwingen |

Die Menüleiste enthält denselben Umfang plus schnellen Sprachwechsel. Das
Overlay zeigt links das Transkript (deutsche Zeile groß, Original klein
darunter) und rechts die Antwortkarten mit gemessener Latenz.

## Einstellungen, die wirklich etwas ändern

- **Antwortsprache** – „Gesprächssprache“ formuliert die Antwort so, dass sie
  direkt ausgesprochen werden kann. Für einen englischen Call ist das der
  eigentlich nützliche Modus.
- **Auslöseschwelle** – in Schritten von 0,05 von 0,15 bis 0,80, mit Zahlenwert
  und Klartext daneben. Unter 0,30 kommt die Anrede-Stufe dazu (an den Zuhörer
  gerichtete Aussagen werden vom Modell geprüft), bis 0,50 indirekte Bitten und
  Fragen ohne Fragezeichen, darüber nur noch klar fragende Formulierungen.
- **Hintergrund** – Rolle, Fachgebiet, Produktnamen. Geht in jede Antwort ein.
- **Stromsparmodus** – die Erkennung pausiert bei Stille. Ein halbsekündiger
  Vorlauf verhindert abgeschnittene Wortanfänge.
- **Vor Bildschirmfreigabe verbergen** – standardmäßig an.

---

## Datenschutz

- Der Ton wird im System abgegriffen und nie auf die Festplatte geschrieben.
- Die Spracherkennung nutzt Apples geräteinterne Modelle.
- Sämtliche Sprachmodell-Aufrufe gehen an `127.0.0.1`. Der `URLSession`-Client
  ist auf Loopback festgelegt und ohne Proxy konfiguriert; es gibt in dieser App
  keinen zweiten Netzwerkpfad.
- Das Protokoll liegt im Arbeitsspeicher, bis es bewusst kopiert wird.

## Projektaufbau

```
Sources/AlfredHelpCore/     Audio, Erkennung, Ollama, Pipeline (Swift 6, ohne UI)
  Audio/                  Prozess-Tap, Mikrofon, Core-Audio-Hilfen
  Transcription/          SpeechAnalyzer-Anbindung, Resampling, Stille-Gate
  Ollama/                 HTTP-Client, Supervisor, Modellkatalog
  Intelligence/           Prompts, Textwerkzeuge, Gesprächsgedächtnis
  Pipeline/               Orchestrierung, Sitzungssteuerung
Sources/AlfredHelpApp/      SwiftUI-Oberfläche, Overlay-Panel, Hotkeys
Tests/                    215 Tests: Segmentierung, Heuristik, JSON, Auswahl,
                          Antwortstrom, Stille-Gate, Ollama-Protokoll,
                          Satzzusammenführung
Benchmarks/               Reproduzierbarer Modellvergleich
```

```bash
swift test        # Unit-Tests
./build.sh        # Anwendung bauen
python3 Benchmarks/benchmark.py    # Modelle neu vermessen
```

---

<sub>AlfredHelp · PalescoDev</sub>
