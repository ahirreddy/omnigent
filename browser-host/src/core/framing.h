// host.sock framing: u32 little-endian payload length, u8 kind, payload. Kind 1 is a UTF-8 JSON
// text message, 2 a binary media message (MediaHeader plus payload), 3 a close (u16 LE code plus
// a UTF-8 reason). See browser-host/README.md, "Socket protocol".
#pragma once

#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace rb {

enum class FrameKind : uint8_t { kText = 1, kBinary = 2, kClose = 3 };

inline constexpr size_t kFrameHeaderSize = 5;
inline constexpr uint32_t kMaxFramePayload = 16u << 20;

struct Frame {
  FrameKind kind = FrameKind::kText;
  std::vector<uint8_t> payload;

  std::string_view text() const {
    return std::string_view(reinterpret_cast<const char*>(payload.data()), payload.size());
  }
};

/// Serializes a frame header plus payload.
std::vector<uint8_t> EncodeFrame(FrameKind kind, const void* payload, size_t length);
std::vector<uint8_t> EncodeTextFrame(std::string_view text);
std::vector<uint8_t> EncodeCloseFrame(uint16_t code, std::string_view reason);

/// Parses a close frame payload. False when it is shorter than the code.
bool DecodeClosePayload(const std::vector<uint8_t>& payload, uint16_t* code, std::string* reason);

/// Incremental decoder for a byte stream of frames.
class FrameReader {
 public:
  /// Appends received bytes.
  void Append(const uint8_t* data, size_t length);
  /// Returns the next complete frame, or nullopt when more bytes are needed or on error.
  std::optional<Frame> Next();
  /// Set when the stream is malformed (unknown kind, oversized frame). Sticky.
  const std::string& error() const { return error_; }
  size_t buffered() const { return buffer_.size() - offset_; }

 private:
  std::vector<uint8_t> buffer_;
  size_t offset_ = 0;
  std::string error_;
};

}  // namespace rb
