#!/usr/bin/env python3
"""Plot batch-time speedup over std::barrier against batch size.

    python3 scripts/plot_barrier_speedup.py RESULTS_CSV [-o OUT] [--title TEXT]

RESULTS_CSV is compare_barrier_speed.sh's results.csv. One panel per thread
count. The x axis is the batch size divided by the benchmark's default (1000
for YCSB, 500 for TPC-C), so both benchmarks share an axis; the y axis is
std::barrier's median ms/batch over each build's median, with bars spanning
std's median over the build's slowest and fastest run. Color is the build,
line style and marker the benchmark. Writes OUT.svg and OUT.png (default:
next to the CSV, speedup_vs_batch).
"""
import argparse
import csv
import statistics
from collections import defaultdict
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.lines import Line2D
from matplotlib.ticker import FuncFormatter

DEFAULT_BATCH = {"ycsb": 1000, "tpcc": 500}
BENCH_STYLE = {"ycsb": ("YCSB", "-", "o"), "tpcc": ("TPC-C", "--", "s")}
# std::barrier is the baseline (speedup 1), drawn as a gray reference.
BUILDS = [("smc", "SmcBarrier", "#2a78d6"), ("nobar", "no barrier (Aria's signaling)", "#eb6834")]
BASELINE = "#8a8985"
SURFACE, INK, INK_2, GRID = "#fcfcfb", "#0b0b0b", "#52514e", "#e4e3df"


def ht_level(workers, cores, offset):
    """Core use of a run: the workers and the manager are busy on consecutive CPUs
    offset .. offset + workers, CPU c and c + cores being siblings of core c."""
    busy = set(range(offset, offset + workers + 1))
    used = sum(1 for c in range(cores) if c in busy or c + cores in busy)
    doubled = sum(1 for c in range(cores) if c in busy and c + cores in busy)
    return f"{used}/{cores} cores" if doubled == 0 else f"{round(100 * doubled / cores)}% HT"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("csv")
    ap.add_argument("-o", "--out")
    ap.add_argument("--title", default="Aria batch time: speedup over std::barrier (higher is better)")
    ap.add_argument("--cores", type=int,
                    help="physical cores; labels each panel with the cores used or the "
                         "%% of cores running two threads (assumes CPU c and c + cores are "
                         "siblings, as on dubliner and manchego)")
    ap.add_argument("--cpu-offset", type=int, default=0,
                    help="first CPU the workers are pinned to (0 since the pinning fix; "
                         "2 for runs before it, which left CPUs 0-1 to idle dispatchers)")
    args = ap.parse_args()
    out = Path(args.out) if args.out else Path(args.csv).with_name("speedup_vs_batch")

    # times[(bench, threads, size, build)] = [ms_per_batch, ...]
    times = defaultdict(list)
    with open(args.csv) as f:
        for r in csv.DictReader(f):
            key = (r["bench"], int(r["threads"]), int(r["batch_size"]), r["build"])
            times[key].append(float(r["ms_per_batch"]))
    threads = sorted({k[1] for k in times})

    plt.rcParams.update({"font.size": 10, "axes.edgecolor": INK_2, "axes.labelcolor": INK_2,
                         "xtick.color": INK_2, "ytick.color": INK_2})
    ncols = min(4, len(threads))
    nrows = -(-len(threads) // ncols)
    fig, axes = plt.subplots(nrows, ncols, figsize=(5.2 * ncols, 4.2 * nrows + 0.6),
                             sharey=True, facecolor=SURFACE, squeeze=False)
    for ax in axes.flat[len(threads):]:
        ax.set_visible(False)
    for ax, n in zip(axes.flat, threads):
        ax.set_facecolor(SURFACE)
        ax.axhline(1.0, color=BASELINE, lw=1.5, ls=(0, (4, 3)), zorder=1)
        for bench, (_, ls, marker) in BENCH_STYLE.items():
            sizes = sorted({k[2] for k in times if k[0] == bench and k[1] == n})
            if not sizes:
                continue
            xs = [s / DEFAULT_BATCH[bench] for s in sizes]
            for build, _, color in BUILDS:
                med, lo, hi = [], [], []
                for s in sizes:
                    std = statistics.median(times[(bench, n, s, "std")])
                    t = times[(bench, n, s, build)]
                    sp = std / statistics.median(t)
                    med.append(sp)
                    lo.append(sp - std / max(t))
                    hi.append(std / min(t) - sp)
                ax.errorbar(xs, med, yerr=[lo, hi], color=color, ls=ls, lw=2, marker=marker,
                            ms=6, mec=SURFACE, mew=1.2, elinewidth=1, capsize=2.5, zorder=3)
        ax.set_xscale("log")
        ax.xaxis.set_major_formatter(FuncFormatter(lambda v, _: f"{v:g}×"))
        ax.set_title(f"{n} worker thread{'' if n == 1 else 's'}" + (f" ({ht_level(n, args.cores, args.cpu_offset)})" if args.cores else ""),
                     loc="left", color=INK, fontsize=11)
        ax.grid(axis="y", color=GRID, lw=0.8)
        for side in ("top", "right"):
            ax.spines[side].set_visible(False)
    for row in axes:
        row[0].set_ylabel("speedup in median ms/batch vs std::barrier")
    axes[0][0].set_ylim(bottom=0.8)
    axes[0][0].yaxis.set_major_formatter(FuncFormatter(lambda v, _: f"{v:g}×"))
    fig.supxlabel("batch size ÷ benchmark default (YCSB 1000, TPC-C 500)", color=INK_2,
                  fontsize=10, y=0.055)

    handles = [Line2D([], [], color=c, lw=2, label=l) for _, l, c in BUILDS]
    handles.append(Line2D([], [], color=BASELINE, lw=1.5, ls=(0, (4, 3)), label="std::barrier (baseline)"))
    handles += [Line2D([], [], color=INK_2, lw=1.5, ls=ls, marker=m, ms=6, label=name)
                for name, ls, m in BENCH_STYLE.values()]
    fig.legend(handles=handles, loc="lower center", ncol=5, frameon=False, labelcolor=INK,
               bbox_to_anchor=(0.5, -0.02))
    fig.suptitle(args.title, x=0.01, ha="left", color=INK, fontsize=12)
    fig.tight_layout(rect=(0, 0.07, 1, 1))
    for ext in ("svg", "png"):
        fig.savefig(out.with_suffix(f".{ext}"), dpi=160, facecolor=SURFACE, bbox_inches="tight")
    print(f"wrote {out}.svg, {out}.png")


if __name__ == "__main__":
    main()
