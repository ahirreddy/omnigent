#include "OWLHost.hpp"

#import <AppKit/AppKit.h>

#include <unistd.h>

#include <algorithm>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <optional>
#include <vector>

#include "OWLBrowserClient.hpp"
#include "OWLPresenter.hpp"
#include "include/cef_app.h"
#include "include/cef_application_mac.h"
#include "include/cef_version.h"
#include "include/wrapper/cef_library_loader.h"

@interface OWLHostApplication : NSApplication <CefAppProtocol> {
  BOOL _handlingSendEvent;
}
@end

@implementation OWLHostApplication

- (BOOL)isHandlingSendEvent {
  return _handlingSendEvent;
}

- (void)setHandlingSendEvent:(BOOL)handlingSendEvent {
  _handlingSendEvent = handlingSendEvent;
}

- (void)sendEvent:(NSEvent*)event {
  CefScopedSendingEvent sending_event_scoper;
  [super sendEvent:event];
}

- (void)terminate:(id)sender {
  (void)sender;
  owl::Host::Get().BeginShutdown("terminate: was sent to the host application");
}

@end

namespace owl {

namespace {

constexpr uint32_t kSendTimeoutMs = 250;
constexpr int64_t kAckTimeoutSeconds = 10;
constexpr int64_t kShutdownWatchdogSeconds = 5;

void Log(const char* format, ...) __attribute__((format(printf, 1, 2)));
void Log(const char* format, ...) {
  va_list arguments;
  va_start(arguments, format);
  std::fprintf(stderr, "owl-host[%d]: ", getpid());
  std::vfprintf(stderr, format, arguments);
  std::fputc('\n', stderr);
  va_end(arguments);
}

void OnMessageThunk(void*, owl_message* message) {
  Host::Get().OnChannelMessage(message);
}

void OnEventThunk(void*, owl_channel_event event, int64_t detail) {
  Host::Get().OnChannelEvent(event, detail);
}

bool IsValidStorageKey(const std::string& key) {
  if (key.empty() || key.size() > 64) {
    return false;
  }
  for (char character : key) {
    const bool hex = (character >= '0' && character <= '9') || (character >= 'a' && character <= 'f');
    if (!hex) {
      return false;
    }
  }
  return true;
}

/// Lets the views' popup policy decide (OWLBrowserPopups.mm): Chrome's own popup blocker would
/// otherwise drop gesture-less window.open before OnBeforePopup, without telling anyone. Only
/// persistent contexts accept a default content setting; incognito (ephemeral) ones keep
/// Chrome's blocker for opens without a user gesture.
class PopupSettingHandler : public CefRequestContextHandler {
 public:
  void OnRequestContextInitialized(CefRefPtr<CefRequestContext> context) override {
    context->SetContentSetting(CefString(), CefString(), CEF_CONTENT_SETTING_TYPE_POPUPS,
                               CEF_CONTENT_SETTING_VALUE_ALLOW);
  }

 private:
  IMPLEMENT_REFCOUNTING(PopupSettingHandler);
};

class HostApp : public CefApp, public CefBrowserProcessHandler {
 public:
  explicit HostApp(bool use_mock_keychain) : use_mock_keychain_(use_mock_keychain) {}

  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override { return this; }

  void OnBeforeCommandLineProcessing(const CefString& process_type,
                                     CefRefPtr<CefCommandLine> command_line) override {
    if (process_type.empty() && use_mock_keychain_) {
      command_line->AppendSwitch("use-mock-keychain");
    }
    if (process_type.empty()) {
      // Chrome copies its bundle to a temporary "code sign clone" so in-place updates cannot
      // break running helpers, then launches a detached --type=code-sign-clone-cleanup helper at
      // exit. CEF helpers cannot run that type and crash. The host bundle is immutable inside
      // the signed app, so the clone is unnecessary.
      command_line->AppendSwitchWithValue("disable-features", "MacAppCodeSignClone");
      // Without this, HTTP auth opens Chrome's own login dialog as a window in the host process
      // instead of calling CefRequestHandler::GetAuthCredentials.
      command_line->AppendSwitch("disable-chrome-login-prompt");
    }
  }

