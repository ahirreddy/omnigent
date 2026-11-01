// Entry point shared by the web host's CEF helper bundles: "Omnigent Web Host Helper" and its
// (GPU), (Renderer), (Plugin) and (Alerts) variants, all in the host's Contents/Frameworks.
#include <cstdio>

#include "include/cef_app.h"
#include "include/cef_sandbox_mac.h"
#include "include/wrapper/cef_library_loader.h"

int main(int argc, char* argv[]) {
  CefScopedSandboxContext sandbox_context;
  if (!sandbox_context.Initialize(argc, argv)) {
    std::fprintf(stderr, "owl-helper: failed to initialize the Chromium sandbox\n");
    return 1;
  }
  CefScopedLibraryLoader library_loader;
  if (!library_loader.LoadInHelper()) {
    std::fprintf(stderr, "owl-helper: failed to load Chromium Embedded Framework\n");
    return 1;
  }
  CefMainArgs main_args(argc, argv);
  return CefExecuteProcess(main_args, nullptr, nullptr);
}
