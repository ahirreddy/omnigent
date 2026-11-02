// One remote tab: a windowless CEF browser, its FrameSink and TabStreamer, its navigation,
// cursor, text-input, control and dialog state, and the attach connections viewing it.
// Everything here runs on the CEF UI thread except the MediaSender methods.
#pragma once

#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "core/frame_sink.h"
#include "core/json.h"
#include "core/protocol.h"
#include "core/stream.h"
#include "include/cef_client.h"
#include "include/cef_devtools_message_observer.h"

namespace rb {

class BrowserHost;

class Tab : public CefClient,
            public CefRenderHandler,
            public CefDisplayHandler,
            public CefLoadHandler,
            public CefLifeSpanHandler,
            public CefRequestHandler,
            public CefJSDialogHandler,
            public CefDialogHandler,
            public CefDevToolsMessageObserver,
            public MediaSender {
 public:
  Tab(BrowserHost* host, std::string id, std::string session_id, std::string created_by,
      protocol::Viewport viewport);
  ~Tab() override;

  const std::string& id() const { return id_; }
  const std::string& session_id() const { return session_id_; }
  protocol::TabRecord Record() const;
  bool has_browser() const { return browser_ != nullptr; }
  bool target_known() const { return !target_id_.empty(); }
  /// Runs once the CDP target id is known (or immediately if it is).
  void WhenTargetKnown(std::function<void()> callback);

  /// Starts the CEF browser. False when CEF refused.
  bool Create(const std::string& url, CefRefPtr<CefRequestContext> context);
  /// Marks a browser Chromium creates for this client (popups, DevTools targets).
  void ExpectBrowser() { browser_requested_ = true; }
  void Navigate(const std::string& url);
  /// Closes the browser; viewers get tab_closed (`reason`) and close 4404.
  void Close(const std::string& reason);
  bool closing() const { return closing_; }

  // Attach connections.
  void Attach(uint64_t connection, const std::string& mode);
  void OnClientMessage(uint64_t connection, const Json& message);
  void Detach(uint64_t connection);
  size_t viewer_count() const { return viewers_.size(); }

  // Benchmarks.
  bool StartRecording(const std::string& path, int max_frames, std::string* error);
  int StopRecording();
  TabStreamer* streamer() { return streamer_.get(); }

  // MediaSender (streamer threads).
  void SendMedia(uint64_t connection, std::vector<uint8_t> message) override;
  void CloseStalled(uint64_t connection) override;
  void Log(const std::string& message) override;
  void ReportError(const std::string& code, const std::string& message) override;

  // CefClient
  CefRefPtr<CefRenderHandler> GetRenderHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }
  CefRefPtr<CefJSDialogHandler> GetJSDialogHandler() override { return this; }
  CefRefPtr<CefDialogHandler> GetDialogHandler() override { return this; }

  // CefRenderHandler
  void GetViewRect(CefRefPtr<CefBrowser> browser, CefRect& rect) override;
  bool GetScreenInfo(CefRefPtr<CefBrowser> browser, CefScreenInfo& screen_info) override;
  void OnPopupShow(CefRefPtr<CefBrowser> browser, bool show) override;
  void OnPopupSize(CefRefPtr<CefBrowser> browser, const CefRect& rect) override;
  void OnPaint(CefRefPtr<CefBrowser> browser, PaintElementType type, const RectList& dirty_rects,
               const void* buffer, int width, int height) override;
  void OnImeCompositionRangeChanged(CefRefPtr<CefBrowser> browser, const CefRange& selected_range,
                                    const RectList& character_bounds) override;
  void OnScrollOffsetChanged(CefRefPtr<CefBrowser> browser, double x, double y) override;
  void OnTextSelectionChanged(CefRefPtr<CefBrowser> browser, const CefString& selected_text,
                              const CefRange& selected_range) override;
  void OnVirtualKeyboardRequested(CefRefPtr<CefBrowser> browser, TextInputMode input_mode) override;

  // CefDisplayHandler
  void OnAddressChange(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                       const CefString& url) override;
  void OnTitleChange(CefRefPtr<CefBrowser> browser, const CefString& title) override;
  void OnFaviconURLChange(CefRefPtr<CefBrowser> browser,
                          const std::vector<CefString>& icon_urls) override;
  void OnLoadingProgressChange(CefRefPtr<CefBrowser> browser, double progress) override;
  bool OnCursorChange(CefRefPtr<CefBrowser> browser, CefCursorHandle cursor, cef_cursor_type_t type,
                      const CefCursorInfo& custom_cursor_info) override;

