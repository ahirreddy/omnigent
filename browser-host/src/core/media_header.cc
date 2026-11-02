#include "core/media_header.h"

#include <cstring>

namespace rb {

namespace {

template <typename T>
void Put(uint8_t* out, T value) {
  for (size_t index = 0; index < sizeof(T); ++index) {
    out[index] = static_cast<uint8_t>(value >> (8 * index));
  }
}

template <typename T>
T Get(const uint8_t* in) {
  T value = 0;
  for (size_t index = 0; index < sizeof(T); ++index) {
    value |= static_cast<T>(static_cast<T>(in[index]) << (8 * index));
  }
  return value;
}

}  // namespace

const char* MediaHeaderErrorName(MediaHeaderError error) {
  switch (error) {
    case MediaHeaderError::kNone:
      return "none";
    case MediaHeaderError::kTruncated:
      return "truncated";
    case MediaHeaderError::kBadMagic:
      return "bad_magic";
    case MediaHeaderError::kUnsupportedVersion:
      return "unsupported_version";
    case MediaHeaderError::kBadHeaderLen:
      return "bad_header_len";
  }
  return "unknown";
}

void WriteMediaHeader(const MediaHeader& header, uint8_t out[kMediaHeaderSize]) {
  Put<uint16_t>(out, kMediaMagic);
  out[2] = kMediaVersion;
  out[3] = header.kind;
  Put<uint16_t>(out + 4, header.flags);
  Put<uint16_t>(out + 6, kMediaHeaderSize);
  Put<uint32_t>(out + 8, header.seq);
  Put<uint32_t>(out + 12, header.stream_id);
  Put<uint64_t>(out + 16, header.pts_us);
}

MediaHeaderError ReadMediaHeader(const uint8_t* data, size_t length, MediaHeader* header) {
  if (length < kMediaHeaderSize) {
    return MediaHeaderError::kTruncated;
  }
  if (Get<uint16_t>(data) != kMediaMagic) {
    return MediaHeaderError::kBadMagic;
  }
  if (data[2] != kMediaVersion) {
    return MediaHeaderError::kUnsupportedVersion;
  }
  const uint16_t header_len = Get<uint16_t>(data + 6);
  if (header_len < kMediaHeaderSize || header_len > length) {
    return MediaHeaderError::kBadHeaderLen;
  }
  header->kind = data[3];
  header->flags = Get<uint16_t>(data + 4);
  header->header_len = header_len;
  header->seq = Get<uint32_t>(data + 8);
  header->stream_id = Get<uint32_t>(data + 12);
  header->pts_us = Get<uint64_t>(data + 16);
  return MediaHeaderError::kNone;
}

std::vector<uint8_t> BuildMediaMessage(const MediaHeader& header, const uint8_t* payload,
                                       size_t length) {
  std::vector<uint8_t> message(kMediaHeaderSize + length);
  WriteMediaHeader(header, message.data());
  if (length > 0) {
    std::memcpy(message.data() + kMediaHeaderSize, payload, length);
  }
  return message;
}

}  // namespace rb