  void OnContextInitialized() override { Host::Get().OnContextInitialized(); }

 private:
  bool use_mock_keychain_;
  IMPLEMENT_REFCOUNTING(HostApp);
};

/// Whether the private API behind remote-layer mode exists. Checked before choosing the mode.
bool RemoteLayerAvailable() {
  return NSClassFromString(@"CAContext") != Nil &&
         [NSClassFromString(@"CAContext")
             respondsToSelector:NSSelectorFromString(@"contextWithCGSConnection:options:")];
}

}  // namespace

Host& Host::Get() {
  static Host* host = new Host();
  return *host;
}

bool Host::ParseOptions(int argc, char* argv[]) {
  for (int index = 1; index < argc; ++index) {
    const std::string argument = argv[index];
    auto value = [&](const char* prefix) -> std::optional<std::string> {
      const size_t length = std::strlen(prefix);
      if (argument.compare(0, length, prefix) == 0) {
        return argument.substr(length);
      }
      return std::nullopt;
    };
    if (auto service = value("--owl-service=")) {
      options_.service = *service;
    } else if (auto token = value("--owl-token=")) {
      options_.token = *token;
    } else if (auto parent = value("--owl-parent-pid=")) {
      options_.parent_pid = static_cast<pid_t>(std::strtol(parent->c_str(), nullptr, 10));
    }
  }
  return !options_.service.empty() && !options_.token.empty() && options_.parent_pid > 0;
}

bool Host::Connect() {
  owl_channel* channel = nullptr;
  kern_return_t kr = owl_channel_connect(options_.service.c_str(), &channel);
  if (kr != KERN_SUCCESS || channel == nullptr) {
    Log("cannot connect to %s: %s (%d)", options_.service.c_str(), owl_error_string(kr), kr);
    return false;
  }
  channel_ = channel;
  owl_channel_set_expected_pid(channel_, options_.parent_pid);
  owl_channel_start(channel_, dispatch_get_main_queue(), nullptr, OnMessageThunk, OnEventThunk);
  char chromium_version[64];
  std::snprintf(chromium_version, sizeof(chromium_version), "%d.%d.%d.%d", CHROME_VERSION_MAJOR,
                CHROME_VERSION_MINOR, CHROME_VERSION_BUILD, CHROME_VERSION_PATCH);
  Send(OWLMessageKindHello, 0, 0,
       Encoder()
           .U64(OWLFieldProtocolMajor, OWL_PROTOCOL_MAJOR)
           .U64(OWLFieldProtocolMinor, OWL_PROTOCOL_MINOR)
           .String(OWLFieldToken, options_.token)
           .U64(OWLFieldHostPID, static_cast<uint64_t>(getpid()))
           .String(OWLFieldCEFVersion, CEF_VERSION)
           .String(OWLFieldChromiumVersion, chromium_version),
       owl_channel_receive_port(channel_), MACH_MSG_TYPE_MAKE_SEND);
  return true;
}

bool Host::WaitForAck() {
  NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:kAckTimeoutSeconds];
  while (!ack_received_ && !shutting_down_ && deadline.timeIntervalSinceNow > 0) {
    @autoreleasepool {
      [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode
                          beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
  }
  if (!ack_received_) {
    Log("no HelloAck from the client within %llds", static_cast<long long>(kAckTimeoutSeconds));
    return false;
  }
  return ack_accepted_;
}

void Host::HandleHelloAck(const Decoder& fields) {
  ack_received_ = true;
  if (!fields.Bool(OWLFieldAccepted).value_or(false)) {
    Log("client rejected the handshake: %s",
        fields.String(OWLFieldReason).value_or("no reason").c_str());
    return;
  }
  auto root = fields.String(OWLFieldRootCachePath);
  if (!root || root->empty()) {
    Log("HelloAck has no RootCachePath");
    return;
  }
  config_.root_cache_path = *root;
  config_.locale = fields.String(OWLFieldLocale).value_or("");
  config_.keychain_service = fields.String(OWLFieldKeychainService).value_or("");
  config_.remote_debugging_port =
      static_cast<int>(fields.U64(OWLFieldRemoteDebuggingPort).value_or(0));
  config_.use_mock_keychain = fields.Bool(OWLFieldUseMockKeychain).value_or(false);
  config_.disable_sandbox = fields.Bool(OWLFieldDisableSandbox).value_or(false);
  const uint64_t mode = fields.U64(OWLFieldRenderMode).value_or(OWLRenderModeRemoteLayer);
  config_.render_mode =
      mode == OWLRenderModeIOSurface ? OWLRenderModeIOSurface : OWLRenderModeRemoteLayer;
  config_.client_minor = fields.U64(OWLFieldProtocolMinor).value_or(0);
  ack_accepted_ = true;
}

bool Host::InitializeCef(int argc, char* argv[]) {
  NSBundle* bundle = NSBundle.mainBundle;
  NSString* frameworks = bundle.privateFrameworksPath;
  NSString* executable = bundle.executablePath.lastPathComponent;
  if (frameworks == nil || executable == nil) {
    Send(OWLMessageKindInitFailed, 0, 0,
         Encoder().String(OWLFieldReason, "The host is not running from its app bundle."));
    return false;
  }
  NSString* helper_name = [executable stringByAppendingString:@" Helper"];
  NSString* helper = [frameworks
      stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.app/Contents/MacOS/%@",
                                                                helper_name, helper_name]];
  NSString* framework = [frameworks stringByAppendingPathComponent:@"Chromium Embedded Framework.framework"];
  NSString* root = [NSString stringWithUTF8String:config_.root_cache_path.c_str()];
  NSError* directory_error = nil;
  if (![NSFileManager.defaultManager createDirectoryAtPath:root
                               withIntermediateDirectories:YES
                                                attributes:nil
                                                     error:&directory_error]) {
    std::string reason = "Cannot create the Chromium profile directory: ";
    const char* detail = directory_error.localizedDescription.UTF8String;
    reason += detail != nullptr ? detail : "unknown error";
    Send(OWLMessageKindInitFailed, 0, 0, Encoder().String(OWLFieldReason, reason));
    return false;
  }

  CefMainArgs main_args(argc, argv);
  CefSettings settings;
  settings.no_sandbox = config_.disable_sandbox;
  settings.windowless_rendering_enabled = true;
  settings.command_line_args_disabled = true;
  settings.persist_session_cookies = true;
  settings.remote_debugging_port = config_.remote_debugging_port;
  settings.log_severity = LOGSEVERITY_WARNING;
  CefString(&settings.browser_subprocess_path) = helper.UTF8String;
  CefString(&settings.framework_dir_path) = framework.UTF8String;
  CefString(&settings.main_bundle_path) = bundle.bundlePath.UTF8String;
  CefString(&settings.root_cache_path) = config_.root_cache_path;
  CefString(&settings.log_file) = config_.root_cache_path + "/chromium-host.log";
  if (!config_.locale.empty()) {
    CefString(&settings.locale) = config_.locale;
  }
  if (!config_.keychain_service.empty()) {
    CefString(&settings.keychain_service_name) = config_.keychain_service;
  }
  CefRefPtr<HostApp> app(new HostApp(config_.use_mock_keychain));
  if (!CefInitialize(main_args, settings, app.get(), nullptr)) {
    std::string reason = "CefInitialize failed with exit code " + std::to_string(CefGetExitCode()) +
                         ". Another process may be using " + config_.root_cache_path + ".";
    Send(OWLMessageKindInitFailed, 0, 0, Encoder().String(OWLFieldReason, reason));
    return false;
  }
  cef_initialized_ = true;
  return true;
}

int Host::Run(int argc, char* argv[]) {
  start_nanos_ = NowNanos();
  if (!ParseOptions(argc, argv)) {
    Log("usage: %s --owl-service=<name> --owl-token=<token> --owl-parent-pid=<pid>", argv[0]);
    return 64;
  }
  if (getppid() != options_.parent_pid) {
    Log("parent %d is gone (getppid=%d); exiting", options_.parent_pid, getppid());
    return 0;
  }
  [OWLHostApplication sharedApplication];
  [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

  dispatch_source_t parent_watch = dispatch_source_create(
      DISPATCH_SOURCE_TYPE_PROC, static_cast<uintptr_t>(options_.parent_pid), DISPATCH_PROC_EXIT,
      dispatch_get_main_queue());
  dispatch_source_set_event_handler(parent_watch, ^{
    BeginShutdown("the client process exited");
  });
  dispatch_activate(parent_watch);

  if (!Connect()) {
    return 69;
  }
  if (!WaitForAck()) {
    return shutting_down_ ? 0 : 65;
  }
  if (config_.render_mode == OWLRenderModeRemoteLayer && !RemoteLayerAvailable()) {
    Log("CAContext is unavailable; falling back to iosurface mode");
    config_.render_mode = OWLRenderModeIOSurface;
  }

  CefScopedLibraryLoader library_loader;
  if (!library_loader.LoadInMain()) {
    Send(OWLMessageKindInitFailed, 0, 0,
         Encoder().String(OWLFieldReason, "Could not load Chromium Embedded Framework."));
    return 70;
  }
  if (!InitializeCef(argc, argv)) {
    return 70;
  }
  CefRunMessageLoop();
  views_.clear();
  profiles_.clear();
  const uint64_t shutdown_start = NowNanos();
  CefShutdown();
  Log("CefShutdown finished in %llu ms",
      static_cast<unsigned long long>((NowNanos() - shutdown_start) / 1000000));
  return 0;
}

void Host::OnContextInitialized() {
  context_ready_ = true;
  const uint64_t elapsed = (NowNanos() - start_nanos_) / 1000000;
  Log("CEF %s ready in %llu ms (render mode %llu, client protocol minor %llu)", CEF_VERSION,
      static_cast<unsigned long long>(elapsed),
      static_cast<unsigned long long>(config_.render_mode),
      static_cast<unsigned long long>(config_.client_minor));
  Send(OWLMessageKindReady, 0, 0,
       Encoder()
           .U64(OWLFieldElapsedMilliseconds, elapsed)
           .U64(OWLFieldRenderMode, config_.render_mode));
  if (shutting_down_ && views_.empty()) {
    QuitLoop();
  }
}

void Host::Send(OWLMessageKind kind, uint64_t request, uint64_t target, const Encoder& payload,
                mach_port_t port, mach_msg_type_name_t disposition) {
  if (channel_ == nullptr) {
    return;
  }
  const auto& data = payload.data();
  kern_return_t kr = owl_channel_send(channel_, kind, request, target, data.data(), data.size(),
                                      port, disposition, kSendTimeoutMs);
  if (kr == KERN_SUCCESS) {
    return;
  }
  if (kr == MACH_SEND_INVALID_DEST && shutting_down_) {
    return;  // The client is already gone; nothing is waiting for this message.
  }
  Log("send of message %u failed: %s (%d)", kind, owl_error_string(kr), kr);
  if (kr == MACH_SEND_INVALID_DEST) {
    BeginShutdown("the client channel is gone");
  }
}

void Host::ReportError(uint64_t target, OWLHostErrorCode code, const std::string& message) {
  Log("error %llu for target %llu: %s", static_cast<unsigned long long>(code),
      static_cast<unsigned long long>(target), message.c_str());
  Send(OWLMessageKindHostError, 0, target,
       Encoder().U64(OWLFieldErrorCode, code).String(OWLFieldMessage, message));
}

void Host::QuitLoop() {
  if (!quit_posted_ && cef_initialized_) {
    quit_posted_ = true;
    CefQuitMessageLoop();
  }
}

void Host::BeginShutdown(const char* reason) {
  if (shutting_down_) {
    return;
  }
  shutting_down_ = true;
  Log("shutting down: %s", reason);
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, kShutdownWatchdogSeconds * NSEC_PER_SEC),
                 dispatch_get_main_queue(), ^{
                   Log("shutdown did not finish in %llds; exiting",
                       static_cast<long long>(kShutdownWatchdogSeconds));
                   _exit(3);
                 });
  if (!cef_initialized_) {
    return;
  }
  if (views_.empty()) {
    QuitLoop();
    return;
  }
  // Close() can finish synchronously and erase from views_, so iterate over a copy.
  std::vector<CefRefPtr<BrowserClient>> closing;
  closing.reserve(views_.size());
  for (const auto& entry : views_) {
    closing.push_back(entry.second);
  }
  for (const auto& view : closing) {
    view->Close();
  }
}

