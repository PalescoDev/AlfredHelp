# Sicherheit

## Sicherheitslücke melden

**Bitte keine öffentliche Issue öffnen.** Melde die Lücke vertraulich über GitHub:

*Security → Sicherheitslücke melden*:
<https://github.com/PalescoDev/AlfredHelp/security/advisories/new>

Das ist der einzige Meldeweg. Die Meldung geht direkt und vertraulich an die Projektverantwortlichen.

In der Regel antworten wir innerhalb von sieben Tagen. Auf Wunsch nennen wir die meldende Person in der Sicherheitsmeldung.

## Unterstützte Versionen

| Version | Unterstützt |
|---|---|
| 1.0.x | ✅ |
| älter | – |

## Was die App tut

Diese Angaben beschreiben die Angriffsfläche.

### Ton

Systemton wird über ScreenCaptureKit aufgenommen und **nie auf die Festplatte geschrieben**. Die Spracherkennung läuft mit Apples Gerätemodellen.

### Netzwerk

Es gibt genau **zwei** ausgehende Verbindungen:

1. **`127.0.0.1:11434`** — Ollama. Der HTTP-Client ist fest auf Loopback gestellt und verwendet keinen Proxy. Gesprächsinhalte gehen nur dorthin.
2. **`ollama.com` / `github.com`** — einmalig bei der Ersteinrichtung, um Ollama zu laden. Dabei werden keine Daten gesendet; die App lädt nur eine Datei. Danach gibt es keinen weiteren Zugriff.

Einen dritten Netzwerkweg gibt es nicht.

### Ersteinrichtung

Die App lädt dabei Programmcode aus dem Internet und legt ihn im Programme-Ordner ab. Deshalb gilt:

- Downloads kommen über TLS ausschließlich von der offiziellen Quelle.
- **Vor jedem Schreiben außerhalb des temporären Ordners** prüft die App `codesign --verify --deep --strict`, die Team-ID `3MU9H2V9Y9` und eine Entwickler-ID-Signatur. Eine beliebige intakte Signatur genügt nicht. Tests sichern dieses Verhalten.
- Erst danach wird die Quarantäne-Kennzeichnung entfernt.
- Ohne Administratorrechte nutzt die App `~/Applications`. Es gibt keine Passwortabfrage und keinen privilegierten Hilfsprozess.
- Eine vorhandene Installation wird nicht ersetzt oder verändert.

Der Download lässt sich unter *Einstellungen › Modelle › Dienst* abschalten. Die App zeigt dann nur, was fehlt.

### Berechtigungen

| Berechtigung | Verwendung |
|---|---|
| Bildschirm- und Systemaudioaufnahme | Ton der Gegenseite erfassen |
| Mikrofon | Eigene Gesprächsseite optional erfassen |
| Spracherkennung | Apples Gerätemodelle verwenden |

Die App-Sandbox ist nicht aktiv: AlfredHelp startet Ollama als eigenen Prozess und schreibt während der Ersteinrichtung in den Programme-Ordner. Beides ist in einer Sandbox nicht möglich.

### Lokal gespeicherte Daten

`~/Library/Application Support/AlfredHelp/Protokolle` enthält Gesprächsprotokolle – nur wenn die Speicherung eingeschaltet ist. Sie lässt sich in den Einstellungen abschalten. Sonst werden keine Gesprächsdaten gespeichert.

## Bekannte Einschränkung

Ohne Entwicklerzertifikat wird ein Build ad-hoc signiert. macOS bindet die Audioberechtigung dann an die Prüfsumme des Programms, die sich mit jedem Neubau ändert. Das ist keine Sicherheitslücke, aber der Grund, warum veröffentlichte Builds signiert und notarisiert sein müssen.
