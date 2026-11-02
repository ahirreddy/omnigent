#include "core/framing.h"

#include <cstring>

namespace rb {

namespace {

void PutU32(uint8_t* out, uint32_t value) {
  out[0] = static_cast<uint8_t>(value);
  out[1] = static_cast<uint8_t>(value >> 8);
  out[2] = static_cast<uint8_t>(value >> 16);
  out[3] = static_cast<uint8_t>(value >> 24);
}

uint32_t GetU32(const uint8_t* in) {
  return static_cast<uint32_t>(in[0]) | (static_cast<uint32_t>(in[1]) << 8) |
         (static_cast<uint32_t>(in[2]) << 16) | (static_cast<uint32_t>(in[3]) << 24);
}

}  // namespace

std::vector<uint8_t> EncodeFrame(FrameKind kind, const void* payload, size_t length) {
  std::vector<uint8_t> frame(kFrameHeaderSize + length);
  PutU32(frame.data(), static_cast<uint32_t>(length));
  frame[4] = static_cast<uint8_t>(kind);
  if (length > 0) {
    std::memcpy(frame.data() + kFrameHeaderSize, payload, length);
  }
  return frame;
}

std::vector<uint8_t> EncodeTextFrame(std::string_view text) {
  return EncodeFrame(FrameKind::kText, text.data(), text.size());
}

std::vector<uint8_t> EncodeCloseFrame(uint16_t code, std::string_view reason) {
  std::vector<uint8_t> payload(2 + reason.size());
  payload[0] = static_cast<uint8_t>(code);
  payload[1] = static_cast<uint8_t>(code >> 8);
  std::memcpy(payload.data() + 2, reason.data(), reason.size());
  return EncodeFrame(FrameKind::kClose, payload.data(), payload.size());
}

bool DecodeClosePayload(const std::vector<uint8_t>& payload, uint16_t* code, std::string* reason) {
  if (payload.size() < 2) {
    return false;
  }
  *code = static_cast<uint16_t>(payload[0] | (payload[1] << 8));
  reason->assign(reinterpret_cast<const char*>(payload.data() + 2), payload.size() - 2);
  return true;
}

void FrameReader::Append(const uint8_t* data, size_t length) {
  if (offset_ > 0 && offset_ == buffer_.size()) {
    buffer_.clear();
    offset_ = 0;
  } else if (offset_ > (1u << 20)) {
    buffer_.erase(buffer_.begin(), buffer_.begin() + static_cast<std::ptrdiff_t>(offset_));
    offset_ = 0;
  }
  buffer_.insert(buffer_.end(), data, data + length);
}

std::optional<Frame> FrameReader::Next() {
  if (!error_.empty() || buffered() < kFrameHeaderSize) {
    return std::nullopt;
  }
  const uint8_t* header = buffer_.data() + offset_;
  const uint32_t length = GetU32(header);
  const uint8_t kind = header[4];
  if (kind < static_cast<uint8_t>(FrameKind::kText) ||
      kind > static_cast<uint8_t>(FrameKind::kClose)) {
    error_ = "unknown frame kind " + std::to_string(kind);
    return std::nullopt;
  }
  if (length > kMaxFramePayload) {
    error_ = "frame of " + std::to_string(length) + " bytes exceeds the 16 MiB limit";
    return std::nullopt;
  }
  if (buffered() < kFrameHeaderSize + length) {
    return std::nullopt;
  }
  Frame frame;
  frame.kind = static_cast<FrameKind>(kind);
  frame.payload.assign(header + kFrameHeaderSize, header + kFrameHeaderSize + length);
  offset_ += kFrameHeaderSize + length;
  return frame;
}

}  // namespace rb
