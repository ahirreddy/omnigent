// Main-thread hitch monitor for profiling a Debug build: inject with
// DYLD_INSERT_LIBRARIES=hitch-monitor.dylib OMNIGENT_HITCH_LOG=<file>. A background thread
// pings the main queue every 4 ms and appends each ping that waited 12 ms or more as
// "<unix ms> <wait ms>" to the log, "# stalled <unix ms>" while a long one lasts and
// "# alive <unix ms>" every 250 ms; perf.py turns a time window of it into hitch counts.
#include <dispatch/dispatch.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

static FILE *hitch_log;

static double now_ms(void) {
  struct timespec spec;
  clock_gettime(CLOCK_MONOTONIC_RAW, &spec);
  return spec.tv_sec * 1000.0 + spec.tv_nsec / 1e6;
}

static double wall_ms(void) {
  struct timeval value;
  gettimeofday(&value, NULL);
  return value.tv_sec * 1000.0 + value.tv_usec / 1000.0;
}

static void pong(void *context) { dispatch_semaphore_signal((dispatch_semaphore_t)context); }

static void *watch(void *unused) {
  (void)unused;
  dispatch_semaphore_t answered = dispatch_semaphore_create(0);
  double beat = 0;
  for (;;) {
    double sent = now_ms();
    dispatch_async_f(dispatch_get_main_queue(), answered, pong);
    // A long stall is marked while it lasts, so a reader can tell busy from quiet.
    if (dispatch_semaphore_wait(answered, dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC))) {
      fprintf(hitch_log, "# stalled %.0f\n", wall_ms() - (now_ms() - sent));
      fflush(hitch_log);
      dispatch_semaphore_wait(answered, DISPATCH_TIME_FOREVER);
    }
    double waited = now_ms() - sent;
    if (waited >= 12.0) {
      fprintf(hitch_log, "%.0f %.1f\n", wall_ms() - waited, waited);
      fflush(hitch_log);
    }
    if (now_ms() - beat >= 250) {
      beat = now_ms();
      fprintf(hitch_log, "# alive %.0f\n", wall_ms());
      fflush(hitch_log);
    }
    usleep(4000);
  }
  return NULL;
}

__attribute__((constructor)) static void start_hitch_monitor(void) {
  const char *path = getenv("OMNIGENT_HITCH_LOG");
  if (path == NULL) return;
  hitch_log = fopen(path, "a");
  if (hitch_log == NULL) return;
  fprintf(hitch_log, "# start %.0f\n", wall_ms());
  fflush(hitch_log);
  pthread_t thread;
  pthread_create(&thread, NULL, watch, NULL);
  pthread_detach(thread);
}
