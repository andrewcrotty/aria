**Yi Lu**, Xiangyao Yu, Lei Cao, Samuel Madden

[Aria: A Fast and Practical Deterministic OLTP Database]()

*Proc. of the VLDB Endowment (PVLDB), Volume 13, Tokyo, Japan, 2020.*

[![Build Status](https://travis-ci.org/luyi0619/aria.svg?branch=master)](https://travis-ci.org/luyi0619/aria)

# Dependencies

```sh
sudo apt-get update
sudo apt-get install -y zip make cmake g++ libjemalloc-dev libboost-dev libgoogle-glog-dev
```

# Download

```sh
git clone https://github.com/luyi0619/aria.git
```

# Build

```
./compile.sh
```

# Additions in this fork

Aria's phase barriers (`common/Barrier.h`) can use `SmcBarrier` from
[smc_barrier](https://github.com/lxbtlr/smc_barrier) (`-DUSE_SMC_BARRIER=ON`) instead of
`std::barrier`. `--seed` and `--batches` make runs deterministic and log a database checksum, so
barrier builds can be checked for identical results and timed on identical work with the scripts below.

<details>
<summary>Scripts, flags and dependencies</summary>

**Clone with submodules**: smc_barrier lives in `external/smc_barrier`.

```sh
git clone --recursive https://github.com/andrewcrotty/aria.git
```

**CMake options**

- `-DUSE_BARRIER=ON` (default): phase barriers instead of Aria's original signaling.
- `-DUSE_SMC_BARRIER=ON`: use `SmcBarrier`, with slots grouped by the NUMA nodes of the CPUs the
  workers are pinned to. Needs `-DASMJIT_ROOT=<prefix>` (defaults to `$ASMJIT`).

**Run flags (Aria protocol only)**

- `--seed=S`: seed worker i's generator with `S + i`, so every run executes the same transactions.
- `--batches=N`: stop after N batches instead of after 25 s, then log the elapsed time, ms per
  batch, commit/abort totals and a checksum of every table. With the same seed, batches and threads,
  every correct build must log the same checksum.

**Scripts** (run from the repo root; both build `build-det-{std,smc,nobar}`, i.e. `std::barrier`,
`SmcBarrier` and no barrier, and share `scripts/barrier_common.sh`)

- `scripts/check_barrier_determinism.sh [-t "1 2 4 8"] [-b BATCHES] [-s SEED] [-o DIR]`: runs YCSB and
  TPC-C on each build at each thread count and fails unless every build logs the same checksum and
  totals, and a different seed changes the checksum.
- `scripts/compare_barrier_speed.sh [-t "4 12"] [-B "10 100 1000"] [-r REPS] [-y TXNS] [-c TXNS] [-s SEED] [-o DIR]`:
  times every build on identical work, `REPS` runs per point with the build order rotated, and prints
  median/min/max ms per batch and the speedup over `std::barrier`. `-B` sweeps the batch size;
  `-y`/`-c` fix the total transactions per run. It also fails on any checksum mismatch. Every run is
  written to `DIR/results.csv`.

**New dependencies**

- gflags and glog are found through their CMake packages (`find_package`), which glog >= 0.7
  requires: install `libgflags-dev` along with `libgoogle-glog-dev`. Tested with glog 0.7 and gflags
  2.3 from nixpkgs; older Ubuntu packages are untested.
- `-DUSE_SMC_BARRIER=ON` needs a static AsmJit at revision `677a10b` (see smc_barrier's README).
- The scripts need bash 4+, `timeout` (coreutils) and `awk`.

</details>
