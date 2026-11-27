#!/usr/bin/env bash
#SBATCH --job-name=aria-skew
#SBATCH --exclusive
#SBATCH --nodes=1
#
# One skew_barrier_speed.sh sweep as a Slurm job, on a whole node.
#
#   sbatch -p <partition> -w <node> -o skew-runs/<node>/slurm-%j.out \
#          --export=ALL,ASMJIT=<asmjit prefix>[,ZIPFS="0 0.5 0.999"][,TXNS=N][,DROP=1][,TIMED=S][,PROTOCOL=P][,LOCK_MANAGERS=L][,OUTDIR=<dir>] \
#          scripts/slurm_skew_sweep.sbatch "<threads>" "<batch sizes>" <reps>
#
# Submit from the repo root. Builds go to build-det-<host>-* (several machines
# can share one checkout) and results to OUTDIR (default skew-runs/<host>/, or
# skew-runs/<host>-drop/ with DROP=1): every job for a host appends to the same
# results.csv and skips runs already in it, so a killed job can simply be
# resubmitted. ZIPFS overrides the skew factors (default: the paper's 0, 0.1,
# ..., 0.9, 0.999) and TXNS the transactions per run (default 1000000).
# DROP=1 drops conflict aborts like the original Aria (skew_barrier_speed.sh -D),
# which is what the paper's Fig. 11 measures; TXNS is then attempted, not
# committed, transactions. TIMED=S runs each benchmark for S seconds instead of
# a fixed amount of work (skew_barrier_speed.sh -T S; WARMUP and COOLDOWN
# seconds, default 3 and 1, are left out of the average) and adds -timed to the
# default OUTDIR. PROTOCOL=P runs another protocol (skew_barrier_speed.sh -P P;
# needs DROP=1 unless P is Aria, and TIMED for TwoPL; LOCK_MANAGERS for Calvin / AriaFB,
# default 1) and adds -<p> (lower case) to the default OUTDIR.
set -euo pipefail

THREADS=${1:?thread counts, e.g. "8 15"}
SIZES=${2:?batch sizes, e.g. "10 100 1000"}
REPS=${3:-5}

cd "${SLURM_SUBMIT_DIR:-$PWD}"
host=$(hostname -s)
export BUILD_PREFIX=build-det-$host
export RUN_TIMEOUT=${RUN_TIMEOUT:-1800}
opts=()
suffix=
if [[ ${DROP:-0} == 1 ]]; then
  opts+=(-D)
  suffix=-drop
fi
if [[ ${TIMED:-0} != 0 ]]; then
  opts+=(-T "$TIMED")
  suffix=$suffix-timed
fi
PROTOCOL=${PROTOCOL:-Aria}
opts+=(-P "$PROTOCOL")
if [[ $PROTOCOL != Aria ]]; then
  suffix=$suffix-${PROTOCOL,,}
  [[ $PROTOCOL == Calvin || $PROTOCOL == AriaFB ]] && suffix=$suffix-lm${LOCK_MANAGERS:-1}
fi
OUTDIR=${OUTDIR:-skew-runs/$host$suffix}
[[ -n ${ZIPFS:-} ]] && opts+=(-z "$ZIPFS")
[[ -n ${TXNS:-} ]] && opts+=(-y "$TXNS")

echo "== $(date) job ${SLURM_JOB_ID:-local} on $host: threads [$THREADS] sizes [$SIZES] reps $REPS zipfs [${ZIPFS:-default}]"
echo "== ASMJIT=${ASMJIT:-unset} BUILD_PREFIX=$BUILD_PREFIX RUN_TIMEOUT=$RUN_TIMEOUT OUTDIR=$OUTDIR TXNS=${TXNS:-default} DROP=${DROP:-0} TIMED=${TIMED:-0} WARMUP=${WARMUP:-3} COOLDOWN=${COOLDOWN:-1} PROTOCOL=$PROTOCOL LOCK_MANAGERS=${LOCK_MANAGERS:-1}"
mkdir -p "$OUTDIR"
scripts/skew_barrier_speed.sh -t "$THREADS" -B "$SIZES" -r "$REPS" "${opts[@]}" -o "$OUTDIR"
echo "== $(date) done"
