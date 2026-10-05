#!/usr/bin/env python3
"""A/B-Vergleich des Kontextfensters am ECHTEN Antwortmodell.

Gleiche Prompts, gleiches Modell – nur num_ctx unterscheidet sich. Prüft, ob
das dynamisch verkleinerte Fenster Abdeckung oder Tempo kostet.
"""
import json, re, statistics, sys, time, urllib.request
sys.path.insert(0, ".")
from testset import ANSWERS
from benchmark import ANSWER_SYSTEM, is_german

HOST = "http://127.0.0.1:11434"
MODEL = "gemma3:12b"

def unload(model):
    try:
        urllib.request.urlopen(urllib.request.Request(
            HOST + "/api/chat",
            data=json.dumps({"model": model, "messages": [], "keep_alive": 0}).encode(),
            headers={"Content-Type": "application/json"}, method="POST"), timeout=60).read()
    except Exception:
        pass
    time.sleep(3)

def run(num_ctx):
    covered, german, ttfts, totals, speeds = [], [], [], [], []
    for case in ANSWERS:
        payload = {
            "model": MODEL,
            "messages": [
                {"role": "system", "content": ANSWER_SYSTEM},
                {"role": "user", "content":
                 f"Gesprächskontext:\n{case['ctx']}\n\nFrage aus dem Gespräch:\n{case['q']}"},
            ],
            "stream": True, "keep_alive": "10m",
            "options": {"temperature": 0.0, "num_predict": 320, "num_ctx": num_ctx, "seed": 7},
        }
        request = urllib.request.Request(
            HOST + "/api/chat", data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"}, method="POST")
        start, ttft, text, tokens, eval_ms = time.perf_counter(), None, "", 0, 0.0
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
                if event.get("done"):
                    tokens = event.get("eval_count", 0) or 0
                    eval_ms = (event.get("eval_duration", 0) or 0) / 1e6
        lowered = text.lower()
        hits = sum(1 for concept in case["must"] if any(w in lowered for w in concept))
        covered.append(hits / len(case["must"]))
        german.append(1.0 if is_german(text) else 0.0)
        ttfts.append(ttft or 0)
        totals.append((time.perf_counter() - start) * 1000)
        if eval_ms:
            speeds.append(tokens / (eval_ms / 1000))
    return {
        "Abdeckung %": 100 * statistics.mean(covered),
        "Deutsch %": 100 * statistics.mean(german),
        "TTFT ms": statistics.median(ttfts),
        "Gesamt ms": statistics.median(totals),
        "tok/s": statistics.mean(speeds) if speeds else 0,
    }

print(f"Antwortmodell {MODEL}, {len(ANSWERS)} Fachfragen, identische Prompts\n")
results = {}
for ctx in (8192, 2048):
    unload(MODEL)
    run(ctx)          # aufwärmen, nicht werten
    results[ctx] = run(ctx)
    vram = 0
    try:
        with urllib.request.urlopen(HOST + "/api/ps", timeout=10) as r:
            for m in json.load(r).get("models", []):
                if m["name"] == MODEL:
                    vram = m.get("size_vram", 0) / 1e9
    except Exception:
        pass
    results[ctx]["VRAM GB"] = vram

header = f"{'num_ctx':<10}" + "".join(f"{k:>13}" for k in results[8192])
print(header); print("─" * len(header))
for ctx, row in results.items():
    print(f"{ctx:<10}" + "".join(f"{v:>13.1f}" for v in row.values()))
