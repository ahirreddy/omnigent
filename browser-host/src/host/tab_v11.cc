// Protocol v1.1 for one tab (design doc section 16): viewport ownership and mobile emulation,
// edit commands that never touch the OS clipboard, touch input, and the selection and scroll
// reports. DevTools calls go over the tab's own in-process session.
#include <cmath>

#include "core/keycodes.h"
#include "core/stream.h"
#include "host/browser_host.h"
#include "host/log.h"
#include "host/tab.h"
#include "host/ui_task.h"
#include "include/cef_version.h"

namespace rb {

namespace {

constexpr uint64_t kSelectionIntervalUs = 100000;
constexpr uint64_t kScrollIntervalUs = 33000;

// Reads the selection (a focused field's, else the document's), lets the page rewrite it
// through a synthetic copy or cut event, and deletes it for cut. Password fields give nothing;
// a selection inside an iframe is reported as `frame` (the host then uses CEF's text).
constexpr char kCopyScript[] = R"JS((op) => {
  const active = document.activeElement;
  if (active && active.tagName === 'IFRAME') return {frame: true, text: ''};
  const field = active && (active.tagName === 'TEXTAREA' || active.tagName === 'INPUT') &&
      typeof active.selectionStart === 'number' ? active : null;
  if (active && active.tagName === 'INPUT' && active.type === 'password') {
    return {password: true, text: ''};
  }
  let text = field ? field.value.substring(field.selectionStart, field.selectionEnd)
                   : String(window.getSelection() || '');
  const data = new DataTransfer();
  data.setData('text/plain', text);
  const event = new ClipboardEvent(op, {clipboardData: data, bubbles: true, cancelable: true});
  (active || document.body || document).dispatchEvent(event);
  if (event.defaultPrevented) {
    text = data.getData('text/plain');
  } else if (op === 'cut' && text) {
    document.execCommand('delete');
  }
  return {text};
})JS";

// Offers the text to the page as a synthetic paste event, then inserts it as typing would
// (undoable, fires input events). `insert` asks the host to fall back to Input.insertText.
constexpr char kPasteScript[] = R"JS((text) => {
  const active = document.activeElement;
  if (active && active.tagName === 'IFRAME') return 'insert';
  const data = new DataTransfer();
  data.setData('text/plain', text);
  const event = new ClipboardEvent('paste', {clipboardData: data, bubbles: true, cancelable: true});
  (active || document.body || document).dispatchEvent(event);
  if (event.defaultPrevented) return 'handled';
  return document.execCommand('insertText', false, text) ? 'inserted' : 'insert';
})JS";

constexpr char kSelectionScript[] = R"JS((() => {
  const active = document.activeElement;
  const field = active && (active.tagName === 'TEXTAREA' || active.tagName === 'INPUT') &&
      typeof active.selectionStart === 'number' ? active : null;
  const editable = !!field || !!(active && active.isContentEditable);
  const box = (r) => r && (r.width || r.height) ? [r.x, r.y, r.width, r.height] : null;
  if (field) {
    const length = Math.abs(field.selectionEnd - field.selectionStart);
    return {editable, collapsed: length === 0, length, rect: box(field.getBoundingClientRect())};
  }
  const selection = window.getSelection();
  if (!selection || selection.rangeCount === 0) {
    return {editable, collapsed: true, length: 0,
            rect: editable ? box(active.getBoundingClientRect()) : null};
  }
  const range = selection.getRangeAt(0);
  let rect = box(range.getBoundingClientRect());
  if (!rect) {
    const rects = range.getClientRects();
    if (rects.length) rect = box(rects[0]);
  }
  if (!rect && editable) rect = box(active.getBoundingClientRect());
  return {editable, collapsed: range.collapsed, length: String(selection).length, rect};
})())JS";

std::string JsonLiteral(const std::string& text) {
  std::string out;
  AppendJsonString(text, &out);
  return out;
}

