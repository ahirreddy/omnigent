// The 24-byte little-endian header of binary media messages (design doc section 5.2).
#pragma once

#include <cstddef>
#include <cstdint>
#include <vector>

namespace rb {

inline constexpr uint16_t kMediaMagic = 0x4252;  // Bytes 52 42 on the wire.
inline constexpr uint8_t kMediaVersion = 1;
inline constexpr uint16_t kMediaHeaderSize = 24;

enum class MediaKind : uint8_t { kH264AccessUnit = 1, kJpegStill = 2, kJpegThumbnail = 3 };

inline constexpr uint16_t kMediaFlagKeyframe = 1u << 0;
inline constexpr uint16_t kMediaFlagNewStream = 1u << 1;

struct MediaHeader {
  uint8_t kind = static_cast<uint8_t>(MediaKind::kH264AccessUnit);
  uint16_t flags = 0;
  uint16_t header_len = kMediaHeaderSize;
  uint32_t seq = 0;
  uint32_t stream_id = 0;
  uint64_t pts_us = 0;
};

enum class MediaHeaderError { kNone, kTruncated, kBadMagic, kUnsupportedVersion, kBadHeaderLen };

const char* MediaHeaderErrorName(MediaHeaderError error);

/// Writes the fixed 24 bytes (`header_len` is always written as 24).
void WriteMediaHeader(const MediaHeader& header, uint8_t out[kMediaHeaderSize]);
/// Validates and parses a whole binary message's header. `header.header_len` tells where the
/// payload starts.
MediaHeaderError ReadMediaHeader(const uint8_t* data, size_t length, MediaHeader* header);
/// Header plus payload, ready to wrap in a binary frame.
std::vector<uint8_t> BuildMediaMessage(const MediaHeader& header, const uint8_t* payload,
                                       size_t length);

}  // namespace rb
