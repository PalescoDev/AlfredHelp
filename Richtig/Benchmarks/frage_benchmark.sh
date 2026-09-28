#!/bin/bash
# Voller Frageerkennungs-Benchmark (Heuristik + gemma3:4b).
# Nach einem Call ausführen – unter GPU-Volllast sind die Latenzen nicht aussagekräftig.
cd "$(dirname "$0")/.."
ALFREDHELP_LLM_BENCH=1 swift test --filter FullPathBenchmarkTests && cat Benchmarks/frage_report.txt
