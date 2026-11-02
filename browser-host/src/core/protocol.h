// Typed models of the remote browser protocol v1 messages (design doc sections 5.3-5.7) with
// JSON conversion in both directions. Host-sent messages are built from these models; client
// messages and runner requests are parsed into them.
#pragma once

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

#include "core/json.h"

namespace rb::protocol {

inline constexpr int kProtocolVersion = 1;
inline constexpr uint32_t kWindowMaxFrames = 2;
inline constexpr uint32_t kWindowMaxBytes = 512 * 1024;

/// Close codes (section 5.8).
enum CloseCode : uint16_t {
  kCloseNormal = 1000,
  kCloseGoingAway = 1001,
  kCloseProtocolError = 1002,
  kCloseTooLarge = 1009,
  kCloseInternal = 1011,
  kCloseTryAgainLater = 1013,
  kCloseTabGone = 4404,
  kCloseProtocolUnsupported = 4426,
};

/// Protocol modifier bits (section 5.4).
enum Modifier : uint32_t {
  kModifierShift = 1u << 0,
  kModifierCtrl = 1u << 1,
  kModifierAlt = 1u << 2,
  kModifierMeta = 1u << 3,
  kModifierCapsLock = 1u << 4,
  kModifierNumLock = 1u << 5,
  kModifierLeftButton = 1u << 6,
  kModifierMiddleButton = 1u << 7,
  kModifierRightButton = 1u << 8,
};

bool IsValidTabId(const std::string& id);
bool IsValidProfileName(const std::string& name);

struct Viewport {
  int w = 1280;
  int h = 800;
  double dpr = 1;
  bool operator==(const Viewport&) const = default;
};

struct Rect {
  double x = 0;
  double y = 0;
  double w = 0;
  double h = 0;
};

struct Settings {
  uint32_t max_fps = 15;
  std::string quality = "medium";  // low | medium | high
  double scale = 1;
  std::string codec = "auto";  // auto | h264 | jpeg
};

struct Handoff {
  std::string id;
  std::string reason;
};

struct ControlState {
  std::string owner = "agent";        // agent | user
  std::optional<std::string> holder;  // this | other | absent (null)
  std::optional<std::string> user_id;
  std::optional<Handoff> handoff;
};

struct NavState {
  std::string url = "about:blank";
  std::string title;
  bool loading = false;
  double progress = 1;
  bool can_go_back = false;
  bool can_go_forward = false;
  std::optional<std::string> favicon_url;
};

struct CustomCursor {
  std::string png_base64;
  double hotspot_x = 0;
  double hotspot_y = 0;
  double scale = 1;
};

struct CursorState {
  std::string cursor = "default";
  std::optional<CustomCursor> custom;
};

struct TextInputState {
  std::string mode = "none";
  std::optional<Rect> caret_rect;
};

struct HostHello {
  std::string tab_id;
  std::string profile;
  std::string host_version;
  std::string mode;  // view | control
  std::vector<std::string> codecs = {"h264", "jpeg"};
  Viewport viewport;
  ControlState control;
  Settings settings;
  uint32_t window_max_frames = kWindowMaxFrames;
  uint32_t window_max_bytes = kWindowMaxBytes;
  std::vector<std::string> features;
};

struct Dialog {
  std::string id;
  std::string kind;  // alert | confirm | prompt | beforeunload | file_chooser
  std::string message;
  std::optional<std::string> default_text;
  std::optional<std::string> origin;
};

struct Stats {
  double fps = 0;
  double kbps = 0;
  double encode_ms_p50 = 0;
  double encode_ms_p95 = 0;
  uint32_t in_flight_frames = 0;
  uint32_t in_flight_bytes = 0;
  double host_cpu = 0;
};

struct ErrorInfo {
  std::string code;
  std::string message;
  bool fatal = false;
};

// Host -> client messages.
Json ToJson(const Viewport& value);
Json ToJson(const Rect& value);
Json ToJson(const Settings& value);
Json ToJson(const ControlState& value);
Json HelloMessage(const HostHello& hello);
Json NavMessage(const NavState& nav);
Json CursorMessage(const CursorState& cursor);
Json TextInputMessage(const TextInputState& text_input);
Json ControlMessage(const ControlState& state, const std::optional<std::string>& reason);
Json DialogMessage(const Dialog& dialog);
Json DialogClosedMessage(const std::string& id);
Json ViewportMessage(const Viewport& viewport);
Json SettingsMessage(const Settings& settings);
Json StatsMessage(const Stats& stats);
Json PongMessage(const std::string& nonce);
Json ErrorMessage(const ErrorInfo& error);
Json TabClosedMessage(const std::string& reason);

// Parsers for host -> client messages, used by tests and tools. Each returns false and sets
// `error` when a required field is missing or has the wrong type.
bool ParseViewport(const Json& json, Viewport* out, std::string* error);
bool ParseSettings(const Json& json, Settings* out, std::string* error);
bool ParseControlState(const Json& json, ControlState* out, std::string* error);
bool ParseHostHello(const Json& json, HostHello* out, std::string* error);
bool ParseNav(const Json& json, NavState* out, std::string* error);
bool ParseCursor(const Json& json, CursorState* out, std::string* error);
bool ParseTextInput(const Json& json, TextInputState* out, std::string* error);
bool ParseDialog(const Json& json, Dialog* out, std::string* error);
bool ParseStats(const Json& json, Stats* out, std::string* error);
bool ParseError(const Json& json, ErrorInfo* out, std::string* error);

/// Client -> host message types. kUnknown is any other `type`, which the host ignores.
enum class ClientType {
  kHello,
  kAck,
  kKeyframeRequest,
  kVisibility,
  kStillRequest,
  kMouse,
  kKey,
  kIme,
  kNav,
  kResize,
  kControl,
  kDialogReply,
  kSettings,
  kPing,
  kUnknown,
};

struct Range {
  int64_t start = 0;
  int64_t end = 0;
};

/// One parsed client message. Only the fields of `type` are meaningful.
struct ClientMessage {
  ClientType type = ClientType::kUnknown;
  std::string type_name;

