#include "OmnigentViewTestingBootstrap.h"

// Written in Swift, in OmnigentViewTesting.
extern void omnigent_view_testing_install_runner_loop_shield(void);
extern void omnigent_view_testing_clear_earlier_settings(void);

static int shield_requested = 0;

// A stop can arrive as a test's body returns, so the shield must be up before the first test.
__attribute__((constructor)) static void omnigent_view_testing_bootstrap(void) {
  shield_requested = 1;
  omnigent_view_testing_install_runner_loop_shield();
  omnigent_view_testing_clear_earlier_settings();
}

int omnigent_view_testing_shield_requested(void) { return shield_requested; }