/// Chrome for Android's reduced user agent at the host's Chromium major: honest about the
/// engine, so pages that sniff for Blink features get what they test for.
std::string MobileUserAgent() {
  return "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/" +
         std::to_string(CHROME_VERSION_MAJOR) + ".0.0.0 Mobile Safari/537.36";
}

Json MobileUserAgentMetadata() {
  const std::string major = std::to_string(CHROME_VERSION_MAJOR);
  Json brands = Json::MakeArray();
  for (const auto& [brand, version] :
       {std::pair<std::string, std::string>{"Chromium", major}, {"Not.A/Brand", "99"}}) {
    Json entry = Json::MakeObject();
    entry.Set("brand", brand);
    entry.Set("version", version);
    brands.Push(entry);
  }
  Json metadata = Json::MakeObject();
  metadata.Set("brands", brands);
  metadata.Set("platform", "Android");
  metadata.Set("platformVersion", "10.0.0");
  metadata.Set("architecture", "");
  metadata.Set("model", "K");
  metadata.Set("mobile", true);
  return metadata;
}

/// The `value` of a Runtime.evaluate result, or an error description.
std::optional<Json> EvaluatedValue(bool ok, const Json& result, std::string* error) {
  if (!ok) {
    *error = result.GetString("message").value_or(result.Dump());
    return std::nullopt;
  }
  if (const Json* exception = result.Find("exceptionDetails")) {
    *error = "the page script threw: " + exception->Dump();
    return std::nullopt;
  }
  const Json* remote = result.Find("result");
  const Json* value = remote != nullptr ? remote->Find("value") : nullptr;
  if (value == nullptr) {
    *error = "the page script returned no value: " + result.Dump();
    return std::nullopt;
  }
  return *value;
}

}  // namespace

// MARK: DevTools

void Tab::CallDevTools(const std::string& method, Json params, DevToolsCallback done) {
  if (!browser_) {
    done(false, Json("the tab has no browser"));
    return;
  }
  const int id = next_devtools_id_++;
  Json message = Json::MakeObject();
  message.Set("id", id);
  message.Set("method", method);
  message.Set("params", std::move(params));
  const std::string text = message.Dump();
  devtools_calls_[id] = std::move(done);
  if (!browser_->GetHost()->SendDevToolsMessage(text.data(), text.size())) {
    DevToolsCallback failed = std::move(devtools_calls_[id]);
    devtools_calls_.erase(id);
    failed(false, Json("CEF rejected DevTools " + method));
  }
}

void Tab::Evaluate(const std::string& expression, DevToolsCallback done) {
  Json params = Json::MakeObject();
  params.Set("expression", expression);
  params.Set("returnByValue", true);
  params.Set("userGesture", true);
  CallDevTools("Runtime.evaluate", std::move(params), std::move(done));
}

Tab::DevToolsCallback Tab::ReportFailure(const std::string& what) {
  CefRefPtr<Tab> self(this);
  return [self, what](bool ok, const Json& result) {
    if (ok) {
      return;
    }
    const std::string detail = what + " failed: " + result.Dump();
    self->Log(detail);
    self->Broadcast(protocol::ErrorMessage({"internal", detail, false}));
  };
}

// MARK: Viewport and emulation

protocol::ViewportState Tab::CurrentViewport() const {
  protocol::ViewportState state;
  state.viewport = viewport_;
  state.scope = viewport_scope_;
  state.mobile = mobile_;
  if (viewport_scope_ == "control") {
    state.agent = agent_viewport_;
  }
  return state;
}

void Tab::RestoreAgentViewport() {
  viewport_holder_ = 0;
  SetViewport(agent_viewport_, "tab", "off");
}

