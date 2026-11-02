// Linux entry point: the same executable runs the browser process and every CEF subprocess.
#include "host/browser_host.h"
#include "host/host_app.h"

int main(int argc, char* argv[]) {
  CefMainArgs main_args(argc, argv);
  // Subprocesses get their switches from the browser process; the app only matters there.
  const int exit_code = CefExecuteProcess(main_args, nullptr, nullptr);
  if (exit_code >= 0) {
    return exit_code;
  }
  return rb::BrowserHost::Get().Run(argc, argv);
}
