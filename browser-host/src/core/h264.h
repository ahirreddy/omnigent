// H.264 bitstream helpers: Annex-B NAL splitting, and an incremental FLV demuxer that turns an
// encoder's FLV output into Annex-B access units. FLV gives exact frame boundaries over a pipe,
// which raw Annex-B cannot (a NAL unit only ends when the next start code arrives).
#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace rb {

enum NalType : uint8_t {
  kNalSlice = 1,
  kNalIdr = 5,
  kNalSei = 6,
  kNalSps = 7,
  kNalPps = 8,
  kNalAud = 9,
  kNalFiller = 12,
};

struct NalUnit {
  const uint8_t* data = nullptr;  // First byte after the start code (the NAL header).
  size_t size = 0;
  uint8_t type() const { return size > 0 ? data[0] & 0x1F : 0; }
};

/// Splits an Annex-B byte stream (3- or 4-byte start codes) into NAL units.
std::vector<NalUnit> SplitAnnexB(const uint8_t* data, size_t size);
/// Whether the access unit contains an IDR slice.
bool ContainsIdr(const uint8_t* data, size_t size);

struct AccessUnit {
  std::vector<uint8_t> annexb;
  bool keyframe = false;
  uint32_t flv_timestamp_ms = 0;
};

/// Parses FLV (as written by x264 --muxer flv and ffmpeg -f flv) into access units. Keyframes
/// get the SPS and PPS from the AVC sequence header prepended when they do not carry them.
class FlvDemuxer {
 public:
  void Append(const uint8_t* data, size_t size);
  /// Moves out the access units completed so far.
  std::vector<AccessUnit> TakeAccessUnits();
  /// Non-empty once the stream is malformed. Sticky.
  const std::string& error() const { return error_; }
  const std::vector<uint8_t>& sps() const { return sps_; }
  const std::vector<uint8_t>& pps() const { return pps_; }

 private:
  bool ParseTag(uint8_t type, const uint8_t* data, size_t size, uint32_t timestamp);
  bool ParseSequenceHeader(const uint8_t* data, size_t size);

  std::vector<uint8_t> buffer_;
  size_t offset_ = 0;
  bool header_done_ = false;
  int length_size_ = 4;
  std::vector<uint8_t> sps_;
  std::vector<uint8_t> pps_;
  std::vector<AccessUnit> ready_;
  std::string error_;
};

}  // namespace rb
