#include "host/host_app.h"

#include "host/browser_host.h"

namespace rb {

void HostApp::OnBeforeCommandLineProcessing(const CefString& process_type,
                                            CefRefPtr<CefCommandLine> command_line) {
  if (!process_type.empty()) {
    return;  // Subprocesses inherit the browser process's switches.
  }
  // CPU OnPaint path: no GPU process work, software compositing (design doc section 11).
  command_line->AppendSwitch("disable-gpu");
  command_line->AppendSwitch("disable-gpu-compositing");
  command_line->AppendSwitch("mute-audio");
  command_line->AppendSwitch("disable-chrome-login-prompt");
  command_line->AppendSwitch("no-first-run");
  command_line->AppendSwitch("no-default-browser-check");
  // An agent browser has no use for Chrome's component downloads (CRLSets excepted, which
  // Chromium fetches on its own schedule regardless).
  command_line->AppendSwitch("disable-component-update");
  if (!switches_.ozone_platform.empty()) {
    command_line->AppendSwitchWithValue("ozone-platform", switches_.ozone_platform);
  }
#if defined(__APPLE__)
  command_line->AppendSwitch("use-mock-keychain");
  command_line->AppendSwitchWithValue("disable-features", "MacAppCodeSignClone");
#else
  // Headless machines have no keyring; Chromium would otherwise block on one.
  command_line->AppendSwitchWithValue("password-store", "basic");
#endif
  if (switches_.no_sandbox) {
    command_line->AppendSwitch("no-sandbox");
  }
}

void HostApp::OnContextInitialized() { BrowserHost::Get().OnContextInitialized(); }

CefRefPtr<CefClient> HostApp::GetDefaultClient() {
  return BrowserHost::Get().DefaultClientForNewBrowser();
}

}  // namespace rb
