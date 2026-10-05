# Änderungsprotokoll

Dieses Protokoll folgt [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versionsnummern richten sich nach [Semantic Versioning](https://semver.org/).

## [Noch nicht veröffentlicht]

### Behoben

- **Der Release-Build funktioniert wieder mit Swift 6.3.** Wartende ScreenCaptureKit-Aufrufe werden korrekt gesammelt und fortgesetzt.
- **Der Start fragt keine Freigabe mehrfach ab.** Die ScreenCaptureKit-Anfrage läuft höchstens einmal; spätere Änderungen öffnest du in den Systemeinstellungen. Core Audio wird nicht still beim Programmstart geprüft. Ein stiller Ausgang gilt nicht mehr als bewiesene Ablehnung.
- **Automatisches Zuhören ist jetzt freiwillig.** Es ist standardmäßig ausgeschaltet. Ein einmaliger Umzug übernimmt bestehende Einstellungen und schaltet den alten Standard ab. Die Bundle-ID bleibt stabil; macOS-Freigaben können bei gleicher Signatur weitergelten.
- **Ein fehlgeschlagener Audiostream bleibt nicht als aktive Sitzung stehen.** Erschöpfte Wiederherstellungsversuche stoppen die Sitzung mit einem sichtbaren Fehler. Wiederholungen sind begrenzt und werden erst nach stabiler Ausgabe zurückgesetzt.
- **Abbrüche und Fristen beenden auch wartende Abläufe.** Ollama-Warteaufrufe und Sprachasset-Installationen geben den Aufrufer zeitnah frei; ungültige Ollama-Zeitlimits starten keine Netzwerkanfrage. Ein Modell-Pull gilt erst nach bestätigtem Erfolg als fertig.
- **Gleichzeitige Einrichtung startet keine doppelten Installationen.** Bootstrap-Aufrufe werden zusammengeführt und Stoppen während eines Downloads hält keine Sitzung offen.
- **Ollama folgt jetzt dem Lebenszyklus der App.** Beim regulären Beenden wird erst die aktive Sitzung abgeschlossen. Danach stoppt AlfredHelp nur den eigenen Ollama-Prozess. Bereits laufende fremde Instanzen bleiben unangetastet. Eine Sperre verhindert, dass ein später Start- oder Wiederherstellungsversuch Ollama während des Beendens neu startet.
- **Stoppen und Zurücksetzen verlieren keine Äußerungen mehr.** Letzte Spracherkennungsergebnisse, Satzverknüpfung und Zustellung werden vor dem Archivieren oder Leeren in Reihenfolge abgeschlossen.
- **Beim Beenden der Tonaufnahme bleibt das letzte Erkennungsergebnis erhalten.** Der Ergebnisempfänger wird nach Abschluss der Analyse abgewartet und nicht abgebrochen.
- **Abgebrochene Fragenerkennung behält ihren erkannten Status.** Die eindeutigen Kennungen für Frage, keine Frage und unvollständigen Satz bleiben auch in einer gekürzten JSON-Antwort erhalten. Nicht erkennbare Ausgaben nutzen einen abgesicherten Ersatzweg.
- **Fragen werden geordnet, ohne ältere brauchbare Treffer zu verlieren.** Eine spätere Aussage verwirft eine frühere Frage erst, wenn sie selbst als Frage bestätigt ist. Unsichere Erkennung kann das Modell nicht über Sofort- oder Zeitüberschreitungspfade umgehen.
- **Verknüpfte Fragen werden dem Modell nicht doppelt übergeben.** Die aktuelle Äußerung und die darin enthaltenen vorherigen Satzteile werden anhand ihrer Identität ausgeschlossen. Frühere gleichlautende Äußerungen bleiben verfügbar.
- **Strukturierte Antworten schlagen sichtbar und vorsichtig fehl.** JSON und Codeblöcke erscheinen nicht während der Ausgabe. Lesbare Teilergebnisse bleiben bei einem Übertragungsfehler erhalten. Fehlender Kontext senkt die Sicherheit; unbelegte Zahlen werden zur Prüfung gegen den Wortlaut markiert.
- **Antworten finden relevante ältere Fakten wieder.** Namen, auffällige Begriffe und Zahlen können frühere Aussagen innerhalb des Tokenlimits erneut einbringen. Zusammenfassungen holen keine später korrigierten Fakten zurück.
- **Alte Übersetzungs- und Zusammenfassungsaufträge überleben keinen Gesprächsneustart.** Beide Abläufe nutzen jetzt Sitzungs- oder Auftragskennungen. Regressionstests prüfen die zuvor möglichen Überschneidungen.
- **Umformulierte Fragen erreichen das Antwortmodell.** Erweitert die Fragenerkennung eine Rückfrage wie „Und warum?“, wird die vorläufige Modellanfrage durch eine mit der vollständigen Frage ersetzt.
- **Fehlgeschlagene Antworten blockieren keine Wiederholung mehr.** Eine Frage gilt erst nach erfolgreicher Antwort als beantwortet.
- **Mikrofonbetrieb und schnelle Einstellungsänderungen bleiben konsistent.** Ist Systemton ausgeschaltet, wird dessen Freigabe nicht mehr verlangt. Starts lassen sich abbrechen; Änderungen und Neustarts werden geordnet.
- **Release-Kennung und Installationsprüfung sind vollständig.** Release-Builds übernehmen Tag und Buildnummer. Entwickler-ID-Signaturen erhalten einen sicheren Zeitstempel; heruntergeladene Ollama-Pakete müssen zusätzlich Gatekeepers Notarisierungsprüfung bestehen.
- **Beim Beenden wird die Sitzung jetzt tatsächlich gestoppt.** `applicationWillTerminate` startete eine Aufgabe und wartete auf eine Sperre. Da `AppModel` auf dem Hauptakteur läuft, blockierte die Wartezeit genau den Akteur, den die Aufgabe brauchte. Die Aufnahme lief weiter und das Protokoll wurde nicht gespeichert. Das Beenden nutzt jetzt `applicationShouldTerminate` mit `.terminateLater`.
- **Datenrennen bei den Transkribierern sind behoben.** `systemTranscriber` und `microphoneTranscriber` wurden ohne Sperre beschrieben, aber vom Audiothread gelesen. Beide Zugriffe sind jetzt geschützt. Der Audiocallback liest die Transkribierer nicht mehr; die Aufnahmefunktion hält ihre Referenz.
- **Überlappende Starts bauen keine doppelten Aufnahmeketten mehr.** `isRunning` wurde erst am Ende von `bringUp()` gesetzt. Der frühe Schutz in `start()` griff deshalb während des mehrsekündigen Starts nicht. Die erste Kette blieb unerreichbar und hielt ihre Reservierung für das Sprachmodell bis zum Prozessende.
- **Stoppen während des Starts wird nicht mehr ignoriert.** Der Wunsch zu stoppen wird gespeichert und nach Abschluss des Starts ausgeführt. `restart()` berücksichtigt einen laufenden Start, damit Sprach- oder Quellenwechsel nicht verloren gehen.
- **Kein Audiostream läuft nach `stop()` weiter.** Die Einrichtung von `SCStream` ist asynchron. Ein Stop während des Starts konnte vom abgeschlossenen Start überschrieben werden; der Stream lief weiter und die macOS-Aufnahmeanzeige blieb an. Ein Generationszähler macht überholte Starts ungültig.
- **Die Berechtigungsprüfung folgt der gewählten Audioquelle.** Zuvor wurde immer die Bildschirmaufnahme geprüft, obwohl der Core-Audio-Prozess-Tap eine Audioaufnahmefreigabe benötigt. Prüfung, Sitzung und Sprung zu den Systemeinstellungen richten sich nun nach der Einstellung.
- **Der Installierer löscht eine vorhandene Ollama-Installation nicht mehr bei einem fehlgeschlagenen Umzug.** Die bestehende Installation wird zuerst beiseitegelegt und erst verworfen, wenn die neue am Ziel liegt.
- **Die Signaturprüfung nutzt jetzt einen einzelnen `codesign -R`-Ausdruck** statt eines Textvergleichs mit der Ausgabe von `codesign -dv`.
- **Fehler beim Aufwärmen werden nicht mehr verschluckt.** Ein fehlendes Modell zeigte sich zuvor erst mitten im Gespräch bei der ersten echten Frage.

### Geändert

- **Das Gesprächsfenster passt sich jetzt als schmale Seitenleiste an.** Gespräch und Antworten haben eigene Überschriften, Zähler und Statusanzeigen. Im schmalen Layout wechselt eine Auswahl zwischen den Bereichen und markiert ungesehene Antworten.
- **Das Mitlesen lässt sich steuern.** Manuelles Scrollen pausiert das automatische Nachführen. Schaltflächen springen zum neuesten Inhalt; gleichzeitige Teilresultate von Mikrofon und Systemton werden beide angezeigt. Die Einstellung bleibt auch bei Größenänderungen erhalten.
- **Die Oberfläche erklärt den nächsten Schritt.** Start, Aufnahme, Warten auf eine Frage, fehlende Modelle, Überarbeitung und Fehler haben eigene Hinweise. Fehlerkarten können die genaue Kontextfrage erneut senden; doppelte Antwortaufträge werden sofort blockiert.
- **Die Barrierefreiheit berücksichtigt macOS-Anzeigeeinstellungen.** Das Fenster beachtet „Bewegung reduzieren“, „Transparenz reduzieren“ und erhöhten Kontrast, erhält VoiceOver-Fokus beim Scrollen, meldet fertige Antworten und Probleme und beschriftet Ton, Modelle und Live-Text.
- **Das schwebende Fenster bleibt nach Monitorwechseln erreichbar.** Gespeicherte und sichtbare Positionen werden auf einen verfügbaren Bildschirm begrenzt.
- **Die gestreamte Antwortausgabe ist nicht mehr quadratisch langsam.** Bisher wurde bei jedem Token der gesamte Text erneut verarbeitet. Das blockierte Aufnahme und Übersetzung bei kritischer Latenz. Eine inkrementelle Formatierung erkennt den Trennpunkt einmalig; Änderungen werden höchstens alle 50 ms gesendet. Tests sichern das bisherige, bytegleiche Ergebnis.
- Spitzenerkennung und Kanalzusammenführung nutzen `Accelerate` (`vDSP`) statt Schleifen pro Tonprobe.
- `WindowPrivacy` folgt dem Ereignislauf nur, wenn die Einstellung aktiv ist, und beobachtet nur noch `beforeWaiting`.
- `.unsafeFlags(["-Onone"])` wurde aus `Package.swift` entfernt. Die Einstellung war im Debug-Build wirkungslos, verhinderte aber, `AlfredHelpCore` als Paketabhängigkeit zu verwenden.
- Eine verworfene Antwort ist jetzt ein eigenes `answerDiscarded`-Ereignis statt einer `answerFinished`-Karte mit dem Text „verworfen“ über die Modulgrenze hinweg.
- Die Stilleprüfung liegt jetzt als testbares `SilenceGate` außerhalb von `SourceTranscriber`.

### Hinzugefügt

- **Zerlegte Sätze werden wieder zusammengesetzt.** Eine gesprochene Frage kommt häufig in zwei oder drei abgeschlossenen Teilen an. Bisher wurde nur der letzte Teil beurteilt. `UtteranceStitcher` kann bis zu vier Teile verbinden. Sichtbar abgeschnittene Teile warten höchstens `continuationFlushSeconds` (2,6 s); ein fehlender Punkt wird nur ergänzt, wenn die Erkennung zwischen den Teilen weniger als 0,6 s Stille meldet. Beide Zeitfenster werden bei `swift test` gegen neue Daten geprüft. Antworten, die schon möglich sind, werden nicht verzögert.
- **`Benchmarks/satzzusammenfuehrung.json`** enthält 45 markierte Folgen von Erkennungsteilen samt Zeitpositionen: abgebrochene Teile, Satzmitten, Wiederholungen, Dreierketten, mehrere Sätze pro Block und Teile, die getrennt bleiben müssen.
- **Beim Verbinden werden Wiederholungen entfernt.** Die Erkennung wiederholt mitunter bereits gelieferte Wörter. Der überlappende Teil wird aus dem zweiten Fragment entfernt; Satzzeichen des ersten Fragments bleiben erhalten. Ein einzelnes gemeinsames Funktionswort wird nicht entfernt. Dieselbe Funktion läuft bereits in `UtteranceAssembler`, damit Wiederholungen nicht im Protokoll landen.
- **Mehrere Sätze zählen nicht mehr als eine einzige Frage.** `TextUtilities.questionFocus` beschränkt die Frage auf Sätze, die tatsächlich etwas fragen. Der Rest bleibt als Kontext verfügbar.
- **Überholte Antwortkarten werden ausdrücklich verworfen.** Ein abgebrochener Antwortstrom blieb zuvor bis zum Ende der Sitzung unvollständig stehen. Bei einer vollständigeren Folgefrage wird jetzt die alte Karte entfernt.
- **Die Regelerkennung erfasst bisher übersehene Frageformen.** Dazu gehören indirekte Fragen, Aufforderungen als Aussage, mehrteilige Anhängsel ohne Fragezeichen, elliptische Rückfragen mit Präposition, trennbare deutsche Verben und Nebensätze. Auf den früheren 162 Beispielen bleibt die Trefferquote bei 1,000 ohne sofortige Fehlalarme; die Präzision der Regeln steigt von 0,961 auf 0,971. Der vollständige Ablauf mit `gemma3:4b` steigt von 0,961/0,990 auf 0,970/0,990. Die Latenz bleibt unverändert.
- **79 markierte Beispiele** ergänzen `Benchmarks/frageerkennung.json` (162 → 241): 50 Fragen, 25 Aussagen und 4 Satzfragmente. Die Aussagen prüfen gezielt die neuen Regeln. Im gesamten Datensatz liegt die Trefferquote bei 1,000 und die Präzision bei 0,968; die fünf übrigen Fehlalarme liegen im einstellbaren 0,40-Bereich.
- **Neue Antwortkarten machen sich bemerkbar.** Sie gleiten ein und erhalten zwei Sekunden lang einen Akzentrand. Ohne Ton und Blinken.
- **Probleme bleiben in der Hinweisleiste sichtbar**, bis sie ablaufen, und werden nicht von einer harmlosen Meldung verdrängt.
- **`⌥⌘A` erklärt, wenn die Aktion nicht möglich ist.** Schaltfläche und Menüpunkt verwenden denselben Aktivierungsstatus; ohne aktive Sitzung erscheint ein Hinweis.
- **AlfredHelp startet Ollama bei Bedarf neu**, statt Nutzende zum manuellen Start aufzufordern.
- Die inaktive Schaltfläche „Fertig“ bei der Ersteinrichtung zeigt jetzt den noch fehlenden Schritt.
- **30 Tests** prüfen Antwortstrom, `cleanModelText`, Neuabtastung, Stilleprüfung und den Ollama-NDJSON-Parser mit einem simulierten Transport. Der Testumfang stieg von 97 auf 127, mit 11 weiteren Tests zur Fragenerkennung auf 138. Die Satzverknüpfung ergänzte 24 Tests auf 162.
- **CI prüft jetzt die macOS-Version,** erklärt SDK-Fehler verständlich, berücksichtigt Swift im Cache-Schlüssel und behandelt Compilerwarnungen im Release-Build als Fehler.

## [1.0.0] – 2026-08-11

Erste Veröffentlichung.

### Hinzugefügt

- **Ersteinrichtung ohne manuelle Schritte.** Fehlen Ollama, ein Sprachmodell oder Spracherkennungsdaten, lädt AlfredHelp sie beim Start. Ollama wird vor der Installation anhand der Entwickler-ID-Signatur und Team-ID geprüft. Ohne Administratorrechte wird `~/Applications` verwendet. Abschaltbar unter *Einstellungen › Modelle › Dienst*.
- **Systemtonaufnahme** über ScreenCaptureKit, unabhängig von der abspielenden App. Alternativ steht ein Core-Audio-Prozess-Tap bereit.
- **Live-Übersetzung ins Deutsche**, Satz für Satz und fortlaufend.
- **Zweistufige Fragenerkennung:** zuerst feste Regeln, bei unklaren Fällen das Sprachmodell. Präzision und Trefferquote liegen bei 1,000 auf 162 markierten deutschen und englischen Beispielen.
- **Antwortkarten** mit einem vorlesbaren Satz und ausklappbarer Begründung.
- **Manuelle Antwort als Rückfallebene:** Jede Äußerung der Gegenseite lässt sich anklicken, unabhängig von der automatischen Erkennung.
- **Gesprächskontext** aus fortlaufender Zusammenfassung und den letzten Äußerungen im Wortlaut.
- **Bei Bildschirmfreigaben unsichtbar**, prüfbar mit `--privacy-check`.
- **Modellauswahl mit Messwerten** statt Werbeversprechen, gespeist aus `Benchmarks/benchmark.py`.
- Kommandozeilenprüfungen: `--selftest`, `--audio-diagnose`, `--audio-watch`, `--audio-devices`, `--capture-probe`, `--transcribe-test`, `--recognition-latency` und `--privacy-check`.

### Gemessen

- Die Erkennungszeit nach dem Sprechen sank von 4.451 ms auf **782 ms**, indem der Abschluss am Tonpegel statt an der Textvermutung ausgerichtet wurde.
- Mit `gemma3:4b` als Hilfsmodell dauerte die Fragenerkennung 375 ms statt 881 ms mit `gemma3:12b`; zugleich sank die Zahl der Erkennungsfehler um einen.

[Noch nicht veröffentlicht]: https://github.com/PalescoDev/AlfredHelp/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/PalescoDev/AlfredHelp/releases/tag/v1.0.0
