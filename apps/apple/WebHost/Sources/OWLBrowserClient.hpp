// One windowless CEF browser per client WebView. Translates CEF callbacks into OWL events and
// OWL commands into CEF calls.
#pragma once

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <deque>
#include <map>
#include <memory>
#include <string>
#include <vector>

#include "OWLNavigationRules.hpp"
#include "OWLPresenter.hpp"
#include "OWLWire.hpp"
#include "include/cef_client.h"
#include "include/cef_devtools_message_observer.h"

namespace owl {

class BrowserClient : public CefClient,
                      public CefRenderHandler,
                      public CefDisplayHandler,
                      public CefLoadHandler,
                      public CefLifeSpanHandler,
                      public CefRequestHandler,
                      public CefDownloadHandler,
                      public CefFindHandler,
                      public CefKeyboardHandler,
                      public CefJSDialogHandler,
                      public CefDialogHandler,
                      public CefPermissionHandler,
                      public CefContextMenuHandler,
                      public CefDevToolsMessageObserver {
 public:
  BrowserClient(uint64_t view_id, double width, double height, double scale, bool visible);

  bool StartPresenter(std::string* error);
  bool HasBrowser() const { return browser_ != nullptr; }
  void Close();

  // Commands from the client.
  void Navigate(const std::string& url);
  void GoBack();
  void GoForward();
  void Reload();
  void Stop();
  void Resize(double width, double height, double scale, double screen_x, double screen_y);
  void SetVisible(bool visible);
  void SetFocused(bool focused);
  void SetZoom(double level);
  void Evaluate(uint64_t request, const std::string& script);
  void DevToolsMethod(uint64_t request, const std::string& method, const std::string& params);
  void Snapshot(uint64_t request);
  void Find(const std::string& text, bool forward, bool match_case, bool find_next);
  void StopFind();
  void ShowDevTools();
  void InputMouse(const Decoder& fields);
  void InputKey(const Decoder& fields);
  void AcknowledgeFrame(uint32_t surface_id) { presenter_.AcknowledgeFrame(surface_id); }

  // 1.1 commands: replies to host requests, policies, IME and drag and drop
  // (OWLBrowserPrompts.mm, OWLBrowserPopups.mm, OWLBrowserInput.mm).
  /// Whether `kind` is a 1.1 view command this class handles.
  static bool IsBrowserUICommand(uint16_t kind);
  void HandleBrowserUICommand(uint16_t kind, const Decoder& fields);
  /// Popups only: the view that opened this one.
  void SetOpener(uint64_t opener_id) { opener_id_ = opener_id; }
  /// Applies the PopupPolicy and Rules fields of ViewCreate before the first navigation.
  void ApplyInitialPolicies(const Decoder& fields);

  // CefClient
  CefRefPtr<CefRenderHandler> GetRenderHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }
  CefRefPtr<CefDownloadHandler> GetDownloadHandler() override { return this; }
  CefRefPtr<CefFindHandler> GetFindHandler() override { return this; }
  CefRefPtr<CefKeyboardHandler> GetKeyboardHandler() override { return this; }
  CefRefPtr<CefJSDialogHandler> GetJSDialogHandler() override { return this; }
  CefRefPtr<CefDialogHandler> GetDialogHandler() override { return this; }
  CefRefPtr<CefPermissionHandler> GetPermissionHandler() override { return this; }
  CefRefPtr<CefContextMenuHandler> GetContextMenuHandler() override { return this; }

  // CefRenderHandler
  void GetViewRect(CefRefPtr<CefBrowser> browser, CefRect& rect) override;
  bool GetScreenPoint(CefRefPtr<CefBrowser> browser, int view_x, int view_y, int& screen_x,
                      int& screen_y) override;
  bool GetScreenInfo(CefRefPtr<CefBrowser> browser, CefScreenInfo& screen_info) override;
  void OnPopupShow(CefRefPtr<CefBrowser> browser, bool show) override;
  void OnPopupSize(CefRefPtr<CefBrowser> browser, const CefRect& rect) override;
  void OnPaint(CefRefPtr<CefBrowser> browser, PaintElementType type, const RectList& dirty_rects,
               const void* buffer, int width, int height) override;
  void OnAcceleratedPaint(CefRefPtr<CefBrowser> browser, PaintElementType type,
                          const RectList& dirty_rects,
                          const CefAcceleratedPaintInfo& info) override;

  // CefDisplayHandler
  void OnAddressChange(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                       const CefString& url) override;
  void OnTitleChange(CefRefPtr<CefBrowser> browser, const CefString& title) override;
  void OnLoadingProgressChange(CefRefPtr<CefBrowser> browser, double progress) override;
  bool OnCursorChange(CefRefPtr<CefBrowser> browser, CefCursorHandle cursor,
                      cef_cursor_type_t type, const CefCursorInfo& custom_cursor_info) override;

