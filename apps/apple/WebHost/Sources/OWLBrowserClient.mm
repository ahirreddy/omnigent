#include "OWLBrowserClient.hpp"

#import <AppKit/AppKit.h>

#include "OWLFreezeWatch.hpp"
#include "OWLHost.hpp"
#include "include/base/cef_callback.h"
#include "include/cef_parser.h"
#include "include/cef_task.h"
#include "include/wrapper/cef_closure_task.h"

namespace owl {

namespace {

constexpr auto kSentKeyLifetime = std::chrono::seconds(5);
constexpr int64_t kRepaintAfterDropMilliseconds = 16;
// How long the renderer has to answer a constant, and then to run one animation frame.
constexpr int64_t kProbeAnswerMilliseconds = 3000;
constexpr int64_t kProbeFrameMilliseconds = 2000;
// An unanswered question is forgotten after this long, and the next stall asks again.
constexpr uint64_t kProbeForgetNanos = 60 * NSEC_PER_SEC;
// What Blink believes about the page, as two fixed words. Nothing of the page's content.
constexpr char kProbeStateScript[] =
    "document.visibilityState + '/' + (document.hasFocus() ? 'focused' : 'blurred')";
constexpr char kProbeFrameScript[] =
    "new Promise((resolve) => requestAnimationFrame(() => resolve(true)))";

/// The host's clock in `NSEvent.timestamp` terms: seconds of system uptime.
double UptimeSeconds() {
  return static_cast<double>(NowNanos()) / 1e9;
}

uint64_t MillisecondsSince(uint64_t since_nanos) {
  const uint64_t now = NowNanos();
  return now > since_nanos ? (now - since_nanos) / NSEC_PER_MSEC : 0;
}

/// The page state a probe answered with, kept only when it is the two words the script builds:
/// a page can redefine what the script reads, and nothing else may reach the log.
std::string ProbeState(bool success, const std::string& json) {
  CefRefPtr<CefValue> parsed = success ? CefParseJSON(json, JSON_PARSER_RFC) : nullptr;
  if (!parsed || parsed->GetType() != VTYPE_DICTIONARY) {
    return "unreadable";
  }
  CefRefPtr<CefDictionaryValue> result = parsed->GetDictionary()->GetDictionary("result");
  const std::string state = result ? result->GetString("value").ToString() : "";
  for (const char* known : {"visible/focused", "visible/blurred", "hidden/focused",
                            "hidden/blurred", "prerender/blurred"}) {
    if (state == known) {
      return state;
    }
  }
  return "unreadable";
}

/// The page's host name for the health record, or its scheme when it has none (data:, about:).
std::string SiteOf(const CefString& url) {
  CefURLParts parts;
  if (!CefParseURL(url, parts)) {
    return "";
  }
  const std::string host = CefString(&parts.host).ToString();
  return host.empty() ? CefString(&parts.scheme).ToString() + ":" : host;
}

OWLCursor CursorFor(cef_cursor_type_t type) {
  switch (type) {
    case CT_CROSS:
      return OWLCursorCross;
    case CT_HAND:
      return OWLCursorHand;
    case CT_IBEAM:
    case CT_VERTICALTEXT:
      return OWLCursorIBeam;
    case CT_WAIT:
    case CT_PROGRESS:
      return OWLCursorWait;
    case CT_HELP:
      return OWLCursorHelp;
    case CT_EASTRESIZE:
    case CT_WESTRESIZE:
    case CT_EASTWESTRESIZE:
    case CT_COLUMNRESIZE:
      return OWLCursorResizeEastWest;
    case CT_NORTHRESIZE:
    case CT_SOUTHRESIZE:
    case CT_NORTHSOUTHRESIZE:
    case CT_ROWRESIZE:
      return OWLCursorResizeNorthSouth;
    case CT_NOTALLOWED:
    case CT_NODROP:
      return OWLCursorNotAllowed;
    case CT_GRAB:
      return OWLCursorGrab;
    case CT_GRABBING:
      return OWLCursorGrabbing;
    case CT_NONE:
      return OWLCursorNone;
    default:
      return OWLCursorPointer;
  }
}

}  // namespace

BrowserClient::BrowserClient(uint64_t view_id, double width, double height, double scale,
                             bool visible)
    : view_id_(view_id),
      width_(width),
      height_(height),
      scale_(scale),
      visible_(visible),
      presenter_(view_id, Host::Get().config().render_mode),
      health_(FreezeWatch::Get().AddView(view_id)) {
  presenter_.SetGeometry(width, height, scale);
  health_->width.store(width);
  health_->height.store(height);
  health_->scale.store(scale);
  health_->visible.store(visible);
}

bool BrowserClient::StartPresenter(std::string* error) {
  return presenter_.Start(error);
}

void BrowserClient::Emit(OWLMessageKind kind, const Encoder& fields) {
  Host::Get().Send(kind, 0, view_id_, fields);
}

void BrowserClient::Blocked(const std::string& feature, const std::string& detail) {
  Emit(OWLMessageKindFeatureBlocked,
       Encoder().String(OWLFieldFeature, feature).String(OWLFieldMessage, detail));
}

void BrowserClient::Close() {
  close_requested_ = true;
  if (browser_) {
    browser_->GetHost()->CloseBrowser(true);
  }
}

void BrowserClient::Navigate(const std::string& url) {
  if (browser_) {
    browser_->GetMainFrame()->LoadURL(url);
  }
}

void BrowserClient::GoBack() {
  if (browser_) {
    browser_->GoBack();
  }
}

void BrowserClient::GoForward() {
  if (browser_) {
    browser_->GoForward();
  }
}

void BrowserClient::Reload(bool ignore_cache) {
  if (!browser_) {
    return;
  }
  if (ignore_cache) {
    browser_->ReloadIgnoreCache();
  } else {
    browser_->Reload();
  }
}

void BrowserClient::Stop() {
  if (browser_) {
    browser_->StopLoad();
  }
}

void BrowserClient::Resize(double width, double height, double scale, double screen_x,
                           double screen_y) {
  const bool scale_changed = scale != scale_;
  width_ = width;
  height_ = height;
  scale_ = scale;
  screen_x_ = screen_x;
  screen_y_ = screen_y;
  presenter_.SetGeometry(width, height, scale);
  health_->width.store(width);
  health_->height.store(height);
  health_->scale.store(scale);
  if (!browser_) {
    return;
  }
  if (scale_changed) {
    browser_->GetHost()->NotifyScreenInfoChanged();
  }
  browser_->GetHost()->WasResized();
}

void BrowserClient::SetVisible(bool visible) {
  if (visible != visible_) {
    FreezeWatch::Get().Note("kind=view-visibility view=" + std::to_string(view_id_) +
                            " visible=" + std::to_string(visible) + " browser=" +
                            std::to_string(browser_ != nullptr));
  }
  const bool shown = visible && !visible_;
  visible_ = visible;
  health_->visible.store(visible);
  if (!browser_) {
    return;
  }
  browser_->GetHost()->WasHidden(!visible);
  if (shown) {
    // A hidden page whose frame Chromium evicted draws nothing until it gets a newer surface,
    // and CEF's show does not always allocate one. This gives it one on every show.
    browser_->GetHost()->NotifyScreenInfoChanged();
  }
}

void BrowserClient::SetFocused(bool focused) {
  if (focused != focused_) {
    FreezeWatch::Get().Note("kind=view-focus view=" + std::to_string(view_id_) + " focused=" +
                            std::to_string(focused) + " visible=" + std::to_string(visible_));
  }
  focused_ = focused;
  health_->focused.store(focused);
  if (browser_) {
    browser_->GetHost()->SetFocus(focused);
  }
}

void BrowserClient::SetZoom(double level) {
  if (browser_) {
    browser_->GetHost()->SetZoomLevel(level);
  }
}

void BrowserClient::RunDevTools(uint64_t request, OWLMessageKind reply, const std::string& method,
                                CefRefPtr<CefDictionaryValue> params) {
  if (!browser_) {
    Host::Get().Send(reply, request, view_id_,
                     Encoder()
                         .Bool(OWLFieldSuccess, false)
                         .String(OWLFieldJSON, "{\"message\":\"The view is not ready.\"}"));
    return;
  }
  const int message_id = ++next_message_id_;
  pending_devtools_[message_id] = PendingDevTools{request, reply};
  if (browser_->GetHost()->ExecuteDevToolsMethod(message_id, method, params) == 0) {
    pending_devtools_.erase(message_id);
    Host::Get().Send(reply, request, view_id_,
                     Encoder()
                         .Bool(OWLFieldSuccess, false)
                         .String(OWLFieldJSON, "{\"message\":\"CEF rejected the DevTools call.\"}"));
  }
}

void BrowserClient::Evaluate(uint64_t request, const std::string& script) {
  CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
  params->SetString("expression", script);
  params->SetBool("returnByValue", true);
  params->SetBool("awaitPromise", false);
  params->SetBool("userGesture", true);
  RunDevTools(request, OWLMessageKindEvaluateResult, "Runtime.evaluate", params);
}

void BrowserClient::DevToolsMethod(uint64_t request, const std::string& method,
                                   const std::string& params_json) {
  CefRefPtr<CefDictionaryValue> params;
  if (!params_json.empty()) {
    CefRefPtr<CefValue> value = CefParseJSON(params_json, JSON_PARSER_RFC);
    if (!value || value->GetType() != VTYPE_DICTIONARY) {
      Host::Get().Send(
          OWLMessageKindDevToolsResult, request, view_id_,
          Encoder()
              .Bool(OWLFieldSuccess, false)
              .String(OWLFieldJSON, "{\"message\":\"DevTools params must be a JSON object.\"}"));
      return;
    }
    params = value->GetDictionary();
  }
  RunDevTools(request, OWLMessageKindDevToolsResult, method, params);
}

void BrowserClient::Snapshot(uint64_t request) {
  if (!visible_ || !presenter_.HasFrame()) {
    // Hidden views produce no frames; let Chromium render one for the capture. Agent views are
    // often off screen.
    CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
    params->SetString("format", "png");
    RunDevTools(request, OWLMessageKindSnapshotResult, "Page.captureScreenshot", params);
    return;
  }
  std::vector<uint8_t> png;
  std::string error;
  if (presenter_.Snapshot(&png, &error)) {
    Host::Get().Send(OWLMessageKindSnapshotResult, request, view_id_,
                     Encoder().Bool(OWLFieldSuccess, true).Bytes(OWLFieldPNG, png.data(),
                                                                 png.size()));
  } else {
    Host::Get().Send(OWLMessageKindSnapshotResult, request, view_id_,
                     Encoder().Bool(OWLFieldSuccess, false).String(OWLFieldMessage, error));
  }
}

void BrowserClient::Find(const std::string& text, bool forward, bool match_case, bool find_next) {
  if (browser_) {
    last_find_text_ = text;
    browser_->GetHost()->Find(text, forward, match_case, find_next);
  }
}

void BrowserClient::StopFind() {
  last_find_text_.clear();
  if (browser_) {
    browser_->GetHost()->StopFinding(true);
  }
}

void BrowserClient::ShowDevTools() {
  if (!browser_) {
    Host::Get().ReportError(view_id_, OWLHostErrorDevToolsFailed, "The view is not ready.");
    return;
  }
  CefWindowInfo window_info;
  window_info.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
  CefBrowserSettings settings;
  browser_->GetHost()->ShowDevTools(window_info, nullptr, settings, CefPoint());
  [NSApp activate];
}

void BrowserClient::FocusForAgent(OWLInputOrigin origin) {
  // Agent views are often off screen and never get app focus; the page widget still needs focus
  // before a click so the clicked element keeps it and later keys reach it.
  if (origin == OWLInputOriginAgent && !focused_) {
    SetFocused(true);
  }
}

bool BrowserClient::IsInputCommand(uint16_t kind) {
  return kind == OWLMessageKindInputMouse || kind == OWLMessageKindInputKey ||
         (kind >= OWLMessageKindImeSetComposition && kind <= OWLMessageKindDragSourceEnded);
}

void BrowserClient::ReplayInput(uint16_t kind, const Decoder& fields) {
  health_->NoteInput(owl_input_class(kind, fields.U64(OWLFieldMouseKind).value_or(0),
                                     fields.U64(OWLFieldKeyKind).value_or(0),
                                     fields.U64(OWLFieldNativeKeyCode).value_or(0)),
                     NowNanos());
  earliest_input_time_ = owl_input_event_time(fields.Double(OWLFieldEventTime).value_or(0),
                                              UptimeSeconds(), earliest_input_time_);
  const ScopedInputEvent current_event(earliest_input_time_);
  if (!current_event.IsInstalled()) {
    health_->input_failures.fetch_add(1);
    // Without it CEF would stamp the input with a stale time or none, which Blink rejects.
    Host::Get().ReportError(view_id_, OWLHostErrorInputFailed,
                            "Input " + std::to_string(kind) + " could not be given a time.");
    return;
  }
  switch (kind) {
    case OWLMessageKindInputMouse:
      InputMouse(fields);
      return;
    case OWLMessageKindInputKey:
      InputKey(fields);
      return;
    default:
      HandleBrowserUICommand(kind, fields);
      return;
  }
}

void BrowserClient::InputMouse(const Decoder& fields) {
  auto origin = fields.U64(OWLFieldInputOrigin);
  auto kind = fields.U64(OWLFieldMouseKind);
  auto x = fields.Double(OWLFieldX);
  auto y = fields.Double(OWLFieldY);
  if (!origin || !kind || !x || !y) {
    Host::Get().ReportError(view_id_, OWLHostErrorMalformedMessage,
                            "InputMouse needs InputOrigin, MouseKind, X and Y.");
    return;
  }
  if (!browser_) {
    return;
  }
  FocusForAgent(static_cast<OWLInputOrigin>(*origin));
  if (*kind == OWLMouseKindDown) {
    // Browser UI a click opens (context menus, drags) is suppressed for agent clicks.
    last_pointer_origin_ = static_cast<OWLInputOrigin>(*origin);
  }
  CefMouseEvent event;
  event.x = static_cast<int>(*x);
  event.y = static_cast<int>(*y);
  event.modifiers = static_cast<uint32_t>(fields.U64(OWLFieldModifiers).value_or(0));
  CefRefPtr<CefBrowserHost> host = browser_->GetHost();
  switch (*kind) {
    case OWLMouseKindMove:
      host->SendMouseMoveEvent(event, false);
      break;
    case OWLMouseKindLeave:
      host->SendMouseMoveEvent(event, true);
      break;
    case OWLMouseKindDown:
    case OWLMouseKindUp: {
      const auto button = static_cast<cef_mouse_button_type_t>(
          fields.U64(OWLFieldButton).value_or(OWLMouseButtonLeft));
      const int clicks = static_cast<int>(fields.U64(OWLFieldClickCount).value_or(1));
      host->SendMouseClickEvent(event, button, *kind == OWLMouseKindUp, clicks);
      break;
    }
    case OWLMouseKindWheel:
      host->SendMouseWheelEvent(event, static_cast<int>(fields.Double(OWLFieldDeltaX).value_or(0)),
                                static_cast<int>(fields.Double(OWLFieldDeltaY).value_or(0)));
      break;
    default:
      Host::Get().ReportError(view_id_, OWLHostErrorMalformedMessage, "Unknown MouseKind.");
      break;
  }
}

void BrowserClient::InputKey(const Decoder& fields) {
  auto origin = fields.U64(OWLFieldInputOrigin);
  auto kind = fields.U64(OWLFieldKeyKind);
  auto native_key_code = fields.U64(OWLFieldNativeKeyCode);
  if (!origin || !kind || !native_key_code || *kind > OWLKeyKindChar) {
    Host::Get().ReportError(view_id_, OWLHostErrorMalformedMessage,
                            "InputKey needs InputOrigin, a valid KeyKind and NativeKeyCode.");
    return;
  }
  if (!browser_) {
    return;
  }
  FocusForAgent(static_cast<OWLInputOrigin>(*origin));
  CefKeyEvent event;
  event.type = static_cast<cef_key_event_type_t>(*kind);
  event.native_key_code = static_cast<int>(*native_key_code);
  event.modifiers = static_cast<uint32_t>(fields.U64(OWLFieldModifiers).value_or(0));
  event.character = static_cast<char16_t>(fields.U64(OWLFieldCharacter).value_or(0));
  event.unmodified_character =
      static_cast<char16_t>(fields.U64(OWLFieldUnmodifiedCharacter).value_or(0));
  const auto now = std::chrono::steady_clock::now();
  while (!sent_keys_.empty() && now - sent_keys_.front().sent > kSentKeyLifetime) {
    sent_keys_.pop_front();
  }
  sent_keys_.push_back(SentKey{event.type, event.native_key_code,
                               static_cast<OWLInputOrigin>(*origin), now});
  browser_->GetHost()->SendKeyEvent(event);
}

// MARK: CefRenderHandler

void BrowserClient::GetViewRect(CefRefPtr<CefBrowser>, CefRect& rect) {
  rect = CefRect(0, 0, std::max(1, static_cast<int>(width_)), std::max(1, static_cast<int>(height_)));
}

bool BrowserClient::GetScreenPoint(CefRefPtr<CefBrowser>, int view_x, int view_y, int& screen_x,
                                   int& screen_y) {
  screen_x = static_cast<int>(screen_x_) + view_x;
  screen_y = static_cast<int>(screen_y_) + view_y;
  return true;
}

bool BrowserClient::GetScreenInfo(CefRefPtr<CefBrowser> browser, CefScreenInfo& screen_info) {
  CefRect view;
  GetViewRect(browser, view);
  screen_info.device_scale_factor = static_cast<float>(scale_);
  screen_info.rect = view;
  screen_info.available_rect = view;
  return true;
}

void BrowserClient::OnPopupShow(CefRefPtr<CefBrowser>, bool show) {
  health_->popup_open.store(show);
  presenter_.SetPopupVisible(show);
}

void BrowserClient::OnPopupSize(CefRefPtr<CefBrowser>, const CefRect& rect) {
  presenter_.SetPopupRect(rect.x, rect.y, rect.width, rect.height);
}

void BrowserClient::OnPaint(CefRefPtr<CefBrowser>, PaintElementType type, const RectList&,
                            const void* buffer, int width, int height) {
  const uint64_t paint_nanos = NowNanos();
  health_->NotePaint(paint_nanos);
  const uint64_t delivered = presenter_.FramesDelivered();
  const bool kept = presenter_.PresentPixels(type == PET_POPUP ? OWLLayerPopup : OWLLayerPage,
                                             buffer, width, height, paint_nanos);
  NotePresentResult(type, kept, delivered);
}

void BrowserClient::NotePresentResult(PaintElementType type, bool kept,
                                      uint64_t delivered_before) {
  const uint64_t now = NowNanos();
  health_->ring_slots.store(static_cast<uint32_t>(presenter_.PageRingSlots()),
                            std::memory_order_relaxed);
  health_->ring_busy_peak.store(static_cast<uint32_t>(presenter_.PageRingBusyPeak()),
                                std::memory_order_relaxed);
  if (!kept) {
    health_->NoteDrop(now);
    RepaintAfterDrop(type);
  } else if (presenter_.FramesDelivered() != delivered_before) {
    health_->NoteFrame(now);
  } else {
    health_->present_errors.fetch_add(1, std::memory_order_relaxed);
  }
}

void BrowserClient::RepaintAfterDrop(PaintElementType type) {
  if (repaint_after_drop_pending_) {
    return;
  }
  repaint_after_drop_pending_ = true;
  CefRefPtr<BrowserClient> self(this);
  // Long enough for the window server to let go of a buffer, short enough not to be seen.
  CefPostDelayedTask(TID_UI, base::BindOnce(
                                 [](CefRefPtr<BrowserClient> client, PaintElementType element) {
                                   client->repaint_after_drop_pending_ = false;
                                   if (client->browser_ != nullptr) {
                                     client->browser_->GetHost()->Invalidate(element);
                                   }
                                 },
                                 self, type),
                     kRepaintAfterDropMilliseconds);
}

void BrowserClient::OnAcceleratedPaint(CefRefPtr<CefBrowser>, PaintElementType type,
                                       const RectList&, const CefAcceleratedPaintInfo& info) {
  const uint64_t paint_nanos = NowNanos();
  health_->NotePaint(paint_nanos);
  auto surface = static_cast<IOSurfaceRef>(info.shared_texture_io_surface);
  if (surface == nullptr) {
    health_->present_errors.fetch_add(1, std::memory_order_relaxed);
    Host::Get().ReportError(view_id_, OWLHostErrorRenderFailed,
                            "OnAcceleratedPaint delivered no IOSurface.");
    return;
  }
  int x = 0;
  int y = 0;
  int width = static_cast<int>(IOSurfaceGetWidth(surface));
  int height = static_cast<int>(IOSurfaceGetHeight(surface));
  const cef_rect_t& visible = info.extra.visible_rect;
  if (visible.width > 0 && visible.height > 0 && visible.x + visible.width <= width &&
      visible.y + visible.height <= height) {
    x = visible.x;
    y = visible.y;
    width = visible.width;
    height = visible.height;
  }
  const uint64_t delivered = presenter_.FramesDelivered();
  const bool kept = presenter_.PresentAccelerated(
      type == PET_POPUP ? OWLLayerPopup : OWLLayerPage, surface, x, y, width, height, paint_nanos);
  NotePresentResult(type, kept, delivered);
}

// MARK: CefDisplayHandler

void BrowserClient::OnAddressChange(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame,
                                    const CefString& url) {
  if (frame->IsMain()) {
    // Input that happened before this commit was aimed at the page before it. Blink requires
    // the input that starts a soft navigation to be newer than the document it lands in.
    earliest_input_time_ = std::max(earliest_input_time_, UptimeSeconds());
    health_->SetSite(SiteOf(url));
    health_->NoteNavigation();
    Emit(OWLMessageKindURLChanged, Encoder().String(OWLFieldURL, url.ToString()));
  }
}

void BrowserClient::OnTitleChange(CefRefPtr<CefBrowser>, const CefString& title) {
  Emit(OWLMessageKindTitleChanged, Encoder().String(OWLFieldTitle, title.ToString()));
  EmitNavigationHistory();
}

void BrowserClient::OnLoadingProgressChange(CefRefPtr<CefBrowser>, double progress) {
  Emit(OWLMessageKindLoadProgress, Encoder().Double(OWLFieldProgress, progress));
}

bool BrowserClient::OnCursorChange(CefRefPtr<CefBrowser>, CefCursorHandle, cef_cursor_type_t type,
                                   const CefCursorInfo&) {
  Emit(OWLMessageKindCursorChanged, Encoder().U64(OWLFieldCursor, CursorFor(type)));
  return true;
}

// MARK: CefLoadHandler

void BrowserClient::OnLoadingStateChange(CefRefPtr<CefBrowser>, bool is_loading,
                                         bool can_go_back, bool can_go_forward) {
  health_->SetLoading(is_loading, NowNanos());
  Emit(OWLMessageKindLoadingState, Encoder()
                                       .Bool(OWLFieldIsLoading, is_loading)
                                       .Bool(OWLFieldCanGoBack, can_go_back)
                                       .Bool(OWLFieldCanGoForward, can_go_forward));
  EmitNavigationHistory();
}

void BrowserClient::OnLoadError(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame,
                                ErrorCode error_code, const CefString& error_text,
                                const CefString& failed_url) {
  if (frame->IsMain()) {
    Emit(OWLMessageKindLoadError, Encoder()
                                      .I64(OWLFieldErrorCode, error_code)
                                      .String(OWLFieldText, error_text.ToString())
                                      .String(OWLFieldURL, failed_url.ToString()));
  }
}

// MARK: CefLifeSpanHandler

void BrowserClient::OnAfterCreated(CefRefPtr<CefBrowser> browser) {
  browser_ = browser;
  health_->has_browser.store(true);
  devtools_registration_ = browser->GetHost()->AddDevToolsMessageObserver(this);
  if (close_requested_) {
    browser->GetHost()->CloseBrowser(true);
    return;
  }
  if (!visible_) {
    browser->GetHost()->WasHidden(true);
  }
  if (ClientHandlesPrompts()) {
    InstallPageBridge();
  }
  if (ClientHandlesBrowsing()) {
    InstallMediaBridge();
  }
  Emit(OWLMessageKindViewCreated, Encoder());
}

void BrowserClient::OnBeforeClose(CefRefPtr<CefBrowser>) {
  devtools_registration_ = nullptr;
  browser_ = nullptr;
  health_->has_browser.store(false);
  probe_ = RendererProbe();
  CancelPendingPrompts("The view was closed.");
  for (const auto& entry : pending_devtools_) {
    if (entry.second.request == 0) {
      continue;  // Internal calls have no client waiting.
    }
    Host::Get().Send(entry.second.reply, entry.second.request, view_id_,
                     Encoder()
                         .Bool(OWLFieldSuccess, false)
                         .String(OWLFieldJSON, "{\"message\":\"The view was closed.\"}"));
  }
  pending_devtools_.clear();
  Host::Get().OnBrowserClosed(view_id_);
}

// MARK: CefRequestHandler

void BrowserClient::OnRenderProcessTerminated(CefRefPtr<CefBrowser>, TerminationStatus status,
                                              int error_code, const CefString& error_string) {
  // Its answer will never come, and the hang monitor has nothing left to watch.
  probe_ = RendererProbe();
  health_->unresponsive.store(false);
  FreezeWatch::Get().Note("kind=renderer-gone view=" + std::to_string(view_id_) + " status=" +
                          std::to_string(status) + " code=" + std::to_string(error_code));
  Emit(OWLMessageKindRendererGone, Encoder()
                                       .I64(OWLFieldStatus, status)
                                       .I64(OWLFieldErrorCode, error_code)
                                       .String(OWLFieldMessage, error_string.ToString()));
}

// MARK: CefFindHandler

void BrowserClient::OnFindResult(CefRefPtr<CefBrowser>, int, int count, const CefRect&,
                                 int active_match_ordinal, bool final_update) {
  Emit(OWLMessageKindFindResult, Encoder()
                                     .I64(OWLFieldCount, count)
                                     .I64(OWLFieldActiveMatch, active_match_ordinal)
                                     .Bool(OWLFieldFinalUpdate, final_update));
}

// MARK: CefKeyboardHandler

bool BrowserClient::OnKeyEvent(CefRefPtr<CefBrowser>, const CefKeyEvent& event, CefEventHandle) {
  health_->keys_returned.fetch_add(1, std::memory_order_relaxed);
  OWLInputOrigin origin = OWLInputOriginUser;
  bool matched = false;
  while (!sent_keys_.empty()) {
    SentKey sent = sent_keys_.front();
    sent_keys_.pop_front();
    if (sent.type == event.type && sent.native_key_code == event.native_key_code) {
      origin = sent.origin;
      matched = true;
      break;
    }
  }
  // Agent keys never bounce back into the app; unmatched events are dropped for the same reason.
  const bool is_down = event.type == KEYEVENT_RAWKEYDOWN || event.type == KEYEVENT_KEYDOWN;
  if (matched && origin == OWLInputOriginUser && is_down) {
    Emit(OWLMessageKindKeyUnhandled, Encoder()
                                         .U64(OWLFieldKeyKind, static_cast<uint64_t>(event.type))
                                         .U64(OWLFieldNativeKeyCode,
                                              static_cast<uint64_t>(event.native_key_code))
                                         .U64(OWLFieldModifiers, event.modifiers)
                                         .U64(OWLFieldCharacter, event.character)
                                         .U64(OWLFieldUnmodifiedCharacter,
                                              event.unmodified_character));
  }
  return true;
}

void BrowserClient::ReplyWithScreenshot(uint64_t request, bool success, const std::string& json) {
  CefRefPtr<CefValue> parsed = success ? CefParseJSON(json, JSON_PARSER_RFC) : nullptr;
  CefRefPtr<CefBinaryValue> png;
  if (parsed && parsed->GetType() == VTYPE_DICTIONARY) {
    png = CefBase64Decode(parsed->GetDictionary()->GetString("data"));
  }
  if (!png || png->GetSize() == 0) {
    Host::Get().Send(OWLMessageKindSnapshotResult, request, view_id_,
                     Encoder()
                         .Bool(OWLFieldSuccess, false)
                         .String(OWLFieldMessage, "Page.captureScreenshot failed: " + json));
    return;
  }
  std::vector<uint8_t> bytes(png->GetSize());
  png->GetData(bytes.data(), bytes.size(), 0);
  Host::Get().Send(OWLMessageKindSnapshotResult, request, view_id_,
                   Encoder().Bool(OWLFieldSuccess, true).Bytes(OWLFieldPNG, bytes.data(),
                                                               bytes.size()));
}

// MARK: CefDevToolsMessageObserver

void BrowserClient::OnDevToolsMethodResult(CefRefPtr<CefBrowser>, int message_id, bool success,
                                           const void* result, size_t result_size) {
  if (HandleProbeResult(message_id, success,
                        std::string(static_cast<const char*>(result), result_size))) {
    return;
  }
  auto found = pending_devtools_.find(message_id);
  if (found == pending_devtools_.end()) {
    return;
  }
  PendingDevTools pending = found->second;
  pending_devtools_.erase(found);
  std::string json(static_cast<const char*>(result), result_size);
  if (pending.request == 0) {
    // Internal call (page bridge set-up, color replies): only failures are reported.
    if (!success) {
      Host::Get().ReportError(view_id_, OWLHostErrorDevToolsFailed, "Internal DevTools call failed: " + json);
    }
    return;
  }
  if (pending.reply == OWLMessageKindSnapshotResult) {
    ReplyWithScreenshot(pending.request, success, json);
    return;
  }
  Host::Get().Send(pending.reply, pending.request, view_id_,
                   Encoder().Bool(OWLFieldSuccess, success).String(OWLFieldJSON, json));
}

// MARK: Freeze diagnostics

bool BrowserClient::OnRenderProcessUnresponsive(CefRefPtr<CefBrowser>,
                                                CefRefPtr<CefUnresponsiveProcessCallback>) {
  unresponsive_since_nanos_ = NowNanos();
  health_->unresponsive.store(true);
  FreezeWatch::Get().Report(
      OWLHealthKindRendererUnresponsive, view_id_, 0,
      "kind=renderer-unresponsive view=" + std::to_string(view_id_) + " " +
          health_->Line(unresponsive_since_nanos_, 0) + " " + PresentationState());
  // Chromium keeps waiting, as it did before this was recorded.
  return false;
}

void BrowserClient::OnRenderProcessResponsive(CefRefPtr<CefBrowser>) {
  // Chromium does not report the start while a DevTools session is attached, as this host's
  // always is; it still reports the end.
  const bool started = unresponsive_since_nanos_ != 0;
  const uint64_t lasted = started ? MillisecondsSince(unresponsive_since_nanos_) : 0;
  unresponsive_since_nanos_ = 0;
  health_->unresponsive.store(false);
  FreezeWatch::Get().Report(OWLHealthKindRendererResponsive, view_id_, lasted,
                            "kind=renderer-responsive view=" + std::to_string(view_id_) +
                                " unresponsive_ms=" +
                                (started ? std::to_string(lasted) : "unreported"));
}

size_t BrowserClient::PendingPromptCount() const {
  return dialogs_.size() + permission_prompts_.size() + media_requests_.size() +
         file_dialogs_.size() + download_requests_.size() + context_menus_.size() +
         auth_requests_.size() + certificate_errors_.size() + color_requests_.size();
}

std::string BrowserClient::PresentationState() const {
  const Presenter::RingState ring = presenter_.PageRing();
  return "ring=slots:" + std::to_string(ring.slots) + ",in_use:" + std::to_string(ring.in_use) +
         ",unacked:" + std::to_string(ring.awaiting_ack) + ",dropped:" +
         std::to_string(ring.dropped) + " prompts=" + std::to_string(PendingPromptCount()) +
         " dialogs=" + std::to_string(dialogs_.size()) + " devtools_pending=" +
         std::to_string(pending_devtools_.size());
}

void BrowserClient::ReportProbe(const std::string& verdict, uint64_t elapsed_milliseconds) {
  FreezeWatch::Get().Report(OWLHealthKindRendererProbe, view_id_, elapsed_milliseconds,
                            "kind=renderer-probe view=" + std::to_string(view_id_) + " " +
                                verdict + " " + PresentationState());
}

void BrowserClient::ProbeRenderer(bool quiet) {
  if (probe_.stage != RendererProbe::Stage::kIdle) {
    const uint64_t waited = MillisecondsSince(probe_.started_nanos);
    if (waited * NSEC_PER_MSEC < kProbeForgetNanos) {
      if (quiet || (probe_.quiet && !probe_.timed_out)) {
        // One question at a time: the one in flight now also answers for the stall.
        probe_.quiet = probe_.quiet && quiet;
        return;
      }
      // The earlier question is still unanswered; a second one would only queue behind it.
      ReportProbe(std::string(probe_.stage == RendererProbe::Stage::kAnswer
                                  ? "renderer=hung"
                                  : "renderer=alive frames=stopped") +
                      " asked=earlier waiting_ms=" + std::to_string(waited),
                  waited);
      return;
    }
    probe_ = RendererProbe();
  }
  if (!browser_) {
    if (!quiet) {
      ReportProbe("renderer=unknown why=no-browser", 0);
    }
    return;
  }
  probe_.quiet = quiet;
  StartProbeStage(RendererProbe::Stage::kAnswer, kProbeStateScript, false,
                  kProbeAnswerMilliseconds);
}

void BrowserClient::StartProbeStage(RendererProbe::Stage stage, const char* script,
                                    bool await_promise, int64_t timeout_milliseconds) {
  CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
  params->SetString("expression", script);
  params->SetBool("returnByValue", true);
  params->SetBool("awaitPromise", await_promise);
  const int message_id = ++next_message_id_;
  if (browser_->GetHost()->ExecuteDevToolsMethod(message_id, "Runtime.evaluate", params) == 0) {
    probe_ = RendererProbe();
    ReportProbe("renderer=unknown why=devtools-rejected", 0);
    return;
  }
  probe_.stage = stage;
  probe_.message_id = message_id;
  probe_.serial = ++probe_serial_;
  probe_.started_nanos = NowNanos();
  probe_.timed_out = false;
  CefRefPtr<BrowserClient> self(this);
  CefPostDelayedTask(TID_UI, base::BindOnce(
                                 [](CefRefPtr<BrowserClient> client, uint64_t serial) {
                                   client->ProbeTimedOut(serial);
                                 },
                                 self, probe_.serial),
                     timeout_milliseconds);
}

void BrowserClient::ProbeTimedOut(uint64_t serial) {
  if (probe_.stage == RendererProbe::Stage::kIdle || probe_.serial != serial ||
      probe_.timed_out) {
    return;
  }
  // The question stays open so a late answer is recognized; nothing new is asked meanwhile.
  probe_.timed_out = true;
  const uint64_t waited = MillisecondsSince(probe_.started_nanos);
  if (probe_.stage == RendererProbe::Stage::kAnswer) {
    ReportProbe("renderer=hung waited_ms=" + std::to_string(waited) +
                    (probe_.quiet ? " asked=while-in-use" : ""),
                waited);
  } else {
    ReportProbe("renderer=alive answer_ms=" + std::to_string(probe_.answer_milliseconds) +
                    " page=" + probe_.page_state + " frames=stopped waited_ms=" +
                    std::to_string(waited),
                waited);
  }
}

bool BrowserClient::HandleProbeResult(int message_id, bool success, const std::string& json) {
  if (probe_.stage == RendererProbe::Stage::kIdle || message_id != probe_.message_id) {
    return false;
  }
  const uint64_t took = MillisecondsSince(probe_.started_nanos);
  const bool late = probe_.timed_out;
  if (probe_.stage == RendererProbe::Stage::kFrame) {
    ReportProbe(late ? "renderer=alive frames=resumed answered_after_ms=" + std::to_string(took)
                     : "renderer=alive answer_ms=" + std::to_string(probe_.answer_milliseconds) +
                           " page=" + probe_.page_state + " frames=alive frame_ms=" +
                           std::to_string(took),
                took);
    probe_ = RendererProbe();
    return true;
  }
  probe_.answer_milliseconds = took;
  probe_.page_state = ProbeState(success, json);
  const bool hidden = probe_.page_state.rfind("hidden", 0) == 0;
  if (probe_.quiet && !late) {
    probe_ = RendererProbe();  // The routine question was answered in time: nothing to write.
    return true;
  }
  if (late || hidden || !browser_) {
    // A hidden page runs no animation frames, so there is nothing more to ask it.
    ReportProbe(late ? "renderer=recovered answered_after_ms=" + std::to_string(took) + " page=" +
                           probe_.page_state
                     : "renderer=alive answer_ms=" + std::to_string(took) + " page=" +
                           probe_.page_state + " frames=not-asked",
                took);
    probe_ = RendererProbe();
    return true;
  }
  StartProbeStage(RendererProbe::Stage::kFrame, kProbeFrameScript, true, kProbeFrameMilliseconds);
  return true;
}

}  // namespace owl
