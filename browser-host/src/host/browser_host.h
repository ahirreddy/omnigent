// The omnigent-browser-host process: one CEF instance for one profile, its host.sock server,
// the tab registry and the runner control API (design doc section 5.7).
#pragma once

#include <sys/types.h>

#include <cstdint>
#include <map>
#include <memory>
#include <string>
#include <vector>

#include "core/encoder.h"
#include "core/json.h"
#include "core/options.h"
#include "core/protocol.h"
#include "core/socket_server.h"
#include "core/stream.h"
#include "include/cef_app.h"
#include "include/cef_request_context.h"

namespace rb {

class Tab;

class BrowserHost {
 public:
  static BrowserHost& Get();

  /// The browser process lifecycle; returns the exit code.
  int Run(int argc, char* argv[]);

  // Called from CEF callbacks on the UI thread.
  void OnContextInitialized();
  /// A client for a browser Chromium creates on its own (DevTools Target.createTarget).
  CefRefPtr<CefClient> DefaultClientForNewBrowser();

  // Used by tabs.
  const HostOptions& options() const { return options_; }
  std::unique_ptr<EncoderBackend> MakeEncoder() const;
  StreamConfig stream_config() const;
  void SendText(uint64_t connection, const Json& message);
  void SendBytes(uint64_t connection, std::vector<uint8_t> bytes);
  void CloseConnection(uint64_t connection, uint16_t code, const std::string& reason);
  /// Creates and registers a tab (also for popups). Its browser is created by the caller.
  CefRefPtr<Tab> NewTab(const std::string& session_id, const std::string& created_by,
                        const protocol::Viewport& viewport);
  void OnTabClosed(const std::string& tab_id);
  CefRefPtr<CefRequestContext> request_context() const { return context_; }
  bool shutting_down() const { return shutting_down_; }
  /// Host process tree CPU in cores over the last stats interval.
  double host_cpu_cores() const { return host_cpu_cores_; }
  int cdp_port() const { return cdp_port_; }

  /// Begins an orderly shutdown (closes tabs, then quits the loop).
  void BeginShutdown(const std::string& reason);

 private:
  BrowserHost() = default;

  enum class ConnectionKind { kNew, kAttach, kControl };
  struct Connection {
    ConnectionKind kind = ConnectionKind::kNew;
    std::string tab_id;
  };

  bool Prepare(std::string* error);
  bool StartXvfb(std::string* error);
  bool InitializeCef(int argc, char* argv[], std::string* error);
  void StartServer();
  void OnConnectionOpen(uint64_t connection);
  void OnConnectionFrame(uint64_t connection, Frame frame);
  void OnConnectionClosed(uint64_t connection);
  void HandleRequest(uint64_t connection, const protocol::ControlRequest& request);
  void Respond(uint64_t connection, const std::string& id, Json result);
  void RespondError(uint64_t connection, const std::string& id, const std::string& code,
                    const std::string& message);
  void PeriodicTick();
  void QuitWhenTabsClosed();
  std::string NewTabId() const;
  CefRefPtr<Tab> FindTab(const std::string& tab_id) const;

  HostOptions options_;
  EncoderInfo encoder_;
  std::string shim_library_;
  std::string executable_path_;
  int lock_fd_ = -1;
  int cdp_port_ = 0;
  pid_t xvfb_pid_ = -1;
  int64_t started_at_ = 0;
  bool context_ready_ = false;
  bool shutting_down_ = false;
  bool quit_posted_ = false;
  CefRefPtr<CefRequestContext> context_;
  SocketServer server_;
  std::map<uint64_t, Connection> connections_;
  std::map<std::string, CefRefPtr<Tab>> tabs_;
  int64_t idle_since_ms_ = 0;
  double last_cpu_seconds_ = 0;
  int64_t last_cpu_sample_ms_ = 0;
  double host_cpu_cores_ = 0;
};

}  // namespace rb
