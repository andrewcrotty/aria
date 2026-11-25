# Shared by check_barrier_determinism.sh and compare_barrier_speed.sh (source it).
#
# The three barrier builds of Aria, each in $BUILD_PREFIX-<name>:
#
#   std    USE_BARRIER=ON  (std::barrier)
#   smc    USE_BARRIER=ON  USE_SMC_BARRIER=ON  (SmcBarrier; needs ASMJIT_ROOT or $ASMJIT)
#   nobar  USE_BARRIER=OFF (Aria's original signaling, no barrier at all)

# Environment overrides:
#   BUILD_PREFIX  build directory prefix (default build-det; use a per-host prefix
#                 when several machines share one checkout)
#   RUN_TIMEOUT   seconds before one benchmark run is killed (default 600)
BUILD_PREFIX=${BUILD_PREFIX:-build-det}
RUN_TIMEOUT=${RUN_TIMEOUT:-600}

BUILDS="std smc nobar"
declare -A CMAKE_FLAGS=(
  [std]="-DUSE_BARRIER=ON -DUSE_SMC_BARRIER=OFF"
  [smc]="-DUSE_BARRIER=ON -DUSE_SMC_BARRIER=ON"
  [nobar]="-DUSE_BARRIER=OFF -DUSE_SMC_BARRIER=OFF"
)

# build_all LOGDIR: configure and build every build, exit on failure.
build_all() {
  local b
  for b in $BUILDS; do
    echo "== building $b (log: $1/build-$b.log)"
    if ! { cmake -S . -B "$BUILD_PREFIX-$b" -DCMAKE_BUILD_TYPE=Release ${CMAKE_FLAGS[$b]} &&
           make -C "$BUILD_PREFIX-$b" -j"$(nproc)" bench_ycsb bench_tpcc; } > "$1/build-$b.log" 2>&1; then
      tail -20 "$1/build-$b.log"
      echo "FAIL: build $b"
      exit 1
    fi
  done
}

# Default transactions per batch (aria's defaults).
declare -A DEFAULT_BATCH_SIZE=([ycsb]=1000 [tpcc]=500)

# run_aria BUILD BENCH THREADS SEED BATCHES LOG [BATCH_SIZE]: one deterministic
# run; returns its exit status. One partition per worker.
run_aria() {
  local build=$1 bench=$2 n=$3 seed=$4 batches=$5 log=$6
  local size=${7:-${DEFAULT_BATCH_SIZE[$bench]}}
  local args=(--logtostderr=1 --id=0 --servers=127.0.0.1:10010 --protocol=Aria
              --threads="$n" --partition_num="$n" --seed="$seed" --batches="$batches"
              --batch_size="$size")
  if [[ $bench == ycsb ]]; then
    # YCSB writes the same value every time (its value generator is fixed-seed),
    # so its final state is just the set of keys ever written: keep enough keys
    # (the default 200000 per partition) that some stay unwritten.
    args+=(--keys=200000)
  else
    args+=(--query=mixed)
  fi
  timeout "$RUN_TIMEOUT" "$BUILD_PREFIX-$build/bench_$bench" "${args[@]}" > "$log" 2>&1
}

# log_totals LOG -> "commit abort checksum" ("? ? ?" where missing)
log_totals() {
  local totals sum
  totals=$(sed -n 's/.*batches: [0-9]* total commit: \([0-9]*\) total abort: \([0-9]*\).*/\1 \2/p' "$1")
  sum=$(sed -n 's/.*db checksum: \([0-9a-f]*\).*/\1/p' "$1")
  echo "${totals:-? ?} ${sum:-?}"
}

# log_elapsed LOG -> elapsed seconds of the run ("?" where missing)
log_elapsed() {
  local e
  e=$(sed -n 's/.*elapsed: \([0-9.e+-]*\) s,.*/\1/p' "$1")
  echo "${e:-?}"
}
