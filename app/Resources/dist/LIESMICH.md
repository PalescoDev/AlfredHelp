# AlfredHelp

**Dein Mac hört mit, übersetzt live ins Deutsche und beantwortet Fragen der
Gegenseite — vollständig lokal, ohne Internetverbindung.**

Egal woher der Ton kommt: Microsoft Teams, Zoom, Discord, ein Browser-Tab, ein
Video. Erfasst wird, was der Mac abspielt.

<sub>PalescoDev</sub>

---

## In zwei Schritten startklar

### 1. AlfredHelp starten

`AlfredHelp.app` in den Programme-Ordner ziehen und öffnen. **Mehr ist nicht
vorzubereiten** — insbesondere musst du Ollama nicht selbst installieren.

Beim ersten Start holt sich AlfredHelp, was auf diesem Mac fehlt:

| Was | Größe |
|---|---|
| Ollama (offizielles Bündel, gegen die Signatur des Herstellers geprüft) | ~180 MB |
| Sprachmodell `gemma3:4b` | 3,3 GB |
| Erkennungsdaten deiner Sprache | je nach Sprache |

Der Fortschritt steht im Einrichtungsfenster und in der Menüleiste. Klicken
musst du dafür nichts. Hast du Ollama oder eigene Modelle schon, wird nichts
geladen und nichts angefasst.

Das Ganze läuft einmal. Ab dem zweiten Start ist alles da.

