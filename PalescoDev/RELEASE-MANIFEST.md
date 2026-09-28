# Release-Manifest

## Quelle

- App-Code, Ressourcen und Tests: `Richtig/`
- Versionsnummer: `Richtig/Resources/Info.plist`
- Änderungsprotokolle: `CHANGELOG.md`, `Richtig/CHANGELOG.md`, `Richtig/GitHub/CHANGELOG.md`
- Release-Notiz: `Richtig/GitHub/Release/Release-Notes-v<Version>.md`
- Release-Ablauf: `.github/workflows/release.yml`

## Benötigt für ein offizielles Release

- `MACOS_CERTIFICATE_P12`
- `MACOS_CERTIFICATE_PASSWORD`
- `MACOS_SIGNING_IDENTITY`
- `NOTARY_API_KEY`
- `NOTARY_API_KEY_ID`
- `NOTARY_API_ISSUER`
- Erfolgreiche Tests, Signaturprüfung und Apple-Notarisierung

Fehlt eine Voraussetzung, stoppt der Release-Ablauf. Ein lokaler Build, eine Selbstsignatur oder eine bestandene Test-Suite ersetzt weder Developer-ID-Signatur noch Notarisierung.

## GitHub-Artefakte

Der Workflow erstellt zunächst einen Entwurf mit:

- `AlfredHelp-v<Version>.zip`
- `AlfredHelp-v<Version>.zip.sha256`
- fertige deutsche Veröffentlichungsnotiz

Die Veröffentlichung bleibt ein Entwurf, bis sie von Hand freigegeben wird.

## Nicht als fertiges Release behandeln

`Richtig/dist/AlfredHelp.app` ist eine lokale, ignorierte Build-Ausgabe. Sie wird nicht als GitHub-Artefakt verwendet. Nur das im Release-Ablauf signierte und von Apple notarisierte, anschließend geprüfte Archiv ist für die Freigabe vorgesehen.
