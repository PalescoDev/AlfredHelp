#!/usr/bin/env python3
"""Modellbenchmark für AlfredHelp.

Misst für jedes lokal installierte Ollama-Modell (<= 20B Parameter) die drei
Aufgaben, die die App tatsächlich ausführt:

  1. Live-Übersetzung ins Deutsche   -> chrF2 gegen Referenz + Latenz
  2. Frageerkennung (JSON-Ausgabe)   -> Genauigkeit + Latenz
  3. Kontextbezogene Antwort         -> Abdeckung der Kernpunkte + Latenz

Nur Standardbibliothek, spricht ausschließlich mit 127.0.0.1:11434.

    python3 benchmark.py                 # alle installierten Kandidaten
    python3 benchmark.py qwen3:8b ...    # gezielte Auswahl
"""

from __future__ import annotations

import json
import re
import statistics
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from testset import ANSWERS, QUESTIONS, TRANSLATION  # noqa: E402

HOST = "http://127.0.0.1:11434"
MAX_PARAM_BILLIONS = 20.0
SEED = 7

# Modelle, die intern "denken" können – das kostet Latenz und wird abgeschaltet.
THINKING_HINTS = ("qwen3", "gpt-oss", "deepseek-r1", "magistral", "granite3.2")


# --------------------------------------------------------------------------- #
# HTTP
# --------------------------------------------------------------------------- #
def _post_stream(path: str, payload: dict):
    request = urllib.request.Request(
        HOST + path,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=600) as response:
        for raw in response:
            raw = raw.strip()
            if raw:
                yield json.loads(raw)


def _get(path: str) -> dict:
    with urllib.request.urlopen(HOST + path, timeout=30) as response:
        return json.loads(response.read())


@dataclass
class Call:
    text: str = ""
    ttft_ms: float = 0.0
    total_ms: float = 0.0
    eval_tokens: int = 0
    eval_ms: float = 0.0
    prompt_tokens: int = 0
    failed: bool = False

    @property
    def tok_per_s(self) -> float:
        return self.eval_tokens / (self.eval_ms / 1000) if self.eval_ms else 0.0


def generate(
    model: str,
    system: str,
    user: str,
    *,
    num_predict: int,
    fmt=None,
    temperature: float = 0.0,
) -> Call:
    payload = {
        "model": model,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
        "stream": True,
        "keep_alive": "30m",
        "options": {
            "temperature": temperature,
            "num_predict": num_predict,
            "num_ctx": 4096,
            "seed": SEED,
        },
    }
    if fmt is not None:
        payload["format"] = fmt
    if any(hint in model for hint in THINKING_HINTS):
        payload["think"] = False

    call = Call()
    start = time.perf_counter()
    try:
        for event in _post_stream("/api/chat", payload):
            piece = event.get("message", {}).get("content", "")
            if piece and not call.ttft_ms:
                call.ttft_ms = (time.perf_counter() - start) * 1000
            call.text += piece
            if event.get("done"):
                call.eval_tokens = event.get("eval_count", 0) or 0
                call.eval_ms = (event.get("eval_duration", 0) or 0) / 1e6
                call.prompt_tokens = event.get("prompt_eval_count", 0) or 0
    except urllib.error.HTTPError as error:
        body = error.read().decode(errors="replace")
        if "think" in body and "think" in payload:
            # Modell kennt den Parameter nicht -> ohne erneut versuchen.
            payload.pop("think")
            call = Call()
            start = time.perf_counter()
            try:
                for event in _post_stream("/api/chat", payload):
                    piece = event.get("message", {}).get("content", "")
                    if piece and not call.ttft_ms:
                        call.ttft_ms = (time.perf_counter() - start) * 1000
                    call.text += piece
                    if event.get("done"):
                        call.eval_tokens = event.get("eval_count", 0) or 0
                        call.eval_ms = (event.get("eval_duration", 0) or 0) / 1e6
                        call.prompt_tokens = event.get("prompt_eval_count", 0) or 0
            except Exception:
                call.failed = True
        else:
            call.failed = True
    except Exception:
        call.failed = True

    call.total_ms = (time.perf_counter() - start) * 1000
    return call


# --------------------------------------------------------------------------- #
# Metriken
# --------------------------------------------------------------------------- #
def _char_ngrams(text: str, n: int) -> dict[str, int]:
    stripped = re.sub(r"\s+", "", text.lower())
    counts: dict[str, int] = {}
    for index in range(len(stripped) - n + 1):
        gram = stripped[index : index + n]
        counts[gram] = counts.get(gram, 0) + 1
    return counts


