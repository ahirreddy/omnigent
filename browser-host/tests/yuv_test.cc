#include <cstdlib>

#include "core/yuv.h"
#include "test.h"

namespace {

std::vector<uint8_t> Solid(int width, int height, uint8_t red, uint8_t green, uint8_t blue) {
  std::vector<uint8_t> bgra(static_cast<size_t>(width) * height * 4);
  for (size_t index = 0; index < bgra.size(); index += 4) {
    bgra[index] = blue;
    bgra[index + 1] = green;
    bgra[index + 2] = red;
    bgra[index + 3] = 255;
  }
  return bgra;
}

}  // namespace

TEST(YuvSolidColorsRoundTripWithinTolerance) {
  const uint8_t colors[][3] = {{255, 255, 255}, {0, 0, 0},     {255, 0, 0},
                               {0, 200, 0},     {10, 20, 240}, {128, 128, 128}};
  for (const auto& color : colors) {
    const std::vector<uint8_t> bgra = Solid(8, 6, color[0], color[1], color[2]);
    rb::I420Frame frame;
    frame.Resize(8, 6);
    rb::ConvertBgraToI420(bgra.data(), 8 * 4, 8, 6, {0, 0, 8, 6}, &frame);
    uint8_t rgb[3];
    rb::I420PixelToRgb(frame, 3, 3, rgb);
    for (int channel = 0; channel < 3; ++channel) {
      CHECK_MSG(std::abs(rgb[channel] - color[channel]) <= 4,
                "channel " + std::to_string(channel) + " " + std::to_string(rgb[channel]) + " vs " +
                    std::to_string(color[channel]));
    }
  }
}

TEST(YuvWhiteAndBlackHitLimitedRange) {
  const std::vector<uint8_t> white = Solid(2, 2, 255, 255, 255);
  rb::I420Frame frame;
  frame.Resize(2, 2);
  rb::ConvertBgraToI420(white.data(), 8, 2, 2, {0, 0, 2, 2}, &frame);
  CHECK_EQ(frame.y()[0], 235);
  CHECK_EQ(frame.u()[0], 128);
  CHECK_EQ(frame.v()[0], 128);
  const std::vector<uint8_t> black = Solid(2, 2, 0, 0, 0);
  rb::ConvertBgraToI420(black.data(), 8, 2, 2, {0, 0, 2, 2}, &frame);
  CHECK_EQ(frame.y()[0], 16);
}

TEST(YuvOddSizesPadByReplicatingEdges) {
  const std::vector<uint8_t> red = Solid(5, 3, 255, 0, 0);
  rb::I420Frame frame;
  frame.Resize(5, 3);
  CHECK_EQ(frame.width(), 6);
  CHECK_EQ(frame.height(), 4);
  rb::ConvertBgraToI420(red.data(), 5 * 4, 5, 3, {0, 0, 6, 4}, &frame);
  uint8_t rgb[3];
  rb::I420PixelToRgb(frame, 5, 3, rgb);
  CHECK(rgb[0] > 240 && rgb[1] < 15);
}

TEST(YuvRectConversionTouchesOnlyTheRect) {
  const std::vector<uint8_t> white = Solid(16, 16, 255, 255, 255);
  rb::I420Frame frame;
  frame.Resize(16, 16);
  rb::ConvertBgraToI420(white.data(), 64, 16, 16, {3, 3, 2, 2}, &frame);
  CHECK_EQ(frame.y()[2 * 16 + 2], 235);  // Grown to the even block at (2,2).
  CHECK_EQ(frame.y()[5 * 16 + 5], 235);
  CHECK_EQ(frame.y()[0], 0);
  CHECK_EQ(frame.y()[8 * 16 + 8], 0);
}
