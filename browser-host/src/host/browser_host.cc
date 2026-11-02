#include "host/browser_host.h"

#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <signal.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>

#include <chrono>
#include <cstdlib>
#include <cstring>
#include <random>
#include <thread>

#include "core/host_files.h"
#include "core/process.h"
#include "host/host_app.h"
#include "host/log.h"
#include "host/tab.h"
#include "host/ui_task.h"
#include "include/cef_version.h"

#if defined(__APPLE__)
#include <mach-o/dyld.h>
#else
#include <sched.h>
#endif

namespace rb {

namespace {

constexpr int kShutdownWatchdogSeconds = 15;
constexpr int kCefShutdownTimeoutSeconds = 5;
constexpr int64_t kCreateResponseTimeoutMs = 2000;
constexpr size_t kMaxTextFrame = 1u << 20;

int signal_pipe[2] = {-1, -1};

void OnSignal(int) {
  const char byte = 1;
  // Async-signal-safe; a full pipe already means a shutdown is pending.
  if (write(signal_pipe[1], &byte, 1) < 0) {
    _exit(4);
  }
}

int64_t NowMs() {
  return std::chrono::duration_cast<std::chrono::milliseconds>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}

std::string ExecutablePath() {
#if defined(__APPLE__)
  char buffer[4096];
  uint32_t size = sizeof(buffer);
  if (_NSGetExecutablePath(buffer, &size) != 0) {
    return "";
  }
  char resolved[PATH_MAX];
  return realpath(buffer, resolved) != nullptr ? resolved : buffer;
#else
  char buffer[4096];
  const ssize_t length = readlink("/proc/self/exe", buffer, sizeof(buffer) - 1);
  if (length <= 0) {
    return "";
  }
  buffer[length] = '\0';
  return buffer;
#endif
}

std::string DirectoryOf(const std::string& path) {
  const size_t slash = path.find_last_of('/');
  return slash == std::string::npos ? "." : path.substr(0, slash);
}

bool PickFreeLoopbackPort(int* port, std::string* error) {
  const int fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) {
    *error = std::string("socket failed: ") + std::strerror(errno);
    return false;
  }
  sockaddr_in address{};
  address.sin_family = AF_INET;
  address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  address.sin_port = 0;
  socklen_t length = sizeof(address);
  if (bind(fd, reinterpret_cast<sockaddr*>(&address), sizeof(address)) != 0 ||
      getsockname(fd, reinterpret_cast<sockaddr*>(&address), &length) != 0) {
    *error = std::string("cannot pick a loopback port: ") + std::strerror(errno);
    close(fd);
    return false;
  }
  *port = ntohs(address.sin_port);
  close(fd);
  return true;
}

#if !defined(__APPLE__)
/// Whether this process may create user namespaces (what Chromium's namespace sandbox needs).
bool UserNamespacesAvailable() {
  const pid_t child = fork();
  if (child == 0) {
    _exit(unshare(CLONE_NEWUSER) == 0 ? 0 : 1);
  }
  if (child < 0) {
    return false;
  }
  int status = 0;
  while (waitpid(child, &status, 0) < 0 && errno == EINTR) {
  }
  return WIFEXITED(status) && WEXITSTATUS(status) == 0;
}
#endif

bool ValidRecordingName(const std::string& name) {
  if (name.empty() || name.size() > 128 || name[0] == '.') {
    return false;
  }
  for (char character : name) {
    const bool allowed = (character >= 'a' && character <= 'z') ||
                         (character >= 'A' && character <= 'Z') ||
                         (character >= '0' && character <= '9') || character == '_' ||
                         character == '-' || character == '.';
    if (!allowed) {
      return false;
    }
  }
  return true;
}

}  // namespace

BrowserHost& BrowserHost::Get() {
  static BrowserHost* host = new BrowserHost();
  return *host;
}

std::unique_ptr<EncoderBackend> BrowserHost::MakeEncoder() const {
  return std::make_unique<SubprocessEncoder>(encoder_, shim_library_, options_.profile_dir);
}

StreamConfig BrowserHost::stream_config() const {
  StreamConfig config;
  config.encoder_threads = options_.encoder_threads;
  return config;
}

