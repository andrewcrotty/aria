//
// Created by Yi Lu on 2019-09-05.
//

#pragma once

#include "common/Barrier.h"
#include "core/Manager.h"
#include "glog/logging.h"
#include "protocol/Bohm/Bohm.h"
#include "protocol/Bohm/BohmHelper.h"
#include "protocol/Bohm/BohmPartitioner.h"
#include "protocol/Bohm/BohmTransaction.h"

#include <memory>
#include <thread>
#include <vector>

namespace aria {

template <class Workload> class BohmManager : public aria::Manager {
public:
  using base_type = aria::Manager;

  using WorkloadType = Workload;
  using DatabaseType = typename WorkloadType::DatabaseType;
  using StorageType = typename WorkloadType::StorageType;

  using TransactionType = BohmTransaction;
  using ContextType = typename DatabaseType::ContextType;
  using RandomType = typename DatabaseType::RandomType;

  BohmManager(std::size_t coordinator_id, std::size_t id, DatabaseType &db,
              const ContextType &context, std::atomic<bool> &stopFlag)
      : base_type(coordinator_id, id, context, stopFlag), db(db), epoch(0),
        partitioner(coordinator_id, context.coordinator_num) {

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

    set_worker_status(ExecutorStatus::Bohm_Analysis);
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
      barrier->wait(id);
      barrier->wait(id);
    }
#else
    std::size_t n_workers = context.worker_num;
    std::size_t n_coordinators = context.coordinator_num;

    while (!stopFlag.load() && !batches_done()) {

      // the coordinator on each machine generates
      // a batch of transactions using the same random seed.

      epoch.fetch_add(1);

      // LOG(INFO) << "Seed: " << random.get_seed();
      n_started_workers.store(0);
      n_completed_workers.store(0);
      signal_worker(ExecutorStatus::Bohm_Analysis);
      // Allow each worker to analyse the read/write set
      // each worker analyse i, i + n, i + 2n transaction
      wait_all_workers_start();
      wait_all_workers_finish();
      // wait for all machines until they finish the analysis phase.
      wait4_ack();

      // Allow each worker to insert write sets
      n_started_workers.store(0);
      n_completed_workers.store(0);
      signal_worker(ExecutorStatus::Bohm_Insert);
      wait_all_workers_start();
      wait_all_workers_finish();
      // wait for all machines until they finish the execution phase.
      wait4_ack();

      // Allow each worker to run transactions
      n_started_workers.store(0);
      n_completed_workers.store(0);
      signal_worker(ExecutorStatus::Bohm_Execute);
      wait_all_workers_start();
      wait_all_workers_finish();
      // wait for all machines until they finish the execution phase.
      wait4_ack();

      // Allow each worker to garbage collect
      n_started_workers.store(0);
      n_completed_workers.store(0);
      signal_worker(ExecutorStatus::Bohm_GC);
      wait_all_workers_start();
      wait_all_workers_finish();
      // wait for all machines until they finish the execution phase.
      wait4_ack();
    }

    signal_worker(ExecutorStatus::EXIT);
#endif
  }

  void non_coordinator_start() override {

    std::size_t n_workers = context.worker_num;
    std::size_t n_coordinators = context.coordinator_num;

    for (;;) {
      // LOG(INFO) << "Seed: " << random.get_seed();
      ExecutorStatus status = wait4_signal();
      if (status == ExecutorStatus::EXIT) {
        set_worker_status(ExecutorStatus::EXIT);
        break;
      }

      DCHECK(status == ExecutorStatus::Bohm_Analysis);
      // the coordinator on each machine generates
      // a batch of transactions using the same random seed.
      // Allow each worker to analyse the read/write set
      // each worker analyse i, i + n, i + 2n transaction

      epoch.fetch_add(1);

      n_started_workers.store(0);
      n_completed_workers.store(0);
      set_worker_status(ExecutorStatus::Bohm_Analysis);
      wait_all_workers_start();
      wait_all_workers_finish();
      send_ack();

      status = wait4_signal();
      DCHECK(status == ExecutorStatus::Bohm_Insert);
      // Allow each worker to run transactions
      n_started_workers.store(0);
      n_completed_workers.store(0);
      set_worker_status(ExecutorStatus::Bohm_Insert);
      wait_all_workers_start();
      wait_all_workers_finish();
      send_ack();

      status = wait4_signal();
      DCHECK(status == ExecutorStatus::Bohm_Execute);
      // Allow each worker to run transactions
      n_started_workers.store(0);
      n_completed_workers.store(0);
      set_worker_status(ExecutorStatus::Bohm_Execute);
      wait_all_workers_start();
      wait_all_workers_finish();
      send_ack();

      status = wait4_signal();
      DCHECK(status == ExecutorStatus::Bohm_GC);
      // Allow each worker to garbage collect
      n_started_workers.store(0);
      n_completed_workers.store(0);
      set_worker_status(ExecutorStatus::Bohm_GC);
      wait_all_workers_start();
      wait_all_workers_finish();
      send_ack();
    }
  }

public:
  RandomType random;
  DatabaseType &db;
  std::atomic<uint32_t> epoch;
  BohmPartitioner partitioner;
  std::vector<StorageType> storages;
  std::vector<std::unique_ptr<TransactionType>> transactions;
  std::unique_ptr<Barrier> barrier;
};
} // namespace aria