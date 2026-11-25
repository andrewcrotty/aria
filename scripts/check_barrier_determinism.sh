#!/usr/bin/env bash
# Checks that every barrier build of Aria computes the same thing.
#
# Aria is deterministic: with the same transactions (--seed), the same number of
# batches (--batches) and the same worker count, the final database must be
# identical whatever the barrier. This builds Aria three ways (std, smc, nobar:
# see barrier_common.sh), runs YCSB and TPC-C on each at several thread counts,
# and compares the logged
# database checksum and commit/abort totals across builds. It also checks that a
# different seed changes the checksum, so a checksum that ignores the data
# cannot pass.
#
# Usage: scripts/check_barrier_determinism.sh [-t "1 2 4 8"] [-b BATCHES] [-s SEED] [-o OUTDIR]
# Run from the repo root (inside barrier_bench's dev shell for the dependencies).
set -euo pipefail
source "$(dirname "$0")/barrier_common.sh"

THREADS="1 2 4 8"
BATCHES=200
SEED=42
OUT=det-runs

while getopts "t:b:s:o:" opt; do
  case $opt in
    t) THREADS=$OPTARG ;;
    b) BATCHES=$OPTARG ;;
    s) SEED=$OPTARG ;;
    o) OUT=$OPTARG ;;
    *) sed -n '2,20p' "$0"; exit 2 ;;
  esac
done

mkdir -p "$OUT"
build_all "$OUT"

# run BUILD BENCH THREADS SEED -> "commit abort checksum" (and a log in $OUT)
run() {
  local log="$OUT/${2}_${1}_t${3}_s${4}.log"
  if ! run_aria "$1" "$2" "$3" "$4" "$BATCHES" "$log"; then
    echo "FAILED-RUN - -"
    return
  fi
  log_totals "$log"
}

fail=0
printf '%-5s %3s  %-7s %10s %10s  %s\n' bench thr build commit abort checksum
for bench in ycsb tpcc; do
  for n in $THREADS; do
    ref=""
    for b in $BUILDS; do
      res=$(run "$b" "$bench" "$n" "$SEED")
      printf '%-5s %3s  %-7s %10s %10s  %s\n' "$bench" "$n" "$b" $res
      if [[ -z $ref ]]; then
        ref=$res
      elif [[ $res != "$ref" ]]; then
        echo "   MISMATCH: $b differs from ${BUILDS%% *}"
        fail=1
      fi
    done
    # Sensitivity: another seed must give another database.
    other=$(run std "$bench" "$n" "$((SEED + 1))")
    if [[ ${other##* } == "${ref##* }" ]]; then
      echo "   SUSPICIOUS: seed $((SEED + 1)) gives the same checksum as seed $SEED"
      fail=1
    fi
  done
done

if (( fail )); then
  echo "FAIL (logs in $OUT/)"
  exit 1
fi
echo "PASS: all builds agree (logs in $OUT/)"
