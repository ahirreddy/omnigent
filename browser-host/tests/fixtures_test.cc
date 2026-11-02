// Round-trips the shared protocol v1 fixtures (client-core/fixtures/remote_browser): every
// message parses into the host's models and serializes back to the same JSON, and the binary
// fixtures decode to the headers in their index and re-encode byte for byte.
#include <dirent.h>

#include <algorithm>

#include "core/framing.h"
#include "core/h264.h"
#include "core/host_files.h"
#include "core/json.h"
#include "core/media_header.h"
#include "core/protocol.h"
#include "test.h"

using rb::Json;
namespace protocol = rb::protocol;

namespace {

std::vector<std::string> JsonFiles(const std::string& directory) {
  std::vector<std::string> files;
  DIR* handle = opendir(rb::test::FixturePath(directory).c_str());
  if (handle == nullptr) {
    return files;
  }
  while (dirent* entry = readdir(handle)) {
    const std::string name = entry->d_name;
    if (name.size() > 5 && name.substr(name.size() - 5) == ".json") {
      files.push_back(directory + "/" + name);
    }
  }
  closedir(handle);
  std::sort(files.begin(), files.end());
  return files;
}

bool LoadJson(const std::string& relative, Json* out, std::string* error) {
  std::string text;
  if (!rb::test::ReadFile(rb::test::FixturePath(relative), &text)) {
    *error = "cannot read " + relative;
    return false;
  }
  std::optional<Json> parsed = Json::Parse(text, error);
  if (!parsed) {
    return false;
  }
  *out = *parsed;
  return true;
}

/// `expected` minus the keys a v1 receiver ignores (fields not in the spec).
Json WithoutKeys(const Json& value, std::initializer_list<const char*> keys) {
  Json copy = Json::MakeObject();
  for (const auto& [key, item] : value.as_object()) {
    if (std::find_if(keys.begin(), keys.end(), [&](const char* skip) { return key == skip; }) ==
        keys.end()) {
      copy.Set(key, item);
    }
  }
  return copy;
}

/// Parses a host -> client fixture with the typed parser and rebuilds it with the builder the
/// host uses. Returns false when the type is unknown to v1.
bool RoundTripHostMessage(const Json& message, Json* rebuilt, std::string* error) {
  const std::string type = message.GetString("type").value_or("");
  if (type == "hello") {
    protocol::HostHello hello;
    if (!protocol::ParseHostHello(message, &hello, error)) return false;
    *rebuilt = protocol::HelloMessage(hello);
  } else if (type == "nav") {
    protocol::NavState nav;
    if (!protocol::ParseNav(message, &nav, error)) return false;
    *rebuilt = protocol::NavMessage(nav);
  } else if (type == "cursor") {
    protocol::CursorState cursor;
    if (!protocol::ParseCursor(message, &cursor, error)) return false;
    *rebuilt = protocol::CursorMessage(cursor);
  } else if (type == "text_input") {
    protocol::TextInputState text_input;
    if (!protocol::ParseTextInput(message, &text_input, error)) return false;
    *rebuilt = protocol::TextInputMessage(text_input);
  } else if (type == "control") {
    protocol::ControlState state;
    if (!protocol::ParseControlState(message, &state, error)) return false;
    *rebuilt = protocol::ControlMessage(state, message.GetString("reason"));
  } else if (type == "dialog") {
    protocol::Dialog dialog;
    if (!protocol::ParseDialog(message, &dialog, error)) return false;
    *rebuilt = protocol::DialogMessage(dialog);
  } else if (type == "dialog_closed") {
    *rebuilt = protocol::DialogClosedMessage(message.GetString("id").value_or(""));
  } else if (type == "viewport") {
    protocol::Viewport viewport;
    if (!protocol::ParseViewport(message, &viewport, error)) return false;
    *rebuilt = protocol::ViewportMessage(viewport);
  } else if (type == "settings") {
    protocol::Settings settings;
    if (!protocol::ParseSettings(message, &settings, error)) return false;
    *rebuilt = protocol::SettingsMessage(settings);
  } else if (type == "stats") {
    protocol::Stats stats;
    if (!protocol::ParseStats(message, &stats, error)) return false;
    *rebuilt = protocol::StatsMessage(stats);
  } else if (type == "pong") {
    *rebuilt = protocol::PongMessage(message.GetString("nonce").value_or(""));
  } else if (type == "error") {
    protocol::ErrorInfo info;
    if (!protocol::ParseError(message, &info, error)) return false;
    *rebuilt = protocol::ErrorMessage(info);
  } else if (type == "tab_closed") {
    *rebuilt = protocol::TabClosedMessage(message.GetString("reason").value_or(""));
  } else {
    *error = "unknown type";
    return false;
  }
  return true;
}

}  // namespace