void BrowserHost::SendText(uint64_t connection, const Json& message) {
  server_.SendText(connection, message.Dump());
}

void BrowserHost::SendBytes(uint64_t connection, std::vector<uint8_t> bytes) {
  server_.Send(connection, std::move(bytes));
}

void BrowserHost::CloseConnection(uint64_t connection, uint16_t code, const std::string& reason) {
  server_.Close(connection, code, reason);
}

std::string BrowserHost::NewTabId() const {
  static std::mt19937_64 random(std::random_device{}());
  while (true) {
    char buffer[32];
    std::snprintf(buffer, sizeof(buffer), "btab_%016llx",
                  static_cast<unsigned long long>(random()));
    if (tabs_.count(buffer) == 0) {
      return buffer;
    }
  }
}

CefRefPtr<Tab> BrowserHost::NewTab(const std::string& session_id, const std::string& created_by,
                                   const protocol::Viewport& viewport) {
  CefRefPtr<Tab> tab(new Tab(this, NewTabId(), session_id, created_by, viewport));
  tabs_[tab->id()] = tab;
  idle_since_ms_ = 0;
  return tab;
}

CefRefPtr<Tab> BrowserHost::FindTab(const std::string& tab_id) const {
  auto found = tabs_.find(tab_id);
  return found == tabs_.end() ? nullptr : found->second;
}

void BrowserHost::OnTabClosed(const std::string& tab_id) {
  tabs_.erase(tab_id);
  QuitWhenTabsClosed();
}

CefRefPtr<CefClient> BrowserHost::DefaultClientForNewBrowser() {
  // Reached for browsers Chromium creates itself (DevTools Target.createTarget).
  CefRefPtr<Tab> tab = NewTab("", "agent", protocol::Viewport{});
  tab->ExpectBrowser();
  Log("Chromium asked for a client for a new browser; it becomes tab " + tab->id());
  return tab;
}

