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
  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override;
  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override;

  // CefRequestHandler
  void OnRenderProcessTerminated(CefRefPtr<CefBrowser> browser, TerminationStatus status,
                                 int error_code, const CefString& error_string) override;

  // CefDownloadHandler
  bool CanDownload(CefRefPtr<CefBrowser> browser, const CefString& url,
                   const CefString& request_method) override;
  bool OnBeforeDownload(CefRefPtr<CefBrowser> browser, CefRefPtr<CefDownloadItem> download_item,
                        const CefString& suggested_name,
                        CefRefPtr<CefBeforeDownloadCallback> callback) override;

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

  // CefContextMenuHandler
  void OnBeforeContextMenu(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                           CefRefPtr<CefContextMenuParams> params,
                           CefRefPtr<CefMenuModel> model) override;

  // CefDevToolsMessageObserver
  void OnDevToolsMethodResult(CefRefPtr<CefBrowser> browser, int message_id, bool success,
                              const void* result, size_t result_size) override;

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

  void Emit(OWLMessageKind kind, const Encoder& fields);
  void Blocked(const std::string& feature, const std::string& detail);
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

  IMPLEMENT_REFCOUNTING(BrowserClient);
};

}  // namespace owl
