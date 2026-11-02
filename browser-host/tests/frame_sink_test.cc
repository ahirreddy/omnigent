#include "core/frame_sink.h"
#include "test.h"

namespace {

std::vector<uint8_t> Fill(int width, int height, uint8_t value) {
  return std::vector<uint8_t>(static_cast<size_t>(width) * height * 4, value);
}

}  // namespace

TEST(FrameSinkAccumulatesDirtyRectsAndClearsOnTake) {
  rb::FrameSink sink;
  sink.Resize(64, 32);
  rb::I420Frame frame;
  uint64_t capture = 0;
  CHECK_EQ(sink.TakeFrame(&frame, &capture), 64LL * 32);
  CHECK(!sink.HasDamage());
  const std::vector<uint8_t> black = Fill(64, 32, 0);
  sink.PaintView({{4, 4, 8, 8}}, black.data(), 64, 32);
  CHECK(sink.HasDamage());
  CHECK(sink.HasContent());
  CHECK_EQ(sink.TakeFrame(&frame, &capture), 64LL);
  CHECK_EQ(frame.y()[4 * 64 + 4], 16);     // Painted black.
  CHECK_EQ(frame.y()[20 * 64 + 40], 235);  // Untouched white.
}

TEST(FrameSinkComposesThePopupAndRestoresOnHide) {
  rb::FrameSink sink;
  sink.Resize(32, 32);
  const std::vector<uint8_t> white = Fill(32, 32, 255);
  sink.PaintView({{0, 0, 32, 32}}, white.data(), 32, 32);
  sink.SetPopupRect({8, 8, 4, 4});
  sink.SetPopupVisible(true);
  const std::vector<uint8_t> black = Fill(4, 4, 0);
  sink.PaintPopup(black.data(), 4, 4);
  std::vector<uint8_t> canvas;
  int width = 0;
  int height = 0;
  sink.CopyCanvas(&canvas, &width, &height);
  CHECK_EQ(canvas[(9 * 32 + 9) * 4], 0);
  CHECK_EQ(canvas[(20 * 32 + 20) * 4], 255);
  sink.SetPopupVisible(false);
  sink.CopyCanvas(&canvas, &width, &height);
  CHECK_EQ(canvas[(9 * 32 + 9) * 4], 255);
}

TEST(FrameSinkIgnoresPaintsFromBeforeAResize) {
  rb::FrameSink sink;
  sink.Resize(16, 16);
  rb::I420Frame frame;
  uint64_t capture = 0;
  sink.TakeFrame(&frame, &capture);
  const std::vector<uint8_t> stale = Fill(8, 8, 0);
  sink.PaintView({{0, 0, 8, 8}}, stale.data(), 8, 8);
  CHECK(!sink.HasDamage());
}
