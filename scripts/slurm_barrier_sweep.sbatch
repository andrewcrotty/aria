#!/usr/bin/env bash
#SBATCH --job-name=aria-barrier
#SBATCH --exclusive
#SBATCH --nodes=1
#
# One compare_barrier_speed.sh sweep as a Slurm job, on a whole node.
#
#   sbatch -p <partition> -w <node> -o speed-runs/<node>/slurm-%j.out \
#          --export=ALL,ASMJIT=<asmjit prefix>[,SWEEP_FLAG=-F][,OUTDIR=<dir>] \
#          scripts/slurm_barrier_sweep.sbatch "<threads>" "<batch sizes>" <reps>
#
# Submit from the repo root. Builds go to build-det-<host>-* (several machines
# can share one checkout) and results to OUTDIR (default speed-runs/<host>/):
# every job for a host appends to the same results.csv and skips runs already
# in it, so a killed job can simply be resubmitted. SWEEP_FLAG=-F gives the batch
# sizes as fractions of each benchmark's default (default -B: absolute sizes).
set -euo pipefail

THREADS=${1:?thread counts, e.g. "1 2 4"}
SIZES=${2:?batch sizes, e.g. "10 1000"}
REPS=${3:-5}

cd "${SLURM_SUBMIT_DIR:-$PWD}"
host=$(hostname -s)
export BUILD_PREFIX=build-det-$host
export RUN_TIMEOUT=${RUN_TIMEOUT:-1800}
SWEEP_FLAG=${SWEEP_FLAG:--B}
OUTDIR=${OUTDIR:-speed-runs/$host}

echo "== $(date) job ${SLURM_JOB_ID:-local} on $host: threads [$THREADS] sizes $SWEEP_FLAG [$SIZES] reps $REPS"
echo "== ASMJIT=${ASMJIT:-unset} BUILD_PREFIX=$BUILD_PREFIX RUN_TIMEOUT=$RUN_TIMEOUT OUTDIR=$OUTDIR"
scripts/compare_barrier_speed.sh -t "$THREADS" "$SWEEP_FLAG" "$SIZES" -r "$REPS" -o "$OUTDIR"
echo "== $(date) done"