void Host::OnBrowserClosed(uint64_t view_id) {
  Send(OWLMessageKindViewClosed, 0, view_id, Encoder());
  views_.erase(view_id);
  if (shutting_down_ && views_.empty()) {
    QuitLoop();
  }
}

uint64_t Host::AllocateHostViewID() {
  while (views_.count(next_host_view_id_) != 0) {
    ++next_host_view_id_;
  }
  return next_host_view_id_++;
}

void Host::AdoptView(uint64_t view_id, CefRefPtr<BrowserClient> client) {
  views_[view_id] = client;
}

void Host::AbandonView(uint64_t view_id) {
  if (views_.erase(view_id) != 0) {
    Send(OWLMessageKindViewClosed, 0, view_id, Encoder());
  }
  if (shutting_down_ && views_.empty()) {
    QuitLoop();
  }
}

void Host::OnChannelEvent(owl_channel_event event, int64_t detail) {
  switch (event) {
    case OWL_CHANNEL_EVENT_PEER_DIED:
      BeginShutdown("the client channel closed");
      break;
    case OWL_CHANNEL_EVENT_RECEIVE_FAILED:
      Log("receive failed: %s (%lld)", owl_error_string(static_cast<kern_return_t>(detail)),
          static_cast<long long>(detail));
      break;
    case OWL_CHANNEL_EVENT_SENDER_REJECTED:
      Log("rejected a message from pid %lld", static_cast<long long>(detail));
      break;
    case OWL_CHANNEL_EVENT_MALFORMED:
      Log("dropped a malformed message of %lld bytes", static_cast<long long>(detail));
      break;
    case OWL_CHANNEL_EVENT_CANCELLED:
      break;
  }
}

