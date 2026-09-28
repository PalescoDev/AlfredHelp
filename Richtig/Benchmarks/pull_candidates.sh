#!/bin/bash
# Lädt alle Benchmark-Kandidaten (jeweils <= 20B Parameter) lokal herunter.
# Läuft absichtlich sequenziell – Ollama serialisiert Pulls ohnehin.
set -u

MODELS=(
  "llama3.2:3b"
  "gemma3:4b"
  "qwen3:4b"
  "qwen3:8b"
  "aya-expanse:8b"
  "mistral-nemo:12b"
  "gemma3:12b"
  "phi4:14b"
  "qwen3:14b"
)

for m in "${MODELS[@]}"; do
  if ollama list 2>/dev/null | awk '{print $1}' | grep -qx "$m"; then
    echo "== $m bereits vorhanden"
    continue
  fi
  echo "== pull $m"
  ollama pull "$m" 2>&1 | tail -1
done

echo "== fertig"
ollama list
