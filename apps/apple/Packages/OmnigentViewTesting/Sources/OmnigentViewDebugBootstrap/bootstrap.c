#include "OmnigentViewDebugBootstrap.h"

#include <stdlib.h>

// SwiftUI reads this once, at the process's first view, so it is set as the test bundle loads.
// 3 asks for each view's type and value; an existing setting wins.
__attribute__((constructor)) static void omnigent_view_debug_bootstrap(void) {
  setenv("SWIFTUI_VIEW_DEBUG", "3", 0);
}

int omnigent_view_debug_is_enabled(void) { return getenv("SWIFTUI_VIEW_DEBUG") != NULL; }
