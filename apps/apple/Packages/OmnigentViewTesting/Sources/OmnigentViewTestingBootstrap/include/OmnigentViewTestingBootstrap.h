#ifndef OMNIGENT_VIEW_TESTING_BOOTSTRAP_H
#define OMNIGENT_VIEW_TESTING_BOOTSTRAP_H

#include <stdint.h>

// Whether the runner loop shield was requested as the test bundle loaded.
int omnigent_view_testing_shield_requested(void);

// Notes when each `Task.sleep` ends, and counts main actor jobs, from now on; the bundle's
// load calls it.
void omnigent_view_testing_install_sleep_hooks(void);

// The clock sleep ends are kept in, in nanoseconds.
uint64_t omnigent_view_testing_now_ns(void);

// Whether a `Task.sleep` noted ends after `after` and before `before`, in that clock.
int omnigent_view_testing_sleep_ends_between(uint64_t after, uint64_t before);

// How many jobs have been queued for the main actor so far.
unsigned long omnigent_view_testing_main_actor_jobs(void);

#endif