  // CefLoadHandler
  void OnLoadingStateChange(CefRefPtr<CefBrowser> browser, bool is_loading, bool can_go_back,
                            bool can_go_forward) override;
  void OnLoadError(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                   ErrorCode error_code, const CefString& error_text,
                   const CefString& failed_url) override;

  // CefLifeSpanHandler
  bool OnBeforePopup(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, int popup_id,
                     const CefString& target_url, const CefString& target_frame_name,
                     WindowOpenDisposition target_disposition, bool user_gesture,
                     const CefPopupFeatures& popup_features, CefWindowInfo& window_info,
                     CefRefPtr<CefClient>& client, CefBrowserSettings& settings,
                     CefRefPtr<CefDictionaryValue>& extra_info,
                     bool* no_javascript_access) override;
  void OnBeforePopupAborted(CefRefPtr<CefBrowser> browser, int popup_id) override;
  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override;
  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override;

  // CefRequestHandler
  void OnRenderProcessTerminated(CefRefPtr<CefBrowser> browser, TerminationStatus status,
                                 int error_code, const CefString& error_string) override;
  bool OnBeforeBrowse(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                      CefRefPtr<CefRequest> request, bool user_gesture, bool is_redirect) override;
  bool OnOpenURLFromTab(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                        const CefString& target_url, WindowOpenDisposition target_disposition,
                        bool user_gesture) override;
  bool GetAuthCredentials(CefRefPtr<CefBrowser> browser, const CefString& origin_url,
                          bool is_proxy, const CefString& host, int port, const CefString& realm,
                          const CefString& scheme, CefRefPtr<CefAuthCallback> callback) override;
  bool OnCertificateError(CefRefPtr<CefBrowser> browser, cef_errorcode_t cert_error,
                          const CefString& request_url, CefRefPtr<CefSSLInfo> ssl_info,
                          CefRefPtr<CefCallback> callback) override;

  // CefDownloadHandler
  bool CanDownload(CefRefPtr<CefBrowser> browser, const CefString& url,
                   const CefString& request_method) override;
  bool OnBeforeDownload(CefRefPtr<CefBrowser> browser, CefRefPtr<CefDownloadItem> download_item,
                        const CefString& suggested_name,
                        CefRefPtr<CefBeforeDownloadCallback> callback) override;
  void OnDownloadUpdated(CefRefPtr<CefBrowser> browser, CefRefPtr<CefDownloadItem> download_item,
                         CefRefPtr<CefDownloadItemCallback> callback) override;

  // CefFindHandler
  void OnFindResult(CefRefPtr<CefBrowser> browser, int identifier, int count,
                    const CefRect& selection_rect, int active_match_ordinal,
                    bool final_update) override;

  // CefKeyboardHandler
  bool OnKeyEvent(CefRefPtr<CefBrowser> browser, const CefKeyEvent& event,
                  CefEventHandle os_event) override;

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

  // CefPermissionHandler
  bool OnRequestMediaAccessPermission(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                                      const CefString& requesting_origin,
                                      uint32_t requested_permissions,
                                      CefRefPtr<CefMediaAccessCallback> callback) override;
  bool OnShowPermissionPrompt(CefRefPtr<CefBrowser> browser, uint64_t prompt_id,
                              const CefString& requesting_origin, uint32_t requested_permissions,
                              CefRefPtr<CefPermissionPromptCallback> callback) override;
  void OnDismissPermissionPrompt(CefRefPtr<CefBrowser> browser, uint64_t prompt_id,
                                 cef_permission_request_result_t result) override;

  // CefContextMenuHandler
  void OnBeforeContextMenu(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                           CefRefPtr<CefContextMenuParams> params,
                           CefRefPtr<CefMenuModel> model) override;
  bool RunContextMenu(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                      CefRefPtr<CefContextMenuParams> params, CefRefPtr<CefMenuModel> model,
                      CefRefPtr<CefRunContextMenuCallback> callback) override;

  // CefRenderHandler: IME and drag and drop (OWLBrowserInput.mm)
  bool StartDragging(CefRefPtr<CefBrowser> browser, CefRefPtr<CefDragData> drag_data,
                     DragOperationsMask allowed_ops, int x, int y) override;
  void UpdateDragCursor(CefRefPtr<CefBrowser> browser, DragOperation operation) override;
  void OnImeCompositionRangeChanged(CefRefPtr<CefBrowser> browser, const CefRange& selected_range,
                                    const RectList& character_bounds) override;
  void OnTextSelectionChanged(CefRefPtr<CefBrowser> browser, const CefString& selected_text,
                              const CefRange& selected_range) override;

  // CefDevToolsMessageObserver
  void OnDevToolsMethodResult(CefRefPtr<CefBrowser> browser, int message_id, bool success,
                              const void* result, size_t result_size) override;
  void OnDevToolsEvent(CefRefPtr<CefBrowser> browser, const CefString& method,
                       const void* params, size_t params_size) override;