void Tab::SetViewport(const protocol::Viewport& viewport, const std::string& scope,
                      const std::string& mobile) {
  const bool size_changed = !(viewport == viewport_);
  if (!size_changed && scope == viewport_scope_ && mobile == mobile_) {
    return;
  }
  if (mobile != mobile_) {
    ApplyEmulation(mobile);
  }
  viewport_scope_ = scope;
  mobile_ = mobile;
  if (size_changed) {
    const bool dpr_changed = viewport.dpr != viewport_.dpr;
    viewport_ = viewport;
    sink_.Resize(static_cast<int>(std::lround(viewport_.w * viewport_.dpr)),
                 static_cast<int>(std::lround(viewport_.h * viewport_.dpr)));
    streamer_->OnCanvasResized();
    if (browser_) {
      if (dpr_changed) {
        browser_->GetHost()->NotifyScreenInfoChanged();
      }
      browser_->GetHost()->WasResized();
    }
  }
  Broadcast(protocol::ViewportMessage(CurrentViewport()));
  ScheduleScrollReport();
}

void Tab::ApplyEmulation(const std::string& mobile) {
  if (mobile == "off") {
    CallDevTools("Emulation.clearDeviceMetricsOverride", Json::MakeObject(),
                 ReportFailure("clearing mobile emulation"));
  } else {
    // Zero width, height and scale keep the view's own; `mobile` turns on the meta viewport,
    // overlay scroll bars and text autosizing.
    Json metrics = Json::MakeObject();
    metrics.Set("width", 0);
    metrics.Set("height", 0);
    metrics.Set("deviceScaleFactor", 0);
    metrics.Set("mobile", true);
    CallDevTools("Emulation.setDeviceMetricsOverride", std::move(metrics),
                 ReportFailure("mobile emulation"));
  }
  Json touch = Json::MakeObject();
  touch.Set("enabled", mobile != "off");
  if (mobile != "off") {
    touch.Set("maxTouchPoints", 5);
  }
  CallDevTools("Emulation.setTouchEmulationEnabled", std::move(touch),
               ReportFailure("touch emulation"));
  if (mobile == "site" || mobile_ == "site") {
    Json agent = Json::MakeObject();
    // An empty user agent removes the override.
    agent.Set("userAgent", mobile == "site" ? MobileUserAgent() : std::string());
    if (mobile == "site") {
      agent.Set("platform", "Linux armv81");
      agent.Set("userAgentMetadata", MobileUserAgentMetadata());
    }
    CallDevTools("Emulation.setUserAgentOverride", std::move(agent),
                 ReportFailure("the mobile user agent"));
  }
  Log("emulation " + mobile_ + " -> " + mobile);
}

// MARK: Touch

void Tab::InjectTouch(const protocol::ClientMessage& message) {
  if (!browser_) {
    return;
  }
  CefRefPtr<CefBrowserHost> host = browser_->GetHost();
  if (!focused_) {
    host->SetFocus(true);
    focused_ = true;
  }
  CefTouchEvent event;
  event.id = static_cast<int>(message.touch_id);
  event.x = static_cast<float>(message.x);
  event.y = static_cast<float>(message.y);
  event.radius_x = event.radius_y = static_cast<float>(message.radius.value_or(0));
  event.rotation_angle = 0;
  event.pressure = static_cast<float>(message.pressure.value_or(0));
  event.type = message.kind == "start"  ? CEF_TET_PRESSED
               : message.kind == "move" ? CEF_TET_MOVED
               : message.kind == "end"  ? CEF_TET_RELEASED
                                        : CEF_TET_CANCELLED;
  event.modifiers = CefFlagsFromModifiers(message.modifiers);
  event.pointer_type = CEF_POINTER_TYPE_TOUCH;
  host->SendTouchEvent(event);
}

// MARK: Edit

