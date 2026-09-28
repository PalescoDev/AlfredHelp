#!/usr/bin/env python3
"""Schnelle Sondierung der zweiten Stufe der Frageerkennung.

Warum neben dem Swift-Benchmark: `prompt_stufe2.sh` misst den echten,
ausgelieferten Codepfad und ist die verbindliche Zahl – kostet aber jedes Mal
einen Testbuild und blockiert die SwiftPM-Sperre für andere. Beim Formulieren
eines Prompts braucht man dagegen viele kurze Durchläufe hintereinander.

Dieses Skript liest `classifySystem` DIREKT aus Prompts.swift (eine Quelle,
keine Doppelpflege), spricht dieselbe Ollama-Schnittstelle mit demselben
Schema und denselben Optionen an und bildet die Frühentscheidung am
Tokenstrom nach – dieselbe Regel wie QuestionClassifier.earlyDecision.

    ./Benchmarks/prompt_probe.py                 # alle Modellfälle, 1 Lauf
    ./Benchmarks/prompt_probe.py --runs 3
    ./Benchmarks/prompt_probe.py --kategorie ellipse --zeige-umschreibung
    ./Benchmarks/prompt_probe.py --prompt-datei entwurf.txt   # Entwurf testen,
                                                              # ohne Swift anzufassen

Die Zahl, die zählt, bleibt die aus prompt_stufe2.sh; dieses Skript dient dem
Vorsortieren von Varianten.
"""

import argparse
import json
import re
import statistics
import sys
import time
import urllib.request
from pathlib import Path

WURZEL = Path(__file__).resolve().parent.parent
PROMPTS_SWIFT = WURZEL / "Sources/AlfredHelpCore/Intelligence/Prompts.swift"
DATENSATZ = WURZEL / "Benchmarks/frageerkennung.json"
OLLAMA = "http://127.0.0.1:11434"

# Muss zu Prompts.classifySchema passen. Die Reihenfolge ist bedeutungstragend:
# "status" zuerst, sonst greift die Frühentscheidung nicht.
SCHEMA = {
    "type": "object",
    "properties": {
        "status": {"type": "string", "enum": ["frage", "keine_frage", "unvollstaendig"]},
        "eigenstaendig": {"type": "string"},
    },
    "required": ["status", "eigenstaendig"],
}

# Schwellen der ersten Stufe; nur was dazwischen liegt, erreicht das Modell.
GATE, SHORTCUT = 0.35, 0.95


def system_prompt_aus_swift() -> str:
    """Zieht den Systemprompt aus der Swift-Quelle heraus."""
    quelle = PROMPTS_SWIFT.read_text(encoding="utf-8")
    treffer = re.search(r'public static let classifySystem = """\n(.*?)\n    """', quelle, re.S)
    if not treffer:
        sys.exit("classifySystem nicht in Prompts.swift gefunden")
    # Swift rückt mehrzeilige Literale um die schließenden Anführungszeichen ein.
    return "\n".join(
        zeile[4:] if zeile.startswith("    ") else zeile
        for zeile in treffer.group(1).split("\n")
    )


def token_zahl(text: str, modell: str) -> int:
    """Prompt-Token laut Ollama. Wichtig, weil die Latenz bei gemma3 oberhalb
    von 1024 Prompt-Token um den Faktor acht springt (Sliding-Window-Grenze)."""
    körper = json.dumps(
        {"model": modell, "prompt": text, "stream": False, "options": {"num_predict": 1}}
    ).encode()
    antwort = urllib.request.urlopen(
        urllib.request.Request(f"{OLLAMA}/api/generate", körper, {"Content-Type": "application/json"})
    )
    return json.load(antwort)["prompt_eval_count"]


def fruehentscheidung(text: str):
    """Bildet QuestionClassifier.earlyDecision nach: sobald der erste Buchstabe
    des status-Werts sichtbar ist, steht das Urteil."""
    stelle = text.find('"status"')
    if stelle < 0:
        return None
    rest = text[stelle + len('"status"'):]
    doppelpunkt = rest.find(":")
    if doppelpunkt < 0:
        return None
    anfuehrung = rest.find('"', doppelpunkt)
    if anfuehrung < 0 or len(rest) <= anfuehrung + 1:
        return None
    zeichen = rest[anfuehrung + 1]
    if zeichen == "f":
        return True
    if zeichen in ("k", "u"):
        return False
    return None


def klassifiziere(system: str, modell: str, kontext: str, aeusserung: str):
    """Ein Modellaufruf. Liefert (Frage?, Latenz bis zur Frühentscheidung in ms,
    umgeschriebene Fassung)."""
    körper = json.dumps({
        "model": modell,
        "stream": True,
        "format": SCHEMA,
        "options": {"temperature": 0, "num_predict": 220, "num_ctx": 4096},
        "keep_alive": "30m",
        "messages": [
            {"role": "system", "content": system},
            {"role": "user",
             "content": f"Kontext:\nGegenüber: {kontext}\n\nLetzte Äußerung:\n{aeusserung}"},
        ],
    }).encode()
    start = time.time()
    gesammelt, urteil, latenz = "", None, None
    strom = urllib.request.urlopen(
        urllib.request.Request(f"{OLLAMA}/api/chat", körper, {"Content-Type": "application/json"})
    )
    for zeile in strom:
        stueck = json.loads(zeile)
        gesammelt += stueck.get("message", {}).get("content", "")
        if urteil is None:
            fruh = fruehentscheidung(gesammelt)
            if fruh is not None:
                urteil, latenz = fruh, (time.time() - start) * 1000
    umschreibung = ""
    try:
        umschreibung = json.loads(gesammelt).get("eigenstaendig", "")
    except json.JSONDecodeError:
        pass
    if urteil is None:
        urteil, latenz = False, (time.time() - start) * 1000
    return urteil, latenz, umschreibung


