// BGRA to I420 (BT.709, limited range) conversion. The host converts only damaged regions into
// a persistent I420 frame, so typing costs a few rows instead of a whole frame.
#pragma once

#include <cstddef>
#include <cstdint>
#include <vector>

#include "core/geometry.h"

namespace rb {

/// A planar 4:2:0 frame with even dimensions and tightly packed planes (Y, then U, then V).
class I420Frame {
 public:
  void Resize(int width, int height);
  int width() const { return width_; }
  int height() const { return height_; }
  uint8_t* y() { return data_.data(); }
  uint8_t* u() { return data_.data() + static_cast<size_t>(width_) * height_; }
  uint8_t* v() { return u() + static_cast<size_t>(width_ / 2) * (height_ / 2); }
  const uint8_t* y() const { return data_.data(); }
  const uint8_t* u() const { return data_.data() + static_cast<size_t>(width_) * height_; }
  const uint8_t* v() const { return u() + static_cast<size_t>(width_ / 2) * (height_ / 2); }
  const uint8_t* data() const { return data_.data(); }
  size_t size() const { return data_.size(); }

 private:
  int width_ = 0;
  int height_ = 0;
  std::vector<uint8_t> data_;
};

/// Converts `rect` (grown to even coordinates) of a BGRA image into `frame`. The frame may be
/// up to one pixel larger than the image in each direction (even padding); the last column and
/// row are replicated into it.
void ConvertBgraToI420(const uint8_t* bgra, int stride, int width, int height, PixelRect rect,
                       I420Frame* frame);

/// Converts one I420 pixel back to RGB (tests and diagnostics).
void I420PixelToRgb(const I420Frame& frame, int x, int y, uint8_t rgb[3]);

}  // namespace rb