bool BrowserHost::Prepare(std::string* error) {
  executable_path_ = ExecutablePath();
  if (executable_path_.empty()) {
    *error = "cannot resolve the host executable path";
    return false;
  }
  lock_fd_ = AcquireProfileLock(options_.profile_dir, error);
  if (lock_fd_ < 0) {
    return false;
  }
  // CEF compares cache paths textually, so resolve symlinks (macOS /tmp is /private/tmp).
  char resolved_profile[PATH_MAX];
  if (realpath(options_.profile_dir.c_str(), resolved_profile) == nullptr) {
    *error = "cannot resolve " + options_.profile_dir + ": " + std::strerror(errno);
    return false;
  }
  options_.profile_dir = resolved_profile;
  if (!ResolveEncoder(options_.encoder, &encoder_, error)) {
    return false;
  }
  const std::string directory = DirectoryOf(executable_path_);
#if defined(__APPLE__)
  for (const std::string& candidate :
       {directory + "/../Frameworks/libomnigent_unbuffered_stdout.dylib",
        directory + "/libomnigent_unbuffered_stdout.dylib"}) {
#else
  for (const std::string& candidate : {directory + "/libomnigent_unbuffered_stdout.so"}) {
#endif
    if (access(candidate.c_str(), R_OK) == 0) {
      char resolved[PATH_MAX];
      shim_library_ = realpath(candidate.c_str(), resolved) != nullptr ? resolved : candidate;
      break;
    }
  }
  if (encoder_.kind == EncoderKind::kX264 && shim_library_.empty()) {
    *error = "libomnigent_unbuffered_stdout is missing next to the host; x264 needs it";
    return false;
  }
  Log("encoder " + encoder_.path + " (" + EncoderKindName(encoder_.kind) + ": " + encoder_.version +
      ")");
#if !defined(__APPLE__)
  if (!options_.no_sandbox && !UserNamespacesAvailable()) {
    Log("warning: user namespaces are unavailable, so the Chromium sandbox cannot run; "
        "continuing with --no-sandbox");
    options_.no_sandbox = true;
  }
  if (options_.headless_mode == "xvfb" && !StartXvfb(error)) {
    return false;
  }
#endif
  if (options_.no_sandbox) {
    Log("warning: the Chromium sandbox is disabled");
  }
  cdp_port_ = options_.cdp_port;
  if (cdp_port_ == 0 && !PickFreeLoopbackPort(&cdp_port_, error)) {
    return false;
  }
  return true;
}

bool BrowserHost::StartXvfb(std::string* error) {
  const std::string xvfb = FindExecutableOnPath("Xvfb");
  if (xvfb.empty()) {
    *error = "--headless-mode xvfb needs Xvfb on PATH";
    return false;
  }
  ChildProcess child;
  // -displayfd 1: Xvfb picks a free display and prints its number on stdout. GLX is off:
  // Chromium runs with --disable-gpu, and Xvfb's GLX init crashes on hosts with NVIDIA EGL.
  if (!SpawnWithPipes({xvfb, "-displayfd", "1", "-screen", "0", "3840x2160x24", "-nolisten", "tcp",
                       "-extension", "GLX"},
                      {}, &child, error)) {
    return false;
  }
  close(child.stdin_fd);
  std::string display;
  char buffer[64];
  while (display.find('\n') == std::string::npos) {
    const ssize_t count = read(child.stdout_fd, buffer, sizeof(buffer));
    if (count <= 0) {
      *error = "Xvfb exited before reporting its display";
      return false;
    }
    display.append(buffer, static_cast<size_t>(count));
  }
  close(child.stdout_fd);
  close(child.stderr_fd);
  display = ":" + display.substr(0, display.find('\n'));
  setenv("DISPLAY", display.c_str(), 1);
  xvfb_pid_ = child.pid;
  Log("started Xvfb on display " + display + " (pid " + std::to_string(child.pid) + ")");
  return true;
}

bool BrowserHost::InitializeCef(int argc, char* argv[], std::string* error) {
  CefMainArgs main_args(argc, argv);
  CefSettings settings;
  settings.no_sandbox = options_.no_sandbox;
  settings.windowless_rendering_enabled = true;
  settings.command_line_args_disabled = true;
  settings.persist_session_cookies = true;
  settings.remote_debugging_port = cdp_port_;
  settings.log_severity = LOGSEVERITY_WARNING;
  CefString(&settings.root_cache_path) = options_.profile_dir;
  // The global context is the profile; Chrome-style profiles are direct children of the root.
  CefString(&settings.cache_path) = options_.profile_dir + "/chromium";
  CefString(&settings.log_file) = options_.profile_dir + "/chromium.log";
#if !defined(__APPLE__)
  const std::string directory = DirectoryOf(executable_path_);
  CefString(&settings.browser_subprocess_path) = executable_path_;
  CefString(&settings.resources_dir_path) = directory;
  CefString(&settings.locales_dir_path) = directory + "/locales";
#endif
  AppSwitches switches;
#if !defined(__APPLE__)
  switches.ozone_platform = options_.headless_mode == "xvfb" ? "x11" : "headless";
#endif
  switches.no_sandbox = options_.no_sandbox;
  CefRefPtr<HostApp> app(new HostApp(switches));
  if (!CefInitialize(main_args, settings, app.get(), nullptr)) {
    *error = "CefInitialize failed with exit code " + std::to_string(CefGetExitCode());
    return false;
  }
  return true;
}

int BrowserHost::Run(int argc, char* argv[]) {
  std::vector<std::string> arguments;
  for (int index = 1; index < argc; ++index) {
    arguments.emplace_back(argv[index]);
  }
  const char* data_dir = std::getenv("OMNIGENT_DATA_DIR");
  const char* home = std::getenv("HOME");
  std::string error;
  if (!ParseHostOptions(arguments, data_dir != nullptr ? data_dir : "", home != nullptr ? home : "",
                        &options_, &error)) {
    Log(error);
    std::fputs(HostUsage(), stderr);
    return 64;
  }
  if (options_.help) {
    std::fputs(HostUsage(), stdout);
    return 0;
  }
  signal(SIGPIPE, SIG_IGN);
  started_at_ = static_cast<int64_t>(std::time(nullptr));
  if (!Prepare(&error)) {
    Log(error);
    return 69;
  }
  if (!server_.Listen(options_.socket_path, &error)) {
    Log(error);
    return 69;
  }
  if (!InitializeCef(argc, argv, &error)) {
    Log(error);
    return 70;
  }
  if (pipe(signal_pipe) != 0) {
    Log(std::string("cannot create the signal pipe: ") + std::strerror(errno));
    return 70;
  }
  struct sigaction action{};
  action.sa_handler = OnSignal;
  sigemptyset(&action.sa_mask);
  sigaction(SIGTERM, &action, nullptr);
  sigaction(SIGINT, &action, nullptr);
  std::thread([] {
    char byte = 0;
    while (read(signal_pipe[0], &byte, 1) < 0 && errno == EINTR) {
    }
    PostUi([] { BrowserHost::Get().BeginShutdown("signal"); });
  }).detach();

  StartServer();
  CefRunMessageLoop();
  Log("message loop finished; stopping the socket server");
  server_.Stop();
  tabs_.clear();
  context_ = nullptr;
  // The runner treats host.json as "a host is serving this profile"; it goes first.
  if (!RemoveHostState(options_.profile_dir, &error)) {
    Log(error);
  }
  // CefShutdown can stall (seen on macOS while Chromium releases a Keychain handle). Bound it,
  // and make sure no helper or encoder outlives the host either way.
  std::thread([] {
    std::this_thread::sleep_for(std::chrono::seconds(kCefShutdownTimeoutSeconds));
    Log("warning: CefShutdown did not finish in " + std::to_string(kCefShutdownTimeoutSeconds) +
        " s; killing helper processes and exiting");
    SignalDescendants(getpid(), SIGKILL);
    _exit(0);
  }).detach();
  Log("shutting down CEF");
  CefShutdown();
  const int leftover = SignalDescendants(getpid(), SIGKILL);
  if (leftover > 0) {
    Log("killed " + std::to_string(leftover) + " leftover child processes");
  }
  if (xvfb_pid_ > 0) {
    double ignored = 0;
    ReapChild(xvfb_pid_, &ignored, &error);
  }
  Log("exited cleanly");
  return 0;
}

void BrowserHost::OnContextInitialized() {
  context_ready_ = true;
  context_ = CefRequestContext::GetGlobalContext();
  // Popups go through OnBeforePopup, which turns them into tabs; Chrome's own blocker would drop
  // gesture-less window.open first.
  context_->SetContentSetting(CefString(), CefString(), CEF_CONTENT_SETTING_TYPE_POPUPS,
                              CEF_CONTENT_SETTING_VALUE_ALLOW);
  HostState state;
  state.pid = getpid();
  state.socket = options_.socket_path;
  state.cdp_port = cdp_port_;
  state.version = RB_HOST_VERSION;
  state.profile = options_.profile;
  state.started_at = Rfc3339Utc(started_at_);
  state.encoder_path = encoder_.path;
  state.encoder_kind = EncoderKindName(encoder_.kind);
  std::string error;
  if (!WriteHostState(options_.profile_dir, state, &error)) {
    Log(error);
    BeginShutdown("cannot write host.json");
    return;
  }
  Log(std::string("CEF ") + CEF_VERSION + " ready; profile " + options_.profile + ", socket " +
      options_.socket_path + ", CDP 127.0.0.1:" + std::to_string(cdp_port_));
  PostUiDelayed([this] { PeriodicTick(); }, 1000);
}

void BrowserHost::StartServer() {
  SocketServer::Callbacks callbacks;
  callbacks.on_open = [this](uint64_t connection) {
    PostUi([this, connection] { OnConnectionOpen(connection); });
  };
  callbacks.on_frame = [this](uint64_t connection, Frame frame) {
    auto shared = std::make_shared<Frame>(std::move(frame));
    PostUi([this, connection, shared] { OnConnectionFrame(connection, std::move(*shared)); });
  };
  callbacks.on_closed = [this](uint64_t connection, uint16_t, const std::string&) {
    PostUi([this, connection] { OnConnectionClosed(connection); });
  };
  callbacks.log = [](const std::string& message) { Log("socket: " + message); };
  server_.Start(std::move(callbacks));
}

void BrowserHost::OnConnectionOpen(uint64_t connection) {
  connections_[connection] = Connection{};
  idle_since_ms_ = 0;
}

void BrowserHost::OnConnectionClosed(uint64_t connection) {
  auto found = connections_.find(connection);
  if (found == connections_.end()) {
    return;
  }
  if (found->second.kind == ConnectionKind::kAttach) {
    if (CefRefPtr<Tab> tab = FindTab(found->second.tab_id)) {
      tab->Detach(connection);
    }
  }
  connections_.erase(found);
}

void BrowserHost::OnConnectionFrame(uint64_t connection, Frame frame) {
  auto found = connections_.find(connection);
  if (found == connections_.end()) {
    return;
  }
  Connection& state = found->second;
  if (frame.kind != FrameKind::kText) {
    if (state.kind == ConnectionKind::kNew) {
      CloseConnection(connection, protocol::kCloseProtocolError, "the first frame must be text");
    } else {
      SendText(connection, protocol::ErrorMessage(
                               {"invalid_message", "clients do not send binary frames", false}));
    }
    return;
  }
  if (frame.payload.size() > kMaxTextFrame) {
    CloseConnection(connection, protocol::kCloseTooLarge, "text frames are limited to 1 MiB");
    return;
  }
  std::string error;
  std::optional<Json> message = Json::Parse(frame.text(), &error);
  if (!message || !message->is_object()) {
    if (state.kind == ConnectionKind::kNew) {
      CloseConnection(connection, protocol::kCloseProtocolError, "malformed preamble: " + error);
    } else if (state.kind == ConnectionKind::kAttach) {
      SendText(connection,
               protocol::ErrorMessage({"invalid_message", "malformed JSON: " + error, false}));
    } else {
      SendText(connection,
               protocol::ResponseError("", "invalid_input", "malformed JSON: " + error));
    }
    return;
  }
  switch (state.kind) {
    case ConnectionKind::kNew: {
      protocol::AttachPreamble attach;
      const protocol::Preamble preamble = protocol::ParsePreamble(*message, &attach, &error);
      if (preamble == protocol::Preamble::kControl) {
        state.kind = ConnectionKind::kControl;
        return;
      }
      if (preamble == protocol::Preamble::kInvalid) {
        CloseConnection(connection, protocol::kCloseProtocolError, "invalid preamble: " + error);
        return;
      }
      if (attach.protocol != protocol::kProtocolVersion) {
        CloseConnection(connection, protocol::kCloseProtocolUnsupported,
                        "protocol " + std::to_string(attach.protocol) + " is not supported");
        return;
      }
      CefRefPtr<Tab> tab = FindTab(attach.tab_id);
      if (!tab || tab->closing() || shutting_down_) {
        CloseConnection(connection, protocol::kCloseTabGone, "no tab " + attach.tab_id);
        return;
      }
      state.kind = ConnectionKind::kAttach;
      state.tab_id = attach.tab_id;
      tab->Attach(connection, attach.mode);
      return;
    }
    case ConnectionKind::kAttach: {
      CefRefPtr<Tab> tab = FindTab(state.tab_id);
      if (tab) {
        tab->OnClientMessage(connection, *message);
      }
      return;
    }
    case ConnectionKind::kControl: {
      protocol::ControlRequest request;
      if (!protocol::ParseControlRequest(*message, &request, &error)) {
        RespondError(connection, message->GetString("id").value_or(""), "invalid_input", error);
        return;
      }
      HandleRequest(connection, request);
      return;
    }
  }
}

void BrowserHost::Respond(uint64_t connection, const std::string& id, Json result) {
  SendText(connection, protocol::ResponseOk(id, std::move(result)));
}

void BrowserHost::RespondError(uint64_t connection, const std::string& id, const std::string& code,
                               const std::string& message) {
  SendText(connection, protocol::ResponseError(id, code, message));
}

void BrowserHost::HandleRequest(uint64_t connection, const protocol::ControlRequest& request) {
  const Json& args = request.args;
  const std::string& op = request.op;
  if (op == "health") {
    Json result = Json::MakeObject();
    result.Set("version", RB_HOST_VERSION);
    result.Set("profile", options_.profile);
    result.Set("cdp_port", cdp_port_);
    result.Set("tabs", static_cast<int64_t>(tabs_.size()));
    Respond(connection, request.id, result);
    return;
  }
  if (!context_ready_ || shutting_down_) {
    RespondError(connection, request.id, "unavailable",
                 shutting_down_ ? "the host is shutting down" : "Chromium is not ready yet");
    return;
  }
  if (op == "tabs.list") {
    const std::optional<std::string> session = args.GetString("session_id");
    Json tabs = Json::MakeArray();
    for (const auto& [id, tab] : tabs_) {
      if (!tab->closing() && (!session || tab->session_id() == *session)) {
        tabs.Push(protocol::ToJson(tab->Record()));
      }
    }
    Json result = Json::MakeObject();
    result.Set("tabs", tabs);
    Respond(connection, request.id, result);
  } else if (op == "tabs.create") {
    const std::optional<std::string> session = args.GetString("session_id");
    const std::string created_by = args.GetString("created_by").value_or("user");
    const std::string url = args.GetString("url").value_or("about:blank");
    protocol::Viewport viewport;
    viewport.w = static_cast<int>(args.GetInteger("width").value_or(1280));
    viewport.h = static_cast<int>(args.GetInteger("height").value_or(800));
    viewport.dpr = args.GetNumber("dpr").value_or(1);
    if (!session) {
      RespondError(connection, request.id, "invalid_input", "session_id is required");
      return;
    }
    if (created_by != "user" && created_by != "agent") {
      RespondError(connection, request.id, "invalid_input", "created_by must be user or agent");
      return;
    }
    if (viewport.w < 200 || viewport.w > 3840 || viewport.h < 200 || viewport.h > 3840 ||
        viewport.dpr < 1 || viewport.dpr > 3) {
      RespondError(connection, request.id, "invalid_input",
                   "width and height must be 200-3840 and dpr 1-3");
      return;
    }
    CefRefPtr<Tab> tab = NewTab(*session, created_by, viewport);
    if (!tab->Create(url, context_)) {
      tab->Close("closed");
      RespondError(connection, request.id, "internal", "CefBrowserHost::CreateBrowser failed");
      return;
    }
    // Answer once the CDP target id is known (normally within milliseconds), or after a short
    // wait with target_id empty; tabs.list reports it later.
    const std::string id = request.id;
    auto answered = std::make_shared<bool>(false);
    auto answer = [this, connection, id, tab, answered] {
      if (*answered) {
        return;
      }
      *answered = true;
      if (tab->closing() && !tab->has_browser()) {
        RespondError(connection, id, "internal", "the tab closed while it was created");
        return;
      }
      Respond(connection, id, protocol::ToJson(tab->Record()));
    };
    tab->WhenTargetKnown(answer);
    PostUiDelayed(answer, kCreateResponseTimeoutMs);
  } else if (op == "tabs.navigate" || op == "tabs.close" || op == "tabs.record" ||
             op == "tabs.record_stop" || op == "tabs.stats") {
    const std::string tab_id = args.GetString("tab_id").value_or("");
    CefRefPtr<Tab> tab = FindTab(tab_id);
    if (!tab || tab->closing()) {
      RespondError(connection, request.id, "not_found", "no tab " + tab_id);
      return;
    }
    if (op == "tabs.navigate") {
      const std::optional<std::string> url = args.GetString("url");
      if (!url || url->empty()) {
        RespondError(connection, request.id, "invalid_input", "url is required");
        return;
      }
      tab->Navigate(*url);
      Respond(connection, request.id, protocol::ToJson(tab->Record()));
    } else if (op == "tabs.close") {
      tab->Close("closed");
      Json result = Json::MakeObject();
      result.Set("closed", true);
      Respond(connection, request.id, result);
    } else if (op == "tabs.record") {
      const std::string name = args.GetString("name").value_or("");
      if (options_.record_dir.empty() || !ValidRecordingName(name)) {
        RespondError(connection, request.id, "invalid_input",
                     "recording needs --record-dir and a plain file name");
        return;
      }
      std::string error;
      const std::string path = options_.record_dir + "/" + name;
      if (!tab->StartRecording(path, static_cast<int>(args.GetInteger("max_frames").value_or(300)),
                               &error)) {
        RespondError(connection, request.id, "internal", error);
        return;
      }
      Json result = Json::MakeObject();
      result.Set("path", path);
      Respond(connection, request.id, result);
    } else if (op == "tabs.record_stop") {
      Json result = Json::MakeObject();
      result.Set("frames", tab->StopRecording());
      Respond(connection, request.id, result);
    } else {
      Json result = Json::MakeObject();
      result.Set("frames_encoded", static_cast<int64_t>(tab->streamer()->frames_encoded()));
      result.Set("encoder_cpu_s", tab->streamer()->encoder_cpu_seconds());
      result.Set("keyframe_mode", tab->streamer()->encoder_keyframe_mode());
      result.Set("recorded_frames", tab->streamer()->recorded_frames());
      double cpu = 0;
      std::string error;
      if (ProcessTreeCpuTime(getpid(), &cpu, &error)) {
        result.Set("host_tree_cpu_s", cpu);
      }
      long long resident = 0;
      if (ProcessTreeResidentBytes(getpid(), &resident, &error)) {
        result.Set("host_tree_rss_bytes", static_cast<int64_t>(resident));
      }
      Respond(connection, request.id, result);
    }
  } else if (op == "tabs.close_session") {
    const std::optional<std::string> session = args.GetString("session_id");
    if (!session) {
      RespondError(connection, request.id, "invalid_input", "session_id is required");
      return;
    }
    std::vector<CefRefPtr<Tab>> closing;
    for (const auto& [id, tab] : tabs_) {
      if (tab->session_id() == *session && !tab->closing()) {
        closing.push_back(tab);
      }
    }
    for (const CefRefPtr<Tab>& tab : closing) {
      tab->Close("closed");
    }
    Json result = Json::MakeObject();
    result.Set("closed", static_cast<int64_t>(closing.size()));
    Respond(connection, request.id, result);
  } else if (op == "host.shutdown") {
    Respond(connection, request.id, Json::MakeObject());
    BeginShutdown("host.shutdown request");
  } else {
    RespondError(connection, request.id, "invalid_input", "unknown op " + op);
  }
}

void BrowserHost::PeriodicTick() {
  const int64_t now = NowMs();
  double cpu = 0;
  std::string error;
  if (ProcessTreeCpuTime(getpid(), &cpu, &error)) {
    if (last_cpu_sample_ms_ != 0 && now > last_cpu_sample_ms_) {
      host_cpu_cores_ =
          (cpu - last_cpu_seconds_) / (static_cast<double>(now - last_cpu_sample_ms_) / 1000);
    }
    last_cpu_seconds_ = cpu;
    last_cpu_sample_ms_ = now;
  }
  if (tabs_.empty() && connections_.empty() && options_.idle_exit_seconds > 0 && !shutting_down_) {
    if (idle_since_ms_ == 0) {
      idle_since_ms_ = now;
    } else if (now - idle_since_ms_ >= static_cast<int64_t>(options_.idle_exit_seconds) * 1000) {
      BeginShutdown("idle for " + std::to_string(options_.idle_exit_seconds) + " s");
    }
  } else {
    idle_since_ms_ = 0;
  }
  if (!shutting_down_) {
    PostUiDelayed([this] { PeriodicTick(); }, 1000);
  }
}

void BrowserHost::BeginShutdown(const std::string& reason) {
  if (shutting_down_) {
    return;
  }
  shutting_down_ = true;
  Log("shutting down: " + reason);
  std::thread([] {
    std::this_thread::sleep_for(std::chrono::seconds(kShutdownWatchdogSeconds));
    Log("shutdown did not finish in time; exiting");
    SignalDescendants(getpid(), SIGKILL);
    _exit(3);
  }).detach();
  for (const auto& [connection, state] : connections_) {
    if (state.kind != ConnectionKind::kAttach) {
      CloseConnection(connection, protocol::kCloseGoingAway, "host shutting down");
    }
  }
  std::vector<CefRefPtr<Tab>> closing;
  for (const auto& [id, tab] : tabs_) {
    closing.push_back(tab);
  }
  for (const CefRefPtr<Tab>& tab : closing) {
    tab->Close("host_exit");
  }
  QuitWhenTabsClosed();
}

void BrowserHost::QuitWhenTabsClosed() {
  if (!shutting_down_ || !tabs_.empty() || quit_posted_) {
    return;
  }
  quit_posted_ = true;
  // Let queued close frames flush before the loop exits.
  PostUiDelayed([] { CefQuitMessageLoop(); }, 200);
}

}  // namespace rb