void Host::OnChannelMessage(owl_message* message) {
  if (message->protocol_major != OWL_PROTOCOL_MAJOR) {
    ReportError(message->target, OWLHostErrorMalformedMessage,
                "Protocol major " + std::to_string(message->protocol_major) + " is not supported.");
    return;
  }
  auto fields = Decoder::Parse(message->payload, message->payload_length);
  if (!fields) {
    ReportError(message->target, OWLHostErrorMalformedMessage,
                "Message " + std::to_string(message->kind) + " has a malformed payload.");
    return;
  }
  if (message->kind < OWLMessageKindProfileCreate) {
    HandleSessionMessage(message, *fields);
  } else if (message->kind < OWLMessageKindViewCreate) {
    HandleProfileMessage(message, *fields);
  } else {
    HandleViewMessage(message, *fields);
  }
}

void Host::HandleSessionMessage(owl_message* message, const Decoder& fields) {
  switch (message->kind) {
    case OWLMessageKindHelloAck:
      HandleHelloAck(fields);
      break;
    case OWLMessageKindPing:
      Send(OWLMessageKindPong, message->request, 0, Encoder());
      break;
    case OWLMessageKindShutdown:
      BeginShutdown("the client requested it");
      break;
    default:
      ReportError(0, OWLHostErrorUnknownMessage,
                  "Unknown session message " + std::to_string(message->kind) + ".");
      break;
  }
}

