## Änderung

<!-- In ein bis drei Sätzen: Was macht die App danach anders? -->

## Grund

<!-- Welches Problem löst die Änderung? Bei einem Fehler: Behebt #123 -->

## Geprüft

- [ ] `swift test` läuft erfolgreich durch.
- [ ] `./build.sh` erstellt ein startfähiges Programmbündel.
- [ ] Sichtbare Änderungen wurden in der laufenden App geprüft.

## Vier Projektregeln

- [ ] **Deutsche Oberfläche** — alle neuen Texte für Nutzende sind deutsch.
- [ ] **Zahlen sind gemessen** — neue oder geänderte Grenzwerte, Ranglisten und Latenzen stammen aus `Richtig/Benchmarks/`. Die Messmethode steht unten.
- [ ] **Kein dritter Netzwerkweg** — nur Loopback zu Ollama und der einmalige Ollama-Download.
- [ ] **Keine neue Abhängigkeit** — oder es gibt ein Issue, in dem sie besprochen wurde.

## Messung

<!-- Nur ausfüllen, wenn Zahlen betroffen sind. Womit gemessen und was kam heraus? Beispiel:
Richtig/Benchmarks/frage_benchmark.sh, 162 Beispiele, freie GPU
Trefferquote 1,000 → 1,000, Präzision 1,000 → 1,000, p90 492 → 447 ms
-->

## Änderungsprotokoll

<!-- Der Eintrag für den Abschnitt „Noch nicht veröffentlicht“ in CHANGELOG.md. -->
