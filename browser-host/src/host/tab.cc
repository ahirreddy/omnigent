#include "host/tab.h"

#include <algorithm>
#include <cmath>

#include "core/framing.h"
#include "core/keycodes.h"
#include "host/browser_host.h"
#include "host/log.h"
#include "host/ui_task.h"
#include "include/cef_image.h"
#include "include/cef_parser.h"

namespace rb {

namespace {

constexpr int64_t kGraceMs = 60000;
constexpr uint64_t kRefusalIntervalUs = 1000000;
constexpr size_t kMaxPendingInput = 512;

std::string CursorName(cef_cursor_type_t type) {
  switch (type) {
    case CT_POINTER:
      return "default";
    case CT_CROSS:
      return "crosshair";
    case CT_HAND:
      return "pointer";
    case CT_IBEAM:
      return "text";
    case CT_WAIT:
      return "wait";
    case CT_HELP:
      return "help";
    case CT_EASTRESIZE:
    case CT_WESTRESIZE:
    case CT_EASTWESTRESIZE:
      return "ew-resize";
    case CT_NORTHRESIZE:
    case CT_SOUTHRESIZE:
    case CT_NORTHSOUTHRESIZE:
      return "ns-resize";
    case CT_NORTHEASTRESIZE:
    case CT_SOUTHWESTRESIZE:
    case CT_NORTHEASTSOUTHWESTRESIZE:
      return "nesw-resize";
    case CT_NORTHWESTRESIZE:
    case CT_SOUTHEASTRESIZE:
    case CT_NORTHWESTSOUTHEASTRESIZE:
      return "nwse-resize";
    case CT_COLUMNRESIZE:
      return "col-resize";
    case CT_ROWRESIZE:
      return "row-resize";
    case CT_MOVE:
      return "move";
    case CT_VERTICALTEXT:
      return "vertical-text";
    case CT_CELL:
      return "cell";
    case CT_CONTEXTMENU:
      return "context-menu";
    case CT_ALIAS:
      return "alias";
    case CT_PROGRESS:
      return "progress";
    case CT_NODROP:
    case CT_NOTALLOWED:
      return "not-allowed";
    case CT_COPY:
      return "copy";
    case CT_NONE:
      return "none";
    case CT_ZOOMIN:
      return "zoom-in";
    case CT_ZOOMOUT:
      return "zoom-out";
    case CT_GRAB:
      return "grab";
    case CT_GRABBING:
      return "grabbing";
    case CT_CUSTOM:
      return "custom";
    case CT_MIDDLEPANNING:
    case CT_EASTPANNING:
    case CT_NORTHPANNING:
    case CT_NORTHEASTPANNING:
    case CT_NORTHWESTPANNING:
    case CT_SOUTHPANNING:
    case CT_SOUTHEASTPANNING:
    case CT_SOUTHWESTPANNING:
    case CT_WESTPANNING:
    case CT_MIDDLE_PANNING_VERTICAL:
    case CT_MIDDLE_PANNING_HORIZONTAL:
      return "all-scroll";
    default:
      return "default";
  }
}

std::string TextInputModeName(cef_text_input_mode_t mode) {
  switch (mode) {
    case CEF_TEXT_INPUT_MODE_NONE:
      return "none";
    case CEF_TEXT_INPUT_MODE_TEL:
      return "tel";
    case CEF_TEXT_INPUT_MODE_URL:
      return "url";
    case CEF_TEXT_INPUT_MODE_EMAIL:
      return "email";
    case CEF_TEXT_INPUT_MODE_NUMERIC:
      return "numeric";
    case CEF_TEXT_INPUT_MODE_DECIMAL:
      return "decimal";
    case CEF_TEXT_INPUT_MODE_SEARCH:
      return "search";
    default:
      return "text";
  }
}

std::string DialogKind(cef_jsdialog_type_t type) {
  switch (type) {
    case JSDIALOGTYPE_ALERT:
      return "alert";
    case JSDIALOGTYPE_CONFIRM:
      return "confirm";
    default:
      return "prompt";
  }
}

/// Decodes UTF-8 into UTF-16 code units.
std::u16string Utf16(const std::string& text) { return CefString(text).ToString16(); }

CefRange RangeOrInvalid(const std::optional<protocol::Range>& range) {
  if (!range || range->start < 0 || range->end < range->start) {
    return CefRange::InvalidRange();
  }
  return CefRange(static_cast<uint32_t>(range->start), static_cast<uint32_t>(range->end));
}

/// Viewer-facing gate for a client message type (section 5.4).
enum class Gate { kAny, kControl, kHolder };

Gate GateFor(protocol::ClientType type) {
  switch (type) {
    case protocol::ClientType::kMouse:
    case protocol::ClientType::kKey:
    case protocol::ClientType::kIme:
    case protocol::ClientType::kNav:
    case protocol::ClientType::kResize:
    case protocol::ClientType::kDialogReply:
      return Gate::kHolder;
    case protocol::ClientType::kControl:
      return Gate::kControl;
    default:
      return Gate::kAny;
  }
}

}  // namespace

Tab::Tab(BrowserHost* host, std::string id, std::string session_id, std::string created_by,
         protocol::Viewport viewport)
    : host_(host),
      id_(std::move(id)),
      session_id_(std::move(session_id)),
      created_by_(std::move(created_by)),
      viewport_(viewport) {
  const StreamConfig config = host_->stream_config();
  settings_.max_fps = static_cast<uint32_t>(config.fps_agent);
  sink_.Resize(static_cast<int>(std::lround(viewport_.w * viewport_.dpr)),
               static_cast<int>(std::lround(viewport_.h * viewport_.dpr)));
  streamer_ = std::make_unique<TabStreamer>(
      &sink_, [host = host_] { return host->MakeEncoder(); }, this, config);
}

Tab::~Tab() {
  if (streamer_) {
    streamer_->Shutdown();
  }
}

void Tab::ConfigureWindowless(CefWindowInfo* window_info, CefBrowserSettings* settings) {
  window_info->SetAsWindowless(kNullWindowHandle);
  window_info->shared_texture_enabled = false;
  window_info->runtime_style = CEF_RUNTIME_STYLE_ALLOY;
  settings->windowless_frame_rate = BrowserHost::Get().options().idle_frame_rate;
  settings->background_color = CefColorSetARGB(255, 255, 255, 255);
}

protocol::TabRecord Tab::Record() const {
  protocol::TabRecord record;
  record.id = id_;
  record.session_id = session_id_;
  record.url = nav_.url;
  record.title = nav_.title;
  record.loading = nav_.loading;
  record.owner = owner_;
  record.needs_attention = !dialogs_.empty();
  record.profile = host_->options().profile;
  record.created_by = created_by_;
  record.target_id = target_id_;
  record.can_go_back = nav_.can_go_back;
  record.can_go_forward = nav_.can_go_forward;
  return record;
}

void Tab::WhenTargetKnown(std::function<void()> callback) {
  if (!target_id_.empty() || closing_) {
    callback();
    return;
  }
  target_waiters_.push_back(std::move(callback));
}

bool Tab::Create(const std::string& url, CefRefPtr<CefRequestContext> context) {
  CefWindowInfo window_info;
  CefBrowserSettings settings;
  ConfigureWindowless(&window_info, &settings);
  nav_.url = url;
  browser_requested_ = true;
  return CefBrowserHost::CreateBrowser(window_info, this, url, settings, nullptr, context);
}

void Tab::Navigate(const std::string& url) {
  if (browser_) {
    browser_->GetMainFrame()->LoadURL(url);
  }
}

void Tab::Close(const std::string& reason) {
  if (closing_) {
    return;
  }
  closing_ = true;
  close_reason_ = reason;
  for (auto& [id, open] : dialogs_) {
    open.callback->Continue(false, CefString());
  }
  dialogs_.clear();
  if (browser_) {
    browser_->GetHost()->CloseBrowser(true);
  } else if (!browser_requested_) {
    OnBeforeClose(nullptr);  // No browser will arrive; finish now.
  }  // Otherwise OnAfterCreated closes the browser as soon as it exists.
}

// MARK: Connections

void Tab::Send(uint64_t connection, const Json& message) { host_->SendText(connection, message); }

void Tab::Broadcast(const Json& message) {
  for (const auto& [connection, viewer] : viewers_) {
    if (viewer.hello) {
      Send(connection, message);
    }
  }
}

void Tab::SendError(uint64_t connection, const std::string& code, const std::string& message,
                    bool fatal) {
  Send(connection, protocol::ErrorMessage({code, message, fatal}));
}

void Tab::Refuse(uint64_t connection, Viewer* viewer, const std::string& type,
                 const std::string& code, const std::string& message) {
  const uint64_t now = MonotonicMicros();
  uint64_t& last = viewer->last_refusal_us[type];
  if (last != 0 && now - last < kRefusalIntervalUs) {
    return;
  }
  last = now;
  SendError(connection, code, message, false);
}

void Tab::Attach(uint64_t connection, const std::string& mode) {
  Viewer viewer;
  viewer.mode = mode;
  viewers_[connection] = viewer;
  // Both sides send hello at once (section 5.3).
  protocol::HostHello hello;
  hello.tab_id = id_;
  hello.profile = host_->options().profile;
  hello.host_version = RB_HOST_VERSION;
  hello.mode = mode;
  hello.viewport = viewport_;
  hello.control = ControlFor(connection);
  hello.settings = settings_;
  Send(connection, protocol::HelloMessage(hello));
  UpdateFrameRate();
}

void Tab::Detach(uint64_t connection) {
  auto found = viewers_.find(connection);
  if (found == viewers_.end()) {
    return;
  }
  viewers_.erase(found);
  streamer_->RemoveViewer(connection);
  if (holder_ == connection) {
    // The user keeps the tab for a grace period so a reconnect mid-login does not hand it back.
    holder_ = 0;
    const uint64_t generation = ++grace_generation_;
    BroadcastControl("holder_left");
    CefRefPtr<Tab> self(this);
    PostUiDelayed(
        [self, generation] {
          if (self->grace_generation_ == generation && self->owner_ == "user" &&
              self->holder_ == 0) {
            self->SetOwner("agent", 0, "grace_expired");
          }
        },
        kGraceMs);
  }
  UpdateFrameRate();
}

void Tab::CloseViewer(uint64_t connection, uint16_t code, const std::string& reason) {
  host_->CloseConnection(connection, code, reason);
}

void Tab::OnClientMessage(uint64_t connection, const Json& json) {
  auto found = viewers_.find(connection);
  if (found == viewers_.end()) {
    return;
  }
  Viewer* viewer = &found->second;
  protocol::ClientMessage message;
  std::string error;
  if (!protocol::ParseClientMessage(json, &message, &error)) {
    SendError(connection, "invalid_message", error, false);
    return;
  }
  if (message.type == protocol::ClientType::kUnknown) {
    return;  // Unknown types are ignored (section 5.2).
  }
  if (message.type == protocol::ClientType::kHello) {
    HandleHello(connection, viewer, message);
    return;
  }
  if (message.type == protocol::ClientType::kPing) {
    Send(connection, protocol::PongMessage(message.nonce));
    return;
  }
  if (!viewer->hello) {
    SendError(connection, "invalid_message", "send hello first", false);
    return;
  }
  const Gate gate = GateFor(message.type);
  if (gate != Gate::kAny && viewer->mode != "control") {
    Refuse(connection, viewer, message.type_name, "control_not_permitted",
           "this connection is view-only");
    return;
  }
  if (gate == Gate::kHolder && holder_ != connection) {
    Refuse(connection, viewer, message.type_name, "not_in_control",
           "take control before sending " + message.type_name);
    return;
  }
  switch (message.type) {
    case protocol::ClientType::kAck:
      streamer_->Ack(connection, message.seq);
      break;
    case protocol::ClientType::kKeyframeRequest:
      streamer_->RequestKeyframe();
      break;
    case protocol::ClientType::kVisibility:
      streamer_->SetVisible(connection, message.visible);
      UpdateFrameRate();
      break;
    case protocol::ClientType::kStillRequest: {
      if (!streamer_->SendStill(connection, message.kind == "thumbnail", &error)) {
        SendError(connection, "internal", error, false);
      }
      break;
    }
    case protocol::ClientType::kSettings:
      HandleSettings(connection, viewer, message);
      break;
    case protocol::ClientType::kControl:
      HandleControl(connection, viewer, message);
      break;
    case protocol::ClientType::kMouse:
    case protocol::ClientType::kKey:
    case protocol::ClientType::kIme:
      if (!painted_) {
        if (pending_input_.size() >= kMaxPendingInput) {
          SendError(connection, "internal", "input dropped: the page has not painted yet", false);
          return;
        }
        pending_input_.push_back(message);
        return;
      }
      if (message.type == protocol::ClientType::kMouse) {
        InjectMouse(message);
      } else if (message.type == protocol::ClientType::kKey) {
        InjectKey(message);
      } else {
        InjectIme(message);
      }
      break;
    case protocol::ClientType::kNav:
      HandleNav(connection, message);
      break;
    case protocol::ClientType::kResize:
      HandleResize(connection, message);
      break;
    case protocol::ClientType::kDialogReply:
      HandleDialogReply(connection, message);
      break;
    default:
      break;
  }
}

void Tab::HandleHello(uint64_t connection, Viewer* viewer, const protocol::ClientMessage& hello) {
  if (hello.protocol != protocol::kProtocolVersion) {
    SendError(connection, "unsupported", "protocol " + std::to_string(hello.protocol), true);
    CloseViewer(connection, protocol::kCloseProtocolUnsupported, "protocol unsupported");
    return;
  }
  if (viewer->hello) {
    SendError(connection, "invalid_message", "hello was already received", false);
    return;
  }
  viewer->hello = true;
  // Setup order (section 5.3): control, viewport, nav, cursor, text_input, dialogs, then an IDR.
  Send(connection, protocol::ControlMessage(ControlFor(connection), std::nullopt));
  Send(connection, protocol::ViewportMessage(viewport_));
  Send(connection, protocol::NavMessage(nav_));
  Send(connection, protocol::CursorMessage(cursor_));
  Send(connection, protocol::TextInputMessage(text_input_));
  if (viewer->mode == "control") {
    for (const auto& [id, open] : dialogs_) {
      Send(connection, protocol::DialogMessage(open.dialog));
    }
  }
  if (!sink_.HasContent() && browser_) {
    browser_->GetHost()->Invalidate(PET_VIEW);
  }
  streamer_->AddViewer(connection, hello.visible);
  UpdateFrameRate();
}

void Tab::HandleSettings(uint64_t connection, Viewer* viewer,
                         const protocol::ClientMessage& message) {
  if (message.stats) {
    viewer->stats = *message.stats;
    if (viewer->stats) {
      const uint64_t generation = ++stats_generation_;
      SendStatsTick(generation);
    }
  }
  const bool changes_tab = message.max_fps || message.quality || message.scale || message.codec;
  if (!changes_tab) {
    return;
  }
  if (viewer->mode != "control") {
    Refuse(connection, viewer, "settings", "control_not_permitted",
           "only control connections change tab settings");
    return;
  }
  if (message.max_fps) settings_.max_fps = *message.max_fps;
  if (message.quality) settings_.quality = *message.quality;
  if (message.scale) settings_.scale = *message.scale;
  if (message.codec) settings_.codec = *message.codec;
  streamer_->ApplySettings(settings_);
  UpdateFrameRate();
  Broadcast(protocol::SettingsMessage(settings_));
}

void Tab::SendStatsTick(uint64_t generation) {
  if (generation != stats_generation_ || closing_) {
    return;
  }
  bool any = false;
  for (const auto& [connection, viewer] : viewers_) {
    if (!viewer.stats) {
      continue;
    }
    any = true;
    protocol::Stats stats = streamer_->Stats(connection);
    stats.host_cpu = host_->host_cpu_cores();
    Send(connection, protocol::StatsMessage(stats));
  }
  if (any) {
    CefRefPtr<Tab> self(this);
    PostUiDelayed([self, generation] { self->SendStatsTick(generation); }, 1000);
  }
}

protocol::ControlState Tab::ControlFor(uint64_t connection) const {
  protocol::ControlState state;
  state.owner = owner_;
  if (owner_ == "user" && holder_ != 0) {
    state.holder = holder_ == connection ? "this" : "other";
  }
  return state;
}

void Tab::BroadcastControl(const std::string& reason) {
  for (const auto& [connection, viewer] : viewers_) {
    if (viewer.hello) {
      Send(connection, protocol::ControlMessage(ControlFor(connection), reason));
    }
  }
}

void Tab::SetOwner(const std::string& owner, uint64_t holder, const std::string& reason) {
  owner_ = owner;
  holder_ = holder;
  ++grace_generation_;
  streamer_->SetUserInControl(owner_ == "user");
  BroadcastControl(reason);
  UpdateFrameRate();
}

void Tab::HandleControl(uint64_t connection, Viewer* viewer,
                        const protocol::ClientMessage& message) {
  if (message.op == "take") {
    SetOwner("user", connection, "take");
    if (browser_ && !focused_) {
      browser_->GetHost()->SetFocus(true);
      focused_ = true;
    }
    return;
  }
  if (holder_ != connection) {
    Refuse(connection, viewer, "control", "not_in_control", "only the holder can release");
    return;
  }
  SetOwner("agent", 0, "release");
}

void Tab::UpdateFrameRate() {
  if (!browser_) {
    return;
  }
  bool watched = false;
  for (const auto& [connection, viewer] : viewers_) {
    watched |= viewer.hello;
  }
  const int fps = !watched ? host_->options().idle_frame_rate
                           : (owner_ == "user" ? std::max<int>(30, settings_.max_fps)
                                               : static_cast<int>(settings_.max_fps));
  browser_->GetHost()->SetWindowlessFrameRate(fps);
}

// MARK: Input

void Tab::InjectMouse(const protocol::ClientMessage& message) {
  if (!browser_) {
    return;
  }
  CefRefPtr<CefBrowserHost> host = browser_->GetHost();
  if (!focused_) {
    host->SetFocus(true);
    focused_ = true;
  }
  CefMouseEvent event;
  event.x = static_cast<int>(std::lround(message.x));
  event.y = static_cast<int>(std::lround(message.y));
  // Clients may omit the button-held bits; derive them from down and up so a down always
  // carries its button and a drag keeps it.
  uint32_t button_flag = 0;
  if (message.button) {
    button_flag = *message.button == "right"    ? kCefRightMouseButton
                  : *message.button == "middle" ? kCefMiddleMouseButton
                                                : kCefLeftMouseButton;
  }
  if (message.kind == "down") {
    pressed_buttons_ |= button_flag;
  }
  event.modifiers = CefFlagsFromModifiers(message.modifiers) | pressed_buttons_;
  if (message.kind == "up") {
    pressed_buttons_ &= ~button_flag;
  }
  if (message.kind == "move") {
    host->SendMouseMoveEvent(event, false);
  } else if (message.kind == "leave") {
    host->SendMouseMoveEvent(event, true);
  } else if (message.kind == "wheel") {
    // DOM deltas are positive for content moving down; CEF wheel deltas are the opposite.
    host->SendMouseWheelEvent(event, -static_cast<int>(std::lround(message.dx.value_or(0))),
                              -static_cast<int>(std::lround(message.dy.value_or(0))));
  } else {
    const std::string& name = *message.button;
    const cef_mouse_button_type_t button =
        name == "right" ? MBT_RIGHT : (name == "middle" ? MBT_MIDDLE : MBT_LEFT);
    host->SendMouseClickEvent(event, button, message.kind == "up", message.clicks.value_or(1));
  }
}

void Tab::FlushPendingInput() {
  std::vector<protocol::ClientMessage> pending;
  pending.swap(pending_input_);
  for (const protocol::ClientMessage& message : pending) {
    if (message.type == protocol::ClientType::kMouse) {
      InjectMouse(message);
    } else if (message.type == protocol::ClientType::kKey) {
      InjectKey(message);
    } else {
      InjectIme(message);
    }
  }
}

void Tab::InjectKey(const protocol::ClientMessage& message) {
  if (!browser_) {
    return;
  }
  CefRefPtr<CefBrowserHost> host = browser_->GetHost();
  if (!focused_) {
    host->SetFocus(true);
    focused_ = true;
  }
  KeyMapping mapping;
  const bool known = LookupKeyCode(message.code, &mapping);
  CefKeyEvent event;
  event.modifiers = CefFlagsFromModifiers(message.modifiers);
  if (mapping.keypad) event.modifiers |= kCefIsKeyPad;
  if (mapping.left) event.modifiers |= kCefIsLeft;
  if (mapping.right) event.modifiers |= kCefIsRight;
  event.windows_key_code = known ? mapping.windows_key_code : 0;
#if defined(__APPLE__)
  event.native_key_code = known ? mapping.mac_keycode : 0xFFFF;
#else
  event.native_key_code = known ? mapping.xkb_keycode : 0;
#endif
  event.is_system_key = false;
  const std::u16string key_text = Utf16(message.key);
  char16_t character = key_text.size() == 1 ? key_text[0] : 0;
#if defined(__APPLE__)
  if (character == 0) {
    character = mapping.mac_function_character;
  }
#endif
  if (message.kind == "char") {
    const std::u16string text = Utf16(message.text.value_or(message.key));
    for (char16_t unit : text) {
      CefKeyEvent char_event = event;
      char_event.type = KEYEVENT_CHAR;
      char_event.character = unit;
      char_event.unmodified_character = unit;
      if (!known) {
        char_event.windows_key_code = unit;
      }
      host->SendKeyEvent(char_event);
    }
    return;
  }
  event.type = message.kind == "keyup" ? KEYEVENT_KEYUP : KEYEVENT_RAWKEYDOWN;
  event.character = character;
  event.unmodified_character = character;
  host->SendKeyEvent(event);
}

void Tab::InjectIme(const protocol::ClientMessage& message) {
  if (!browser_) {
    return;
  }
  CefRefPtr<CefBrowserHost> host = browser_->GetHost();
  if (message.op == "set_composition") {
    const CefString text = message.text.value_or("");
    if (text.empty()) {
      host->ImeCancelComposition();  // An empty composition asserts in the renderer.
      return;
    }
    CefCompositionUnderline underline{};
    underline.size = sizeof(underline);
    underline.range = CefRange(0, static_cast<uint32_t>(text.length()));
    underline.color = CefColorSetARGB(255, 0, 0, 0);
    underline.background_color = CefColorSetARGB(0, 0, 0, 0);
    underline.style = CEF_CUS_SOLID;
    host->ImeSetComposition(text, {underline}, RangeOrInvalid(message.replacement),
                            RangeOrInvalid(message.selection));
  } else if (message.op == "commit") {
    host->ImeCommitText(message.text.value_or(""), RangeOrInvalid(message.replacement), 0);
  } else if (message.op == "finish") {
    host->ImeFinishComposingText(false);
  } else {
    host->ImeCancelComposition();
  }
}

void Tab::HandleNav(uint64_t connection, const protocol::ClientMessage& message) {
  if (!browser_) {
    SendError(connection, "navigation_failed", "the tab is not ready", false);
    return;
  }
  if (message.op == "navigate") {
    browser_->GetMainFrame()->LoadURL(*message.url);
  } else if (message.op == "back") {
    browser_->GoBack();
  } else if (message.op == "forward") {
    browser_->GoForward();
  } else if (message.op == "reload") {
    browser_->Reload();
  } else {
    browser_->StopLoad();
  }
}

void Tab::HandleResize(uint64_t connection, const protocol::ClientMessage& message) {
  const protocol::Viewport& wanted = message.viewport;
  if (wanted.w < 200 || wanted.w > 3840 || wanted.h < 200 || wanted.h > 3840 || wanted.dpr < 1 ||
      wanted.dpr > 3) {
    SendError(connection, "invalid_message", "resize bounds: w and h 200-3840, dpr 1-3", false);
    return;
  }
  const bool dpr_changed = wanted.dpr != viewport_.dpr;
  viewport_ = wanted;
  sink_.Resize(static_cast<int>(std::lround(viewport_.w * viewport_.dpr)),
               static_cast<int>(std::lround(viewport_.h * viewport_.dpr)));
  streamer_->OnCanvasResized();
  if (browser_) {
    if (dpr_changed) {
      browser_->GetHost()->NotifyScreenInfoChanged();
    }
    browser_->GetHost()->WasResized();
  }
  Broadcast(protocol::ViewportMessage(viewport_));
}

void Tab::HandleDialogReply(uint64_t connection, const protocol::ClientMessage& message) {
  auto found = dialogs_.find(message.id);
  if (found == dialogs_.end()) {
    SendError(connection, "no_dialog", "no open dialog " + message.id, false);
    return;
  }
  CefRefPtr<CefJSDialogCallback> callback = found->second.callback;
  dialogs_.erase(found);
  callback->Continue(message.accept, message.text.value_or(""));
  Broadcast(protocol::DialogClosedMessage(message.id));
}

// MARK: Recording

bool Tab::StartRecording(const std::string& path, int max_frames, std::string* error) {
  if (browser_) {
    browser_->GetHost()->SetWindowlessFrameRate(30);
  }
  return streamer_->StartRecording(path, max_frames, error);
}

int Tab::StopRecording() {
  const int frames = streamer_->StopRecording();
  UpdateFrameRate();
  return frames;
}

// MARK: MediaSender

void Tab::SendMedia(uint64_t connection, std::vector<uint8_t> message) {
  host_->SendBytes(connection, EncodeFrame(FrameKind::kBinary, message.data(), message.size()));
}

void Tab::CloseStalled(uint64_t connection) {
  BrowserHost* host = host_;
  PostUi([host, connection] {
    host->CloseConnection(connection, protocol::kCloseTryAgainLater, "viewer stalled");
  });
}

void Tab::Log(const std::string& message) { rb::Log("tab " + id_ + ": " + message); }

void Tab::ReportError(const std::string& code, const std::string& message) {
  CefRefPtr<Tab> self(this);
  PostUi(
      [self, code, message] { self->Broadcast(protocol::ErrorMessage({code, message, false})); });
}

// MARK: CefRenderHandler

void Tab::GetViewRect(CefRefPtr<CefBrowser>, CefRect& rect) {
  rect = CefRect(0, 0, std::max(1, viewport_.w), std::max(1, viewport_.h));
}

bool Tab::GetScreenInfo(CefRefPtr<CefBrowser> browser, CefScreenInfo& screen_info) {
  CefRect view;
  GetViewRect(browser, view);
  screen_info.device_scale_factor = static_cast<float>(viewport_.dpr);
  screen_info.rect = view;
  screen_info.available_rect = view;
  return true;
}

void Tab::OnPopupShow(CefRefPtr<CefBrowser>, bool show) { sink_.SetPopupVisible(show); }

void Tab::OnPopupSize(CefRefPtr<CefBrowser>, const CefRect& rect) {
  const double scale = viewport_.dpr;
  sink_.SetPopupRect({static_cast<int>(std::lround(rect.x * scale)),
                      static_cast<int>(std::lround(rect.y * scale)),
                      static_cast<int>(std::lround(rect.width * scale)),
                      static_cast<int>(std::lround(rect.height * scale))});
}

void Tab::OnPaint(CefRefPtr<CefBrowser>, PaintElementType type, const RectList& dirty_rects,
                  const void* buffer, int width, int height) {
  if (type == PET_POPUP) {
    sink_.PaintPopup(buffer, width, height);
    streamer_->NotifyDamage();
    return;
  }
  std::vector<PixelRect> dirty;
  if (width != sink_.width() || height != sink_.height()) {
    sink_.Resize(width, height);
    streamer_->OnCanvasResized();
    dirty.push_back({0, 0, width, height});
  } else {
    for (const CefRect& rect : dirty_rects) {
      dirty.push_back({rect.x, rect.y, rect.width, rect.height});
    }
  }
  sink_.PaintView(dirty, buffer, width, height);
  streamer_->NotifyDamage();
  if (!painted_) {
    painted_ = true;
    if (!pending_input_.empty()) {
      CefRefPtr<Tab> self(this);
      PostUi([self] { self->FlushPendingInput(); });  // Not from inside the paint callback.
    }
  }
}

void Tab::OnImeCompositionRangeChanged(CefRefPtr<CefBrowser>, const CefRange&,
                                       const RectList& character_bounds) {
  if (character_bounds.empty()) {
    return;
  }
  const CefRect& last = character_bounds.back();
  protocol::Rect caret{static_cast<double>(last.x + last.width), static_cast<double>(last.y), 1,
                       static_cast<double>(last.height)};
  text_input_.caret_rect = caret;
  Broadcast(protocol::TextInputMessage(text_input_));
}

void Tab::OnVirtualKeyboardRequested(CefRefPtr<CefBrowser>, TextInputMode input_mode) {
  const std::string mode = TextInputModeName(input_mode);
  if (mode == text_input_.mode) {
    return;
  }
  text_input_.mode = mode;
  if (mode == "none") {
    text_input_.caret_rect.reset();
  }
  Broadcast(protocol::TextInputMessage(text_input_));
}

// MARK: CefDisplayHandler

void Tab::BroadcastNav() { Broadcast(protocol::NavMessage(nav_)); }

void Tab::OnAddressChange(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, const CefString& url) {
  if (frame->IsMain()) {
    nav_.url = url.ToString();
    BroadcastNav();
  }
}

void Tab::OnTitleChange(CefRefPtr<CefBrowser>, const CefString& title) {
  nav_.title = title.ToString();
  BroadcastNav();
}

void Tab::OnFaviconURLChange(CefRefPtr<CefBrowser>, const std::vector<CefString>& icon_urls) {
  if (icon_urls.empty()) {
    nav_.favicon_url.reset();
  } else {
    nav_.favicon_url = icon_urls.front().ToString();
  }
  BroadcastNav();
}

void Tab::OnLoadingProgressChange(CefRefPtr<CefBrowser>, double progress) {
  nav_.progress = progress;
  BroadcastNav();
}

bool Tab::OnCursorChange(CefRefPtr<CefBrowser>, CefCursorHandle, cef_cursor_type_t type,
                         const CefCursorInfo& custom_cursor_info) {
  protocol::CursorState cursor;
  cursor.cursor = CursorName(type);
  if (type == CT_CUSTOM && custom_cursor_info.buffer != nullptr) {
    CefRefPtr<CefImage> image = CefImage::CreateImage();
    const int width = custom_cursor_info.size.width;
    const int height = custom_cursor_info.size.height;
    const float scale =
        custom_cursor_info.image_scale_factor > 0 ? custom_cursor_info.image_scale_factor : 1;
    int png_width = 0;
    int png_height = 0;
    if (image->AddBitmap(scale, width, height, CEF_COLOR_TYPE_BGRA_8888,
                         CEF_ALPHA_TYPE_PREMULTIPLIED, custom_cursor_info.buffer,
                         static_cast<size_t>(width) * height * 4)) {
      CefRefPtr<CefBinaryValue> png = image->GetAsPNG(scale, true, png_width, png_height);
      if (png && png->GetSize() > 0) {
        std::vector<uint8_t> bytes(png->GetSize());
        png->GetData(bytes.data(), bytes.size(), 0);
        cursor.custom =
            protocol::CustomCursor{CefBase64Encode(bytes.data(), bytes.size()).ToString(),
                                   static_cast<double>(custom_cursor_info.hotspot.x),
                                   static_cast<double>(custom_cursor_info.hotspot.y), scale};
      }
    }
    if (!cursor.custom) {
      Log("could not convert a custom cursor; showing default");
      cursor.cursor = "default";
    }
  }
  cursor_ = cursor;
  Broadcast(protocol::CursorMessage(cursor_));
  return true;
}

// MARK: CefLoadHandler

void Tab::OnLoadingStateChange(CefRefPtr<CefBrowser>, bool is_loading, bool can_go_back,
                               bool can_go_forward) {
  nav_.loading = is_loading;
  nav_.can_go_back = can_go_back;
  nav_.can_go_forward = can_go_forward;
  if (!is_loading) {
    nav_.progress = 1;
  }
  BroadcastNav();
}

void Tab::OnLoadError(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, ErrorCode error_code,
                      const CefString& error_text, const CefString& failed_url) {
  if (!frame->IsMain() || error_code == ERR_ABORTED) {
    return;
  }
  Broadcast(protocol::ErrorMessage({"navigation_failed",
                                    failed_url.ToString() + ": " + error_text.ToString() + " (" +
                                        std::to_string(error_code) + ")",
                                    false}));
}

// MARK: CefLifeSpanHandler

bool Tab::OnBeforePopup(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, int popup_id,
                        const CefString& target_url, const CefString&,
                        cef_window_open_disposition_t, bool, const CefPopupFeatures&,
                        CefWindowInfo& window_info, CefRefPtr<CefClient>& client,
                        CefBrowserSettings& settings, CefRefPtr<CefDictionaryValue>&, bool*) {
  if (host_->shutting_down()) {
    return true;
  }
  // window.open and target=_blank become host tabs in the same session (section 6).
  CefRefPtr<Tab> popup = host_->NewTab(session_id_, created_by_, viewport_);
  popup->nav_.url = target_url.ToString();
  popup->ExpectBrowser();
  ConfigureWindowless(&window_info, &settings);
  client = popup;
  pending_popups_[popup_id] = popup->id();
  Log("popup " + target_url.ToString() + " opens as tab " + popup->id());
  return false;
}

void Tab::OnBeforePopupAborted(CefRefPtr<CefBrowser>, int popup_id) {
  auto found = pending_popups_.find(popup_id);
  if (found == pending_popups_.end()) {
    return;
  }
  const std::string tab_id = found->second;
  pending_popups_.erase(found);
  Log("Chromium aborted popup tab " + tab_id);
  host_->OnTabClosed(tab_id);
}

bool Tab::OnOpenURLFromTab(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame>,
                           const CefString& target_url, cef_window_open_disposition_t disposition,
                           bool) {
  if (disposition == CEF_WOD_CURRENT_TAB || host_->shutting_down()) {
    return false;
  }
  CefRefPtr<Tab> tab = host_->NewTab(session_id_, created_by_, viewport_);
  if (!tab->Create(target_url.ToString(), browser->GetHost()->GetRequestContext())) {
    Log("CreateBrowser failed for a new-tab link");
    tab->browser_requested_ = false;
    tab->Close("closed");
  }
  return true;
}

void Tab::OnAfterCreated(CefRefPtr<CefBrowser> browser) {
  browser_ = browser;
  Log("browser created (windowless " +
      std::string(browser->GetHost()->IsWindowRenderingDisabled() ? "yes" : "no") + ")");
  devtools_registration_ = browser->GetHost()->AddDevToolsMessageObserver(this);
  if (closing_) {
    browser->GetHost()->CloseBrowser(true);
    return;
  }
  browser->GetHost()->SetFocus(true);
  focused_ = true;
  UpdateFrameRate();
  // The result can arrive before ExecuteDevToolsMethod returns, so the id is chosen up front.
  target_info_message_ = 1;
  if (browser->GetHost()->ExecuteDevToolsMethod(target_info_message_, "Target.getTargetInfo",
                                                nullptr) == 0) {
    Log("CEF rejected Target.getTargetInfo");
    std::vector<std::function<void()>> waiters;
    waiters.swap(target_waiters_);
    for (auto& waiter : waiters) {
      waiter();
    }
  }
}

bool Tab::DoClose(CefRefPtr<CefBrowser>) {
  return false;  // Windowless: let CEF finish the close.
}

void Tab::OnBeforeClose(CefRefPtr<CefBrowser>) {
  closing_ = true;
  devtools_registration_ = nullptr;
  browser_ = nullptr;
  streamer_->Shutdown();
  for (auto& [id, open] : dialogs_) {
    open.callback->Continue(false, CefString());
  }
  dialogs_.clear();
  std::vector<uint64_t> connections;
  for (const auto& [connection, viewer] : viewers_) {
    connections.push_back(connection);
  }
  for (uint64_t connection : connections) {
    if (viewers_[connection].hello) {
      Send(connection, protocol::TabClosedMessage(close_reason_));
    }
    CloseViewer(connection, protocol::kCloseTabGone, "tab " + close_reason_);
  }
  viewers_.clear();
  std::vector<std::function<void()>> waiters;
  waiters.swap(target_waiters_);
  for (auto& waiter : waiters) {
    waiter();
  }
  host_->OnTabClosed(id_);
}

// MARK: CefRequestHandler

void Tab::OnRenderProcessTerminated(CefRefPtr<CefBrowser>, TerminationStatus status, int error_code,
                                    const CefString& error_string) {
  Log("renderer terminated (status " + std::to_string(status) + ", code " +
      std::to_string(error_code) + "): " + error_string.ToString());
  Close("crashed");
}

// MARK: Dialogs

bool Tab::OnJSDialog(CefRefPtr<CefBrowser>, const CefString& origin_url, JSDialogType dialog_type,
                     const CefString& message_text, const CefString& default_prompt_text,
                     CefRefPtr<CefJSDialogCallback> callback, bool&) {
  protocol::Dialog dialog;
  dialog.id = "dlg_" + std::to_string(++next_dialog_);
  dialog.kind = DialogKind(dialog_type);
  dialog.message = message_text.ToString();
  dialog.origin = origin_url.ToString();
  if (dialog_type == JSDIALOGTYPE_PROMPT) {
    dialog.default_text = default_prompt_text.ToString();
  }
  if (owner_ != "user") {
    // The agent's dialog tools land with the control API (M2); until then the host answers
    // so the page does not stall: alerts and confirms accept, prompts take their default.
    Log("agent-owned tab: auto-accepting " + dialog.kind + " '" + dialog.message + "'");
    callback->Continue(true, default_prompt_text);
    return true;
  }
  dialogs_[dialog.id] = OpenDialog{dialog, callback};
  for (const auto& [connection, viewer] : viewers_) {
    if (viewer.hello && viewer.mode == "control") {
      Send(connection, protocol::DialogMessage(dialog));
    }
  }
  return true;
}

bool Tab::OnBeforeUnloadDialog(CefRefPtr<CefBrowser> browser, const CefString& message_text, bool,
                               CefRefPtr<CefJSDialogCallback> callback) {
  if (owner_ != "user" || closing_) {
    callback->Continue(true, CefString());
    return true;
  }
  protocol::Dialog dialog;
  dialog.id = "dlg_" + std::to_string(++next_dialog_);
  dialog.kind = "beforeunload";
  dialog.message = message_text.ToString();
  dialog.origin = browser->GetMainFrame()->GetURL().ToString();
  dialogs_[dialog.id] = OpenDialog{dialog, callback};
  for (const auto& [connection, viewer] : viewers_) {
    if (viewer.hello && viewer.mode == "control") {
      Send(connection, protocol::DialogMessage(dialog));
    }
  }
  return true;
}

void Tab::OnResetDialogState(CefRefPtr<CefBrowser>) {
  std::vector<std::string> closed;
  for (const auto& [id, open] : dialogs_) {
    closed.push_back(id);
  }
  dialogs_.clear();
  for (const std::string& id : closed) {
    Broadcast(protocol::DialogClosedMessage(id));
  }
}

bool Tab::OnFileDialog(CefRefPtr<CefBrowser>, FileDialogMode, const CefString& title,
                       const CefString&, const std::vector<CefString>&,
                       const std::vector<CefString>&, const std::vector<CefString>&,
                       CefRefPtr<CefFileDialogCallback> callback) {
  // Uploads are out of scope for v1; cancel rather than open a native dialog on the host.
  Log("cancelled a file chooser ('" + title.ToString() + "'): uploads are not supported");
  callback->Cancel();
  Broadcast(protocol::ErrorMessage({"unsupported", "file uploads are not supported yet", false}));
  return true;
}

// MARK: CefDevToolsMessageObserver

void Tab::OnDevToolsMethodResult(CefRefPtr<CefBrowser>, int message_id, bool success,
                                 const void* result, size_t result_size) {
  if (message_id != target_info_message_ || !target_id_.empty()) {
    return;
  }
  const std::string json(static_cast<const char*>(result), result_size);
  std::string error;
  std::optional<Json> parsed = Json::Parse(json, &error);
  const Json* info = parsed ? parsed->Find("targetInfo") : nullptr;
  if (success && info != nullptr) {
    target_id_ = info->GetString("targetId").value_or("");
  }
  if (target_id_.empty()) {
    Log("Target.getTargetInfo failed: " + json);
  }
  std::vector<std::function<void()>> waiters;
  waiters.swap(target_waiters_);
  for (auto& waiter : waiters) {
    waiter();
  }
}

}  // namespace rb