  // hello
  int protocol = 0;
  std::string client;
  std::vector<std::string> decoders;
  std::string mode;
  bool visible = true;
  std::vector<std::string> features;
  // ack
  uint32_t seq = 0;
  // keyframe_request, still_request, mouse, key: `kind`; keyframe_request: `reason`
  std::string kind;
  std::string reason;
  // mouse
  double x = 0;
  double y = 0;
  std::optional<std::string> button;
  std::optional<int> clicks;
  uint32_t modifiers = 0;
  std::optional<double> dx;
  std::optional<double> dy;
  // key
  std::string code;
  std::string key;
  std::optional<std::string> text;
  bool repeat = false;
  // ime, nav, control: `op`
  std::string op;
  std::optional<Range> selection;
  std::optional<Range> replacement;
  // nav
  std::optional<std::string> url;
  // resize
  Viewport viewport;
  // dialog_reply
  std::string id;
  bool accept = false;
  // settings
  std::optional<uint32_t> max_fps;
  std::optional<std::string> quality;
  std::optional<double> scale;
  std::optional<std::string> codec;
  std::optional<bool> stats;
  // ping
  std::string nonce;
};

/// Parses and validates one client text message. Returns false with `error` for a malformed
/// message of a known type; unknown types parse as kUnknown.
bool ParseClientMessage(const Json& json, ClientMessage* out, std::string* error);
/// Serializes a client message (the inverse of ParseClientMessage; used by tests and tools).
Json ToJson(const ClientMessage& message);

// Runner <-> host (section 5.7).

struct AttachPreamble {
  int protocol = 0;
  std::string tab_id;
  std::string mode;
};

struct ControlRequest {
  std::string id;
  std::string op;
  Json args;
};

struct TabRecord {
  std::string id;
  std::string session_id;
  std::string url;
  std::string title;
  bool loading = false;
  std::string owner = "agent";
  bool needs_attention = false;
  std::string profile;
  std::string created_by = "user";
  std::string target_id;
  bool can_go_back = false;
  bool can_go_forward = false;
};

/// What the first frame of a host.sock connection asks for.
enum class Preamble { kAttach, kControl, kInvalid };

Preamble ParsePreamble(const Json& json, AttachPreamble* attach, std::string* error);
bool ParseControlRequest(const Json& json, ControlRequest* out, std::string* error);
bool ParseTabRecord(const Json& json, TabRecord* out, std::string* error);
Json ToJson(const TabRecord& tab);
Json ResponseOk(const std::string& id, Json result);
Json ResponseError(const std::string& id, const std::string& code, const std::string& message);

}  // namespace rb::protocol
