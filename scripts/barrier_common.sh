# Shared by check_barrier_determinism.sh, compare_barrier_speed.sh and
# skew_barrier_speed.sh (source it).
#
# The three barrier builds, each in $BUILD_PREFIX-<name>. On a single node they
# set the phase hand-off of every batch protocol (Aria, AriaFB, Bohm, Calvin,
# Pwv); TwoPL has no batches and is the same in all three:
#
#   std    USE_BARRIER=ON  (std::barrier)
#   smc    USE_BARRIER=ON  SMC_BARRIER=ON  (SmcBarrier; needs ASMJIT_ROOT or $ASMJIT)
#   nobar  USE_BARRIER=OFF (the original signaling, no barrier at all)

# Environment overrides:
#   BUILD_PREFIX  build directory prefix (default build-det; use a per-host prefix
#                 when several machines share one checkout)
#   RUN_TIMEOUT   seconds before one benchmark run is killed (default 600)
#   RETRY         1: retry mode (see run_aria; the scripts' -R sets it)
#   ARIA_EXTRA    extra benchmark flags for every run (word-split)
#   YCSB_KEYS     YCSB keys per partition (default 200000)
#   ZIPF          YCSB skew factor; set (even to 0) to draw keys from the global
#                 key space like the paper's skew figure (--global_key_space).
#                 Unset: aria's default per-partition uniform keys.
#   TIMED         seconds: run each benchmark for a fixed time instead of a fixed
#                 amount of work (no --batches / --commits; WORK is ignored),
#                 averaging the seconds after WARMUP and before COOLDOWN
#                 (default 3 and 1). Unset or 0: fixed work.
#   PROTOCOL      Aria (default), AriaFB, Bohm, Calvin, Pwv or TwoPL. Every
#                 batch protocol supports fixed-work runs (--batches, with
#                 checksums; AriaFB, Bohm, Calvin and Pwv seed worker i with i,
#                 ignoring --seed); retry mode (--commits) is Aria only, and
#                 TwoPL (no batches) needs TIMED (see check_protocol).
#   LOCK_MANAGERS lock manager threads of Calvin and AriaFB (default 1), taken
#                 from the workers; Calvin needs threads > LOCK_MANAGERS and
#                 (threads - LOCK_MANAGERS) a multiple of LOCK_MANAGERS.
BUILD_PREFIX=${BUILD_PREFIX:-build-det}
RUN_TIMEOUT=${RUN_TIMEOUT:-600}
RETRY=${RETRY:-0}
YCSB_KEYS=${YCSB_KEYS:-200000}
ZIPF=${ZIPF:-}
TIMED=${TIMED:-0}
WARMUP=${WARMUP:-3}
COOLDOWN=${COOLDOWN:-1}
PROTOCOL=${PROTOCOL:-Aria}
LOCK_MANAGERS=${LOCK_MANAGERS:-1}

# Per-protocol flags, as in the paper's skew script (scripts/aws_reordering.py).
declare -A PROTOCOL_FLAGS=(
  [Aria]=""
  [AriaFB]="--ariaFB_lock_manager=$LOCK_MANAGERS"
  [Bohm]="--mvcc=True --bohm_single_spin=True --same_batch=False"
  [Calvin]="--lock_manager=$LOCK_MANAGERS --replica_group=1 --same_batch=False"
  [Pwv]="--same_batch=False"
  [TwoPL]=""
)

# check_protocol: exit unless PROTOCOL is known and the run mode suits it.
check_protocol() {
  if [[ -z ${PROTOCOL_FLAGS[$PROTOCOL]+set} ]]; then
    echo "FAIL: unknown protocol '$PROTOCOL' (Aria AriaFB Bohm Calvin Pwv TwoPL)"
    exit 2
  fi
  if [[ $PROTOCOL != Aria ]] && (( RETRY )); then
    echo "FAIL: retry mode (-R) is Aria only; use drop mode (-D) for $PROTOCOL"
    exit 2
  fi
  if [[ $PROTOCOL == TwoPL ]] && (( ! TIMED )); then
    echo "FAIL: TwoPL has no batches, so it supports only fixed-time runs (TIMED / -T)"
    exit 2
  fi
}

BUILDS="std smc nobar"
declare -A CMAKE_FLAGS=(
  [std]="-DUSE_BARRIER=ON -DSMC_BARRIER=OFF"
  [smc]="-DUSE_BARRIER=ON -DSMC_BARRIER=ON"
  [nobar]="-DUSE_BARRIER=OFF -DSMC_BARRIER=OFF"
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
# transactions have committed (--retry_aborts --commits). Runs PROTOCOL (default
# Aria) with its PROTOCOL_FLAGS.
run_aria() {
  local build=$1 bench=$2 n=$3 seed=$4 work=$5 log=$6
  local size=${7:-${DEFAULT_BATCH_SIZE[$bench]}}
  local args=(--logtostderr=1 --id=0 --servers=127.0.0.1:10010 --protocol="$PROTOCOL"
              --threads="$n" --partition_num="$n" --seed="$seed" --batch_size="$size")
  local extra
  read -ra extra <<< "${PROTOCOL_FLAGS[$PROTOCOL]}"
  args+=("${extra[@]}")
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
  # shellcheck disable=SC2206
  args+=(${ARIA_EXTRA:-})
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