TEST(FixturesHostToClientMessagesRoundTrip) {
  const std::vector<std::string> files = JsonFiles("messages/host_to_client");
  CHECK_MSG(files.size() >= 20, "fixtures not found under " RB_FIXTURE_DIR);
  for (const std::string& file : files) {
    Json message;
    std::string error;
    CHECK_MSG(LoadJson(file, &message, &error), file + ": " + error);
    Json rebuilt;
    const bool known = RoundTripHostMessage(message, &rebuilt, &error);
    if (file.find("unknown_type") != std::string::npos) {
      CHECK_MSG(!known, file + " should be an unknown type");
      continue;
    }
    CHECK_MSG(known, file + ": " + error);
    Json expected = WithoutKeys(message, {"future_field"});
    if (const Json* control = message.Find("control")) {
      // hello.control is a control_state; its absent `holder` is written as null.
      Json normalized = *control;
      if (normalized.Find("holder") == nullptr) normalized.Set("holder", nullptr);
      expected.Set("control", normalized);
    }
    CHECK_MSG(rebuilt == expected, file + ": rebuilt " + rebuilt.Dump());
  }
}

TEST(FixturesClientToHostMessagesRoundTrip) {
  const std::vector<std::string> files = JsonFiles("messages/client_to_host");
  CHECK(files.size() >= 25);
  for (const std::string& file : files) {
    Json message;
    std::string error;
    CHECK_MSG(LoadJson(file, &message, &error), file + ": " + error);
    protocol::ClientMessage parsed;
    CHECK_MSG(protocol::ParseClientMessage(message, &parsed, &error), file + ": " + error);
    CHECK_MSG(parsed.type != protocol::ClientType::kUnknown, file);
    const Json rebuilt = protocol::ToJson(parsed);
    CHECK_MSG(rebuilt == message, file + ": rebuilt " + rebuilt.Dump());
  }
}

TEST(FixturesClientMessagesMapToHostInputs) {
  Json message;
  std::string error;
  protocol::ClientMessage parsed;
  CHECK(LoadJson("messages/client_to_host/mouse_down.json", &message, &error));
  CHECK(protocol::ParseClientMessage(message, &parsed, &error));
  CHECK_EQ(*parsed.button, std::string("left"));
  CHECK_EQ(parsed.modifiers, static_cast<uint32_t>(protocol::kModifierLeftButton));
  CHECK(LoadJson("messages/client_to_host/mouse_wheel.json", &message, &error));
  CHECK(protocol::ParseClientMessage(message, &parsed, &error));
  CHECK_EQ(*parsed.dy, 120.0);
  // A down without a button is rejected.
  Json invalid = *Json::Parse(R"({"type":"mouse","kind":"down","x":1,"y":1})", &error);
  CHECK(!protocol::ParseClientMessage(invalid, &parsed, &error));
}

