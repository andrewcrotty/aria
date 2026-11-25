#!/usr/bin/env bash
# Checks that every barrier build of Aria computes the same thing.
#
# Aria is deterministic: with the same transactions (--seed), the same number of
# batches (--batches) and the same worker count, the final database must be
# identical whatever the barrier. This builds Aria three ways
#
#   std    USE_BARRIER=ON  (std::barrier)
#   smc    USE_BARRIER=ON  USE_SMC_BARRIER=ON  (SmcBarrier; needs ASMJIT_ROOT or $ASMJIT)
#   nobar  USE_BARRIER=OFF (Aria's original signaling, no barrier at all)
#
# runs YCSB and TPC-C on each at several thread counts, and compares the logged
# database checksum and commit/abort totals across builds. It also checks that a
# different seed changes the checksum, so a checksum that ignores the data
# cannot pass.
#
# Usage: scripts/check_barrier_determinism.sh [-t "1 2 4 8"] [-b BATCHES] [-s SEED] [-o OUTDIR]
# Run from the repo root (inside barrier_bench's dev shell for the dependencies).
set -euo pipefail

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

BUILDS="std smc nobar"
declare -A CMAKE_FLAGS=(
  [std]="-DUSE_BARRIER=ON -DUSE_SMC_BARRIER=OFF"
  [smc]="-DUSE_BARRIER=ON -DUSE_SMC_BARRIER=ON"
  [nobar]="-DUSE_BARRIER=OFF -DUSE_SMC_BARRIER=OFF"
)

mkdir -p "$OUT"

for b in $BUILDS; do
  echo "== building $b (log: $OUT/build-$b.log)"
  if ! { cmake -S . -B "build-det-$b" -DCMAKE_BUILD_TYPE=Release ${CMAKE_FLAGS[$b]} &&
         make -C "build-det-$b" -j"$(nproc)" bench_ycsb bench_tpcc; } > "$OUT/build-$b.log" 2>&1; then
    tail -20 "$OUT/build-$b.log"
    echo "FAIL: build $b"
    exit 1
  fi
done

# run BUILD BENCH THREADS SEED -> "commit abort checksum" (and a log in $OUT)
run() {
  local build=$1 bench=$2 n=$3 seed=$4
  local log="$OUT/${bench}_${build}_t${n}_s${seed}.log"
  local args=(--logtostderr=1 --id=0 --servers=127.0.0.1:10010 --protocol=Aria
              --threads="$n" --partition_num="$n" --seed="$seed" --batches="$BATCHES")
  if [[ $bench == ycsb ]]; then
    # YCSB writes the same value every time (its value generator is fixed-seed),
    # so its final state is just the set of keys ever written: keep enough keys
    # (the default 200000 per partition) that some stay unwritten.
    args+=(--batch_size=1000 --keys=200000)
  else
    args+=(--batch_size=500 --query=mixed)
  fi
  if ! timeout 300 "build-det-$build/bench_$bench" "${args[@]}" > "$log" 2>&1; then
    echo "FAILED-RUN - -"
    return
  fi
  local totals sum
  totals=$(sed -n 's/.*batches: [0-9]* total commit: \([0-9]*\) total abort: \([0-9]*\).*/\1 \2/p' "$log")
  sum=$(sed -n 's/.*db checksum: \([0-9a-f]*\).*/\1/p' "$log")
  echo "${totals:-? ?} ${sum:-?}"
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
