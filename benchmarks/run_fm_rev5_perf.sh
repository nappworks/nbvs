#!/usr/bin/env bash
set -euo pipefail

binary="${1:-./benchmarks/fm_dictionary_rev5}"
count="${2:-1000000}"
average_length="${3:-16}"
corpus="${4:-0}"
queries="${5:-100000}"
pattern_length="${6:-8}"

events="cycles,instructions,branches,branch-misses,cache-references,cache-misses,L1-dcache-loads,L1-dcache-load-misses,LLC-loads,LLC-load-misses"

for backend in 1 2; do
  for query_kind in 0 1; do
    perf stat -x, -e "${events}" -- \
      "${binary}" "${count}" "${average_length}" "${corpus}" \
      "${backend}" "${queries}" "${pattern_length}" "${query_kind}"
  done
done