void Host::HandleProfileMessage(owl_message* message, const Decoder& fields) {
  const uint64_t profile_id = message->target;
  if (!context_ready_) {
    ReportError(profile_id, OWLHostErrorProfileCreateFailed, "Chromium is not ready yet.");
    return;
  }
  switch (message->kind) {
    case OWLMessageKindProfileCreate: {
      auto key = fields.String(OWLFieldStorageKey);
      auto persistent = fields.Bool(OWLFieldPersistent);
      if (!key || !persistent || !IsValidStorageKey(*key)) {
        ReportError(profile_id, OWLHostErrorProfileCreateFailed,
                    "ProfileCreate needs a hex StorageKey and Persistent.");
        return;
      }
      CefRequestContextSettings settings;
      if (*persistent) {
        // Chrome-style profiles must be direct children of root_cache_path.
        CefString(&settings.cache_path) = config_.root_cache_path + "/Profile-" + *key;
        settings.persist_session_cookies = true;
      }
      // An empty cache_path gives an isolated in-memory (off-the-record) context.
      CefRefPtr<CefRequestContextHandler> handler;
      if (*persistent && config_.client_minor >= OWL_PROTOCOL_MINOR_PROMPTS) {
        handler = new PopupSettingHandler();
      }
      CefRefPtr<CefRequestContext> context = CefRequestContext::CreateContext(settings, handler);
      if (!context) {
        ReportError(profile_id, OWLHostErrorProfileCreateFailed,
                    "CefRequestContext::CreateContext failed for profile " + *key + ".");
        return;
      }
      profiles_[profile_id] = context;
      break;
    }
    case OWLMessageKindProfileDestroy:
      profiles_.erase(profile_id);
      break;
    default:
      ReportError(profile_id, OWLHostErrorUnknownMessage,
                  "Unknown profile message " + std::to_string(message->kind) + ".");
      break;
  }
}