def main() -> None:
    zerleger = argparse.ArgumentParser(description=__doc__,
                                       formatter_class=argparse.RawDescriptionHelpFormatter)
    zerleger.add_argument("--modell", default="gemma3:4b")
    zerleger.add_argument("--runs", type=int, default=1)
    zerleger.add_argument("--kategorie", action="append",
                          help="nur diese Kategorie(n) messen, z. B. ellipse")
    zerleger.add_argument("--prompt-datei",
                          help="Systemprompt aus dieser Datei statt aus Prompts.swift")
    zerleger.add_argument("--zeige-umschreibung", action="store_true")
    zerleger.add_argument("--modellfaelle",
                          default=str(WURZEL / "Benchmarks/modellfaelle.json"),
                          help="Liste der Äußerungen, die Stufe 1 ans Modell weiterreicht")
    argumente = zerleger.parse_args()

    system = (Path(argumente.prompt_datei).read_text(encoding="utf-8").rstrip()
              if argumente.prompt_datei else system_prompt_aus_swift())

    beispiele = json.loads(DATENSATZ.read_text(encoding="utf-8"))["beispiele"]
    auswahl = Path(argumente.modellfaelle)
    if auswahl.exists():
        weitergereicht = set(json.loads(auswahl.read_text(encoding="utf-8")))
        beispiele = [b for b in beispiele if b["text"] in weitergereicht]
    else:
        print(f"Hinweis: {auswahl.name} fehlt – es werden ALLE Beispiele gemessen, "
              f"auch die, die Stufe 1 allein entscheidet.", file=sys.stderr)
    if argumente.kategorie:
        beispiele = [b for b in beispiele if b["kategorie"] in argumente.kategorie]

    tokens = token_zahl(system, argumente.modell)
    warnung = "  ⚠ über 1024 – Latenzklippe" if tokens > 1024 else ""
    print(f"Systemprompt: {len(system)} Zeichen, {tokens} Token{warnung}")
    print(f"Beispiele: {len(beispiele)}, Läufe: {argumente.runs}, Modell: {argumente.modell}\n")

    # Warmlauf, damit der erste Fall die Latenz nicht verzerrt.
    klassifiziere(system, argumente.modell, "Warmlauf.", "Alles klar?")

    urteile = {b["text"]: [] for b in beispiele}
    umschreibungen = {}
    latenzen = []
    for _ in range(argumente.runs):
        for beispiel in beispiele:
            frage, latenz, umschreibung = klassifiziere(
                system, argumente.modell, beispiel["kontext"], beispiel["text"])
            urteile[beispiel["text"]].append(frage)
            latenzen.append(latenz)
            if umschreibung:
                umschreibungen[beispiel["text"]] = umschreibung

    tp = fp = fn = tn = 0
    dauerhaft_falsch, wackelig = [], []
    for beispiel in beispiele:
        gold = beispiel["label"] == "frage"
        stimmen = urteile[beispiel["text"]]
        als_frage = sum(stimmen)
        tp += sum(1 for s in stimmen if gold and s)
        fp += sum(1 for s in stimmen if not gold and s)
        fn += sum(1 for s in stimmen if gold and not s)
        tn += sum(1 for s in stimmen if not gold and not s)
        if 0 < als_frage < len(stimmen):
            wackelig.append((beispiel, als_frage))
        elif (als_frage == 0) == gold:
            dauerhaft_falsch.append(beispiel)

    präzision = tp / max(1, tp + fp)
    ausbeute = tp / max(1, tp + fn)
    latenzen.sort()
    print(f"Precision {präzision:.3f}   Recall {ausbeute:.3f}   "
          f"FP {fp / argumente.runs:.1f}   FN {fn / argumente.runs:.1f}")
    print(f"Latenz Median {statistics.median(latenzen):.0f} ms   "
          f"p90 {latenzen[int(len(latenzen) * 0.9)]:.0f} ms")

    if dauerhaft_falsch:
        print("\nDurchgehend falsch:")
        for b in dauerhaft_falsch:
            print(f"  · [{b['kategorie']}] {b['text']}  → Gold: {b['label']}")
    if wackelig:
        print(f"\nWackelkandidaten (x von {argumente.runs} Läufen „frage“):")
        for b, n in wackelig:
            print(f"  · [{b['kategorie']}] {b['text']}  → {n}/{argumente.runs}, Gold: {b['label']}")

    if argumente.zeige_umschreibung:
        print("\nUmschreibungen:")
        for b in beispiele:
            if b["label"] == "frage":
                print(f"  · „{b['text']}“ [{b['kontext']}]\n      → {umschreibungen.get(b['text'], '—')}")


if __name__ == "__main__":
    main()
