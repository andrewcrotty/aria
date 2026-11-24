#pragma once

#include <cstddef>

#ifdef USE_SMC_BARRIER
#include "smc_barrier.hpp"
#else
#include <barrier>
#endif

namespace aria {

class Barrier {
public:
  explicit Barrier(std::size_t nthreads)
      : barrier(nthreads) {}

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
  SmcBarrier barrier;
#else
  std::barrier<> barrier;
#endif
};

} // namespace aria