TEST(FixturesRunnerHostPreamblesRequestsAndResponses) {
  Json message;
  std::string error;
  protocol::AttachPreamble attach;
  CHECK(LoadJson("runner_host/attach.json", &message, &error));
  CHECK(protocol::ParsePreamble(message, &attach, &error) == protocol::Preamble::kAttach);
  CHECK_EQ(attach.tab_id, std::string("btab_7f3a9c2e"));
  CHECK_EQ(attach.mode, std::string("control"));
  CHECK(LoadJson("runner_host/attach_view.json", &message, &error));
  CHECK(protocol::ParsePreamble(message, &attach, &error) == protocol::Preamble::kAttach);
  CHECK_EQ(attach.mode, std::string("view"));
  CHECK(LoadJson("runner_host/control_preamble.json", &message, &error));
  CHECK(protocol::ParsePreamble(message, &attach, &error) == protocol::Preamble::kControl);

  for (const std::string& file : JsonFiles("runner_host")) {
    CHECK(LoadJson(file, &message, &error));
    const std::string type = message.GetString("type").value_or("");
    if (type == "request") {
      protocol::ControlRequest request;
      CHECK_MSG(protocol::ParseControlRequest(message, &request, &error), file + ": " + error);
      CHECK(!request.op.empty());
    } else if (type == "response") {
      const std::string id = message.GetString("id").value_or("");
      Json rebuilt;
      if (message.GetBool("ok").value_or(false)) {
        Json result = *message.Find("result");
        // Tab records go through the host's TabRecord model.
        if (result.Find("session_id") != nullptr) {
          protocol::TabRecord tab;
          CHECK_MSG(protocol::ParseTabRecord(result, &tab, &error), file + ": " + error);
          result = protocol::ToJson(tab);
        } else if (const Json* tabs = result.Find("tabs"); tabs != nullptr && tabs->is_array()) {
          Json list = Json::MakeArray();
          for (const Json& item : tabs->as_array()) {
            protocol::TabRecord tab;
            CHECK_MSG(protocol::ParseTabRecord(item, &tab, &error), file + ": " + error);
            list.Push(protocol::ToJson(tab));
          }
          result.Set("tabs", list);
        }
        rebuilt = protocol::ResponseOk(id, result);
      } else {
        const Json* failure = message.Find("error");
        CHECK(failure != nullptr);
        rebuilt = protocol::ResponseError(id, failure->GetString("code").value_or(""),
                                          failure->GetString("message").value_or(""));
      }
      CHECK_MSG(rebuilt == message, file + ": rebuilt " + rebuilt.Dump());
    }
  }

  CHECK(LoadJson("runner_host/host_json.json", &message, &error));
  rb::HostState state;
  state.pid = *message.GetInteger("pid");
  state.socket = *message.GetString("socket");
  state.cdp_port = static_cast<int>(*message.GetInteger("cdp_port"));
  state.version = *message.GetString("version");
  state.profile = *message.GetString("profile");
  state.started_at = rb::Rfc3339Utc(1793570400);  // 2026-11-01T22:00:00Z
  state.encoder_path = *message.Find("encoder")->GetString("path");
  state.encoder_kind = *message.Find("encoder")->GetString("kind");
  CHECK_MSG(rb::HostStateJson(state) == message, rb::HostStateJson(state).Dump());
}

TEST(FixturesBinaryFramesDecodeAndReencode) {
  Json index;
  std::string error;
  CHECK_MSG(LoadJson("binary_frames/index.json", &index, &error), error);
  const Json* frames = index.Find("frames");
  CHECK(frames != nullptr && frames->as_array().size() >= 10);
  for (const Json& entry : frames->as_array()) {
    const std::string file = "binary_frames/" + *entry.GetString("file");
    std::string bytes;
    CHECK_MSG(rb::test::ReadFile(rb::test::FixturePath(file), &bytes), file);
    const auto* data = reinterpret_cast<const uint8_t*>(bytes.data());
    rb::MediaHeader header;
    const rb::MediaHeaderError result = rb::ReadMediaHeader(data, bytes.size(), &header);
    if (!entry.GetBool("valid").value_or(false)) {
      CHECK_MSG(std::string(rb::MediaHeaderErrorName(result)) == *entry.GetString("error"),
                file + ": got " + rb::MediaHeaderErrorName(result));
      continue;
    }
    CHECK_MSG(result == rb::MediaHeaderError::kNone, file);
    const Json& expected = *entry.Find("header");
    CHECK_EQ(static_cast<int64_t>(header.kind), *expected.GetInteger("kind"));
    CHECK_EQ(static_cast<int64_t>(header.flags), *expected.GetInteger("flags"));
    CHECK_EQ(static_cast<int64_t>(header.header_len), *expected.GetInteger("header_len"));
    CHECK_EQ(static_cast<int64_t>(header.seq), *expected.GetInteger("seq"));
    CHECK_EQ(static_cast<int64_t>(header.stream_id), *expected.GetInteger("stream_id"));
    CHECK_EQ(static_cast<int64_t>(header.pts_us), *expected.GetInteger("pts_us"));
    CHECK_EQ(static_cast<int64_t>(bytes.size() - header.header_len),
             *entry.GetInteger("payload_length"));
    if (header.header_len == rb::kMediaHeaderSize) {
      const std::vector<uint8_t> rebuilt =
          rb::BuildMediaMessage(header, data + header.header_len, bytes.size() - header.header_len);
      CHECK_MSG(std::string(rebuilt.begin(), rebuilt.end()) == bytes, file + " re-encoding");
    }
    if (header.kind == 1) {
      const bool keyframe =
          rb::ContainsIdr(data + header.header_len, bytes.size() - header.header_len);
      CHECK_EQ(keyframe, (header.flags & rb::kMediaFlagKeyframe) != 0);
    }
  }
}

