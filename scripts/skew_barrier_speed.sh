#!/usr/bin/env bash
# Times each barrier build of Aria (std, smc, nobar: see barrier_common.sh) on
# YCSB across skew factors, as in the paper's skew figure (Fig. 11).
#
# The workload is the paper's: Zipfian keys drawn over the whole table
# (--global_key_space, ranks not scrambled: key = rank, partition = key %
# partitions), 10 operations per transaction, 80% reads, -k keys per partition
# (40000) and one partition per worker. Skew factor 0 is uniform over the whole
# table. Like compare_barrier_speed.sh, every build runs the same transactions
# (--seed), each point REPS times with the build order rotated, and the builds'
# checksums must agree. Retry mode (-R, the default here) retries conflict
# aborts and stops each run after the batch in which -y transactions have
# committed, so runs at every skew do the same committed work; -D drops aborts
# instead, and -y is then the attempted transactions.
#
# Usage: scripts/skew_barrier_speed.sh [-t "8 15"] [-B "10 100 1000"]
#                                      [-z "0 0.1 ... 0.9 0.999"] [-k KEYS]
#                                      [-r REPS] [-y TXNS] [-D] [-s SEED] [-o OUTDIR]
# Run from the repo root (inside barrier_bench's dev shell for the dependencies).
# Every run goes to OUTDIR/results.csv. Rerunning with the same OUTDIR resumes:
# runs already in results.csv are skipped (so use the same -k/-y/-s).
set -euo pipefail
source "$(dirname "$0")/barrier_common.sh"

THREADS="8 15"
SIZES="10 100 1000"
ZIPFS="0 0.1 0.2 0.3 0.4 0.5 0.6 0.7 0.8 0.9 0.999"
KEYS=40000
REPS=5
TXNS=1000000
RETRY=1
SEED=42
OUT=skew-runs

while getopts "t:B:z:k:r:y:Ds:o:" opt; do
  case $opt in
    t) THREADS=$OPTARG ;;
    B) SIZES=$OPTARG ;;
    z) ZIPFS=$OPTARG ;;
    k) KEYS=$OPTARG ;;
    r) REPS=$OPTARG ;;
    y) TXNS=$OPTARG ;;
    D) RETRY=0 ;;
    s) SEED=$OPTARG ;;
    o) OUT=$OPTARG ;;
    *) sed -n '2,21p' "$0"; exit 2 ;;
  esac
done
YCSB_KEYS=$KEYS

mkdir -p "$OUT"
build_all "$OUT"

CSV="$OUT/results.csv"
HEADER="zipf,batch_size,threads,build,rep,elapsed_s,ms_per_batch,commit,abort,checksum,batches"
if [[ -s $CSV ]]; then
  if [[ $(head -1 "$CSV") != "$HEADER" ]]; then
    echo "FAIL: $CSV exists with a different header"
    exit 1
  fi
  echo "== resuming: $(($(wc -l < "$CSV") - 1)) runs already in $CSV"
else
  echo "$HEADER" > "$CSV"
fi
# done_run ZIPF SIZE THREADS BUILD REP: is that run already recorded?
done_run() { grep -q "^$1,$2,$3,$4,$5," "$CSV"; }
read -ra builds <<< "$BUILDS"
fail=0

for ZIPF in $ZIPFS; do
  for size in $SIZES; do
    work=$((TXNS / size))
    (( RETRY )) && work=$TXNS
    for n in $THREADS; do
      for ((rep = 1; rep <= REPS; rep++)); do
        for ((k = 0; k < ${#builds[@]}; k++)); do
          b=${builds[(k + rep) % ${#builds[@]}]}
          done_run "$ZIPF" "$size" "$n" "$b" "$rep" && continue
          log="$OUT/ycsb_z${ZIPF}_B${size}_${b}_t${n}_r${rep}.log"
          if ! run_aria "$b" ycsb "$n" "$SEED" "$work" "$log" "$size"; then
            echo "run failed: $log"
            fail=1
            continue
          fi
          e=$(log_elapsed "$log")
          batches=$(log_batches "$log")
          read -r commit abort sum <<< "$(log_totals "$log")"
          ms=$(awk -v e="$e" -v b="$batches" 'BEGIN { printf "%.4f", 1e3 * e / b }')
          echo "$ZIPF,$size,$n,$b,$rep,$e,$ms,$commit,$abort,$sum,$batches" >> "$CSV"
          printf '  z=%-5s B=%-5s t=%-3s %-6s rep %d: %8s ms/batch\n' \
            "$ZIPF" "$size" "$n" "$b" "$rep" "$ms"
        done
      done
    done
  done
done

# column ZIPF SIZE THREADS BUILD EXPR -> EXPR (awk, over the CSV fields) of each run, sorted
column() {
  awk -F, -v z="$1" -v size="$2" -v n="$3" -v b="$4" \
    "\$1 == z && \$2 == size && \$3 == n && \$4 == b { print $5 }" "$CSV" | sort -g
}

# stats FMT: sorted numbers on stdin -> "median min max", each printed with FMT
stats() {
  awk -v f="$1" '{ v[NR] = $1 } END {
    if (NR == 0) { print "? ? ?"; exit }
    m = (NR % 2) ? v[(NR + 1) / 2] : (v[NR / 2] + v[NR / 2 + 1]) / 2
    printf f " " f " " f "\n", m, v[1], v[NR] }'
}

# summary ZIPF SIZE THREADS BUILD -> "median_ms min_ms max_ms median_commit/s"
summary() {
  local ms tput
  ms=$(column "$@" '$7' | stats %.4f)
  tput=$(column "$@" '$8 / $6' | stats %.0f)
  echo "$ms ${tput%% *}"
}

echo
printf '%-5s %6s %3s  %-6s %10s %10s %10s %12s %8s\n' \
  zipf batch thr build median_ms min_ms max_ms commit/s speedup
for ZIPF in $ZIPFS; do
  for size in $SIZES; do
    for n in $THREADS; do
      read -r std_med _ _ _ <<< "$(summary "$ZIPF" "$size" "$n" std)"
      for b in $BUILDS; do
        read -r med lo hi tput <<< "$(summary "$ZIPF" "$size" "$n" "$b")"
        sp=$(awk -v s="$std_med" -v m="$med" 'BEGIN { if (m > 0) printf "%.2fx", s / m; else print "?" }')
        printf '%-5s %6s %3s  %-6s %10s %10s %10s %12s %8s\n' \
          "$ZIPF" "$size" "$n" "$b" "$med" "$lo" "$hi" "$tput" "$sp"
      done
      sums=$(awk -F, -v z="$ZIPF" -v size="$size" -v n="$n" \
        '$1 == z && $2 == size && $3 == n { print $10 }' "$CSV" | sort -u)
      if [[ $(wc -l <<< "$sums") -ne 1 || $sums == "?" ]]; then
        echo "   CHECKSUM MISMATCH at zipf=$ZIPF batch=$size t=$n: $(tr '\n' ' ' <<< "$sums")"
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
