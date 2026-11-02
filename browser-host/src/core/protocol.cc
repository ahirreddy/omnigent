#include "core/protocol.h"

#include <cmath>

namespace rb::protocol {

namespace {

/// Reads typed fields from a JSON object and records the first problem.
class Fields {
 public:
  Fields(const Json& json, std::string* error) : json_(json), error_(error) {
    if (!json.is_object()) {
      Fail("", "expected a JSON object");
    }
  }

  bool ok() const { return ok_; }

  std::string String(const char* key) {
    std::optional<std::string> value = OptionalString(key);
    if (!value) {
      Missing(key);
      return "";
    }
    return *value;
  }

  std::optional<std::string> OptionalString(const char* key) {
    const Json* value = Present(key);
    if (value == nullptr) {
      return std::nullopt;
    }
    if (!value->is_string()) {
      Fail(key, "must be a string");
      return std::nullopt;
    }
    return value->as_string();
  }

  double Number(const char* key) {
    std::optional<double> value = OptionalNumber(key);
    if (!value) {
      Missing(key);
      return 0;
    }
    return *value;
  }

  std::optional<double> OptionalNumber(const char* key) {
    const Json* value = Present(key);
    if (value == nullptr) {
      return std::nullopt;
    }
    if (!value->is_number()) {
      Fail(key, "must be a number");
      return std::nullopt;
    }
    return value->as_double();
  }

  int64_t Integer(const char* key) {
    std::optional<int64_t> value = OptionalInteger(key);
    if (!value) {
      Missing(key);
      return 0;
    }
    return *value;
  }

  std::optional<int64_t> OptionalInteger(const char* key) {
    const Json* value = Present(key);
    if (value == nullptr) {
      return std::nullopt;
    }
    std::optional<int64_t> integer = value->as_integer();
    if (!integer) {
      Fail(key, "must be an integer");
    }
    return integer;
  }

  uint32_t Unsigned(const char* key) {
    const int64_t value = Integer(key);
    if (value < 0 || value > 0xFFFFFFFFLL) {
      Fail(key, "is out of range");
      return 0;
    }
    return static_cast<uint32_t>(value);
  }

  bool Bool(const char* key) {
    std::optional<bool> value = OptionalBool(key);
    if (!value) {
      Missing(key);
      return false;
    }
    return *value;
  }

  std::optional<bool> OptionalBool(const char* key) {
    const Json* value = Present(key);
    if (value == nullptr) {
      return std::nullopt;
    }
    if (!value->is_bool()) {
      Fail(key, "must be a boolean");
      return std::nullopt;
    }
    return value->as_bool();
  }

  std::vector<std::string> StringList(const char* key) {
    std::vector<std::string> out;
    const Json* value = Present(key);
    if (value == nullptr) {
      Missing(key);
      return out;
    }
    if (!value->is_array()) {
      Fail(key, "must be an array");
      return out;
    }
    for (const Json& item : value->as_array()) {
      if (!item.is_string()) {
        Fail(key, "must contain only strings");
        return out;
      }
      out.push_back(item.as_string());
    }
    return out;
  }

  /// An optional nested object (absent or null gives null).
  const Json* OptionalObject(const char* key) {
    const Json* value = Present(key);
    if (value != nullptr && !value->is_object()) {
      Fail(key, "must be an object");
      return nullptr;
    }
    return value;
  }

  const Json* Object(const char* key) {
    const Json* value = OptionalObject(key);
    if (value == nullptr) {
      Missing(key);
    }
    return value;
  }

  void Fail(const std::string& key, const std::string& message) {
    if (ok_ && error_ != nullptr) {
      *error_ = key.empty() ? message : "`" + key + "` " + message;
    }
    ok_ = false;
  }

  /// Folds a nested parse result in.
  void Require(bool nested_ok) {
    if (!nested_ok) {
      ok_ = false;
    }
  }

 private:
  const Json* Present(const char* key) const {
    const Json* value = json_.Find(key);
    return value == nullptr || value->is_null() ? nullptr : value;
  }

