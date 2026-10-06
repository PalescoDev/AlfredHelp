# KI-Unterstützung bei AlfredHelp

## Überblick

Ich habe AlfredHelp auf Grundlage meines bestehenden Projekts mit KI-Unterstützung weiterentwickelt. Die KI half bei der Analyse, bei unabhängigen Reviews und bei ausgewählten Codeänderungen. Ziel, Umfang und Freigabe der Arbeiten habe ich selbst festgelegt.

## Ablauf

Zuerst ließ ich den macOS-Codebestand untersuchen, ohne Änderungen vorzunehmen. Den iPhone-Teil schloss ich für diese Arbeit ausdrücklich aus.

Für unabhängige Prüfungen setzte ich mehrere Subagenten parallel ein. Sie untersuchten getrennte Bereiche:

- Audioaufnahme, Sitzungsabläufe und Lebenszyklus
- Pipeline und Nebenläufigkeit
- Frageerkennung und Antwortqualität
- Oberfläche und Barrierefreiheit
- Release-Ablauf und Sicherheit

Anschließend ließ ich mögliche Verbesserungen erläutern, bevor ich die Umsetzung freigab. Danach unterstützte die KI bei ausgewählten Änderungen, insbesondere bei der Frageerkennung, der Antwortausgabe und dem geordneten Beenden des von AlfredHelp gestarteten Ollama-Prozesses. Die Ergebnisse wurden zusammengeführt und lokal geprüft.

## Modell- und Subagenten-Konfiguration

Für die Arbeit verwendete ich GPT-5 als Hauptmodell. Die Subagenten liefen mit Opus 5 auf der Reasoning-Stufe XHigh. Ich nutzte sie parallel für voneinander unabhängige Prüfungen und Teilaufgaben; ihre Ergebnisse wurden anschließend zusammengeführt und von mir bewertet.

## Mein eigener Beitrag

Ich habe Ziel und Umfang festgelegt, den iPhone-Teil ausgeschlossen, Prüfbereiche bestimmt, Verbesserungsvorschläge bewertet und die Umsetzung freigegeben. Ausgangspunkt war mein bestehendes Projekt.

Die gespeicherten Arbeitsaufzeichnungen ordnen einzelne Codeänderungen nicht zuverlässig Datei für Datei mir oder der KI zu. Deshalb nenne ich hier keine konkreten Dateien als ausschließlich von mir manuell geänderte Dateien. Ergänzungen zu eigenen manuellen Änderungen sollten konkret und nachvollziehbar dokumentiert werden.

## Prüfung der Änderungen

Für dokumentierte Zwischenstände wurden lokale Swift-Builds und Tests ausgeführt. Am 28. September 2026 bestanden lokal ein Build mit Warnungen als Fehlern, 240 Tests in 46 Testsuiten sowie Prüfungen des App-Bundles, der Signatur und des Selbsttests.

## KI-Funktionen in der App

Die KI-Unterstützung während der Entwicklung ist von den KI-Funktionen der fertigen App zu unterscheiden. AlfredHelp verwendet Ollama lokal auf dem Mac für Übersetzung, Frageerkennung, Antwortvorschläge und Gesprächszusammenfassungen. Ollama kann während der Ersteinrichtung aus dem Internet geladen werden; die Modellaufrufe der App laufen lokal.

Die Prompts, die AlfredHelp zur Laufzeit an das lokale Modell sendet, liegen zentral in [`Prompts.swift`](../Sources/AlfredHelpCore/Intelligence/Prompts.swift). Dazu gehören Prompts für Übersetzung, Frageerkennung, Antworten und Gesprächszusammenfassungen.

Die GitHub-Dateien enthalten nicht den vollständigen Wortlaut aller Entwicklungs-Chats und Nutzer-Prompts. Diese Seite beschreibt den dokumentierten Ablauf und ist kein vollständiges Gesprächsprotokoll.