  // CefLoadHandler
  void OnLoadingStateChange(CefRefPtr<CefBrowser> browser, bool is_loading, bool can_go_back,
                            bool can_go_forward) override;
  void OnLoadError(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, ErrorCode error_code,
                   const CefString& error_text, const CefString& failed_url) override;

  // CefLifeSpanHandler
  bool OnBeforePopup(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, int popup_id,
                     const CefString& target_url, const CefString& target_frame_name,
                     cef_window_open_disposition_t target_disposition, bool user_gesture,
                     const CefPopupFeatures& popup_features, CefWindowInfo& window_info,
                     CefRefPtr<CefClient>& client, CefBrowserSettings& settings,
                     CefRefPtr<CefDictionaryValue>& extra_info,
                     bool* no_javascript_access) override;
  void OnBeforePopupAborted(CefRefPtr<CefBrowser> browser, int popup_id) override;
  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override;
  bool DoClose(CefRefPtr<CefBrowser> browser) override;
  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override;

  // CefRequestHandler
  void OnRenderProcessTerminated(CefRefPtr<CefBrowser> browser, TerminationStatus status,
                                 int error_code, const CefString& error_string) override;
  bool OnOpenURLFromTab(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                        const CefString& target_url,
                        cef_window_open_disposition_t target_disposition,
                        bool user_gesture) override;

  // CefJSDialogHandler
  bool OnJSDialog(CefRefPtr<CefBrowser> browser, const CefString& origin_url,
                  JSDialogType dialog_type, const CefString& message_text,
                  const CefString& default_prompt_text, CefRefPtr<CefJSDialogCallback> callback,
                  bool& suppress_message) override;
  bool OnBeforeUnloadDialog(CefRefPtr<CefBrowser> browser, const CefString& message_text,
                            bool is_reload, CefRefPtr<CefJSDialogCallback> callback) override;
  void OnResetDialogState(CefRefPtr<CefBrowser> browser) override;

  // CefDialogHandler
  bool OnFileDialog(CefRefPtr<CefBrowser> browser, FileDialogMode mode, const CefString& title,
                    const CefString& default_file_path,
                    const std::vector<CefString>& accept_filters,
                    const std::vector<CefString>& accept_extensions,
                    const std::vector<CefString>& accept_descriptions,
                    CefRefPtr<CefFileDialogCallback> callback) override;

  // CefDevToolsMessageObserver
  void OnDevToolsMethodResult(CefRefPtr<CefBrowser> browser, int message_id, bool success,
                              const void* result, size_t result_size) override;

  /// Windowless browser settings shared by tabs and popups.
  static void ConfigureWindowless(CefWindowInfo* window_info, CefBrowserSettings* settings);

 private:
  struct Viewer {
    std::string mode;  // view | control
    bool hello = false;
    bool stats = false;
    // Protocol v1.1 reports this connection asked for in its hello.
    bool wants_selection = false;
    bool wants_scroll = false;
    std::map<std::string, uint64_t> last_refusal_us;
  };
  /// Rate limit for a report that needs an asynchronous DevTools round trip: at most one per
  /// interval and one in flight; a change while one is in flight runs another after it.
  struct ReportThrottle {
    uint64_t last_us = 0;
    bool scheduled = false;
    bool in_flight = false;
    bool dirty = false;
  };
  using DevToolsCallback = std::function<void(bool ok, const Json& result)>;
  struct OpenDialog {
    protocol::Dialog dialog;
    CefRefPtr<CefJSDialogCallback> callback;
  };

  void Send(uint64_t connection, const Json& message);
  void Broadcast(const Json& message);
  void SendError(uint64_t connection, const std::string& code, const std::string& message,
                 bool fatal);
  /// Answers a refused message with a rate-limited non-fatal error (section 5.4).
  void Refuse(uint64_t connection, Viewer* viewer, const std::string& type, const std::string& code,
              const std::string& message);
  void HandleHello(uint64_t connection, Viewer* viewer, const protocol::ClientMessage& hello);
  void HandleSettings(uint64_t connection, Viewer* viewer, const protocol::ClientMessage& message);
  void HandleControl(uint64_t connection, Viewer* viewer, const protocol::ClientMessage& message);
  void InjectMouse(const protocol::ClientMessage& message);
  /// Delivers input held back until the first paint (see OnPaint).
  void FlushPendingInput();
  void InjectKey(const protocol::ClientMessage& message);
  void InjectIme(const protocol::ClientMessage& message);
  void HandleNav(uint64_t connection, const protocol::ClientMessage& message);
  void HandleResize(uint64_t connection, const protocol::ClientMessage& message);
  void HandleDialogReply(uint64_t connection, const protocol::ClientMessage& message);
  void DispatchInput(const protocol::ClientMessage& message);