TEST(FixturesUnixSocketFramesDecodeAndReencode) {
  Json index;
  std::string error;
  CHECK(LoadJson("unix_socket/index.json", &index, &error));
  for (const Json& entry : index.Find("frames")->as_array()) {
    const std::string file = "unix_socket/" + *entry.GetString("file");
    std::string bytes;
    CHECK_MSG(rb::test::ReadFile(rb::test::FixturePath(file), &bytes), file);
    rb::FrameReader reader;
    // Feed one byte at a time to exercise partial reads.
    std::optional<rb::Frame> frame;
    for (size_t index_byte = 0; index_byte < bytes.size(); ++index_byte) {
      CHECK(!frame.has_value());
      reader.Append(reinterpret_cast<const uint8_t*>(bytes.data()) + index_byte, 1);
      frame = reader.Next();
    }
    CHECK_MSG(frame.has_value(), file + ": " + reader.error());
    CHECK_EQ(static_cast<int64_t>(frame->kind), *entry.GetInteger("kind"));
    CHECK_EQ(static_cast<int64_t>(frame->payload.size()), *entry.GetInteger("payload_length"));
    const std::vector<uint8_t> rebuilt =
        rb::EncodeFrame(frame->kind, frame->payload.data(), frame->payload.size());
    CHECK_MSG(std::string(rebuilt.begin(), rebuilt.end()) == bytes, file + " re-encoding");
    if (frame->kind == rb::FrameKind::kClose) {
      uint16_t code = 0;
      std::string reason;
      CHECK(rb::DecodeClosePayload(frame->payload, &code, &reason));
      CHECK(code == 4404 || code == 1000);
    }
    if (frame->kind == rb::FrameKind::kText) {
      protocol::AttachPreamble attach;
      CHECK(protocol::ParsePreamble(*Json::Parse(frame->text(), &error), &attach, &error) ==
            protocol::Preamble::kAttach);
    }
  }
}

TEST(FixturesH264StreamsSplitIntoTheListedAccessUnits) {
  for (const char* name : {"testsrc_1280x800", "testsrc_640x400"}) {
    Json frames;
    std::string error;
    CHECK(LoadJson(std::string("h264/") + name + ".frames.json", &frames, &error));
    std::string stream;
    CHECK(rb::test::ReadFile(rb::test::FixturePath(std::string("h264/") + name + ".annexb"),
                             &stream));
    const auto* data = reinterpret_cast<const uint8_t*>(stream.data());
    const Json* units = frames.Find("frames");
    CHECK(units != nullptr && !units->as_array().empty());
    for (const Json& unit : units->as_array()) {
      const size_t offset = static_cast<size_t>(*unit.GetInteger("offset"));
      const size_t length = static_cast<size_t>(*unit.GetInteger("length"));
      CHECK(offset + length <= stream.size());
      std::vector<int64_t> types;
      for (const rb::NalUnit& nal : rb::SplitAnnexB(data + offset, length)) {
        types.push_back(nal.type());
      }
      std::vector<int64_t> expected;
      for (const Json& type : unit.Find("nal_types")->as_array()) {
        expected.push_back(*type.as_integer());
      }
      CHECK_MSG(types == expected, std::string(name) + " NAL types differ");
      CHECK_EQ(rb::ContainsIdr(data + offset, length), *unit.GetBool("keyframe"));
    }
  }
}