def chrf(hypothesis: str, reference: str, max_n: int = 6, beta: float = 2.0) -> float:
    """chrF2 – zeichenbasiertes F-Maß, Standardmetrik für maschinelle Übersetzung."""
    if not hypothesis.strip():
        return 0.0
    precisions, recalls = [], []
    for n in range(1, max_n + 1):
        hyp = _char_ngrams(hypothesis, n)
        ref = _char_ngrams(reference, n)
        if not hyp or not ref:
            continue
        overlap = sum(min(count, ref.get(gram, 0)) for gram, count in hyp.items())
        precisions.append(overlap / sum(hyp.values()))
        recalls.append(overlap / sum(ref.values()))
    if not precisions:
        return 0.0
    avg_p = statistics.mean(precisions)
    avg_r = statistics.mean(recalls)
    if avg_p + avg_r == 0:
        return 0.0
    beta_sq = beta * beta
    return 100 * (1 + beta_sq) * avg_p * avg_r / (beta_sq * avg_p + avg_r)


GERMAN_MARKERS = re.compile(
    r"\b(der|die|das|und|nicht|wir|ist|sind|für|mit|auf|eine|einen|dass|noch|"
    r"aber|wenn|werden|kann|können|muss|müssen|wird|wurde|haben|hat|sich|"
    r"beim|zum|zur|vom|über|unter|ohne|durch)\b",
    re.IGNORECASE,
)
ENGLISH_MARKERS = re.compile(
    r"\b(the|and|is|are|we|you|they|with|that|this|for|from|would|should|"
    r"could|because|there|their|what|when|which|about)\b",
    re.IGNORECASE,
)


def is_german(text: str) -> bool:
    """Grobe, aber für ganze Sätze zuverlässige Sprachprüfung."""
    german = len(GERMAN_MARKERS.findall(text))
    english = len(ENGLISH_MARKERS.findall(text))
    if german == 0 and english == 0:
        return bool(re.search(r"[äöüßÄÖÜ]", text))
    return german > english


def parse_json_loose(text: str):
    text = re.sub(r"<think>.*?</think>", "", text, flags=re.S).strip()
    try:
        return json.loads(text)
    except Exception:
        pass
    match = re.search(r"\{.*\}", text, re.S)
    if match:
        try:
            return json.loads(match.group(0))
        except Exception:
            return None
    return None


# --------------------------------------------------------------------------- #
# Prompts – identisch zu denen, die die App verwendet
# --------------------------------------------------------------------------- #
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
    "Du läufst während eines Gesprächs mit. Der Nutzer liest deine Antwort vom "
    "Bildschirm ab, während die andere Seite wartet.\n\n"
    "Gib immer genau zwei Teile aus, getrennt durch eine eigene Zeile mit ---MEHR---\n\n"
    "TEIL 1 – zum Vorlesen. Der Nutzer spricht diesen Text wortwörtlich aus.\n"
    "- Höchstens drei kurze Sätze, zusammen unter 45 Wörtern.\n"
    "- Gesprochene Sprache in der ersten Person.\n"
    "- Keine Aufzählungen, keine Überschriften, keine Klammern, keine Sternchen.\n"
    "- Keine Einleitung – direkt der Satz, den er sagt.\n"
    "- Nur die Kernaussage; Details gehören in Teil 2.\n\n"
    "---MEHR---\n\n"
    "TEIL 2 – Hintergrund, den nur der Nutzer liest. Ausführlich erlaubt: "
    "Begründung, Zahlen, Bezeichner, Randfälle, Alternativen. Stichpunkte erlaubt.\n\n"
    "Beide Teile auf Deutsch. Fachlich korrekt, nichts erfinden."
)


# --------------------------------------------------------------------------- #
# Teilbenchmarks
# --------------------------------------------------------------------------- #
@dataclass
class ModelResult:
    model: str
    params: str = ""
    translation_chrf: float = 0.0
    translation_german: float = 0.0
    translation_ttft: float = 0.0
    translation_total: float = 0.0
    question_accuracy: float = 0.0
    question_json_ok: float = 0.0
    question_ttft: float = 0.0
    question_total: float = 0.0
    answer_coverage: float = 0.0
    answer_german: float = 0.0
    answer_ttft: float = 0.0
    answer_tok_s: float = 0.0
    answer_total: float = 0.0
    failures: int = 0
    samples: dict = field(default_factory=dict)


