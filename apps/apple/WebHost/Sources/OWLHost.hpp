// The web host process: owns CEF, serves one client over an owl_channel, and exits when the
// client asks or disappears. See DESIGN.md, "Process model".
#pragma once

#include <mach/mach.h>
#include <sys/types.h>

#include <cstdint>
#include <map>
#include <string>

#include "OWLWire.hpp"
#include "include/cef_base.h"
#include "include/cef_request_context.h"
#include "owl_channel.h"
#include "owl_protocol.h"

namespace owl {

class BrowserClient;

struct HostOptions {
  std::string service;
  std::string token;
  pid_t parent_pid = 0;
  /// Serve DevTools to the client over fds 3 (commands in) and 4 (replies out), never a port.
  bool devtools_pipe = false;
};

struct SessionConfig {
  std::string root_cache_path;
  std::string locale;
  std::string keychain_service;
  int remote_debugging_port = 0;
  bool use_mock_keychain = false;
  bool disable_sandbox = false;
  OWLRenderMode render_mode = OWLRenderModeRemoteLayer;
  /// The client's protocol minor from HelloAck; 0 for 1.0 clients.
  uint64_t client_minor = 0;
};

/// The rate pages draw at, in frames a second: that of the fastest display attached (120 on a
/// 120 Hz screen), and at least 60.
int DisplayFrameRate();

/// While alive, `[NSApp currentEvent]` is a fresh event that happened at `event_time` (seconds
/// of system uptime). CEF stamps the input it is handed with the current event's time, and the
/// host's own current event is nil or left over from minutes ago.
class ScopedInputEvent {
 public:
  explicit ScopedInputEvent(double event_time);
  ~ScopedInputEvent();
  ScopedInputEvent(const ScopedInputEvent&) = delete;
  ScopedInputEvent& operator=(const ScopedInputEvent&) = delete;

  /// False when the event could not be made current; the input must not reach CEF then.
  bool IsInstalled() const { return installed_; }

 private:
  bool installed_ = false;
};

class Host {
 public:
  static Host& Get();

  /// Runs the whole host lifecycle and returns the process exit code.
  int Run(int argc, char* argv[]);

  void Send(OWLMessageKind kind, uint64_t request, uint64_t target, const Encoder& payload,
            mach_port_t port = MACH_PORT_NULL,
            mach_msg_type_name_t disposition = MACH_MSG_TYPE_COPY_SEND);
  void ReportError(uint64_t target, OWLHostErrorCode code, const std::string& message);

  const SessionConfig& config() const { return config_; }

  void OnContextInitialized();
  void OnBrowserClosed(uint64_t view_id);
  /// A fresh ID for a view the host creates itself (popups). Host IDs start at 2^48 so they
  /// never collide with the client's counter.
  uint64_t AllocateHostViewID();
  /// Registers a popup view created by CEF on the host's initiative.
  void AdoptView(uint64_t view_id, CefRefPtr<BrowserClient> client);
  /// Drops a popup view whose creation was aborted before OnAfterCreated.
  void AbandonView(uint64_t view_id);
  bool IsShuttingDown() const { return shutting_down_; }
  /// Asks a view's renderer whether it is alive, for the freeze watch. Main thread.
  void ProbeView(uint64_t view_id, bool quiet, uint64_t frames_after_nanos);
  /// Closes every browser, then quits the CEF loop. A watchdog force-exits if that stalls.
  void BeginShutdown(const char* reason);

  void OnChannelMessage(owl_message* message);
  void OnChannelEvent(owl_channel_event event, int64_t detail);

 private:
  Host() = default;

  bool ParseOptions(int argc, char* argv[]);
  bool Connect();
  bool WaitForAck();
  bool InitializeCef(int argc, char* argv[]);
  void HandleHelloAck(const Decoder& fields);
  void HandleSessionMessage(owl_message* message, const Decoder& fields);
  void HandleProfileMessage(owl_message* message, const Decoder& fields);
  void HandleViewMessage(owl_message* message, const Decoder& fields);
  void CreateView(uint64_t view_id, const Decoder& fields);
  void QuitLoop();

  HostOptions options_;
  SessionConfig config_;
  owl_channel* channel_ = nullptr;
  uint64_t start_nanos_ = 0;
  bool ack_received_ = false;
  bool ack_accepted_ = false;
  bool cef_initialized_ = false;
  bool context_ready_ = false;
  bool shutting_down_ = false;
  bool quit_posted_ = false;
  uint64_t next_host_view_id_ = uint64_t{1} << 48;
  std::map<uint64_t, CefRefPtr<CefRequestContext>> profiles_;
  std::map<uint64_t, CefRefPtr<BrowserClient>> views_;
};

}  // namespace owl
