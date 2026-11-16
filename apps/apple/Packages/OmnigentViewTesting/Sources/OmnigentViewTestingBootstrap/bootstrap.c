#include "OmnigentViewTestingBootstrap.h"

#include <TargetConditionals.h>

// Written in Swift, in OmnigentViewTesting.
#if TARGET_OS_OSX
extern void omnigent_view_testing_install_runner_loop_shield(void);
extern void omnigent_view_testing_clear_earlier_settings(void);
extern void omnigent_view_testing_apply_environment_defaults(void);
extern void omnigent_view_testing_overlay_scroll_bars(void);
extern void omnigent_view_testing_quiet_motion(void);
extern void omnigent_view_testing_track_pauses(void);
#endif

static int shield_requested = 0;

// A stop can arrive as a test's body returns, so the shield must be up before the first test.
// Only AppKit's window server events stop the runner's loop, so iOS needs none of this.
__attribute__((constructor)) static void omnigent_view_testing_bootstrap(void) {
#if TARGET_OS_OSX
  shield_requested = 1;
  omnigent_view_testing_install_runner_loop_shield();
  omnigent_view_testing_clear_earlier_settings();
  omnigent_view_testing_apply_environment_defaults();
  omnigent_view_testing_overlay_scroll_bars();
  omnigent_view_testing_quiet_motion();
  omnigent_view_testing_track_pauses();
#endif
}

int omnigent_view_testing_shield_requested(void) { return shield_requested; }
