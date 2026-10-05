# Fehlersuche

<sub>AlfredHelp · PalescoDev</sub>

Alle Befehle gehen davon aus, dass die App unter `/Applications` liegt. Liegt sie
woanders, den Pfad entsprechend anpassen.

---

## Zuerst: der Selbsttest

```
"/Applications/AlfredHelp.app/Contents/MacOS/AlfredHelp" --selftest
```

Prüft Ollama, führt einen echten Modellaufruf aus, kontrolliert die
Sprachmodelle und hört vier Sekunden Systemton mit. Der Bericht landet
zusätzlich unter `~/Library/Application Support/AlfredHelp/selbsttest.txt`.

---

## „Es wird nichts transkribiert“

**Zuerst die Lautstärke prüfen.** Die Aufnahme greift den Ton dort ab, wo er
zum Ausgabegerät geht — also *hinter* Lautstärkeregler und Stummschaltung. Ein
stummgeschalteter Mac liefert einwandfreie Tonpuffer, in denen ausschließlich
Nullen stehen. Das ist von einer entzogenen Freigabe nicht zu unterscheiden,
solange man nur auf „kommt Ton an?“ schaut. Nachgemessen auf einem USB-Ausgang:

| Ausgabelautstärke | Spitzenpegel | Transkript |
|---|---|---|
| 0 %, stumm | 0,0000 | leer |
| 40 % | 0,9187 | vollständig und korrekt |

AlfredHelp erkennt das inzwischen selbst und schreibt es hin, statt auf die
Freigabe zu zeigen. `--transcribe-test` zeigt den Zustand in der Zeile
*Ausgabe*.

**Vorsicht beim Selberprüfen:** Warntöne aus `/System/Library/Sounds/` laufen
über den separaten Ausgang für Signaltöne und werden auch bei stummem
Hauptausgang erfasst — damit lässt sich also nichts beweisen. Ebenso wenig
taugt `say`: die macOS-Sprachsynthese läuft an der Systemtonerfassung vorbei
und liefert immer Pegel null. Wer die Kette prüfen will, spielt eine Datei über
eine normale App ab:

```
say -v Anna -o /tmp/probe.aiff "Wie hoch sind die laufenden Kosten pro Monat?"
afplay /tmp/probe.aiff
```

Bleibt es danach still, ist es fast immer die fehlende Freigabe für
Systemaudioaufnahme.

**Warum das nicht wie ein Fehler aussieht:** macOS meldet fehlenden Zugriff
nicht. Der Datenstrom startet, liefert korrekt geformte Tonpuffer in der
richtigen Größe und Taktrate — und schreibt lauter Nullen hinein. Deshalb prüft
AlfredHelp immer den tatsächlichen Pegel und meldet nach 30 Sekunden digitaler
Stille ausdrücklich, dass etwas nicht stimmt.

**So beheben:**

1. Systemeinstellungen → *Datenschutz & Sicherheit* → **Bildschirm- &
   Systemaudioaufnahme**
2. Steht dort bereits ein Eintrag für AlfredHelp: **entfernen**
3. AlfredHelp starten, im Einrichtungsfenster auf *Erlauben*
4. **AlfredHelp neu starten** — macOS gibt die Entscheidung erst dem nächsten
   Programmstart mit
5. Im Einrichtungsfenster auf *Erneut prüfen*, während etwas Ton läuft. Der
   Pegel muss deutlich über null liegen.

Vollständiger Nachweis der Kette Systemton → Text:

```
"/Applications/AlfredHelp.app/Contents/MacOS/AlfredHelp" --transcribe-test 20 de-DE
```

Meldet `ERFOLGREICH` nur bei echtem Ton **und** erkanntem Text.

---

## „Wird jedes Mal nach der Berechtigung gefragt?“

Nein. ScreenCaptureKit prüft beim Start nur den Freigabestatus von macOS; es
startet dabei keine Tonaufnahme. Der Core-Audio-Tap wird erst geprüft, wenn du
„Ton prüfen“ auswählst. Dafür muss Systemton laufen, Sprache ist nicht nötig.

Die macOS-Abfrage erscheint höchstens einmal. Fehlt die Freigabe oder ändert
sie sich nach einem Neubau, führt AlfredHelp zu den passenden
Systemeinstellungen. Dort kannst du sie manuell erteilen.

---

## „Sieht mein Gegenüber das Fenster bei einer Bildschirmfreigabe?“

Nein, solange *Vor Bildschirmfreigabe verbergen* aktiv ist – und das lässt sich
nachprüfen:

```
"/Applications/AlfredHelp.app/Contents/MacOS/AlfredHelp" --privacy-check
```

