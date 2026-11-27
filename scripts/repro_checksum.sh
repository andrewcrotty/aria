#!/usr/bin/env bash
# Hunts a rare checksum mismatch: runs one configuration RUNS times on every
# barrier build (see barrier_common.sh) and records each run's database checksum
# and per-table checksums (the "table checksum:" log lines), so an outlier can be
# traced to the tables it differs in.
#
# Every run goes to OUTDIR/runs.csv (run,build,commit,abort,db,<table ids...>).
# The first run of the first build is the reference; a run's log is kept only
# if its checksum differs from it. Ends with each distinct checksum's count
# and, for each outlier, the tables that differ from the reference, at the end
# of the run and right after loading (the "load table checksum:" lines).
#
# -d TABLE (TPC-C) also dumps that table's rows after each run (--dump_table),
# kept like the logs: reference.rows and the outliers' run<R>_<build>.rows, to
# diff row by row.
#
# Usage: scripts/repro_checksum.sh [-b ycsb|tpcc] [-t THREADS] [-B BATCH_SIZE] [-w WORK]
#                                  [-n RUNS] [-R] [-d TABLE] [-s SEED] [-o OUTDIR]
# WORK is a batch count (-R: retry mode, a commit target). Default: TPC-C, 4
# workers, batch 5, 200000 batches (a manchego mismatch), 100 runs per build.
set -euo pipefail
source "$(dirname "$0")/barrier_common.sh"

BENCH=tpcc
THREADS=4
SIZE=5
WORK=200000
RUNS=100
SEED=42
OUT=cksum-runs
DUMP=""

while getopts "b:t:B:w:n:Rd:s:o:" opt; do
  case $opt in
    b) BENCH=$OPTARG ;;
    t) THREADS=$OPTARG ;;
    B) SIZE=$OPTARG ;;
    w) WORK=$OPTARG ;;
    n) RUNS=$OPTARG ;;
    R) RETRY=1 ;;
    d) DUMP=$OPTARG ;;
    s) SEED=$OPTARG ;;
    o) OUT=$OPTARG ;;
    *) sed -n '2,21p' "$0"; exit 2 ;;
  esac
done
check_protocol

mkdir -p "$OUT"
build_all "$OUT"

CSV="$OUT/runs.csv"
ref=""
for ((r = 1; r <= RUNS; r++)); do
  for b in $BUILDS; do
    log="$OUT/run${r}_$b.log"
    rows="$OUT/run${r}_$b.rows"
    ARIA_EXTRA=""
    [[ -n $DUMP ]] && ARIA_EXTRA="--dump_table=$DUMP --dump_file=$rows"
    if ! run_aria "$b" "$BENCH" "$THREADS" "$SEED" "$WORK" "$log" "$SIZE"; then
      echo "run failed: $log"
      continue
    fi
    read -r commit abort sum <<< "$(log_totals "$log")"
    tables=$(sed -n 's/.*\] table checksum: \([0-9]*\) \([0-9a-f]*\).*/\1 \2/p' "$log")
    if [[ ! -s $CSV ]]; then
      echo "run,build,commit,abort,db,$(cut -d' ' -f1 <<< "$tables" | paste -sd,)" > "$CSV"
    fi
    echo "$r,$b,$commit,$abort,$sum,$(cut -d' ' -f2 <<< "$tables" | paste -sd,)" >> "$CSV"
    if [[ -z $ref ]]; then
      ref=$sum
      cp "$log" "$OUT/reference.log"
      [[ -n $DUMP ]] && cp "$rows" "$OUT/reference.rows"
    fi
    if [[ $sum == "$ref" ]]; then
      rm -f "$log" "$rows"
    else
      echo "  run $r $b: checksum $sum differs from $ref (log kept)"
    fi
  done
done

echo
echo "== checksums (count db):"
tail -n +2 "$CSV" | cut -d, -f5 | sort | uniq -c
awk -F, 'NR == 1 { for (i = 6; i <= NF; i++) id[i] = $i; next }
         NR == 2 { for (i = 3; i <= NF; i++) want[i] = $i; next }
         $5 != want[5] {
           d = ""
           for (i = 6; i <= NF; i++) if ($i != want[i]) d = d " " id[i]
           c = ($3 != want[3] || $4 != want[4]) ? ", commit/abort differ too" : ""
           print "   run " $1 " " $2 ": tables" d " differ" c }' "$CSV"
# Did the outliers' tables already differ right after loading?
loaded() { sed -n 's/.*\] load table checksum: \([0-9]*\) \([0-9a-f]*\).*/\1 \2/p' "$1"; }
for log in "$OUT"/run*.log; do
  [[ -e $log ]] || continue
  d=$(join <(loaded "$OUT/reference.log") <(loaded "$log") | awk '$2 != $3 { printf " %s", $1 }')
  echo "   $(basename "$log" .log): after loading, tables${d:- (none)} differ"
done
