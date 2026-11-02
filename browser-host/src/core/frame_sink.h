// FrameSink keeps the tab's composited BGRA canvas: the page layer from CEF OnPaint(PET_VIEW)
// with the popup layer (select dropdowns, PET_POPUP) drawn on top, plus the damage accumulated
// since the encoder last took a frame. Written on the CEF UI thread, read by the encoder thread.
#pragma once

#include <cstdint>
#include <mutex>
#include <vector>

#include "core/geometry.h"
#include "core/yuv.h"

namespace rb {

class FrameSink {
 public:
  /// Sets the canvas size in device pixels. Clears content and marks everything damaged.
  void Resize(int width, int height);

  /// Applies a page paint. `buffer` is the full BGRA view (width x height, stride width*4).
  void PaintView(const std::vector<PixelRect>& dirty, const void* buffer, int width, int height);
  /// Applies a popup paint (the whole popup widget).
  void PaintPopup(const void* buffer, int width, int height);
  void SetPopupVisible(bool visible);
  void SetPopupRect(const PixelRect& rect);

  /// Marks the whole canvas damaged (keyframes, new viewers).
  void DamageAll();
  bool HasDamage() const;
  bool HasContent() const;
  int width() const;
  int height() const;
  /// Monotonic microseconds of the newest paint (the capture time of the next frame).
  uint64_t last_paint_us() const;

  /// Converts the damaged regions into `frame` (resizing it to the canvas when needed, which
  /// converts everything) and clears the damage. Returns the damaged area in pixels.
  long long TakeFrame(I420Frame* frame, uint64_t* capture_us);
  /// Copies the composited canvas (for recordings, stills and tests).
  void CopyCanvas(std::vector<uint8_t>* bgra, int* width, int* height) const;

 private:
  void ComposeLocked(const PixelRect& rect);

  mutable std::mutex mutex_;
  int width_ = 0;
  int height_ = 0;
  std::vector<uint8_t> view_;
  std::vector<uint8_t> canvas_;
  std::vector<uint8_t> popup_;
  PixelRect popup_rect_;
  int popup_width_ = 0;
  int popup_height_ = 0;
  bool popup_visible_ = false;
  bool has_content_ = false;
  Damage damage_;
  uint64_t last_paint_us_ = 0;
};

uint64_t MonotonicMicros();

}  // namespace rb
