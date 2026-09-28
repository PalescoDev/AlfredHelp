#!/usr/bin/env python3
"""Latenzmessung für die tatsächlichen Aufrufformen der App.

Der Hauptbenchmark bewertet Qualität; dieses Skript misst nur Zeiten – dafür
aber genau so, wie AlfredHelp die Modelle aufruft, inklusive des vorzeitigen
Ausstiegs bei der Frageerkennung.

    python3 latency.py gemma3:4b qwen3:14b
"""

from __future__ import annotations

import json
import re
import statistics
import sys
import time
import urllib.request

HOST = "http://127.0.0.1:11434"
REPEATS = 5
THINKING_HINTS = ("qwen3", "gpt-oss", "deepseek-r1")

TRANSLATE_SYSTEM = (
    "Du bist ein AlfredHelpdolmetscher. Übersetze die Äußerung des Sprechers ins Deutsche.\n"
    "Regeln:\n"
    "- Gib ausschließlich die deutsche Übersetzung aus, ohne Anführungszeichen, "
    "ohne Einleitung, ohne Erklärung.\n"
    "- Behalte Register und Ton bei; gesprochene Sprache bleibt gesprochene Sprache.\n"
    "- Eigennamen, Produktnamen und etablierte Fachbegriffe bleiben unverändert.\n"
    "- Übersetze vollständig, kürze nichts weg."
)
CLASSIFY_SYSTEM = (
    "Du analysierst eine laufende Gesprächstranskription.\n"
    "Entscheide, ob die letzte Äußerung eine Frage oder eine Bitte um Information ist, "
    "die eine inhaltliche Antwort verlangt.\n"
    "Reine Aussagen, Zustimmung, Statusmeldungen und Small Talk sind keine Fragen.\n"
    'Antworte ausschließlich als JSON: {"frage": true|false, "eigenstaendig": "..."}\n'
    '"eigenstaendig" ist die Frage aus dem Kontext heraus vollständig ausformuliert '
    "(auf Deutsch), oder ein leerer String, wenn es keine Frage ist."
)
CLASSIFY_SCHEMA = {
    "type": "object",
    "properties": {"frage": {"type": "boolean"}, "eigenstaendig": {"type": "string"}},
    "required": ["frage", "eigenstaendig"],
}
ANSWER_SYSTEM = (
    "Du bist ein Assistent, der während eines laufenden Gesprächs mitläuft. "
    "Der Nutzer muss deine Antwort sofort verwenden können.\n"
    "Regeln:\n- Antworte auf Deutsch.\n"
    "- Beginne direkt mit dem Kern der Antwort, keine Einleitung.\n"
    "- Maximal 5 kurze Punkte oder 4 Sätze.\n"
    "- Konkret und fachlich korrekt.\n- Keine Rückfragen."
)

EARLY_BOOLEAN = re.compile(r'"frage"\s*:\s*(true|false)')


def stream(model, system, user, num_predict, fmt=None, stop_on_early=False):
    payload = {
        "model": model,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
        "stream": True,
        "keep_alive": "30m",
        "options": {"temperature": 0.0, "num_predict": num_predict, "num_ctx": 4096},
    }
    if fmt is not None:
        payload["format"] = fmt
    if any(hint in model for hint in THINKING_HINTS):
        payload["think"] = False

    request = urllib.request.Request(
        HOST + "/api/chat",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    start = time.perf_counter()
    ttft = None
    early = None
    text = ""
    tokens = 0
    eval_ms = 0.0
    with urllib.request.urlopen(request, timeout=300) as response:
        for raw in response:
            raw = raw.strip()
            if not raw:
                continue
            event = json.loads(raw)
            piece = event.get("message", {}).get("content", "")
            if piece:
                if ttft is None:
                    ttft = (time.perf_counter() - start) * 1000
                text += piece
                if stop_on_early and early is None and EARLY_BOOLEAN.search(text):
                    early = (time.perf_counter() - start) * 1000
                    if stop_on_early:
                        break
            if event.get("done"):
                tokens = event.get("eval_count", 0) or 0
                eval_ms = (event.get("eval_duration", 0) or 0) / 1e6
    total = (time.perf_counter() - start) * 1000
    return {
        "ttft": ttft or total,
        "total": total,
        "early": early,
        "tokens": tokens,
        "tok_s": tokens / (eval_ms / 1000) if eval_ms else 0.0,
        "text": text,
    }


def unload(model: str) -> None:
    """Gibt den Speicher des Modells sofort frei – sonst verfälscht der
    Speicherdruck aller gleichzeitig geladenen Modelle die nächste Messung."""
    payload = {"model": model, "messages": [], "stream": False, "keep_alive": 0}
    request = urllib.request.Request(
        HOST + "/api/chat",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        urllib.request.urlopen(request, timeout=60).read()
    except Exception:
        pass
    time.sleep(2)


def loaded_models() -> list[str]:
    try:
        with urllib.request.urlopen(HOST + "/api/ps", timeout=10) as response:
            return [m["name"] for m in json.loads(response.read()).get("models", [])]
    except Exception:
        return []


def median(values):
    return statistics.median(values) if values else 0.0


def main():
    models = sys.argv[1:]
    if not models:
        print("Aufruf: latency.py <modell> [<modell> …]")
        return

    print(f"{'Modell':<20}{'Übersetzung':>14}{'Frage (früh)':>14}"
          f"{'Antwort TTFT':>14}{'Antwort tok/s':>15}")
    print("─" * 77)

    for name in loaded_models():
        unload(name)

    for model in models:
        stream(model, "Antworte mit OK.", "Bereit?", 4)  # aufwärmen

        translation, early, answer_ttft, answer_speed = [], [], [], []
        for _ in range(REPEATS):
            result = stream(
                model, TRANSLATE_SYSTEM,
                "Bisheriger Gesprächskontext: Wir sprechen über den Rollout.\n\n"
                "Äußerung (en):\nSo the rollout is scheduled for the third week of March, "
                "but we still need sign-off from legal.",
                200,
            )
            translation.append(result["total"])

            result = stream(
                model, CLASSIFY_SYSTEM,
                "Kontext:\nA: We deployed the new indexer last night.\n\n"
                "Letzte Äußerung:\nHow long does a full reindex take on production?",
                200, fmt=CLASSIFY_SCHEMA, stop_on_early=True,
            )
            early.append(result["early"] or result["total"])

            result = stream(
                model, ANSWER_SYSTEM,
                "Gesprächskontext:\nEs geht um eine öffentliche REST-API.\n\n"
                "Frage aus dem Gespräch:\nWelchen HTTP-Statuscode geben wir bei "
                "Überschreitung des Rate-Limits zurück?",
                220,
            )
            answer_ttft.append(result["ttft"])
            if result["tok_s"]:
                answer_speed.append(result["tok_s"])

        print(f"{model:<20}{median(translation):>11.0f} ms{median(early):>11.0f} ms"
              f"{median(answer_ttft):>11.0f} ms{median(answer_speed):>15.0f}", flush=True)
        unload(model)


if __name__ == "__main__":
    main()
