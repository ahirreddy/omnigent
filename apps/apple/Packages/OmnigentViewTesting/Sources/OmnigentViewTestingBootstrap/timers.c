#include "OmnigentViewTestingBootstrap.h"

#include <TargetConditionals.h>

#if TARGET_OS_OSX
#include <errno.h>
#include <mach/mach.h>
#include <mach/task_policy.h>
#include <pthread/qos.h>
#include <stdio.h>
#include <string.h>
#include <sys/resource.h>

// A test process launched by a background service (a VM's guest agent, a CI runner) inherits its
// background policy, under which the kernel coalesces timers by tens of milliseconds: a 5 ms
// sleep takes 40. This gives the process a foreground app's timers. Each step that fails is
// reported, and the rest still run.
int omnigent_view_testing_foreground_timers(void) {
  int failures = 0;
  if (setpriority(PRIO_DARWIN_PROCESS, 0, 0) != 0) {
    fprintf(stderr, "omnigent tests: leaving the background policy failed: %s\n", strerror(errno));
    failures++;
  }
  task_category_policy_data_t category = {.role = TASK_FOREGROUND_APPLICATION};
  kern_return_t result = task_policy_set(mach_task_self(), TASK_CATEGORY_POLICY,
                                         (task_policy_t)&category, TASK_CATEGORY_POLICY_COUNT);
  if (result != KERN_SUCCESS) {
    fprintf(stderr, "omnigent tests: the foreground role was refused: %d\n", result);
    failures++;
  }
  struct task_qos_policy qos = {.task_latency_qos_tier = LATENCY_QOS_TIER_0,
                                .task_throughput_qos_tier = THROUGHPUT_QOS_TIER_0};
  result = task_policy_set(mach_task_self(), TASK_BASE_LATENCY_QOS_POLICY, (task_policy_t)&qos,
                           TASK_QOS_POLICY_COUNT);
  if (result != KERN_SUCCESS) {
    fprintf(stderr, "omnigent tests: the latency tier was refused: %d\n", result);
    failures++;
  }
  int qos_result = pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
  if (qos_result != 0) {
    fprintf(stderr, "omnigent tests: the main thread's QoS was refused: %s\n",
            strerror(qos_result));
    failures++;
  }
  return failures;
}
#endif
