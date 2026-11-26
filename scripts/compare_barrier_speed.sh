#!/usr/bin/env bash
# Times each barrier build of Aria (std, smc, nobar: see barrier_common.sh) on
# identical work.
#
# With --seed and --commits every build runs exactly the same transactions (the
# checksums prove it), so the difference in elapsed time is the barrier plus
# scheduling noise. Each point is run REPS times, rotating the build order every
# repetition so no build always goes first, and summarized as the median, min
# and max time per batch; the speedup is std's median over each build's median.
# Fails if any run crashes or the builds' checksums differ.
#
# -B sweeps the batch size (transactions per batch, both benchmarks; default:
# aria's 1000 for YCSB, 500 for TPC-C). Smaller batches leave less work between
# barriers, so the barrier is a larger share of each batch. Every run does the
# same total work: it stops after the batch in which -y / -c transactions have
# committed (conflict aborts are retried, so aborts add batches, not lost work),
# and ms/batch divides by the batches it took.
# -F gives the sizes as fractions of each benchmark's default instead (e.g.
# 0.01 = 10 for YCSB, 5 for TPC-C), so both benchmarks sweep the same points.
#
# Usage: scripts/compare_barrier_speed.sh [-t "1 2 4 8"] [-B "10 100 1000" | -F "0.01 0.1 1"]
#                                         [-r REPS] [-y YCSB_TXNS] [-c TPCC_TXNS] [-s SEED] [-o OUTDIR]
# Run from the repo root (inside barrier_bench's dev shell for the dependencies).
# Every run goes to OUTDIR/results.csv. Rerunning with the same OUTDIR resumes:
# runs already in results.csv are skipped (so use the same -y/-c/-s), and the
# summary covers this invocation's -t and -B / -F.
set -euo pipefail
source "$(dirname "$0")/barrier_common.sh"

THREADS="1 2 4 8"
SIZES=""
FRACTIONS=""
REPS=5
YCSB_TXNS=3000000
TPCC_TXNS=1000000
SEED=42
OUT=speed-runs

while getopts "t:B:F:r:y:c:s:o:" opt; do
  case $opt in
    t) THREADS=$OPTARG ;;
    B) SIZES=$OPTARG ;;
    F) FRACTIONS=$OPTARG ;;
    r) REPS=$OPTARG ;;
    y) YCSB_TXNS=$OPTARG ;;
    c) TPCC_TXNS=$OPTARG ;;
    s) SEED=$OPTARG ;;
    o) OUT=$OPTARG ;;
    *) sed -n '2,25p' "$0"; exit 2 ;;
  esac
done
if [[ -n $SIZES && -n $FRACTIONS ]]; then
  echo "use -B or -F, not both"
  exit 2
fi

# Batch sizes to run for one benchmark.
sizes_for() {
  if [[ -n $FRACTIONS ]]; then
    awk -v d="${DEFAULT_BATCH_SIZE[$1]}" -v f="$FRACTIONS" 'BEGIN {
      n = split(f, fs, " ")
      for (i = 1; i <= n; i++) { s = int(fs[i] * d + 0.5); printf "%d ", (s < 1 ? 1 : s) } }'
  else
    echo "${SIZES:-${DEFAULT_BATCH_SIZE[$1]}}"
  fi
}

mkdir -p "$OUT"
build_all "$OUT"

CSV="$OUT/results.csv"
HEADER="bench,batch_size,threads,build,rep,elapsed_s,ms_per_batch,commit,abort,checksum,batches"
if [[ -s $CSV ]]; then
  if [[ $(head -1 "$CSV") != "$HEADER" ]]; then
    echo "FAIL: $CSV exists with a different header"
    exit 1
  fi
  echo "== resuming: $(($(wc -l < "$CSV") - 1)) runs already in $CSV"
else
  echo "$HEADER" > "$CSV"
fi
# done_run BENCH SIZE THREADS BUILD REP: is that run already recorded?
done_run() { grep -q "^$1,$2,$3,$4,$5," "$CSV"; }
read -ra builds <<< "$BUILDS"
fail=0

for bench in ycsb tpcc; do
  txns=$YCSB_TXNS
  [[ $bench == tpcc ]] && txns=$TPCC_TXNS
  for size in $(sizes_for $bench); do
    for n in $THREADS; do
      for ((rep = 1; rep <= REPS; rep++)); do
        for ((k = 0; k < ${#builds[@]}; k++)); do
          b=${builds[(k + rep) % ${#builds[@]}]}
          done_run "$bench" "$size" "$n" "$b" "$rep" && continue
          log="$OUT/${bench}_B${size}_${b}_t${n}_r${rep}.log"
          if ! run_aria "$b" "$bench" "$n" "$SEED" "$txns" "$log" "$size"; then
            echo "run failed: $log"
            fail=1
            continue
          fi
          e=$(log_elapsed "$log")
          batches=$(log_batches "$log")
          read -r commit abort sum <<< "$(log_totals "$log")"
          ms=$(awk -v e="$e" -v b="$batches" 'BEGIN { printf "%.4f", 1e3 * e / b }')
          echo "$bench,$size,$n,$b,$rep,$e,$ms,$commit,$abort,$sum,$batches" >> "$CSV"
          printf '  %-5s B=%-5s t=%-3s %-6s rep %d: %8s ms/batch\n' \
            "$bench" "$size" "$n" "$b" "$rep" "$ms"
        done
      done
    done
  done
done

# summary BENCH SIZE THREADS BUILD -> "median min max" ms/batch
summary() {
  awk -F, -v bench="$1" -v size="$2" -v n="$3" -v b="$4" \
    '$1 == bench && $2 == size && $3 == n && $4 == b { print $7 }' "$CSV" | sort -g |
    awk '{ v[NR] = $1 } END {
      if (NR == 0) { print "? ? ?"; exit }
      m = (NR % 2) ? v[(NR + 1) / 2] : (v[NR / 2] + v[NR / 2 + 1]) / 2
      printf "%.4f %.4f %.4f\n", m, v[1], v[NR] }'
}

echo
printf '%-5s %6s %3s  %-6s %10s %10s %10s %8s\n' bench batch thr build median_ms min_ms max_ms speedup
for bench in ycsb tpcc; do
  for size in $(sizes_for $bench); do
    for n in $THREADS; do
      read -r std_med _ _ <<< "$(summary "$bench" "$size" "$n" std)"
      for b in $BUILDS; do
        read -r med lo hi <<< "$(summary "$bench" "$size" "$n" "$b")"
        sp=$(awk -v s="$std_med" -v m="$med" 'BEGIN { if (m > 0) printf "%.2fx", s / m; else print "?" }')
        printf '%-5s %6s %3s  %-6s %10s %10s %10s %8s\n' "$bench" "$size" "$n" "$b" "$med" "$lo" "$hi" "$sp"
      done
      sums=$(awk -F, -v bench="$bench" -v size="$size" -v n="$n" \
        '$1 == bench && $2 == size && $3 == n { print $10 }' "$CSV" | sort -u)
      if [[ $(wc -l <<< "$sums") -ne 1 || $sums == "?" ]]; then
        echo "   CHECKSUM MISMATCH at $bench batch=$size t=$n: $(tr '\n' ' ' <<< "$sums")"
        fail=1
      fi
    done
  done
done

if (( fail )); then
  echo "FAIL (logs in $OUT/)"
  exit 1
fi
echo "OK: checksums agree everywhere (results in $CSV)"
