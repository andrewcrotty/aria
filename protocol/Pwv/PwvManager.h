//
// Created by Yi Lu on 1/14/20.
//

#pragma once

#include "common/Barrier.h"
#include "core/Manager.h"
#include "glog/logging.h"
#include "protocol/Pwv/PwvHelper.h"
#include "protocol/Pwv/PwvTransaction.h"
#include "protocol/Pwv/PwvWorkload.h"

#include <atomic>
#include <memory>
#include <thread>
#include <vector>

namespace aria {
template <class Database> class PwvManager : public aria::Manager {
public:
  using base_type = aria::Manager;
  using DatabaseType = Database;
  using WorkloadType = PwvWorkload<Database>;
  using StorageType = typename DatabaseType::StorageType;
  using TransactionType = PwvTransaction;
  using ContextType = typename DatabaseType::ContextType;
  using RandomType = typename DatabaseType::RandomType;

  PwvManager(std::size_t coordinator_id, std::size_t id, DatabaseType &db,
             const ContextType &context, std::atomic<bool> &stopFlag)
      : base_type(coordinator_id, id, context, stopFlag), db(db), epoch(0) {

    storages.resize(context.batch_size);
    transactions.resize(context.batch_size);

#ifdef USE_BARRIER
    CHECK(context.coordinator_num == 1);

    std::size_t nthreads = context.worker_num;
#ifndef NO_MANAGER
    nthreads += 1;
#endif

    std::size_t first_cpu = context.cpu_core_id + 2 * context.io_thread_num;
    barrier = std::make_unique<Barrier>(nthreads, first_cpu);
#endif
  }

  // --batches: true once that many batches have been started.
  bool batches_done() const {
    return context.batches > 0 && epoch.load() >= context.batches;
  }

  bool prepare_local_batch() {
    if (stopFlag.load() || batches_done()) {
      set_worker_status(ExecutorStatus::EXIT);
      return false;
    }

    epoch.fetch_add(1);

    set_worker_status(ExecutorStatus::Pwv_Analysis);
    return true;
  }

  void coordinator_start() override {
#ifdef USE_BARRIER
    for (;;) {
      bool running = prepare_local_batch();

      barrier->wait(id);
      if (!running)
        return;

      barrier->wait(id);
      barrier->wait(id);
    }
#else
    std::size_t n_workers = context.worker_num;
    std::size_t n_coordinators = context.coordinator_num;

    while (!stopFlag.load() && !batches_done()) {

      // the coordinator generates a batch of transactions

      epoch.fetch_add(1);

      // LOG(INFO) << "Seed: " << random.get_seed();
      n_started_workers.store(0);
      n_completed_workers.store(0);
      signal_worker(ExecutorStatus::Pwv_Analysis);
      // Allow each worker to analyse the read/write set
      // each worker analyse i, i + n, i + 2n transaction
      wait_all_workers_start();
      wait_all_workers_finish();

      // Allow each worker to run transactions
      n_started_workers.store(0);
      n_completed_workers.store(0);
      signal_worker(ExecutorStatus::Pwv_Execute);
      wait_all_workers_start();
      wait_all_workers_finish();
    }

    signal_worker(ExecutorStatus::EXIT);
#endif
  }

public:
  RandomType random;
  DatabaseType &db;
  std::atomic<uint32_t> epoch;
  std::vector<StorageType> storages;
  std::vector<std::unique_ptr<TransactionType>> transactions;
  std::unique_ptr<Barrier> barrier;
};
} // namespace aria