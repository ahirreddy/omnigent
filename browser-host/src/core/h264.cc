#include "core/h264.h"

#include <cstring>

namespace rb {

namespace {

constexpr uint8_t kStartCode[4] = {0, 0, 0, 1};

void AppendNal(const uint8_t* data, size_t size, std::vector<uint8_t>* out) {
  out->insert(out->end(), kStartCode, kStartCode + 4);
  out->insert(out->end(), data, data + size);
}

uint32_t Be24(const uint8_t* data) {
  return (static_cast<uint32_t>(data[0]) << 16) | (static_cast<uint32_t>(data[1]) << 8) | data[2];
}

}  // namespace

std::vector<NalUnit> SplitAnnexB(const uint8_t* data, size_t size) {
  std::vector<NalUnit> units;
  size_t index = 0;
  size_t start = SIZE_MAX;
  while (index + 3 <= size) {
    if (data[index] == 0 && data[index + 1] == 0 && data[index + 2] == 1) {
      if (start != SIZE_MAX) {
        size_t end = index;
        while (end > start && data[end - 1] == 0) {
          --end;  // Trailing zero bytes belong to the next 4-byte start code.
        }
        units.push_back({data + start, end - start});
      }
      index += 3;
      start = index;
      continue;
    }
    ++index;
  }
  if (start != SIZE_MAX && start < size) {
    units.push_back({data + start, size - start});
  }
  return units;
}

bool ContainsIdr(const uint8_t* data, size_t size) {
  for (const NalUnit& unit : SplitAnnexB(data, size)) {
    if (unit.type() == kNalIdr) {
      return true;
    }
  }
  return false;
}

void FlvDemuxer::Append(const uint8_t* data, size_t size) {
  if (!error_.empty()) {
    return;
  }
  buffer_.insert(buffer_.end(), data, data + size);
  while (error_.empty()) {
    const size_t available = buffer_.size() - offset_;
    const uint8_t* cursor = buffer_.data() + offset_;
    if (!header_done_) {
      // "FLV", version, flags, u32 header size, then u32 PreviousTagSize0.
      if (available < 13) {
        break;
      }
      if (std::memcmp(cursor, "FLV", 3) != 0) {
        error_ = "the encoder output is not FLV";
        break;
      }
      const uint32_t header_size = (static_cast<uint32_t>(cursor[5]) << 24) |
                                   (static_cast<uint32_t>(cursor[6]) << 16) |
                                   (static_cast<uint32_t>(cursor[7]) << 8) | cursor[8];
      if (available < header_size + 4) {
        break;
      }
      offset_ += header_size + 4;
      header_done_ = true;
      continue;
    }
    if (available < 11) {
      break;
    }
    const uint8_t type = cursor[0] & 0x1F;
    const uint32_t data_size = Be24(cursor + 1);
    const uint32_t timestamp = Be24(cursor + 4) | (static_cast<uint32_t>(cursor[7]) << 24);
    if (available < 11 + static_cast<size_t>(data_size) + 4) {
      break;
    }
    if (!ParseTag(type, cursor + 11, data_size, timestamp)) {
      break;
    }
    offset_ += 11 + static_cast<size_t>(data_size) + 4;
  }
  if (offset_ > 0 && offset_ == buffer_.size()) {
    buffer_.clear();
    offset_ = 0;
  } else if (offset_ > (1u << 20)) {
    buffer_.erase(buffer_.begin(), buffer_.begin() + static_cast<std::ptrdiff_t>(offset_));
    offset_ = 0;
  }
}

bool FlvDemuxer::ParseTag(uint8_t type, const uint8_t* data, size_t size, uint32_t timestamp) {
  if (type != 9) {
    return true;  // Script data (onMetaData) and audio are not needed.
  }
  if (size < 5) {
    error_ = "short FLV video tag";
    return false;
  }
  const uint8_t codec = data[0] & 0x0F;
  if (codec != 7) {
    error_ = "FLV video tag is not AVC (codec " + std::to_string(codec) + ")";
    return false;
  }
  const bool flv_keyframe = (data[0] >> 4) == 1;
  const uint8_t packet_type = data[1];
  const uint8_t* payload = data + 5;
  const size_t payload_size = size - 5;
  if (packet_type == 0) {
    return ParseSequenceHeader(payload, payload_size);
  }
  if (packet_type == 2) {
    return true;  // End of sequence.
  }
  if (packet_type != 1) {
    error_ = "unknown AVC packet type " + std::to_string(packet_type);
    return false;
  }
  AccessUnit unit;
  unit.flv_timestamp_ms = timestamp;
  bool has_sps = false;
  bool has_idr = false;
  std::vector<uint8_t> nals;
  size_t index = 0;
  while (index < payload_size) {
    if (payload_size - index < static_cast<size_t>(length_size_)) {
      error_ = "truncated AVC NAL length";
      return false;
    }
    size_t length = 0;
    for (int byte = 0; byte < length_size_; ++byte) {
      length = (length << 8) | payload[index + static_cast<size_t>(byte)];
    }
    index += static_cast<size_t>(length_size_);
    if (length == 0 || payload_size - index < length) {
      error_ = "invalid AVC NAL length";
      return false;
    }
    const uint8_t nal_type = payload[index] & 0x1F;
    has_sps |= nal_type == kNalSps;
    has_idr |= nal_type == kNalIdr;
    AppendNal(payload + index, length, &nals);
    index += length;
  }
  unit.keyframe = has_idr || (flv_keyframe && has_sps);
  if (has_idr && !has_sps) {
    if (sps_.empty() || pps_.empty()) {
      error_ = "an IDR arrived before the AVC sequence header";
      return false;
    }
    AppendNal(sps_.data(), sps_.size(), &unit.annexb);
    AppendNal(pps_.data(), pps_.size(), &unit.annexb);
  }
  unit.annexb.insert(unit.annexb.end(), nals.begin(), nals.end());
  ready_.push_back(std::move(unit));
  return true;
}

bool FlvDemuxer::ParseSequenceHeader(const uint8_t* data, size_t size) {
  // AVCDecoderConfigurationRecord (ISO/IEC 14496-15 5.2.4.1).
  if (size < 7 || data[0] != 1) {
    error_ = "malformed AVC sequence header";
    return false;
  }
  length_size_ = (data[4] & 0x03) + 1;
  size_t index = 5;
  const int sps_count = data[index++] & 0x1F;
  for (int count = 0; count < sps_count; ++count) {
    if (size - index < 2) {
      error_ = "truncated SPS in the AVC sequence header";
      return false;
    }
    const size_t length = (static_cast<size_t>(data[index]) << 8) | data[index + 1];
    index += 2;
    if (size - index < length) {
      error_ = "truncated SPS in the AVC sequence header";
      return false;
    }
    if (count == 0) {
      sps_.assign(data + index, data + index + length);
    }
    index += length;
  }
  if (size - index < 1) {
    error_ = "missing PPS in the AVC sequence header";
    return false;
  }
  const int pps_count = data[index++];
  for (int count = 0; count < pps_count; ++count) {
    if (size - index < 2) {
      error_ = "truncated PPS in the AVC sequence header";
      return false;
    }
    const size_t length = (static_cast<size_t>(data[index]) << 8) | data[index + 1];
    index += 2;
    if (size - index < length) {
      error_ = "truncated PPS in the AVC sequence header";
      return false;
    }
    if (count == 0) {
      pps_.assign(data + index, data + index + length);
    }
    index += length;
  }
  return true;
}

std::vector<AccessUnit> FlvDemuxer::TakeAccessUnits() {
  std::vector<AccessUnit> out;
  out.swap(ready_);
  return out;
}

}  // namespace rb
