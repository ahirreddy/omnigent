// Entry point of the omnigent-browser-host Helper bundles (GPU, Renderer, Plugin, Alerts).
#include <cstdio>

#include "include/cef_app.h"
#include "include/cef_sandbox_mac.h"
#include "include/wrapper/cef_library_loader.h"

int main(int argc, char* argv[]) {
  CefScopedSandboxContext sandbox_context;
  if (!sandbox_context.Initialize(argc, argv)) {
    std::fprintf(stderr, "omnigent-browser-host helper: cannot initialize the sandbox\n");
    return 1;
  }
  CefScopedLibraryLoader library_loader;
  if (!library_loader.LoadInHelper()) {
    std::fprintf(stderr, "omnigent-browser-host helper: cannot load Chromium Embedded Framework\n");
    return 1;
  }
  CefMainArgs main_args(argc, argv);
  return CefExecuteProcess(main_args, nullptr, nullptr);
}
