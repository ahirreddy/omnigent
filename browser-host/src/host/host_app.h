// CefApp for every omnigent-browser-host process: browser-process switches and the hooks that
// route CEF lifecycle events to BrowserHost.
#pragma once

#include <string>

#include "include/cef_app.h"

namespace rb {

struct AppSwitches {
  std::string ozone_platform;  // headless | x11 | empty (macOS)
  bool no_sandbox = false;
};

class HostApp : public CefApp, public CefBrowserProcessHandler {
 public:
  explicit HostApp(AppSwitches switches) : switches_(std::move(switches)) {}

  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override { return this; }
  void OnBeforeCommandLineProcessing(const CefString& process_type,
                                     CefRefPtr<CefCommandLine> command_line) override;
  void OnContextInitialized() override;
  CefRefPtr<CefClient> GetDefaultClient() override;

 private:
  AppSwitches switches_;
  IMPLEMENT_REFCOUNTING(HostApp);
};

}  // namespace rb
