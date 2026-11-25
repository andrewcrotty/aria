#pragma once

#include <cstddef>

#ifdef USE_SMC_BARRIER
#include "smc_barrier.hpp"
#include <vector>
#else
#include <barrier>
#endif

namespace aria {

class Barrier {
public:
  // tid t must run on CPU first_cpu + t (Coordinator pins workers to consecutive
  // cores after the I/O dispatchers); SmcBarrier groups its slots by those CPUs'
  // NUMA nodes.
  explicit Barrier(std::size_t nthreads, std::size_t first_cpu = 0)
#ifdef USE_SMC_BARRIER
      : barrier(static_cast<int>(nthreads), SmcBarrier::kNumaPage,
                nodes(nthreads, first_cpu).data()) {}
#else
      : barrier(nthreads) {
    (void)first_cpu;
  }
#endif

  inline void wait(std::size_t tid) {
#ifdef USE_SMC_BARRIER
    barrier.wait(tid);
#else
    (void)tid;
    barrier.arrive_and_wait();
#endif
  }

private:
#ifdef USE_SMC_BARRIER
  // NUMA node of CPU first_cpu + t, for each tid t.
  static std::vector<int> nodes(std::size_t n, std::size_t first_cpu) {
    auto all = SmcBarrier::numa_groups(static_cast<int>(first_cpu + n));
    return std::vector<int>(all.begin() + first_cpu, all.end());
  }

  SmcBarrier barrier;
#else
  std::barrier<> barrier;
#endif
};

} // namespace aria