Der Test nimmt den Bildschirm über ScreenCaptureKit auf, also über genau die
Schnittstelle, die Teams, Zoom und Discord benutzen, und vergleicht Bildpunkte.
Er läuft in zwei Durchgängen: zuerst mit einem normalen Fenster als Gegenprobe –
schlägt die nicht an, taugt der Test nichts und sagt das auch –, danach mit dem
Schutz. Gemessenes Ergebnis auf diesem Mac: Gegenprobe 100,00 % Abweichung,
geschütztes Fenster 0,00 %.

Der Schutz gilt für **alle** Fenster von AlfredHelp, auch für Einstellungen und
Einrichtungsfenster, und auch für Fenster, die erst später geöffnet werden.

---

## „Nach einem Update ist die Freigabe wieder weg“

Das war das Verhalten ad-hoc signierter Ausgaben: macOS band die Freigabe an
die Prüfsumme des Programms, und jeder Neubau erzeugte eine neue Prüfsumme.

**Das ist erledigt.** Auf diesem Rechner existiert die Signaturidentität
`AlfredHelp Local Signing`, und `build.sh` benutzt sie automatisch. Die
Freigabe hängt jetzt am Zertifikat statt an der Prüfsumme:

```
designated => identifier "io.github.fvulcan.alfredhelp"
              and certificate root = H"2d6d9d18…"
```

Nachgemessen über drei Builds mit einer echten Codeänderung dazwischen: die
Prüfsumme wechselte, diese Bedingung blieb Zeichen für Zeichen gleich. Die
Freigabe muss also **einmal** für diese Identität erteilt werden und gilt
danach für jeden weiteren Neubau.

Prüfen lässt sich das jederzeit mit:

```
codesign -d -r- /Programme/AlfredHelp.app
```

Steht dort `cdhash H"…"` statt `certificate root`, wurde ad-hoc signiert —
dann fehlt die Identität im Schlüsselbund (`security find-identity | grep
AlfredHelp`), und sie muss einmalig neu angelegt werden: Schlüsselbund­verwaltung
→ *Zertifikatsassistent → Zertifikat erstellen …*, Name `AlfredHelp Local
Signing`, Typ *Selbstsigniertes Stammzertifikat*, Zertifikatstyp *Codesignatur*.

---

## „Keine Antworten, obwohl Fragen kommen“

- **Modell nicht geladen?** Menüleistensymbol prüfen — dort steht das aktive
  Modell. Ist der Eintrag leer, in den Einstellungen eines wählen.
- **Zu wenig Arbeitsspeicher?** `gemma3:12b` belegt gut 10 GB. Auf Macs mit
  16 GB lieber `gemma3:4b` wählen.
- **Nur eindeutige Fragen werden beantwortet?** Dann fällt die Modellstufe aus.
  `--selftest` zeigt, ob das Hilfsmodell installiert ist.
- **Auslöseschwelle** in den Einstellungen unter *Antworten* senken, wenn
  indirekte Fragen übersehen werden.
- **Einzelne Frage trotzdem verpasst?** Im Transkript auf die Sprechblase (？)
  der Zeile klicken — die Äußerung wird dann ohne weitere Prüfung beantwortet.
  Das funktioniert auch nachträglich für jede ältere Zeile der Gegenseite.

---

## „Ollama startet nicht“

AlfredHelp öffnet Ollama beim Programmstart selbst — und **auch später noch**:
Antwortet der Dienst beim Zuhören-Start nicht mehr, versucht die App ihn erneut
zu starten, statt dich dazu aufzufordern. Du siehst dann kurz „Ollama antwortet
nicht – wird gestartet …“, und danach entweder „Ollama läuft wieder.“ oder eine
Meldung mit dem nächsten Schritt.

Klappt das nicht:

```
curl -s http://127.0.0.1:11434/api/version
```

Kommt keine Antwort, Ollama einmal von Hand beenden und neu öffnen. Danach in
AlfredHelp unter *Einstellungen › Modelle* auf *Erneut prüfen* klicken — ein
Neustart der App ist dafür nicht nötig.

---

## Audio-Diagnose für hartnäckige Fälle

| Befehl | Zweck |
|---|---|
| `--audio-devices` | Alle Audiogeräte mit Laufzustand, Standardausgabe markiert |
| `--audio-diagnose` | Acht Erfassungs-Konfigurationen im Vergleich, mit Rohpegel |
| `--audio-watch 12` | Zeitverlauf der Erfassung, halbsekündlich |
| `--capture-probe` | Erfassung als echter Fensterprozess, Rohpuffer-Dump |
| `--recognition-latency <datei.wav> de-DE` | Erkennungsverzögerung an einer Datei messen, spielt nichts ab |

Beispiel:

```
"/Applications/AlfredHelp.app/Contents/MacOS/AlfredHelp" --audio-devices
```

---

## Protokolle des Betriebs

```
log show --last 10m --predicate 'subsystem == "io.github.PalescoDev.alfredhelp"' --style compact
```

Enthält Zeiten und Entscheidungen, **niemals Gesprächsinhalte**.

---

<sub>AlfredHelp · PalescoDev</sub>
