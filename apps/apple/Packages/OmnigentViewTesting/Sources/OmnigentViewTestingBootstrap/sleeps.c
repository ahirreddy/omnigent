#include "OmnigentViewTestingBootstrap.h"

#include <TargetConditionals.h>
#include <os/lock.h>
#include <stdint.h>
#include <time.h>

// Notes when each `Task.sleep` in the process ends, through the Swift runtime's enqueue hooks,
// so a test's wait can tell work still to come from a process at rest.

typedef void *SwiftJob;
typedef __attribute__((swiftcall)) void (*DeadlineOriginal)(
    long long, long long, long long, long long, int, SwiftJob);
typedef __attribute__((swiftcall)) void (*DelayOriginal)(unsigned long long, SwiftJob);

extern __attribute__((swiftcall, weak_import)) void (*swift_task_enqueueGlobalWithDeadline_hook)(
    long long, long long, long long, long long, int, SwiftJob, DeadlineOriginal);
extern __attribute__((swiftcall, weak_import)) void (*swift_task_enqueueGlobalWithDelay_hook)(
    unsigned long long, SwiftJob, DelayOriginal);
extern __attribute__((swiftcall, weak_import)) void swift_get_time(
    long long *seconds, long long *nanoseconds, int clock);

enum { slot_count = 512 };
static uint64_t sleep_ends[slot_count];
static int sleep_end_count = 0;
static os_unfair_lock sleep_lock = OS_UNFAIR_LOCK_INIT;
static int hooks_installed = 0;

uint64_t omnigent_view_testing_now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

// Keeps an end time, first dropping those passed; when full, the soonest end gives way.
static void note_sleep_end(uint64_t end) {
  uint64_t now = omnigent_view_testing_now_ns();
  os_unfair_lock_lock(&sleep_lock);
  int kept = 0;
  for (int index = 0; index < sleep_end_count; index++) {
    if (sleep_ends[index] > now) sleep_ends[kept++] = sleep_ends[index];
  }
  sleep_end_count = kept;
  if (sleep_end_count < slot_count) {
    sleep_ends[sleep_end_count++] = end;
  } else {
    int soonest = 0;
    for (int index = 1; index < slot_count; index++) {
      if (sleep_ends[index] < sleep_ends[soonest]) soonest = index;
    }
    sleep_ends[soonest] = end;
  }
  os_unfair_lock_unlock(&sleep_lock);
}

static __attribute__((swiftcall)) void on_deadline(
    long long seconds, long long nanoseconds, long long tolerance_seconds,
    long long tolerance_nanoseconds, int clock, SwiftJob job, DeadlineOriginal original) {
  if (swift_get_time) {
    long long now_seconds = 0, now_nanoseconds = 0;
    swift_get_time(&now_seconds, &now_nanoseconds, clock);
    long long remaining =
        (seconds - now_seconds) * 1000000000LL + (nanoseconds - now_nanoseconds);
    if (remaining > 0) note_sleep_end(omnigent_view_testing_now_ns() + (uint64_t)remaining);
  }
  original(seconds, nanoseconds, tolerance_seconds, tolerance_nanoseconds, clock, job);
}

static __attribute__((swiftcall)) void on_delay(
    unsigned long long delay, SwiftJob job, DelayOriginal original) {
  if (delay > 0) note_sleep_end(omnigent_view_testing_now_ns() + delay);
  original(delay, job);
}

void omnigent_view_testing_install_sleep_hooks(void) {
  if (hooks_installed) return;
  hooks_installed = 1;
  if (&swift_task_enqueueGlobalWithDeadline_hook && !swift_task_enqueueGlobalWithDeadline_hook) {
    swift_task_enqueueGlobalWithDeadline_hook = on_deadline;
  }
  if (&swift_task_enqueueGlobalWithDelay_hook && !swift_task_enqueueGlobalWithDelay_hook) {
    swift_task_enqueueGlobalWithDelay_hook = on_delay;
  }
}

int omnigent_view_testing_sleep_ends_between(uint64_t after, uint64_t before) {
  int found = 0;
  os_unfair_lock_lock(&sleep_lock);
  for (int index = 0; index < sleep_end_count && !found; index++) {
    found = sleep_ends[index] > after && sleep_ends[index] < before;
  }
  os_unfair_lock_unlock(&sleep_lock);
  return found;
}