void Tab::HandleEdit(uint64_t connection, const protocol::ClientMessage& message) {
  if (!browser_) {
    SendError(connection, "internal", "the tab is not ready", false);
    return;
  }
  const std::string& op = message.op;
  CefRefPtr<Tab> self(this);
  if (op == "copy" || op == "cut") {
    Evaluate("(" + std::string(kCopyScript) + ")(" + JsonLiteral(op) + ")",
             [self, connection, op](bool ok, const Json& result) {
               self->FinishCopy(connection, op, ok, result);
             });
    return;
  }
  if (op == "paste") {
    const std::string text = message.text.value_or("");
    Evaluate("(" + std::string(kPasteScript) + ")(" + JsonLiteral(text) + ")",
             [self, connection, text](bool ok, const Json& result) {
               std::string error;
               std::optional<Json> value = EvaluatedValue(ok, result, &error);
               if (!value) {
                 self->SendError(connection, "internal", "paste failed: " + error, false);
                 return;
               }
               if (value->is_string() && value->as_string() == "insert") {
                 Json params = Json::MakeObject();
                 params.Set("text", text);
                 self->CallDevTools("Input.insertText", std::move(params),
                                    self->ReportFailure("inserting pasted text"));
               }
             });
    return;
  }
  CefRefPtr<CefFrame> frame = browser_->GetFocusedFrame();
  if (!frame) {
    frame = browser_->GetMainFrame();
  }
  // These editing commands never touch the clipboard (unlike CefFrame::Copy and Paste).
  if (op == "select_all") {
    frame->SelectAll();
  } else if (op == "undo") {
    frame->Undo();
  } else if (op == "redo") {
    frame->Redo();
  } else {
    frame->Delete();
  }
}

void Tab::FinishCopy(uint64_t connection, const std::string& op, bool ok, const Json& result) {
  if (viewers_.count(connection) == 0) {
    return;
  }
  std::string error;
  std::optional<Json> value = EvaluatedValue(ok, result, &error);
  if (!value) {
    SendError(connection, "internal", op + " failed: " + error, false);
    return;
  }
  if (value->GetBool("password").value_or(false)) {
    SendError(connection, "unsupported", "copying from a password field is not allowed", false);
    return;
  }
  std::string text = value->GetString("text").value_or("");
  if (text.empty() && value->GetBool("frame").value_or(false)) {
    text = selected_text_;  // The selection is in a child frame; CEF reported its text.
    if (op == "cut" && !text.empty() && browser_) {
      if (CefRefPtr<CefFrame> frame = browser_->GetFocusedFrame()) {
        frame->Delete();
      }
    }
  }
  Send(connection, protocol::ClipboardMessage(op, text));
}

// MARK: Reports

bool Tab::AnyViewer(bool Viewer::* wants) const {
  for (const auto& [connection, viewer] : viewers_) {
    if (viewer.hello && viewer.*wants) {
      return true;
    }
  }
  return false;
}

void Tab::ScheduleReport(ReportThrottle* throttle, uint64_t interval_us, void (Tab::*send)()) {
  if (throttle->in_flight) {
    throttle->dirty = true;
    return;
  }
  if (throttle->scheduled) {
    return;
  }
  const uint64_t now = MonotonicMicros();
  const uint64_t due = throttle->last_us + interval_us;
  if (throttle->last_us == 0 || now >= due) {
    (this->*send)();
    return;
  }
  throttle->scheduled = true;
  CefRefPtr<Tab> self(this);
  PostUiDelayed(
      [self, throttle, send] {
        throttle->scheduled = false;
        if (!self->closing_) {
          (self.get()->*send)();
        }
      },
      static_cast<int64_t>((due - now + 999) / 1000));
}

void Tab::FinishReport(ReportThrottle* throttle, uint64_t interval_us, void (Tab::*send)()) {
  throttle->in_flight = false;
  if (throttle->dirty) {
    throttle->dirty = false;
    ScheduleReport(throttle, interval_us, send);
  }
}

void Tab::ScheduleSelectionReport() {
  if (AnyViewer(&Viewer::wants_selection)) {
    ScheduleReport(&selection_throttle_, kSelectionIntervalUs, &Tab::SendSelectionReport);
  }
}

void Tab::ScheduleScrollReport() {
  if (AnyViewer(&Viewer::wants_scroll)) {
    ScheduleReport(&scroll_throttle_, kScrollIntervalUs, &Tab::SendScrollReport);
  }
}

