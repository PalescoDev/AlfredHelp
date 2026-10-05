#!/usr/bin/env python3
"""Prüft den zweiteiligen Antwort-Prompt am echten Modell.

Gemessen wird, ob (a) die Abdeckung der geforderten Kernpunkte gleich bleibt,
(b) der Vorlese-Teil wirklich kurz und vorlesbar ist, (c) die Wartezeit bis zum
ersten Wort unverändert ist.
"""
import json, re, statistics, sys, time, urllib.request
sys.path.insert(0, ".")
from testset import ANSWERS
from benchmark import is_german

HOST, MODEL = "http://127.0.0.1:11434", "gemma3:12b"
MARKER = "---MEHR---"

ALT = ("Du bist ein Assistent, der während eines laufenden Gesprächs mitläuft. "
       "Der Nutzer muss deine Antwort sofort verwenden können.\nRegeln:\n"
       "- Antworte auf Deutsch.\n- Beginne direkt mit dem Kern der Antwort.\n"
       "- Maximal 5 kurze Punkte oder 4 Sätze.\n- Konkret und fachlich korrekt.\n"
       "- Keine Rückfragen.")

NEU = f"""Du läufst während eines Gesprächs mit. Der Nutzer liest deine Antwort vom Bildschirm ab, während die andere Seite wartet.

Gib immer genau zwei Teile aus, getrennt durch eine eigene Zeile mit {MARKER}

TEIL 1 – zum Vorlesen. Der Nutzer spricht diesen Text wortwörtlich aus.
- Höchstens drei kurze Sätze, zusammen unter 45 Wörtern.
- Gesprochene Sprache in der ersten Person, so wie man es im Gespräch sagen würde.
- Keine Aufzählungen, keine Überschriften, keine Klammern, keine Sternchen, keine Emojis.
- Keine Einleitung wie „Die Antwort lautet“ – direkt der Satz, den er sagt.
- Nur die Kernaussage. Nebenbedingungen und Details gehören in Teil 2.

{MARKER}

TEIL 2 – Hintergrund, den nur der Nutzer liest. Hier darf es ausführlich sein: Begründung, Zahlen, Bezeichner, Randfälle, Alternativen, mögliche Rückfragen der Gegenseite. Stichpunkte sind erlaubt.

Beide Teile auf Deutsch.
Fachlich korrekt, nichts erfinden. Fehlt dir etwas, benenne es in Teil 2, nicht in Teil 1."""


def ask(system, question, context, num_predict):
    payload = {"model": MODEL, "messages": [
        {"role": "system", "content": system},
        {"role": "user", "content": f"Gesprächskontext:\n{context}\n\nFrage aus dem Gespräch:\n{question}"}],
        "stream": True, "keep_alive": "10m",
        "options": {"temperature": 0.0, "num_predict": num_predict, "num_ctx": 8192, "seed": 7}}
    request = urllib.request.Request(HOST + "/api/chat", data=json.dumps(payload).encode(),
                                     headers={"Content-Type": "application/json"}, method="POST")
    start, ttft, text = time.perf_counter(), None, ""
    with urllib.request.urlopen(request, timeout=600) as response:
        for raw in response:
            raw = raw.strip()
            if not raw:
                continue
            event = json.loads(raw)
            piece = event.get("message", {}).get("content", "")
            if piece and ttft is None:
                ttft = (time.perf_counter() - start) * 1000
            text += piece
    return text, ttft or 0


def split(text):
    for variant in (f"**{MARKER}**", MARKER, "[[MEHR]]", "TEIL 2"):
        if variant in text:
            a, b = text.split(variant, 1)
            return a.strip().removeprefix("TEIL 1").strip(" :-\n"), b.strip()
    return text.strip(), ""


for label, system, budget in (("alt (einteilig)", ALT, 320), ("neu (zweiteilig)", NEU, 420)):
    cov, ger, ttfts, words, clean, marked = [], [], [], [], [], []
    for case in ANSWERS:
        text, ttft = ask(system, case["q"], case["ctx"], budget)
        spoken, details = split(text)
        whole = (spoken + " " + details).lower()
        cov.append(sum(1 for c in case["must"] if any(w in c and w in whole for w in c)) / len(case["must"]))
        ger.append(1.0 if is_german(spoken) else 0.0)
        ttfts.append(ttft)
        words.append(len(spoken.split()))
        # vorlesbar? keine Aufzählungen, Sternchen, Überschriften
        clean.append(0.0 if re.search(r"^\s*[-*•#]|\*\*", spoken, re.M) else 1.0)
        marked.append(1.0 if details else 0.0)
    print(f"{label:<18} Abdeckung {100*statistics.mean(cov):5.1f} %  "
          f"Deutsch {100*statistics.mean(ger):3.0f} %  "
          f"TTFT {statistics.median(ttfts):5.0f} ms  "
          f"Vorlese-Teil {statistics.mean(words):4.1f} Wörter  "
          f"vorlesbar {100*statistics.mean(clean):3.0f} %  "
          f"Langteil {100*statistics.mean(marked):3.0f} %")
