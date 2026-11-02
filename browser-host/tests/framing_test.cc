#include "core/framing.h"
#include "test.h"

TEST(FramingReadsSplitAndCoalescedFrames) {
  std::vector<uint8_t> stream = rb::EncodeTextFrame("{\"type\":\"control\"}");
  const std::vector<uint8_t> binary = rb::EncodeFrame(rb::FrameKind::kBinary, "\x01\x02", 2);
  stream.insert(stream.end(), binary.begin(), binary.end());
  rb::FrameReader reader;
  reader.Append(stream.data(), 3);
  CHECK(!reader.Next().has_value());
  reader.Append(stream.data() + 3, stream.size() - 3);
  auto first = reader.Next();
  CHECK(first.has_value());
  CHECK_EQ(first->text(), std::string_view("{\"type\":\"control\"}"));
  auto second = reader.Next();
  CHECK(second.has_value());
  CHECK(second->kind == rb::FrameKind::kBinary);
  CHECK_EQ(second->payload.size(), 2u);
  CHECK(!reader.Next().has_value());
  CHECK_EQ(reader.buffered(), 0u);
}

TEST(FramingRejectsOversizeAndUnknownKinds) {
  const uint8_t oversize[5] = {0x01, 0x00, 0x00, 0x01, 1};  // 16 MiB + 1
  rb::FrameReader reader;
  reader.Append(oversize, 5);
  CHECK(!reader.Next().has_value());
  CHECK(reader.error().find("exceeds") != std::string::npos);
  const uint8_t unknown[5] = {0, 0, 0, 0, 9};
  rb::FrameReader other;
  other.Append(unknown, 5);
  CHECK(!other.Next().has_value());
  CHECK(!other.error().empty());
}

TEST(FramingCloseFrames) {
  const std::vector<uint8_t> frame = rb::EncodeCloseFrame(4404, "tab closed");
  rb::FrameReader reader;
  reader.Append(frame.data(), frame.size());
  auto parsed = reader.Next();
  CHECK(parsed.has_value());
  uint16_t code = 0;
  std::string reason;
  CHECK(rb::DecodeClosePayload(parsed->payload, &code, &reason));
  CHECK_EQ(code, 4404);
  CHECK_EQ(reason, std::string("tab closed"));
}