void Tab::SendSelectionReport() {
  if (!browser_) {
    return;
  }
  selection_throttle_.in_flight = true;
  selection_throttle_.last_us = MonotonicMicros();
  CefRefPtr<Tab> self(this);
  Evaluate(kSelectionScript, [self](bool ok, const Json& result) {
    self->FinishReport(&self->selection_throttle_, kSelectionIntervalUs, &Tab::SendSelectionReport);
    std::string error;
    std::optional<Json> value = EvaluatedValue(ok, result, &error);
    if (!value) {
      self->Log("selection report failed: " + error);
      return;
    }
    protocol::SelectionState selection;
    selection.editable = value->GetBool("editable").value_or(false);
    selection.collapsed = value->GetBool("collapsed").value_or(true);
    selection.length =
        static_cast<uint32_t>(std::max<int64_t>(0, value->GetInteger("length").value_or(0)));
    if (const Json* rect = value->Find("rect");
        rect != nullptr && rect->is_array() && rect->as_array().size() == 4) {
      const Json::Array& box = rect->as_array();
      selection.rect = protocol::Rect{box[0].as_double(), box[1].as_double(), box[2].as_double(),
                                      box[3].as_double()};
    }
    if (self->selection_ == selection) {
      return;
    }
    self->selection_ = selection;
    const Json message = protocol::SelectionMessage(selection);
    for (const auto& [connection, viewer] : self->viewers_) {
      if (viewer.hello && viewer.wants_selection) {
        self->Send(connection, message);
      }
    }
  });
}

void Tab::SendScrollReport() {
  if (!browser_) {
    return;
  }
  scroll_throttle_.in_flight = true;
  scroll_throttle_.last_us = MonotonicMicros();
  CefRefPtr<Tab> self(this);
  CallDevTools("Page.getLayoutMetrics", Json::MakeObject(), [self](bool ok, const Json& result) {
    self->FinishReport(&self->scroll_throttle_, kScrollIntervalUs, &Tab::SendScrollReport);
    const Json* layout = result.Find("cssLayoutViewport");
    const Json* content = result.Find("cssContentSize");
    if (!ok || layout == nullptr || content == nullptr) {
      self->Log("scroll report failed: " + result.Dump());
      return;
    }
    protocol::ScrollMetrics scroll;
    // The compositor scrolls before the main thread knows, so CEF's offset is the current
    // one; it is in device pixels.
    const double dpr = self->viewport_.dpr > 0 ? self->viewport_.dpr : 1;
    scroll.x = self->scroll_offset_ ? self->scroll_offset_->first / dpr
                                    : layout->GetNumber("pageX").value_or(0);
    scroll.y = self->scroll_offset_ ? self->scroll_offset_->second / dpr
                                    : layout->GetNumber("pageY").value_or(0);
    scroll.viewport_w = layout->GetNumber("clientWidth").value_or(0);
    scroll.viewport_h = layout->GetNumber("clientHeight").value_or(0);
    scroll.content_w = content->GetNumber("width").value_or(0);
    scroll.content_h = content->GetNumber("height").value_or(0);
    if (self->scroll_ == scroll) {
      return;
    }
    self->scroll_ = scroll;
    const Json message = protocol::ScrollMessage(scroll);
    for (const auto& [connection, viewer] : self->viewers_) {
      if (viewer.hello && viewer.wants_scroll) {
        self->Send(connection, message);
      }
    }
  });
}

void Tab::SendInitialReports(uint64_t connection, const Viewer& viewer) {
  if (viewer.wants_scroll) {
    if (scroll_) {
      Send(connection, protocol::ScrollMessage(*scroll_));
    } else {
      ScheduleScrollReport();
    }
  }
  if (viewer.wants_selection) {
    if (selection_) {
      Send(connection, protocol::SelectionMessage(*selection_));
    } else {
      ScheduleSelectionReport();
    }
  }
}

void Tab::OnScrollOffsetChanged(CefRefPtr<CefBrowser>, double x, double y) {
  scroll_offset_ = std::make_pair(x, y);
  ScheduleScrollReport();
}

void Tab::OnTextSelectionChanged(CefRefPtr<CefBrowser>, const CefString& selected_text,
                                 const CefRange&) {
  selected_text_ = selected_text.ToString();
  ScheduleSelectionReport();
}

}  // namespace rb
