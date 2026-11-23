// Copyright 2026 Ray. Apache-2.0.

#include <atomic>
#include <utility>

#include "base/functional/bind.h"
#include "base/task/thread_pool.h"
#include "base/time/time.h"
#include "base/timer/elapsed_timer.h"
#include "chrome/browser/ray/ac_engine.h"
#include "partition_alloc/buildflags.h"

#if PA_BUILDFLAG(USE_PARTITION_ALLOC)
#include "partition_alloc/memory_reclaimer.h"
#endif

namespace ray {
namespace {

std::atomic_bool g_trim_pending{false};

double ReclaimAllocatorMemory() {
  base::ElapsedTimer timer;
#if PA_BUILDFLAG(USE_PARTITION_ALLOC)
  ::partition_alloc::MemoryReclaimer::Instance()->ReclaimAll();
#endif
  g_trim_pending.store(false);
  return timer.Elapsed().InMillisecondsF();
}

}
}

AC_ARGS_CALL(ac_memory_trim) {
  ray::Reply out = call.TakeReply();
  if (ray::g_trim_pending.exchange(true)) {
    out.Send(base::DictValue().Set("ok", true).Set("coalesced", true));
    return;
  }
  base::ThreadPool::PostTaskAndReplyWithResult(
      FROM_HERE,
      {base::TaskPriority::BEST_EFFORT,
       base::TaskShutdownBehavior::SKIP_ON_SHUTDOWN},
      base::BindOnce(&ray::ReclaimAllocatorMemory),
      base::BindOnce(
          [](ray::Reply out, double ms) {
            out.Send(base::DictValue().Set("ok", true).Set("ms", ms));
          },
          std::move(out)));
}
