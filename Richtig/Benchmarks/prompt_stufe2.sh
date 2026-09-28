#!/bin/bash
# Misst NUR die zweite Stufe der Frageerkennung (das Sprachmodell) gegen
# Benchmarks/frageerkennung.json und schreibt Benchmarks/frage_promptstufe_report.txt.
#
# Warum ein eigenes Werkzeug neben frage_benchmark.sh: dort verdünnen die 49
# Sofort-Entscheidungen der Heuristik jede Prompt-Änderung, und ein einzelner
# Lauf verrät nicht, ob eine Verschiebung echt oder Rauschen ist. Hier laufen
# ausschließlich die Modellfälle, und zwar mehrfach.
#
#   ./Benchmarks/prompt_stufe2.sh [Läufe] [Variantenname]
#
# Nach einem Call ausführen – unter GPU-Volllast sind die Latenzen wertlos.
cd "$(dirname "$0")/.."
RUNS="${1:-3}"
LABEL="${2:-aktuell}"
ALFREDHELP_LLM_BENCH=1 \
ALFREDHELP_BENCH_RUNS="$RUNS" \
ALFREDHELP_BENCH_LABEL="$LABEL" \
  swift test --filter ClassifierStageBenchmarkTests \
  && cat Benchmarks/frage_promptstufe_report.txt