> Abschaltbar unter *Einstellungen › Modelle › Dienst* („Fehlendes selbst
> nachinstallieren"). Dann meldet die App nur noch, was fehlt.

### 2. Systemton freigeben

Das ist das Einzige, was AlfredHelp **nicht** selbst erledigen kann — die
Freigabe erteilt nur macOS auf deinen Klick hin.

Im Einrichtungsfenster auf *Erlauben* klicken, den macOS-Dialog bestätigen,
**AlfredHelp einmal neu starten**. macOS gibt die Entscheidung erst dem nächsten
Programmstart mit. Die Freigabe heißt dort „Bildschirm- & Systemaudioaufnahme“.

Danach prüft AlfredHelp mit echten Tonproben nach, ob sie wirklich greift — und
sagt dir das Ergebnis, statt es anzunehmen.

### Ein größeres Modell? Freiwillig.

Mit `gemma3:4b` läuft alles. Wer bessere Antworten will und den Arbeitsspeicher
hat, wählt im Einrichtungsfenster ein größeres:

| Modell | Antwortqualität | Tempo | Größe |
|---|---|---|---:|
| **gemma3:12b** | ●●●●● 100 % | ●●●○○ 14 Tok/s | 8,1 GB |
| qwen3:14b | ●●●●● 96 % | ●●○○○ 9 Tok/s | 9,3 GB |
| phi4:14b | ●●●●● 96 % | ●●○○○ 8 Tok/s | 9,1 GB |
| gemma3:4b | ●●●●○ 94 % | ●●●●○ 24 Tok/s | 3,3 GB |
| qwen3:8b | ●●●●○ 92 % | ●●●○○ 14 Tok/s | 5,2 GB |
| llama3.2:3b | ●●●○○ 88 % | ●●●●● 32 Tok/s | 2,0 GB |

Die Prozentwerte sind gemessene Abdeckung geforderter Kernpunkte, die Tok/s
gemessener Durchsatz. Details in `Messwerte.md`.

Wählbar ist nur, was tatsächlich auf diesem Mac liegt. Weitere Modelle stehen
darunter unter *Weitere Modelle herunterladen* — getrennt, damit ein Klick in
der Auswahl nie versehentlich einen Gigabyte-Download auslöst.

Ein Klick genügt: AlfredHelp lädt das Modell in den Speicher und wärmt es auf.
Mithören startest du selbst oder schaltest den automatischen Start bewusst ein.

**Zum Tempo:** Übersetzung und Frageerkennung laufen am besten auf einem kleinen
Helfer. Gemessen mit `gemma3:4b` gegenüber `gemma3:12b` in dieser Rolle:
Frageerkennung 375 statt 881 ms und ein Erkennungsfehler weniger. Genau deshalb
ist `gemma3:4b` das Modell, das die Ersteinrichtung holt — es kann beides.

**Empfehlung:** `gemma3:12b` als Antwortmodell, wenn der Mac 24 GB
Arbeitsspeicher oder mehr hat. Darunter bleibt `gemma3:4b` die bessere Wahl.

### Losreden

Automatisches Zuhören ist zunächst ausgeschaltet. Aktiviere es bei Bedarf unter
*Einstellungen › Modelle › Beim Start automatisch zuhören*. AlfredHelp startet
Ollama selbst und lädt das gewählte Modell, sobald du die Sitzung startest.

---

## Was du im Betrieb siehst

Ein schwebendes Fenster, das dem Meeting nie den Fokus wegnimmt:

**Links** läuft das Gespräch mit — die deutsche Übersetzung groß, das Original
klein darunter.

**Rechts** erscheinen Antwortkarten, sobald die Gegenseite eine Frage stellt.
Ganz oben steht der Satz, den du **wortwörtlich vorlesen** kannst. Darunter
klappt *Ausführlich* den Hintergrund auf: Begründung, Zahlen, Randfälle,
mögliche Rückfragen. Der Kopieren-Knopf nimmt nur den Vorlese-Teil.

Eine neue Karte schiebt sich oben herein und trägt zwei Sekunden lang einen
farbigen Rahmen. Kein Ton, kein Blinken — du sitzt in einer Besprechung. Es
genügt, dass du die Bewegung aus dem Augenwinkel mitbekommst, während du
zuhörst.

**Wurde eine Frage nicht erkannt?** Jede Zeile der Gegenseite trägt rechts eine
kleine Sprechblase (？). Ein Klick darauf behandelt genau diese Äußerung als
Frage und erzeugt sofort eine Antwort — ohne dass die automatische Erkennung
noch dazwischenfunken kann. Dasselbe geht per Rechtsklick auf die Zeile
(*Als Frage beantworten*).

Sobald der Mauszeiger über dem Verlauf steht, **hält das Mitscrollen an** —
sonst wandert die Zeile, die du gerade anklicken willst, unter dem Zeiger weg.
Zeiger wieder weg, und der Verlauf springt ans Ende und läuft normal mit.

Werden zu viele oder zu wenige Fragen erkannt: *Einstellungen › Antworten ›
Auslöseschwelle*. Der Regler zeigt neben dem Zahlenwert im Klartext an, worauf
die App bei dieser Einstellung reagiert.

Das Fenster ist standardmäßig **vor Bildschirmfreigaben verborgen** — wer deinen
Bildschirm in Teams, Zoom oder Discord sieht, sieht AlfredHelp nicht. Das gilt
für alle Fenster der App und lässt sich mit `--privacy-check` nachprüfen: der
Test nimmt den Bildschirm auf und vergleicht Bildpunkte, mit einer Gegenprobe,
damit er nicht bloß immer „bestanden“ sagt.

Nach der Freigabe wird **nicht bei jedem Start erneut gefragt**. ScreenCaptureKit
prüft AlfredHelp beim Start über den Status von macOS. Der Core-Audio-Tap hat
keine Vorabprüfung: Prüfe ihn bewusst mit hörbarem Systemton über „Ton prüfen“.
Bei einer fehlenden Freigabe führt AlfredHelp in die passenden Systemeinstellungen.

Steht ein Problem an — fehlende Freigabe, Ollama antwortet nicht —, **bleibt es
im Hinweisstreifen stehen**, bis es sich erledigt hat. Eine belanglose Meldung
schiebt es nicht mehr weg.

### Tastenkürzel

| | |
|---|---|
| `⌥⌘L` | Mithören starten / stoppen |
| `⌥⌘O` | Fenster ein- / ausblenden |
| `⌥⌘A` | Antwort zur letzten Äußerung erzwingen |

Geht `⌥⌘A` gerade nicht — weil nicht zugehört wird oder Ollama nicht antwortet
—, sagt AlfredHelp das im Hinweisstreifen, statt einfach nichts zu tun.

### Sprache umstellen

Menüleistensymbol → *Sprache der Gegenseite*. Bei Deutsch entfällt die
Übersetzung, die Frageerkennung läuft weiter.

---

## Datenschutz

- Der Ton wird im System abgegriffen und **nie auf die Festplatte geschrieben**.
- Die Spracherkennung nutzt Apples geräteinterne Modelle.
- Übersetzung, Frageerkennung und Antworten laufen über Ollama auf `127.0.0.1`.
  Es gibt in dieser Anwendung **keinen zweiten Netzwerkpfad** — der HTTP-Client
  ist auf Loopback festgelegt und ohne Proxy konfiguriert.
- Sobald die Modelle einmal geladen sind, funktioniert alles **ohne Internet**.
- Gesprächsprotokolle landen nur lokal unter
  `~/Library/Application Support/AlfredHelp/Protokolle` — abschaltbar in den
  Einstellungen. Sie werden auch dann geschrieben, wenn du AlfredHelp direkt
  beendest, ohne vorher zu stoppen.

---

## Wenn etwas klemmt

Ausführlich in `Fehlersuche.md`. Der häufigste Fall zuerst:

**Es wird nichts transkribiert, obwohl Ton läuft.** Die Freigabe für
Systemaudioaufnahme fehlt. AlfredHelp meldet das nach wenigen Sekunden mit einem
Banner. Wichtig zu wissen: macOS meldet fehlenden Zugriff **nicht als Fehler**,
sondern liefert stumme Tonpuffer — deshalb prüft AlfredHelp immer den echten
Pegel und nicht nur, ob der Datenstrom läuft.

Schnelltest im Terminal:

```
"/Applications/AlfredHelp.app/Contents/MacOS/AlfredHelp" --selftest
```

---

<sub>AlfredHelp · PalescoDev · Läuft vollständig lokal auf diesem Mac.</sub>