 private:
  struct PendingDevTools {
    uint64_t request;
    OWLMessageKind reply;
  };
  struct SentKey {
    int type;
    int native_key_code;
    OWLInputOrigin origin;
    std::chrono::steady_clock::time_point sent;
  };

  /// A request waiting for the client's answer, keyed by PromptID.
  template <typename Callback>
  using Pending = std::map<uint64_t, CefRefPtr<Callback>>;
  struct PendingMedia {
    CefRefPtr<CefMediaAccessCallback> callback;
    uint32_t requested;
  };

  void Emit(OWLMessageKind kind, const Encoder& fields);
  void Blocked(const std::string& feature, const std::string& detail);
  /// Whether the client speaks 1.1 and can answer prompts.
  bool ClientHandlesPrompts() const;
  uint64_t NextPromptID() { return ++next_prompt_id_; }
  void PromptCancelled(uint64_t prompt_id, const std::string& reason);
  void UnknownPrompt(uint16_t kind, uint64_t prompt_id);
  void CancelPendingPrompts(const std::string& reason);
  void RequestAuth(std::string origin, bool is_proxy, std::string host, int port,
                   std::string realm, std::string scheme, CefRefPtr<CefAuthCallback> callback);
  /// Creates and registers the client for a new popup view; returns its ID, or 0 on failure.
  uint64_t OpenPopup(const std::string& url, cef_window_open_disposition_t disposition,
                     bool user_gesture, const std::string& frame_name,
                     const CefPopupFeatures* features, CefWindowInfo* window_info,
                     CefRefPtr<CefClient>* client, CefBrowserSettings* settings);
  void HandleDialogReply(const Decoder& fields);
  void HandlePermissionReply(const Decoder& fields);
  void HandleFileChooserReply(const Decoder& fields);
  void HandleDownloadReply(const Decoder& fields);
  void HandleDownloadControl(const Decoder& fields);
  void HandleContextMenuReply(const Decoder& fields);
  void HandleAuthReply(const Decoder& fields);
  void HandleCertificateReply(const Decoder& fields);
  void HandlePolicyCommand(uint16_t kind, const Decoder& fields);
  void HandleImeCommand(uint16_t kind, const Decoder& fields);
  void HandleDragCommand(uint16_t kind, const Decoder& fields);
  void HandleColorReply(const Decoder& fields);
  /// Installs the isolated-world bridge that projects `<input type=color>` (OWLBrowserInput.mm).
  void InstallPageBridge();
  /// Runs a DevTools method whose result only matters when it fails (reported as a host error).
  void RunInternalDevTools(const std::string& method, CefRefPtr<CefDictionaryValue> params);
  void FocusForAgent(OWLInputOrigin origin);
  void ReplyWithScreenshot(uint64_t request, bool success, const std::string& json);
  void RunDevTools(uint64_t request, OWLMessageKind reply, const std::string& method,
                   CefRefPtr<CefDictionaryValue> params);

  uint64_t view_id_;
  double width_;
  double height_;
  double scale_;
  double screen_x_ = 0;
  double screen_y_ = 0;
  bool visible_;
  bool close_requested_ = false;
  bool focused_ = false;
  Presenter presenter_;
  CefRefPtr<CefBrowser> browser_;
  CefRefPtr<CefRegistration> devtools_registration_;
  std::map<int, PendingDevTools> pending_devtools_;
  std::deque<SentKey> sent_keys_;
  int next_message_id_ = 0;
  std::string last_find_text_;

  // 1.1 state. Touched on the CEF UI thread only; IO-thread callbacks post to it.
  uint64_t opener_id_ = 0;
  uint64_t next_prompt_id_ = 0;
  Pending<CefJSDialogCallback> dialogs_;
  Pending<CefPermissionPromptCallback> permission_prompts_;
  std::map<uint64_t, uint64_t> cef_permission_prompts_;  // CEF prompt_id -> PromptID
  std::map<uint64_t, PendingMedia> media_requests_;
  Pending<CefFileDialogCallback> file_dialogs_;
  Pending<CefBeforeDownloadCallback> download_requests_;
  std::map<uint32_t, CefRefPtr<CefDownloadItemCallback>> download_controls_;
  Pending<CefRunContextMenuCallback> context_menus_;
  Pending<CefAuthCallback> auth_requests_;
  Pending<CefCallback> certificate_errors_;
  std::map<int, uint64_t> pending_popups_;  // CEF popup_id -> new view ID
  struct PendingColor {
    int context_id;
    int64_t element_id;
  };
  std::map<uint64_t, PendingColor> color_requests_;
  OWLPopupPolicy popup_policy_ = OWLPopupPolicyRequireGesture;
  NavigationRules rules_;
  OWLInputOrigin last_pointer_origin_ = OWLInputOriginUser;

  IMPLEMENT_REFCOUNTING(BrowserClient);
};

}  // namespace owl