  void Missing(const char* key) {
    if (ok_) {
      Fail(key, "is required");
    }
  }

  const Json& json_;
  std::string* error_;
  bool ok_ = true;
};

Json Message(const char* type) {
  Json json = Json::MakeObject();
  json.Set("type", type);
  return json;
}

Json StringArray(const std::vector<std::string>& values) {
  Json array = Json::MakeArray();
  for (const std::string& value : values) {
    array.Push(value);
  }
  return array;
}

void Merge(const Json& from, Json* into) {
  for (const auto& [key, value] : from.as_object()) {
    into->Set(key, value);
  }
}

bool ParseRect(const Json& json, Rect* out, std::string* error) {
  Fields fields(json, error);
  out->x = fields.Number("x");
  out->y = fields.Number("y");
  out->w = fields.Number("w");
  out->h = fields.Number("h");
  return fields.ok();
}

bool ParseRange(const Json& json, Range* out, std::string* error) {
  Fields fields(json, error);
  out->start = fields.Integer("start");
  out->end = fields.Integer("end");
  return fields.ok();
}

Json RangeJson(const Range& range) {
  Json json = Json::MakeObject();
  json.Set("start", range.start);
  json.Set("end", range.end);
  return json;
}

bool OneOf(const std::string& value, std::initializer_list<const char*> options) {
  for (const char* option : options) {
    if (value == option) {
      return true;
    }
  }
  return false;
}

}  // namespace

bool IsValidTabId(const std::string& id) {
  if (id.empty() || id.size() > 128) {
    return false;
  }
  for (char character : id) {
    const bool allowed =
        (character >= 'a' && character <= 'z') || (character >= 'A' && character <= 'Z') ||
        (character >= '0' && character <= '9') || character == '_' || character == '-';
    if (!allowed) {
      return false;
    }
  }
  return true;
}

bool IsValidProfileName(const std::string& name) {
  if (name.empty() || name.size() > 32) {
    return false;
  }
  for (size_t index = 0; index < name.size(); ++index) {
    const char character = name[index];
    const bool alphanumeric =
        (character >= 'a' && character <= 'z') || (character >= '0' && character <= '9');
    if (!alphanumeric && (index == 0 || (character != '_' && character != '-'))) {
      return false;
    }
  }
  return true;
}

// MARK: Host -> client

Json ToJson(const Viewport& value) {
  Json json = Json::MakeObject();
  json.Set("w", value.w);
  json.Set("h", value.h);
  json.Set("dpr", value.dpr);
  return json;
}

Json ToJson(const Rect& value) {
  Json json = Json::MakeObject();
  json.Set("x", value.x);
  json.Set("y", value.y);
  json.Set("w", value.w);
  json.Set("h", value.h);
  return json;
}

Json ToJson(const Settings& value) {
  Json json = Json::MakeObject();
  json.Set("max_fps", value.max_fps);
  json.Set("quality", value.quality);
  json.Set("scale", value.scale);
  json.Set("codec", value.codec);
  return json;
}

Json ToJson(const ControlState& value) {
  Json json = Json::MakeObject();
  json.Set("owner", value.owner);
  json.Set("holder", value.holder ? Json(*value.holder) : Json(nullptr));
  if (value.user_id) {
    json.Set("user_id", *value.user_id);
  }
  if (value.handoff) {
    Json handoff = Json::MakeObject();
    handoff.Set("id", value.handoff->id);
    handoff.Set("reason", value.handoff->reason);
    json.Set("handoff", handoff);
  }
  return json;
}

Json HelloMessage(const HostHello& hello) {
  Json json = Message("hello");
  json.Set("protocol", kProtocolVersion);
  json.Set("tab_id", hello.tab_id);
  json.Set("profile", hello.profile);
  json.Set("host_version", hello.host_version);
  json.Set("mode", hello.mode);
  json.Set("codecs", StringArray(hello.codecs));
  json.Set("viewport", ToJson(hello.viewport));
  json.Set("control", ToJson(hello.control));
  json.Set("settings", ToJson(hello.settings));
  Json window = Json::MakeObject();
  window.Set("max_frames", hello.window_max_frames);
  window.Set("max_bytes", hello.window_max_bytes);
  json.Set("window", window);
  json.Set("features", StringArray(hello.features));
  return json;
}

Json NavMessage(const NavState& nav) {
  Json json = Message("nav");
  json.Set("url", nav.url);
  json.Set("title", nav.title);
  json.Set("loading", nav.loading);
  json.Set("progress", nav.progress);
  json.Set("can_go_back", nav.can_go_back);
  json.Set("can_go_forward", nav.can_go_forward);
  if (nav.favicon_url) {
    json.Set("favicon_url", *nav.favicon_url);
  }
  return json;
}

Json CursorMessage(const CursorState& cursor) {
  Json json = Message("cursor");
  json.Set("cursor", cursor.cursor);
  if (cursor.custom) {
    Json custom = Json::MakeObject();
    custom.Set("png_base64", cursor.custom->png_base64);
    custom.Set("hotspot_x", cursor.custom->hotspot_x);
    custom.Set("hotspot_y", cursor.custom->hotspot_y);
    custom.Set("scale", cursor.custom->scale);
    json.Set("custom", custom);
  }
  return json;
}

Json TextInputMessage(const TextInputState& text_input) {
  Json json = Message("text_input");
  json.Set("mode", text_input.mode);
  if (text_input.caret_rect) {
    json.Set("caret_rect", ToJson(*text_input.caret_rect));
  }
  return json;
}

Json ControlMessage(const ControlState& state, const std::optional<std::string>& reason) {
  Json json = Message("control");
  Merge(ToJson(state), &json);
  if (reason) {
    json.Set("reason", *reason);
  }
  return json;
}

Json DialogMessage(const Dialog& dialog) {
  Json json = Message("dialog");
  json.Set("id", dialog.id);
  json.Set("kind", dialog.kind);
  json.Set("message", dialog.message);
  if (dialog.default_text) {
    json.Set("default_text", *dialog.default_text);
  }
  if (dialog.origin) {
    json.Set("origin", *dialog.origin);
  }
  return json;
}

Json DialogClosedMessage(const std::string& id) {
  Json json = Message("dialog_closed");
  json.Set("id", id);
  return json;
}

Json ViewportMessage(const Viewport& viewport) {
  Json json = Message("viewport");
  Merge(ToJson(viewport), &json);
  return json;
}

Json SettingsMessage(const Settings& settings) {
  Json json = Message("settings");
  Merge(ToJson(settings), &json);
  return json;
}

Json StatsMessage(const Stats& stats) {
  Json json = Message("stats");
  json.Set("fps", stats.fps);
  json.Set("kbps", stats.kbps);
  json.Set("encode_ms_p50", stats.encode_ms_p50);
  json.Set("encode_ms_p95", stats.encode_ms_p95);
  json.Set("in_flight_frames", stats.in_flight_frames);
  json.Set("in_flight_bytes", stats.in_flight_bytes);
  json.Set("host_cpu", stats.host_cpu);
  return json;
}

Json PongMessage(const std::string& nonce) {
  Json json = Message("pong");
  json.Set("nonce", nonce);
  return json;
}

Json ErrorMessage(const ErrorInfo& error) {
  Json json = Message("error");
  json.Set("code", error.code);
  json.Set("message", error.message);
  json.Set("fatal", error.fatal);
  return json;
}

Json TabClosedMessage(const std::string& reason) {
  Json json = Message("tab_closed");
  json.Set("reason", reason);
  return json;
}

bool ParseViewport(const Json& json, Viewport* out, std::string* error) {
  Fields fields(json, error);
  out->w = static_cast<int>(fields.Integer("w"));
  out->h = static_cast<int>(fields.Integer("h"));
  out->dpr = fields.Number("dpr");
  return fields.ok();
}

bool ParseSettings(const Json& json, Settings* out, std::string* error) {
  Fields fields(json, error);
  out->max_fps = fields.Unsigned("max_fps");
  out->quality = fields.String("quality");
  out->scale = fields.Number("scale");
  out->codec = fields.String("codec");
  return fields.ok();
}

bool ParseControlState(const Json& json, ControlState* out, std::string* error) {
  Fields fields(json, error);
  out->owner = fields.String("owner");
  out->holder = fields.OptionalString("holder");
  out->user_id = fields.OptionalString("user_id");
  if (const Json* handoff = fields.OptionalObject("handoff")) {
    Fields nested(*handoff, error);
    out->handoff = Handoff{nested.String("id"), nested.String("reason")};
    fields.Require(nested.ok());
  }
  return fields.ok();
}

bool ParseHostHello(const Json& json, HostHello* out, std::string* error) {
  Fields fields(json, error);
  if (fields.Integer("protocol") != kProtocolVersion) {
    fields.Fail("protocol", "is not 1");
  }
  out->tab_id = fields.String("tab_id");
  out->profile = fields.String("profile");
  out->host_version = fields.String("host_version");
  out->mode = fields.String("mode");
  out->codecs = fields.StringList("codecs");
  if (const Json* viewport = fields.Object("viewport")) {
    fields.Require(ParseViewport(*viewport, &out->viewport, error));
  }
  if (const Json* control = fields.Object("control")) {
    fields.Require(ParseControlState(*control, &out->control, error));
  }
  if (const Json* settings = fields.Object("settings")) {
    fields.Require(ParseSettings(*settings, &out->settings, error));
  }
  if (const Json* window = fields.Object("window")) {
    Fields nested(*window, error);
    out->window_max_frames = nested.Unsigned("max_frames");
    out->window_max_bytes = nested.Unsigned("max_bytes");
    fields.Require(nested.ok());
  }
  out->features = fields.StringList("features");
  return fields.ok();
}

bool ParseNav(const Json& json, NavState* out, std::string* error) {
  Fields fields(json, error);
  out->url = fields.String("url");
  out->title = fields.String("title");
  out->loading = fields.Bool("loading");
  out->progress = fields.Number("progress");
  out->can_go_back = fields.Bool("can_go_back");
  out->can_go_forward = fields.Bool("can_go_forward");
  out->favicon_url = fields.OptionalString("favicon_url");
  return fields.ok();
}

bool ParseCursor(const Json& json, CursorState* out, std::string* error) {
  Fields fields(json, error);
  out->cursor = fields.String("cursor");
  if (const Json* custom = fields.OptionalObject("custom")) {
    Fields nested(*custom, error);
    out->custom = CustomCursor{nested.String("png_base64"), nested.Number("hotspot_x"),
                               nested.Number("hotspot_y"), nested.Number("scale")};
    fields.Require(nested.ok());
  }
  return fields.ok();
}

bool ParseTextInput(const Json& json, TextInputState* out, std::string* error) {
  Fields fields(json, error);
  out->mode = fields.String("mode");
  if (const Json* caret = fields.OptionalObject("caret_rect")) {
    Rect rect;
    fields.Require(ParseRect(*caret, &rect, error));
    out->caret_rect = rect;
  }
  return fields.ok();
}

bool ParseDialog(const Json& json, Dialog* out, std::string* error) {
  Fields fields(json, error);
  out->id = fields.String("id");
  out->kind = fields.String("kind");
  out->message = fields.String("message");
  out->default_text = fields.OptionalString("default_text");
  out->origin = fields.OptionalString("origin");
  return fields.ok();
}

bool ParseStats(const Json& json, Stats* out, std::string* error) {
  Fields fields(json, error);
  out->fps = fields.Number("fps");
  out->kbps = fields.Number("kbps");
  out->encode_ms_p50 = fields.Number("encode_ms_p50");
  out->encode_ms_p95 = fields.Number("encode_ms_p95");
  out->in_flight_frames = fields.Unsigned("in_flight_frames");
  out->in_flight_bytes = fields.Unsigned("in_flight_bytes");
  out->host_cpu = fields.Number("host_cpu");
  return fields.ok();
}

bool ParseError(const Json& json, ErrorInfo* out, std::string* error) {
  Fields fields(json, error);
  out->code = fields.String("code");
  out->message = fields.String("message");
  out->fatal = fields.Bool("fatal");
  return fields.ok();
}

// MARK: Client -> host

bool ParseClientMessage(const Json& json, ClientMessage* out, std::string* error) {
  Fields fields(json, error);
  out->type_name = fields.String("type");
  if (!fields.ok()) {
    return false;
  }
  const std::string& type = out->type_name;
  if (type == "hello") {
    out->type = ClientType::kHello;
    out->protocol = static_cast<int>(fields.Integer("protocol"));
    out->client = fields.String("client");
    out->decoders = fields.StringList("decoders");
    out->mode = fields.String("mode");
    out->visible = fields.OptionalBool("visible").value_or(true);
    if (json.Find("features") != nullptr && !json.Find("features")->is_null()) {
      out->features = fields.StringList("features");
    }
  } else if (type == "ack") {
    out->type = ClientType::kAck;
    out->seq = fields.Unsigned("seq");
  } else if (type == "keyframe_request") {
    out->type = ClientType::kKeyframeRequest;
    out->reason = fields.OptionalString("reason").value_or("");
  } else if (type == "visibility") {
    out->type = ClientType::kVisibility;
    out->visible = fields.Bool("visible");
  } else if (type == "still_request") {
    out->type = ClientType::kStillRequest;
    out->kind = fields.String("kind");
    if (fields.ok() && !OneOf(out->kind, {"still", "thumbnail"})) {
      fields.Fail("kind", "must be still or thumbnail");
    }
  } else if (type == "mouse") {
    out->type = ClientType::kMouse;
    out->kind = fields.String("kind");
    out->x = fields.Number("x");
    out->y = fields.Number("y");
    out->button = fields.OptionalString("button");
    if (std::optional<int64_t> clicks = fields.OptionalInteger("clicks")) {
      out->clicks = static_cast<int>(*clicks);
    }
    out->modifiers = static_cast<uint32_t>(fields.OptionalInteger("modifiers").value_or(0));
    out->dx = fields.OptionalNumber("dx");
    out->dy = fields.OptionalNumber("dy");
    if (fields.ok() && !OneOf(out->kind, {"move", "down", "up", "wheel", "leave"})) {
      fields.Fail("kind", "is not a mouse event kind");
    }
    const bool press = out->kind == "down" || out->kind == "up";
    if (fields.ok() && press &&
        (!out->button || !OneOf(*out->button, {"left", "middle", "right"}))) {
      fields.Fail("button", "must be left, middle or right for down and up");
    }
    if (fields.ok() && out->clicks && (*out->clicks < 1 || *out->clicks > 3)) {
      fields.Fail("clicks", "must be 1 to 3");
    }
  } else if (type == "key") {
    out->type = ClientType::kKey;
    out->kind = fields.String("kind");
    out->code = fields.String("code");
    out->key = fields.OptionalString("key").value_or("");
    out->text = fields.OptionalString("text");
    out->modifiers = static_cast<uint32_t>(fields.OptionalInteger("modifiers").value_or(0));
    out->repeat = fields.OptionalBool("repeat").value_or(false);
    if (fields.ok() && !OneOf(out->kind, {"rawkeydown", "keyup", "char"})) {
      fields.Fail("kind", "must be rawkeydown, keyup or char");
    }
  } else if (type == "ime") {
    out->type = ClientType::kIme;
    out->op = fields.String("op");
    out->text = fields.OptionalString("text");
    if (const Json* selection = fields.OptionalObject("selection")) {
      Range range;
      fields.Require(ParseRange(*selection, &range, error));
      out->selection = range;
    }
    if (const Json* replacement = fields.OptionalObject("replacement")) {
      Range range;
      fields.Require(ParseRange(*replacement, &range, error));
      out->replacement = range;
    }
    if (fields.ok() && !OneOf(out->op, {"set_composition", "commit", "finish", "cancel"})) {
      fields.Fail("op", "is not an IME operation");
    }
  } else if (type == "nav") {
    out->type = ClientType::kNav;
    out->op = fields.String("op");
    out->url = fields.OptionalString("url");
    if (fields.ok() && !OneOf(out->op, {"navigate", "back", "forward", "reload", "stop"})) {
      fields.Fail("op", "is not a navigation operation");
    }
    if (fields.ok() && out->op == "navigate" && !out->url) {
      fields.Fail("url", "is required for navigate");
    }
  } else if (type == "resize") {
    out->type = ClientType::kResize;
    fields.Require(ParseViewport(json, &out->viewport, error));
  } else if (type == "control") {
    out->type = ClientType::kControl;
    out->op = fields.String("op");
    if (fields.ok() && !OneOf(out->op, {"take", "release"})) {
      fields.Fail("op", "must be take or release");
    }
  } else if (type == "dialog_reply") {
    out->type = ClientType::kDialogReply;
    out->id = fields.String("id");
    out->accept = fields.Bool("accept");
    out->text = fields.OptionalString("text");
  } else if (type == "settings") {
    out->type = ClientType::kSettings;
    if (std::optional<int64_t> max_fps = fields.OptionalInteger("max_fps")) {
      if (*max_fps < 1 || *max_fps > 60) {
        fields.Fail("max_fps", "must be 1 to 60");
      }
      out->max_fps = static_cast<uint32_t>(*max_fps);
    }
    out->quality = fields.OptionalString("quality");
    out->scale = fields.OptionalNumber("scale");
    out->codec = fields.OptionalString("codec");
    out->stats = fields.OptionalBool("stats");
    if (fields.ok() && out->quality && !OneOf(*out->quality, {"low", "medium", "high"})) {
      fields.Fail("quality", "must be low, medium or high");
    }
    if (fields.ok() && out->codec && !OneOf(*out->codec, {"auto", "h264", "jpeg"})) {
      fields.Fail("codec", "must be auto, h264 or jpeg");
    }
    if (fields.ok() && out->scale && (*out->scale < 0.25 || *out->scale > 1)) {
      fields.Fail("scale", "must be 0.25 to 1");
    }
  } else if (type == "ping") {
    out->type = ClientType::kPing;
    out->nonce = fields.String("nonce");
  } else {
    out->type = ClientType::kUnknown;
  }
  return fields.ok();
}

Json ToJson(const ClientMessage& message) {
  Json json = Message(message.type_name.c_str());
  auto optional_string = [&json](const char* key, const std::optional<std::string>& value) {
    if (value) {
      json.Set(key, *value);
    }
  };
  switch (message.type) {
    case ClientType::kHello:
      json.Set("protocol", message.protocol);
      json.Set("client", message.client);
      json.Set("decoders", StringArray(message.decoders));
      json.Set("mode", message.mode);
      json.Set("visible", message.visible);
      json.Set("features", StringArray(message.features));
      break;
    case ClientType::kAck:
      json.Set("seq", message.seq);
      break;
    case ClientType::kKeyframeRequest:
      json.Set("reason", message.reason);
      break;
    case ClientType::kVisibility:
      json.Set("visible", message.visible);
      break;
    case ClientType::kStillRequest:
      json.Set("kind", message.kind);
      break;
    case ClientType::kMouse:
      json.Set("kind", message.kind);
      json.Set("x", message.x);
      json.Set("y", message.y);
      optional_string("button", message.button);
      if (message.clicks) {
        json.Set("clicks", *message.clicks);
      }
      json.Set("modifiers", message.modifiers);
      if (message.dx) {
        json.Set("dx", *message.dx);
      }
      if (message.dy) {
        json.Set("dy", *message.dy);
      }
      break;
    case ClientType::kKey:
      json.Set("kind", message.kind);
      json.Set("code", message.code);
      json.Set("key", message.key);
      optional_string("text", message.text);
      json.Set("modifiers", message.modifiers);
      json.Set("repeat", message.repeat);
      break;
    case ClientType::kIme:
      json.Set("op", message.op);
      optional_string("text", message.text);
      if (message.selection) {
        json.Set("selection", RangeJson(*message.selection));
      }
      if (message.replacement) {
        json.Set("replacement", RangeJson(*message.replacement));
      }
      break;
    case ClientType::kNav:
      json.Set("op", message.op);
      optional_string("url", message.url);
      break;
    case ClientType::kResize:
      Merge(ToJson(message.viewport), &json);
      break;
    case ClientType::kControl:
      json.Set("op", message.op);
      break;
    case ClientType::kDialogReply:
      json.Set("id", message.id);
      json.Set("accept", message.accept);
      optional_string("text", message.text);
      break;
    case ClientType::kSettings:
      if (message.max_fps) {
        json.Set("max_fps", *message.max_fps);
      }
      optional_string("quality", message.quality);
      if (message.scale) {
        json.Set("scale", *message.scale);
      }
      optional_string("codec", message.codec);
      if (message.stats) {
        json.Set("stats", *message.stats);
      }
      break;
    case ClientType::kPing:
      json.Set("nonce", message.nonce);
      break;
    case ClientType::kUnknown:
      break;
  }
  return json;
}

// MARK: Runner <-> host

Preamble ParsePreamble(const Json& json, AttachPreamble* attach, std::string* error) {
  Fields fields(json, error);
  const std::string type = fields.String("type");
  if (!fields.ok()) {
    return Preamble::kInvalid;
  }
  if (type == "control") {
    return Preamble::kControl;
  }
  if (type != "attach") {
    fields.Fail("type", "must be attach or control");
    return Preamble::kInvalid;
  }
  attach->protocol = static_cast<int>(fields.Integer("protocol"));
  attach->tab_id = fields.String("tab_id");
  attach->mode = fields.String("mode");
  if (fields.ok() && attach->mode != "view" && attach->mode != "control") {
    fields.Fail("mode", "must be view or control");
  }
  return fields.ok() ? Preamble::kAttach : Preamble::kInvalid;
}

bool ParseControlRequest(const Json& json, ControlRequest* out, std::string* error) {
  Fields fields(json, error);
  if (fields.String("type") != "request" && fields.ok()) {
    fields.Fail("type", "must be request");
  }
  out->id = fields.String("id");
  out->op = fields.String("op");
  const Json* args = fields.OptionalObject("args");
  out->args = args != nullptr ? *args : Json::MakeObject();
  return fields.ok();
}

bool ParseTabRecord(const Json& json, TabRecord* out, std::string* error) {
  Fields fields(json, error);
  out->id = fields.String("id");
  out->session_id = fields.String("session_id");
  out->url = fields.String("url");
  out->title = fields.String("title");
  out->loading = fields.Bool("loading");
  out->owner = fields.String("owner");
  out->needs_attention = fields.Bool("needs_attention");
  out->profile = fields.String("profile");
  out->created_by = fields.String("created_by");
  out->target_id = fields.String("target_id");
  out->can_go_back = fields.Bool("can_go_back");
  out->can_go_forward = fields.Bool("can_go_forward");
  return fields.ok();
}

Json ToJson(const TabRecord& tab) {
  Json json = Json::MakeObject();
  json.Set("id", tab.id);
  json.Set("session_id", tab.session_id);
  json.Set("url", tab.url);
  json.Set("title", tab.title);
  json.Set("loading", tab.loading);
  json.Set("owner", tab.owner);
  json.Set("needs_attention", tab.needs_attention);
  json.Set("profile", tab.profile);
  json.Set("created_by", tab.created_by);
  json.Set("target_id", tab.target_id);
  json.Set("can_go_back", tab.can_go_back);
  json.Set("can_go_forward", tab.can_go_forward);
  return json;
}

Json ResponseOk(const std::string& id, Json result) {
  Json json = Message("response");
  json.Set("id", id);
  json.Set("ok", true);
  json.Set("result", std::move(result));
  return json;
}

Json ResponseError(const std::string& id, const std::string& code, const std::string& message) {
  Json json = Message("response");
  json.Set("id", id);
  json.Set("ok", false);
  Json error = Json::MakeObject();
  error.Set("code", code);
  error.Set("message", message);
  json.Set("error", error);
  return json;
}

}  // namespace rb::protocol