def bench_translation(model: str, result: ModelResult) -> None:
    scores, german, ttfts, totals = [], [], [], []
    for case in TRANSLATION:
        user = (
            f"Bisheriger Gesprächskontext: {case['ctx']}\n\n"
            f"Äußerung ({case['lang']}):\n{case['src']}"
        )
        call = generate(model, TRANSLATE_SYSTEM, user, num_predict=200)
        if call.failed:
            result.failures += 1
            continue
        text = re.sub(r"<think>.*?</think>", "", call.text, flags=re.S).strip()
        text = text.strip('"').strip()
        scores.append(chrf(text, case["ref"]))
        german.append(1.0 if is_german(text) else 0.0)
        ttfts.append(call.ttft_ms)
        totals.append(call.total_ms)
        result.samples.setdefault("translation", []).append(
            {"src": case["src"], "hyp": text, "chrf": round(scores[-1], 1)}
        )
    result.translation_chrf = statistics.mean(scores) if scores else 0.0
    result.translation_german = 100 * statistics.mean(german) if german else 0.0
    result.translation_ttft = statistics.median(ttfts) if ttfts else 0.0
    result.translation_total = statistics.median(totals) if totals else 0.0


def bench_questions(model: str, result: ModelResult) -> None:
    correct, json_ok, ttfts, totals = [], [], [], []
    for case in QUESTIONS:
        user = f"Kontext:\n{case['ctx']}\n\nLetzte Äußerung:\n{case['utt']}"
        call = generate(
            model, CLASSIFY_SYSTEM, user, num_predict=120, fmt=CLASSIFY_SCHEMA
        )
        if call.failed:
            result.failures += 1
            continue
        parsed = parse_json_loose(call.text)
        json_ok.append(1.0 if isinstance(parsed, dict) and "frage" in parsed else 0.0)
        predicted = bool(parsed.get("frage")) if isinstance(parsed, dict) else False
        correct.append(1.0 if predicted == case["label"] else 0.0)
        ttfts.append(call.ttft_ms)
        totals.append(call.total_ms)
        result.samples.setdefault("questions", []).append(
            {"utt": case["utt"], "pred": predicted, "gold": case["label"]}
        )
    result.question_accuracy = 100 * statistics.mean(correct) if correct else 0.0
    result.question_json_ok = 100 * statistics.mean(json_ok) if json_ok else 0.0
    result.question_ttft = statistics.median(ttfts) if ttfts else 0.0
    result.question_total = statistics.median(totals) if totals else 0.0


def bench_answers(model: str, result: ModelResult) -> None:
    coverage, german, ttfts, totals, speeds = [], [], [], [], []
    for case in ANSWERS:
        user = f"Gesprächskontext:\n{case['ctx']}\n\nFrage aus dem Gespräch:\n{case['q']}"
        call = generate(model, ANSWER_SYSTEM, user, num_predict=420)
        if call.failed:
            result.failures += 1
            continue
        text = re.sub(r"<think>.*?</think>", "", call.text, flags=re.S).strip()
        lowered = text.lower()
        hits = sum(
            1 for concept in case["must"] if any(word in lowered for word in concept)
        )
        coverage.append(hits / len(case["must"]))
        german.append(1.0 if is_german(text) else 0.0)
        ttfts.append(call.ttft_ms)
        totals.append(call.total_ms)
        if call.tok_per_s:
            speeds.append(call.tok_per_s)
        result.samples.setdefault("answers", []).append(
            {"q": case["q"], "answer": text, "coverage": round(coverage[-1], 2)}
        )
    result.answer_coverage = 100 * statistics.mean(coverage) if coverage else 0.0
    result.answer_german = 100 * statistics.mean(german) if german else 0.0
    result.answer_ttft = statistics.median(ttfts) if ttfts else 0.0
    result.answer_total = statistics.median(totals) if totals else 0.0
    result.answer_tok_s = statistics.mean(speeds) if speeds else 0.0


# --------------------------------------------------------------------------- #
# Bewertung
# --------------------------------------------------------------------------- #
def latency_score(milliseconds: float, good: float, bad: float) -> float:
    """100 Punkte bei <= good ms, 0 Punkte bei >= bad ms, linear dazwischen."""
    if milliseconds <= 0:
        return 0.0
    if milliseconds <= good:
        return 100.0
    if milliseconds >= bad:
        return 0.0
    return 100 * (bad - milliseconds) / (bad - good)


def score_fast_role(result: ModelResult) -> float:
    """Eignung als schnelles Modell für Übersetzung + Frageerkennung."""
    quality = (
        0.45 * min(100.0, result.translation_chrf * 1.55)
        + 0.15 * result.translation_german
        + 0.30 * result.question_accuracy
        + 0.10 * result.question_json_ok
    )
    speed = (
        0.5 * latency_score(result.translation_total, 700, 4000)
        + 0.3 * latency_score(result.question_total, 500, 3000)
        + 0.2 * latency_score(result.translation_ttft, 250, 1800)
    )
    return 0.55 * quality + 0.45 * speed


