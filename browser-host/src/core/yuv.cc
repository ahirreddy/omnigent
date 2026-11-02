#include "core/yuv.h"

#include <algorithm>

namespace rb {

namespace {

// BT.709 limited range, coefficients scaled by 256.
constexpr int kYr = 47, kYg = 157, kYb = 16;
constexpr int kUr = -26, kUg = -87, kUb = 113;
constexpr int kVr = 112, kVg = -102, kVb = -10;

inline uint8_t Clamp(int value) { return static_cast<uint8_t>(std::clamp(value, 0, 255)); }

}  // namespace

void I420Frame::Resize(int width, int height) {
  width_ = (width + 1) & ~1;
  height_ = (height + 1) & ~1;
  const size_t luma = static_cast<size_t>(width_) * height_;
  data_.assign(luma + luma / 2, 0);
  std::fill(data_.begin() + static_cast<std::ptrdiff_t>(luma), data_.end(), 128);
}

void ConvertBgraToI420(const uint8_t* bgra, int stride, int width, int height, PixelRect rect,
                       I420Frame* frame) {
  const PixelRect bounds{0, 0, frame->width(), frame->height()};
  rect = rect.AlignedToEven(bounds);
  if (rect.empty() || width <= 0 || height <= 0) {
    return;
  }
  const int frame_width = frame->width();
  const int chroma_width = frame_width / 2;
  uint8_t* y_plane = frame->y();
  uint8_t* u_plane = frame->u();
  uint8_t* v_plane = frame->v();
  // The fast path covers pixels whose 2x2 block lies inside the image; padding replicates.
  for (int row = rect.y; row < rect.bottom(); row += 2) {
    const int row0 = std::min(row, height - 1);
    const int row1 = std::min(row + 1, height - 1);
    const uint8_t* line0 = bgra + static_cast<size_t>(row0) * stride;
    const uint8_t* line1 = bgra + static_cast<size_t>(row1) * stride;
    uint8_t* y0 = y_plane + static_cast<size_t>(row) * frame_width;
    uint8_t* y1 = y0 + frame_width;
    uint8_t* u_out = u_plane + static_cast<size_t>(row / 2) * chroma_width;
    uint8_t* v_out = v_plane + static_cast<size_t>(row / 2) * chroma_width;
    const int fast_end = std::min(rect.right(), width & ~1);
    int column = rect.x;
    for (; column < fast_end; column += 2) {
      const uint8_t* p00 = line0 + column * 4;
      const uint8_t* p01 = p00 + 4;
      const uint8_t* p10 = line1 + column * 4;
      const uint8_t* p11 = p10 + 4;
      y0[column] =
          static_cast<uint8_t>(((kYr * p00[2] + kYg * p00[1] + kYb * p00[0] + 128) >> 8) + 16);
      y0[column + 1] =
          static_cast<uint8_t>(((kYr * p01[2] + kYg * p01[1] + kYb * p01[0] + 128) >> 8) + 16);
      y1[column] =
          static_cast<uint8_t>(((kYr * p10[2] + kYg * p10[1] + kYb * p10[0] + 128) >> 8) + 16);
      y1[column + 1] =
          static_cast<uint8_t>(((kYr * p11[2] + kYg * p11[1] + kYb * p11[0] + 128) >> 8) + 16);
      const int red = p00[2] + p01[2] + p10[2] + p11[2];
      const int green = p00[1] + p01[1] + p10[1] + p11[1];
      const int blue = p00[0] + p01[0] + p10[0] + p11[0];
      u_out[column / 2] =
          static_cast<uint8_t>(((kUr * red + kUg * green + kUb * blue + 512) >> 10) + 128);
      v_out[column / 2] =
          static_cast<uint8_t>(((kVr * red + kVg * green + kVb * blue + 512) >> 10) + 128);
    }
    for (; column < rect.right(); column += 2) {
      const int column0 = std::min(column, width - 1);
      const int column1 = std::min(column + 1, width - 1);
      const uint8_t* pixels[4] = {line0 + column0 * 4, line0 + column1 * 4, line1 + column0 * 4,
                                  line1 + column1 * 4};
      uint8_t* outputs[4] = {y0 + column, y0 + column + 1, y1 + column, y1 + column + 1};
      int red = 0;
      int green = 0;
      int blue = 0;
      for (int index = 0; index < 4; ++index) {
        const uint8_t* pixel = pixels[index];
        *outputs[index] = static_cast<uint8_t>(
            ((kYr * pixel[2] + kYg * pixel[1] + kYb * pixel[0] + 128) >> 8) + 16);
        red += pixel[2];
        green += pixel[1];
        blue += pixel[0];
      }
      u_out[column / 2] =
          static_cast<uint8_t>(((kUr * red + kUg * green + kUb * blue + 512) >> 10) + 128);
      v_out[column / 2] =
          static_cast<uint8_t>(((kVr * red + kVg * green + kVb * blue + 512) >> 10) + 128);
    }
  }
}

void I420PixelToRgb(const I420Frame& frame, int x, int y, uint8_t rgb[3]) {
  const int luma = frame.y()[static_cast<size_t>(y) * frame.width() + x] - 16;
  const size_t chroma_index = static_cast<size_t>(y / 2) * (frame.width() / 2) + x / 2;
  const int cb = frame.u()[chroma_index] - 128;
  const int cr = frame.v()[chroma_index] - 128;
  // BT.709 limited-range inverse, scaled by 256.
  rgb[0] = Clamp((298 * luma + 459 * cr + 128) >> 8);
  rgb[1] = Clamp((298 * luma - 55 * cb - 136 * cr + 128) >> 8);
  rgb[2] = Clamp((298 * luma + 541 * cb + 128) >> 8);
}

}  // namespace rb
