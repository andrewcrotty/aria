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
#   RETRY         1: retry mode (see run_aria; the scripts' -R sets it)
#   YCSB_KEYS     YCSB keys per partition (default 200000)
#   ZIPF          YCSB skew factor; set (even to 0) to draw keys from the global
#                 key space like the paper's skew figure (--global_key_space).
#                 Unset: aria's default per-partition uniform keys.
#   TIMED         seconds: run each benchmark for a fixed time instead of a fixed
#                 amount of work (no --batches / --commits; WORK is ignored),
#                 averaging the seconds after WARMUP and before COOLDOWN
#                 (default 3 and 1). Unset or 0: fixed work.
BUILD_PREFIX=${BUILD_PREFIX:-build-det}
RUN_TIMEOUT=${RUN_TIMEOUT:-600}
RETRY=${RETRY:-0}
YCSB_KEYS=${YCSB_KEYS:-200000}
ZIPF=${ZIPF:-}
TIMED=${TIMED:-0}
WARMUP=${WARMUP:-3}
COOLDOWN=${COOLDOWN:-1}

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

# run_aria BUILD BENCH THREADS SEED WORK LOG [BATCH_SIZE]: one deterministic run;
# returns its exit status. One partition per worker. By default WORK is a batch
# count (--batches; conflict aborts are dropped, as in the original Aria, so the
# work is attempts). With RETRY=1 it is a commit target: conflict aborts are
# retried in the next batch and the run stops after the batch in which WORK
# transactions have committed (--retry_aborts --commits).
run_aria() {
  local build=$1 bench=$2 n=$3 seed=$4 work=$5 log=$6
  local size=${7:-${DEFAULT_BATCH_SIZE[$bench]}}
  local args=(--logtostderr=1 --id=0 --servers=127.0.0.1:10010 --protocol=Aria
              --threads="$n" --partition_num="$n" --seed="$seed" --batch_size="$size")
  (( RETRY )) && args+=(--retry_aborts)
  if (( TIMED )); then
    args+=(--time_to_run="$TIMED" --warmup="$WARMUP" --cooldown="$COOLDOWN")
  elif (( RETRY )); then
    args+=(--commits="$work")
  else
    args+=(--batches="$work")
  fi
  if [[ $bench == ycsb ]]; then
    # YCSB writes the same value every time (its value generator is fixed-seed),
    # so its final state is just the set of keys ever written: keep enough keys
    # (the default 200000 per partition) that some stay unwritten.
    args+=(--keys="$YCSB_KEYS")
    [[ -n $ZIPF ]] && args+=(--zipf="$ZIPF" --global_key_space=True)
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

# log_batches LOG -> batches the run took ("?" where missing)
log_batches() {
  local b
  b=$(sed -n 's/.*batches: \([0-9]*\) total commit:.*/\1/p' "$1")
  echo "${b:-?}"
}

# log_elapsed LOG -> elapsed seconds of the run ("?" where missing)
log_elapsed() {
  local e
  e=$(sed -n 's/.*elapsed: \([0-9.e+-]*\) s,.*/\1/p' "$1")
  echo "${e:-?}"
}

# log_average LOG -> "commit/s abort/s" of a fixed-time run (TIMED), averaged
# over the measured seconds ("? ?" where missing)
log_average() {
  local a
  a=$(sed -n 's/.*average commit: \([0-9.e+-]*\) abort: \([0-9.e+-]*\) .*/\1 \2/p' "$1")
  echo "${a:-? ?}"
}