def score_quality_role(result: ModelResult) -> float:
    """Eignung als Antwortmodell."""
    quality = 0.75 * result.answer_coverage + 0.25 * result.answer_german
    speed = (
        0.6 * latency_score(result.answer_ttft, 400, 4000)
        + 0.4 * latency_score(result.answer_total, 3000, 15000)
    )
    return 0.7 * quality + 0.3 * speed


# --------------------------------------------------------------------------- #
def candidates(explicit: list[str]) -> list[tuple[str, str]]:
    models = _get("/api/tags")["models"]
    result = []
    for entry in models:
        name = entry["name"]
        params = entry.get("details", {}).get("parameter_size", "")
        if explicit and name not in explicit:
            continue
        if not explicit:
            value = re.match(r"([\d.]+)\s*B", params.upper())
            if value and float(value.group(1)) > MAX_PARAM_BILLIONS:
                continue
            if "coder" in name or "embed" in name:
                continue
        result.append((name, params))
    return sorted(result)


def main() -> None:
    explicit = [argument for argument in sys.argv[1:] if not argument.startswith("-")]
    models = candidates(explicit)
    if not models:
        print("Keine passenden Modelle gefunden.")
        return

    print(f"Benchmark über {len(models)} Modelle (<= {MAX_PARAM_BILLIONS:.0f}B)\n")
    results: list[ModelResult] = []

    for name, params in models:
        print(f"── {name} ({params or '?'})", flush=True)
        result = ModelResult(model=name, params=params)
        started = time.perf_counter()

        # Aufwärmen: Ladezeit soll nicht in die Messung einfließen.
        generate(name, "Antworte mit OK.", "Bereit?", num_predict=4)

        print("   Übersetzung …", end="", flush=True)
        bench_translation(name, result)
        print(f" chrF2 {result.translation_chrf:.1f} | {result.translation_total:.0f} ms")

        print("   Frageerkennung …", end="", flush=True)
        bench_questions(name, result)
        print(f" {result.question_accuracy:.0f} % | {result.question_total:.0f} ms")

        print("   Antworten …", end="", flush=True)
        bench_answers(name, result)
        print(
            f" Abdeckung {result.answer_coverage:.0f} % | "
            f"TTFT {result.answer_ttft:.0f} ms | {result.answer_tok_s:.0f} tok/s"
        )
        print(f"   Gesamt {time.perf_counter() - started:.0f} s, "
              f"Fehler {result.failures}\n", flush=True)
        results.append(result)

    print("\n" + "=" * 108)
    print("SCHNELLES MODELL (Übersetzung + Frageerkennung)")
    print("=" * 108)
    header = (
        f"{'Modell':<22}{'Score':>7}{'chrF2':>8}{'DE %':>7}"
        f"{'Frage %':>9}{'JSON %':>8}{'Übers. ms':>11}{'Frage ms':>10}{'TTFT ms':>9}"
    )
    print(header)
    for result in sorted(results, key=score_fast_role, reverse=True):
        print(
            f"{result.model:<22}{score_fast_role(result):>7.1f}"
            f"{result.translation_chrf:>8.1f}{result.translation_german:>7.0f}"
            f"{result.question_accuracy:>9.0f}{result.question_json_ok:>8.0f}"
            f"{result.translation_total:>11.0f}{result.question_total:>10.0f}"
            f"{result.translation_ttft:>9.0f}"
        )

    print("\n" + "=" * 108)
    print("ANTWORTMODELL (Qualität der Gesprächsantworten)")
    print("=" * 108)
    print(
        f"{'Modell':<22}{'Score':>7}{'Abdeckung %':>13}{'DE %':>7}"
        f"{'TTFT ms':>10}{'Gesamt ms':>11}{'tok/s':>8}"
    )
    for result in sorted(results, key=score_quality_role, reverse=True):
        print(
            f"{result.model:<22}{score_quality_role(result):>7.1f}"
            f"{result.answer_coverage:>13.0f}{result.answer_german:>7.0f}"
            f"{result.answer_ttft:>10.0f}{result.answer_total:>11.0f}"
            f"{result.answer_tok_s:>8.0f}"
        )

    output = Path(__file__).parent / "results.json"
    output.write_text(
        json.dumps(
            [
                {
                    **{
                        key: value
                        for key, value in result.__dict__.items()
                        if key != "samples"
                    },
                    "score_fast": round(score_fast_role(result), 2),
                    "score_quality": round(score_quality_role(result), 2),
                    "samples": result.samples,
                }
                for result in results
            ],
            ensure_ascii=False,
            indent=2,
        ),
        encoding="utf-8",
    )
    print(f"\nRohdaten: {output}")


if __name__ == "__main__":
    main()