void Host::CreateView(uint64_t view_id, const Decoder& fields) {
  if (shutting_down_) {
    return;
  }
  auto profile_id = fields.U64(OWLFieldProfileID);
  auto found = profile_id ? profiles_.find(*profile_id) : profiles_.end();
  if (found == profiles_.end()) {
    ReportError(view_id, OWLHostErrorUnknownProfile, "ViewCreate names an unknown profile.");
    return;
  }
  if (views_.count(view_id) != 0) {
    ReportError(view_id, OWLHostErrorViewCreateFailed, "The view already exists.");
    return;
  }
  const double width = std::max(1.0, fields.Double(OWLFieldWidth).value_or(800));
  const double height = std::max(1.0, fields.Double(OWLFieldHeight).value_or(600));
  const double scale = std::max(1.0, fields.Double(OWLFieldScale).value_or(2));
  const bool visible = fields.Bool(OWLFieldVisible).value_or(true);
  const std::string url = fields.String(OWLFieldURL).value_or("about:blank");
  CefRefPtr<BrowserClient> client(new BrowserClient(view_id, width, height, scale, visible));
  client->ApplyInitialPolicies(fields);
  std::string error;
  if (!client->StartPresenter(&error)) {
    ReportError(view_id, OWLHostErrorViewCreateFailed, error);
    return;
  }
  CefWindowInfo window_info;
  window_info.SetAsWindowless(nullptr);
  window_info.shared_texture_enabled = true;
  window_info.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
  CefBrowserSettings browser_settings;
  browser_settings.windowless_frame_rate = 60;
  browser_settings.background_color = CefColorSetARGB(255, 255, 255, 255);
  if (!CefBrowserHost::CreateBrowser(window_info, client, url, browser_settings, nullptr,
                                     found->second)) {
    ReportError(view_id, OWLHostErrorViewCreateFailed, "CefBrowserHost::CreateBrowser failed.");
    return;
  }
  views_[view_id] = client;
}

