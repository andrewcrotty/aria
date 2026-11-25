#!/usr/bin/env bash
# Times each barrier build of Aria (std, smc, nobar: see barrier_common.sh) on
# identical work.
#
# With --seed and --batches every build runs exactly the same transactions (the
# checksums prove it), so the difference in elapsed time is the barrier plus
# scheduling noise. Each point is run REPS times, rotating the build order every
# repetition so no build always goes first, and summarized as the median, min
# and max time per batch; the speedup is std's median over each build's median.
# Fails if any run crashes or the builds' checksums differ.
#
# Usage: scripts/compare_barrier_speed.sh [-t "1 2 4 8"] [-r REPS] [-y YCSB_BATCHES]
#                                         [-c TPCC_BATCHES] [-s SEED] [-o OUTDIR]
# Run from the repo root (inside barrier_bench's dev shell for the dependencies).
# Every run goes to OUTDIR/results.csv.
set -euo pipefail
source "$(dirname "$0")/barrier_common.sh"

THREADS="1 2 4 8"
REPS=5
YCSB_BATCHES=3000
TPCC_BATCHES=2000
SEED=42
OUT=speed-runs

while getopts "t:r:y:c:s:o:" opt; do
  case $opt in
    t) THREADS=$OPTARG ;;
    r) REPS=$OPTARG ;;
    y) YCSB_BATCHES=$OPTARG ;;
    c) TPCC_BATCHES=$OPTARG ;;
    s) SEED=$OPTARG ;;
    o) OUT=$OPTARG ;;
    *) sed -n '2,16p' "$0"; exit 2 ;;
  esac
done

mkdir -p "$OUT"
build_all "$OUT"

CSV="$OUT/results.csv"
echo "bench,threads,build,rep,elapsed_s,ms_per_batch,commit,abort,checksum" > "$CSV"
read -ra builds <<< "$BUILDS"
fail=0

for bench in ycsb tpcc; do
  batches=$YCSB_BATCHES
  [[ $bench == tpcc ]] && batches=$TPCC_BATCHES
  for n in $THREADS; do
    for ((rep = 1; rep <= REPS; rep++)); do
      for ((k = 0; k < ${#builds[@]}; k++)); do
        b=${builds[(k + rep) % ${#builds[@]}]}
        log="$OUT/${bench}_${b}_t${n}_r${rep}.log"
        if ! run_aria "$b" "$bench" "$n" "$SEED" "$batches" "$log"; then
          echo "run failed: $log"
          fail=1
          continue
        fi
        e=$(log_elapsed "$log")
        read -r commit abort sum <<< "$(log_totals "$log")"
        ms=$(awk -v e="$e" -v b="$batches" 'BEGIN { printf "%.4f", 1e3 * e / b }')
        echo "$bench,$n,$b,$rep,$e,$ms,$commit,$abort,$sum" >> "$CSV"
        printf '  %-5s t=%-3s %-6s rep %d: %8s ms/batch\n' "$bench" "$n" "$b" "$rep" "$ms"
      done
    done
  done
done

# Per bench/threads/build: median, min, max ms/batch and speedup vs std.
summary() {
  local bench=$1 n=$2 b=$3
  awk -F, -v bench="$bench" -v n="$n" -v b="$b" \
    '$1 == bench && $2 == n && $3 == b { print $6 }' "$CSV" | sort -g |
    awk '{ v[NR] = $1 } END {
      if (NR == 0) { print "? ? ?"; exit }
      m = (NR % 2) ? v[(NR + 1) / 2] : (v[NR / 2] + v[NR / 2 + 1]) / 2
      printf "%.4f %.4f %.4f\n", m, v[1], v[NR] }'
}

echo
printf '%-5s %3s  %-6s %10s %10s %10s %8s\n' bench thr build median_ms min_ms max_ms speedup
for bench in ycsb tpcc; do
  for n in $THREADS; do
    read -r std_med _ _ <<< "$(summary "$bench" "$n" std)"
    for b in $BUILDS; do
      read -r med lo hi <<< "$(summary "$bench" "$n" "$b")"
      sp=$(awk -v s="$std_med" -v m="$med" 'BEGIN { if (m > 0) printf "%.2fx", s / m; else print "?" }')
      printf '%-5s %3s  %-6s %10s %10s %10s %8s\n' "$bench" "$n" "$b" "$med" "$lo" "$hi" "$sp"
    done
    sums=$(awk -F, -v bench="$bench" -v n="$n" '$1 == bench && $2 == n { print $9 }' "$CSV" | sort -u)
    if [[ $(wc -l <<< "$sums") -ne 1 || $sums == "?" ]]; then
      echo "   CHECKSUM MISMATCH at $bench t=$n: $(tr '\n' ' ' <<< "$sums")"
      fail=1
    fi
  done
done

if (( fail )); then
  echo "FAIL (logs in $OUT/)"
  exit 1
fi
echo "OK: checksums agree everywhere (results in $CSV)"
