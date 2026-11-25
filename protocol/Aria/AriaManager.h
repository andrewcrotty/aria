//
// Created by Yi Lu on 1/7/19.
//

#pragma once

#include "common/Barrier.h"
#include "core/Manager.h"
#include "core/Partitioner.h"
#include "protocol/Aria/Aria.h"
#include "protocol/Aria/AriaHelper.h"
#include "protocol/Aria/AriaTransaction.h"

#include <atomic>
#include <memory>
#include <thread>
#include <vector>

namespace aria {

template <class Workload> class AriaManager : public aria::Manager {
public:
  using base_type = aria::Manager;

  using WorkloadType = Workload;
  using DatabaseType = typename WorkloadType::DatabaseType;
  using StorageType = typename WorkloadType::StorageType;

  using TransactionType = AriaTransaction;
  static_assert(std::is_same<typename WorkloadType::TransactionType,
                             TransactionType>::value,
                "Transaction types do not match.");
  using ContextType = typename DatabaseType::ContextType;
  using RandomType = typename DatabaseType::RandomType;

  AriaManager(std::size_t coordinator_id, std::size_t id, DatabaseType &db,
              const ContextType &context, std::atomic<bool> &stopFlag)
      : base_type(coordinator_id, id, context, stopFlag), db(db), epoch(0) {

    storages.resize(context.batch_size);
    transactions.resize(context.batch_size);

#ifdef USE_BARRIER
    if (context.coordinator_num == 1) {
#ifdef NO_MANAGER
      no_manager = true;
#endif
      std::size_t nthreads = context.worker_num + (no_manager ? 0 : 1);
      // Workers (then the manager) are pinned after the 2 dispatchers per I/O thread.
      std::size_t first_cpu = context.cpu_core_id + 2 * context.io_thread_num;
      barrier = std::make_unique<Barrier>(nthreads, first_cpu);
    }
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
    cleanup_batch();

    set_worker_status(ExecutorStatus::Aria_READ);
    return true;
  }

  void local_barrier_start() {
    for (;;) {
      bool running = prepare_local_batch();

      // Wait for batch preparation.
      barrier->wait(id);

      if (!running)
        return;

      // Wait for snapshot reads and reservations.
      barrier->wait(id);

      // Wait for commits.
      barrier->wait(id);
    }
  }

  void coordinator_start() override {
    if (barrier) {
      local_barrier_start();
      return;
    }

    std::size_t n_workers = context.worker_num;
    std::size_t n_coordinators = context.coordinator_num;

    while (!stopFlag.load() && !batches_done()) {

      // the coordinator on each machine first moves the aborted transactions
      // from the last batch earlier to the next batch and set remaining
      // transaction slots to null.

      // then, each worker threads generates a transaction using the same seed.
      epoch.fetch_add(1);
      cleanup_batch();

      // LOG(INFO) << "Seed: " << random.get_seed();
      n_started_workers.store(0);
      n_completed_workers.store(0);
      signal_worker(ExecutorStatus::Aria_READ);
      wait_all_workers_start();
      wait_all_workers_finish();
      broadcast_stop();
      wait4_stop(n_coordinators - 1);
      n_completed_workers.store(0);
      set_worker_status(ExecutorStatus::STOP);
      wait_all_workers_finish();
      // wait for all machines until they finish the Aria_READ phase.
      wait4_ack();

      // Allow each worker to commit transactions
      n_started_workers.store(0);
      n_completed_workers.store(0);
      signal_worker(ExecutorStatus::Aria_COMMIT);
      wait_all_workers_start();
      wait_all_workers_finish();
      broadcast_stop();
      wait4_stop(n_coordinators - 1);
      n_completed_workers.store(0);
      set_worker_status(ExecutorStatus::STOP);
      wait_all_workers_finish();
      // wait for all machines until they finish the Aria_COMMIT phase.
      wait4_ack();
    }

    signal_worker(ExecutorStatus::EXIT);
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

      DCHECK(status == ExecutorStatus::Aria_READ);
      // the coordinator on each machine first moves the aborted transactions
      // from the last batch earlier to the next batch and set remaining
      // transaction slots to null.

      epoch.fetch_add(1);
      cleanup_batch();

      n_started_workers.store(0);
      n_completed_workers.store(0);
      set_worker_status(ExecutorStatus::Aria_READ);
      wait_all_workers_start();
      wait_all_workers_finish();
      broadcast_stop();
      wait4_stop(n_coordinators - 1);
      n_completed_workers.store(0);
      set_worker_status(ExecutorStatus::STOP);
      wait_all_workers_finish();
      send_ack();

      status = wait4_signal();
      DCHECK(status == ExecutorStatus::Aria_COMMIT);
      n_started_workers.store(0);
      n_completed_workers.store(0);
      set_worker_status(ExecutorStatus::Aria_COMMIT);
      wait_all_workers_start();
      wait_all_workers_finish();
      broadcast_stop();
      wait4_stop(n_coordinators - 1);
      n_completed_workers.store(0);
      set_worker_status(ExecutorStatus::STOP);
      wait_all_workers_finish();
      send_ack();
    }
  }

  void cleanup_batch() {
    std::size_t it = 0;
    for (auto i = 0u; i < transactions.size(); i++) {
      if (transactions[i] == nullptr) {
        break;
      }
      if (transactions[i]->abort_lock) {
        transactions[it++].swap(transactions[i]);
      }
    }
    total_abort.store(it);
  }

public:
  RandomType random;
  DatabaseType &db;
  std::atomic<uint32_t> epoch;
  std::vector<StorageType> storages;
  std::vector<std::unique_ptr<TransactionType>> transactions;
  std::atomic<uint32_t> total_abort;
  std::unique_ptr<Barrier> barrier;
  bool no_manager = false;
};
} // namespace aria