void Host::HandleViewMessage(owl_message* message, const Decoder& fields) {
  const uint64_t view_id = message->target;
  if (message->kind == OWLMessageKindViewCreate) {
    if (!context_ready_) {
      ReportError(view_id, OWLHostErrorViewCreateFailed, "Chromium is not ready yet.");
      return;
    }
    CreateView(view_id, fields);
    return;
  }
  auto found = views_.find(view_id);
  if (found == views_.end()) {
    ReportError(view_id, OWLHostErrorUnknownView,
                "Message " + std::to_string(message->kind) + " names an unknown view.");
    return;
  }
  // Hold a reference: Close() and other calls can erase the map entry.
  CefRefPtr<BrowserClient> view = found->second;
  if (BrowserClient::IsBrowserUICommand(message->kind)) {
    view->HandleBrowserUICommand(message->kind, fields);
    return;
  }
  switch (message->kind) {
    case OWLMessageKindViewClose:
      view->Close();
      break;
    case OWLMessageKindViewResize:
      view->Resize(fields.Double(OWLFieldWidth).value_or(1), fields.Double(OWLFieldHeight).value_or(1),
                  fields.Double(OWLFieldScale).value_or(1), fields.Double(OWLFieldScreenX).value_or(0),
                  fields.Double(OWLFieldScreenY).value_or(0));
      break;
    case OWLMessageKindViewVisibility:
      view->SetVisible(fields.Bool(OWLFieldVisible).value_or(true));
      break;
    case OWLMessageKindViewFocus:
      view->SetFocused(fields.Bool(OWLFieldFocused).value_or(false));
      break;
    case OWLMessageKindNavigate:
      view->Navigate(fields.String(OWLFieldURL).value_or("about:blank"));
      break;
    case OWLMessageKindGoBack:
      view->GoBack();
      break;
    case OWLMessageKindGoForward:
      view->GoForward();
      break;
    case OWLMessageKindReload:
      view->Reload(fields.Bool(OWLFieldIgnoreCache).value_or(false));
      break;
    case OWLMessageKindSetAudioMuted:
      view->SetAudioMuted(fields.Bool(OWLFieldMuted).value_or(false));
      break;
    case OWLMessageKindStop:
      view->Stop();
      break;
    case OWLMessageKindSetZoom:
      view->SetZoom(fields.Double(OWLFieldZoomLevel).value_or(0));
      break;
    case OWLMessageKindEvaluate:
      view->Evaluate(message->request, fields.String(OWLFieldScript).value_or(""));
      break;
    case OWLMessageKindSnapshot:
      view->Snapshot(message->request);
      break;
    case OWLMessageKindFind:
      view->Find(fields.String(OWLFieldText).value_or(""), fields.Bool(OWLFieldForward).value_or(true),
                fields.Bool(OWLFieldMatchCase).value_or(false),
                fields.Bool(OWLFieldFindNext).value_or(false));
      break;
    case OWLMessageKindStopFind:
      view->StopFind();
      break;
    case OWLMessageKindShowDevTools:
      view->ShowDevTools();
      break;
    case OWLMessageKindDevToolsMethod:
      view->DevToolsMethod(message->request, fields.String(OWLFieldMethod).value_or(""),
                          fields.String(OWLFieldJSON).value_or(""));
      break;
    case OWLMessageKindInputMouse:
      view->InputMouse(fields);
      break;
    case OWLMessageKindInputKey:
      view->InputKey(fields);
      break;
    case OWLMessageKindFrameAck:
      view->AcknowledgeFrame(static_cast<uint32_t>(fields.U64(OWLFieldSurfaceIndex).value_or(0)));
      break;
    default:
      ReportError(view_id, OWLHostErrorUnknownMessage,
                  "Unknown view message " + std::to_string(message->kind) + ".");
      break;
  }
}

}  // namespace owl