  // Protocol v1.1 (design doc section 16), in tab_v11.cc.
  void InjectTouch(const protocol::ClientMessage& message);
  void HandleEdit(uint64_t connection, const protocol::ClientMessage& message);
  void FinishCopy(uint64_t connection, const std::string& op, bool ok, const Json& result);
  /// Applies a viewport, its scope and emulation; a no-op when nothing changes.
  void SetViewport(const protocol::Viewport& viewport, const std::string& scope,
                   const std::string& mobile);
  /// Drops the holder's viewport and emulation and returns to the agent's viewport.
  void RestoreAgentViewport();
  protocol::ViewportState CurrentViewport() const;
  void ApplyEmulation(const std::string& mobile);
  /// Sends a DevTools method on this tab's own session; `done` gets the result or the error.
  void CallDevTools(const std::string& method, Json params, DevToolsCallback done);
  /// Evaluates `expression` in the main frame and passes `done` its value (by value).
  void Evaluate(const std::string& expression, DevToolsCallback done);
  DevToolsCallback ReportFailure(const std::string& what);
  bool AnyViewer(bool Viewer::* wants) const;
  void ScheduleReport(ReportThrottle* throttle, uint64_t interval_us, void (Tab::*send)());
  void SendSelectionReport();
  void SendScrollReport();
  void FinishReport(ReportThrottle* throttle, uint64_t interval_us, void (Tab::*send)());
  void ScheduleSelectionReport();
  void ScheduleScrollReport();
  /// Sends the cached reports a v1.1 viewer asked for after its setup messages.
  void SendInitialReports(uint64_t connection, const Viewer& viewer);
  protocol::ControlState ControlFor(uint64_t connection) const;
  void BroadcastControl(const std::string& reason);
  void SetOwner(const std::string& owner, uint64_t holder, const std::string& reason);
  void UpdateFrameRate();
  void BroadcastNav();
  void SendStatsTick(uint64_t generation);
  void CloseViewer(uint64_t connection, uint16_t code, const std::string& reason);

  BrowserHost* const host_;
  const std::string id_;
  const std::string session_id_;
  const std::string created_by_;
  protocol::Viewport viewport_;
  // The agent's viewport (section 16.2); `viewport_` differs while scope is "control".
  protocol::Viewport agent_viewport_;
  std::string viewport_scope_ = "tab";
  std::string mobile_ = "off";
  /// The connection whose control-scoped viewport is applied; 0 while it is orphaned (its
  /// holder left during the grace period) or scope is "tab".
  uint64_t viewport_holder_ = 0;
  int next_devtools_id_ = 100;
  std::map<int, DevToolsCallback> devtools_calls_;
  std::string selected_text_;
  std::optional<protocol::SelectionState> selection_;
  std::optional<protocol::ScrollMetrics> scroll_;
  /// The latest root scroll offset from CEF, in device pixels.
  std::optional<std::pair<double, double>> scroll_offset_;
  ReportThrottle selection_throttle_;
  ReportThrottle scroll_throttle_;
  CefRefPtr<CefBrowser> browser_;
  CefRefPtr<CefRegistration> devtools_registration_;
  std::string target_id_;
  int target_info_message_ = 0;
  std::vector<std::function<void()>> target_waiters_;
  bool closing_ = false;
  bool browser_requested_ = false;
  std::string close_reason_ = "closed";
  bool focused_ = false;
  // Chromium drops input that reaches a renderer before its first compositor frame (no
  // hit-test data yet), so input waits for the tab's first paint.
  bool painted_ = false;
  std::vector<protocol::ClientMessage> pending_input_;
  /// CEF button flags of the mouse buttons currently held (from down and up events).
  uint32_t pressed_buttons_ = 0;

  FrameSink sink_;
  std::unique_ptr<TabStreamer> streamer_;
  protocol::Settings settings_;

  protocol::NavState nav_;
  protocol::CursorState cursor_;
  protocol::TextInputState text_input_;
  std::string owner_ = "agent";
  uint64_t holder_ = 0;
  uint64_t grace_generation_ = 0;
  std::map<std::string, OpenDialog> dialogs_;
  uint64_t next_dialog_ = 0;
  uint64_t stats_generation_ = 0;
  std::map<uint64_t, Viewer> viewers_;
  std::map<int, std::string> pending_popups_;  // CEF popup_id -> tab id

  IMPLEMENT_REFCOUNTING(Tab);
};

}  // namespace rb
