# Veröffentlichungs-Checkliste

<sub>PalescoDev</sub>

Der aktive Quellcode liegt in `app/`. Release-Unterlagen, Versionsskript und Übersicht stehen in `PalescoDev/`.

## Einmalig einrichten

Offizielle Releases brauchen eine **Developer-ID-Signatur** und **Apple-Notarisierung**. Ohne beides stoppt der Release-Ablauf.

Im Apple Developer Program:

1. Zertifikat *Developer ID Application* erstellen und in den Schlüsselbund laden.
2. Notarisierungs-Schlüssel in App Store Connect erstellen (`.p8`, Key-ID und Issuer-ID).
3. Unter *Einstellungen → Geheimnisse und Variablen → Aktionen* diese Geheimnisse hinterlegen:

Schütze `main` und die Tags `v*` vor ungeprüften Änderungen. Nur vertrauenswürdige Personen erhalten Schreibzugriff, weil Schreibzugriff auch Actions-Geheimnisse zugänglich macht.

| Geheimnis | Inhalt |
|---|---|
| `MACOS_CERTIFICATE_P12` | Base64-kodiertes `.p12`-Zertifikat |
| `MACOS_CERTIFICATE_PASSWORD` | Passwort des `.p12` |
| `MACOS_SIGNING_IDENTITY` | z. B. `Developer ID Application: Name (TEAMID)` |
| `NOTARY_API_KEY` | Base64-kodierter Inhalt der `.p8`-Datei |
| `NOTARY_API_KEY_ID` | Schlüssel-ID |
| `NOTARY_API_ISSUER` | Aussteller-ID |

Zertifikat kodieren:

```bash
base64 -i zertifikat.p12 | pbcopy
```

## 1. Version vorbereiten

Zuerst Vorschau ansehen:

```bash
./PalescoDev/VERSION_VORBEREITEN.sh patch
```

Für eine Haupt- oder Nebenfassung `major` oder `minor` einsetzen. Erst nach Prüfung der Vorschau Änderungen schreiben:

```bash
./PalescoDev/VERSION_VORBEREITEN.sh patch --anwenden
```

Das Skript vergleicht die letzte Git-Fassung mit `app/Resources/Info.plist`, erhöht die gewählte SemVer-Stelle und aktualisiert die Versionsnummer sowie alle drei Änderungsprotokolle. Es erstellt keinen Commit und keinen Tag. Die Freigabe bleibt bei dir.

Lege eine deutsche Veröffentlichungsnotiz nach `PalescoDev/RELEASE-NOTIZEN-VORLAGE.md` an und speichere sie unter `app/GitHub/Release/Release-Notes-v<Version>.md`. Der Release-Ablauf stoppt, wenn die Notiz fehlt oder noch Platzhalter enthält.

## 2. Prüfen

```bash
(cd app && swift test)
./build.sh release
codesign --verify --deep --strict --verbose=2 app/dist/AlfredHelp.app
"app/dist/AlfredHelp.app/Contents/MacOS/AlfredHelp" --selftest
"app/dist/AlfredHelp.app/Contents/MacOS/AlfredHelp" --privacy-check
```

- [ ] Tests laufen erfolgreich durch.
- [ ] Versionsnummer in `app/Resources/Info.plist` entspricht der neuen Fassung.
- [ ] Änderungsprotokoll und Release-Notiz sind fertig.
- [ ] Selbsttest und Datenschutzprüfung sind erfolgreich.
- [ ] Die App wurde mit freigegebener Audioberechtigung und hörbarer Tonquelle geprüft.

Ein lokales Programmbündel ist **nicht automatisch veröffentlichungsfertig**. Offizielle Releases werden im GitHub-Ablauf mit Developer ID signiert, notarisiert und geprüft.

## 3. Commit und Tag

Änderungen prüfen und gezielt vormerken. Nicht `git add -A` verwenden.

```bash
VERSION="1.0.1"  # Durch die vorbereitete Fassung ersetzen.
git add app/Resources/Info.plist CHANGELOG.md app/CHANGELOG.md app/GitHub/CHANGELOG.md
if [ -f "app/GitHub/Release/Release-Notes-v$VERSION.md" ]; then
  git add "app/GitHub/Release/Release-Notes-v$VERSION.md"
fi
git diff --cached --check
git diff --cached
git commit -m "AlfredHelp $VERSION"
git tag -a "v$VERSION" -m "AlfredHelp $VERSION"
git push origin main
git push origin "v$VERSION"
```

Der Tag startet `.github/workflows/release.yml`. Er muss auf einem Commit von `main` liegen. Ein manueller Start ist nur auf dem bereits vorhandenen Tag und mit derselben Fassung möglich. Der Ablauf testet, signiert, notarisiert und erstellt einen **Entwurf**. Er veröffentlicht nichts automatisch.

## 4. Entwurf prüfen und freigeben

- [ ] GitHub-Ablauf ist erfolgreich.
- [ ] Entwurf und Release-Text prüfen.
- [ ] ZIP-Archiv laden und SHA-256-Prüfsumme vergleichen.
- [ ] App auf einem anderen Mac öffnen und prüfen.
- [ ] Signatur, Notarisierung, Selbsttest und Datenschutzprüfung bestätigen.
- [ ] Erst danach **Veröffentlichung freigeben**.

## 5. Danach

- [ ] Neuen Abschnitt „Noch nicht veröffentlicht“ im Änderungsprotokoll anlegen.
- [ ] Veröffentlichung im Repository anheften.
- [ ] Meldung für Rückmeldungen anlegen und anheften.

## Wenn etwas schiefläuft

- **Versionsprüfung schlägt fehl:** Den Vorbereitungsablauf nochmals auf dem aktuellen, sauberen Stand ausführen. Tag und `Info.plist` müssen dieselbe SemVer-Fassung haben.
- **Signierung oder Notarisierung schlägt fehl:** Geheimnisse und Apple-Zertifikate prüfen. Ohne beides gibt es kein Release-Archiv.
- **GitHub lehnt das SDK ab:** Der macOS-Läufer hat noch kein benötigtes SDK. Nicht mit einem lokal ad-hoc-signierten Bündel ersetzen; den Lauf später wiederholen.
- **Tag zurückziehen:** Einen bereits veröffentlichten Tag nicht überschreiben. Vor der Freigabe kann ein falscher Tag lokal und auf GitHub gelöscht und danach korrekt neu angelegt werden.
